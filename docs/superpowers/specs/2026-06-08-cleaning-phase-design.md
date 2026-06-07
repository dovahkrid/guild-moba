# Guild — Cleaning / Refactor Phase — Design Spec

**Status:** approved 2026-06-08. Branch `cleaning-phase` off `main` (`6f4d360`).
**Relationship to prior plans:** a **structural** refactor on top of Plans 1–6 (all merged). It adds **no gameplay** and changes **no behavior**; it reorganizes code and a test harness so Plans 7 (XP/shop), 8 (hero kits + more reactions), and 9 (Revenge Boss) are easier to build. The codebase is otherwise clean (no TODO/FIXME/HACK debt) — this is structural, not debt cleanup.

**Predecessor docs:** game spec `docs/superpowers/specs/2026-06-06-elemental-moba-design.md`; plans `docs/superpowers/plans/2026-06-06-plan-1-foundation.md`, `2026-06-06-plan-2a-netcode-core.md`, `2026-06-06-plan-2b-netcode-wiring.md`, `2026-06-07-plan-3-combat.md`, `2026-06-07-plan-4-elemental.md`, `2026-06-07-plan-5-elemental-v2.md`, `2026-06-07-plan-6-respawn-standstill.md`.

---

## 0. The headline invariant — GOLDEN-NEUTRAL

Every task in this phase is a pure structural refactor with **zero behavior change**. The safety net that proves it:

- The replay goldens **`smoke 7e4aa28f`**, **`combat 910ddcfc`**, **`elemental 8d7fbe1b`** and the in-test canonical anchor **`0x0fbfb7ac`** (`packages/sim/test/snapshot_test.dart`) **MUST NOT MOVE** — on any task.
- Snapshot/canonical serialization stays **byte-identical** across native / dart2js / dart2wasm. **No `kSchemaVersion`/`kSnapshotVersion` bump** (both stay **3/3**). A cleaning phase does not touch the wire/byte layout.
- This phase makes **no sanctioned golden move at all.** (The Plan-5 numeric balance pass was considered but is **deferred** to a later, playtest-informed session — see §4 — so there is no allowed exception this phase. If any golden or the anchor moves, a task changed behavior and must be reverted/fixed.)

Determinism rules unchanged (enforced on every implementer): `Fixed` (Q16.16) + `int` only; **no** `dart:math` / `Random(` / `DateTime` / `Stopwatch` in `packages/sim/lib`; preserve the 5-phase `step()` order (it is determinism-load-bearing); iterate `entityIdsSorted` / stable lists; **no new RNG draw**; enums are **append-only**. Do **not** remove the forward-scaffolding `SimEvent`s (`BossSpawned`, `LevelUp`) or the `TowerDestroyed{killerId}` boss hook — reserved for Plans 8/9.

---

## 1. Target 1 — split `packages/sim/lib/src/simulation.dart` (714 lines)

`simulation.dart` is the only oversized file (next is `match_controller.dart` at 255; everything else ≤143). It currently holds: entity setup, the 5 step-phases, all combat, all elemental fields, respawn, and the binary serialization. Plans 8 & 9 will pile combat + elemental + spawning onto it. Split it by concern **now**.

### 1.1 Mechanism — Dart `part` / `part of` files with `extension … on Simulation`

A single class body cannot be split across files in Dart, but the **library** can. Each concern becomes a `part of 'simulation.dart'` file declaring an `extension … on Simulation`. Because parts share one library, the extensions retain full access to `Simulation`'s private fields/methods (`_entities`, `_byId`, `_rng`, `_fields`, `_lastDamager`, `_winnerTeam`, `_applyDamage`, …) and to library-private top-level constants (`_kHeroStep`, etc.) — **zero behavior change, zero public-API change**.

**Verified by throwaway compile @ this session:** a *private* extension method in a part file is callable from the main class body and from other parts; unqualified private-field access inside extension methods works; `dart analyze` is clean. (Mutual cross-part private calls — combat ↔ elemental, e.g. `_stepCombat`→`_stepFields`, `_castBurst`→`_applyHit`, `_stepFields`→`_applyDamage` — all resolve, since names are unique and the library is shared.)

### 1.2 File layout (1 main + 4 parts)

- **`simulation.dart`** (main library file; owns **all imports** and the `part` directives):
  - The `Simulation` class declaration: all instance fields; `Simulation._` and `Simulation.create` (a **factory** — must live in the class body); accessors (`entityIdsSorted`, `entity`, `winnerTeam`, `fields`); the whole **5-phase `step()`** (kept intact and front-and-center — the phase order is load-bearing); `_stepToward`.
  - The **static `peekEntityPos`** stays in the class body. Statics cannot be added via an extension and called as `Simulation.peekEntityPos`; it is the only externally-used static (`netcode/match_controller`), so keeping it on the class is **zero public-API change**. Its body delegates to the shared field-descriptor list from §2 (kept byte-aligned with the writers).
  - Top-level constants stay here (`kSchemaVersion`, `kSnapshotVersion`, `kWandererEntityId`, `_kHeroStep`, `_kWanderStep`).
- **`simulation_combat.dart`** — `extension SimulationCombat on Simulation`: `_stepCombat`, `_sweepDeadStructures`, `_sweepDeadHeroes`, `_sweepDeadCreeps`, `_creditGold`, `_heroSpawnX`, `_isInnerTower`, `_acquireTowerTarget`, `isStructureVulnerable`, `_removeEntity`, `_lastDamagerOf`, `_isAttackable`, `_applyDamage`, `_applyHit`.
- **`simulation_elemental.dart`** — `extension SimulationElemental on Simulation`: `_stepFields`, `_castBurst`. (Plan 8 grows this.)
- **`simulation_spawning.dart`** — `extension SimulationSpawning on Simulation`: `_maybeSpawnWave`. (Small now; the natural home for Plan 9's boss spawn and future wave logic. `create()`'s initial entity setup stays in the class as a factory.)
- **`simulation_serialization.dart`** — `extension SimulationSerialization on Simulation`: `canonicalBytes`, `canonicalStateHash`, `snapshotBytes`, `restoreFromSnapshot`, plus the §2 field-descriptor list (the single source of truth).

Result: `simulation.dart` drops from 714 to ~160 lines; the largest part (combat) is ~200. No test file needs to change — the library's public + library-private surface is unchanged.

---

## 2. Target 2 — DRY the snapshot serialization (single source of truth)

Today `snapshotBytes`, `canonicalBytes`, `restoreFromSnapshot`, and `peekEntityPos` each hand-read/write the per-Entity fields in **four parallel lockstep sites**. Adding a serialized field (Plan 7: XP/level/items) is a 4-in-sync edit that is easy to desync. Replace with **one ordered field-descriptor list**.

### 2.1 Design

A list of typed **field codecs**, one per serialized Entity *body* field, in exact wire order. Each codec knows: how to **write** it (from an `Entity` to a `ByteWriter`), how to **read+apply** it (from a `ByteReader` onto an `Entity`), and how to **read** it bare (return the value, for `peekEntityPos`'s skip path). A `snapshotOnly` flag marks `target` (present in `snapshotBytes`/`restoreFromSnapshot`, absent from `canonicalBytes`).

Codec variants cover only the widths the per-Entity body actually uses: `i32`, `fixed` (one i32), and `fvec2` (two i32 = x,y). The header's `u32` rng limbs are **not** part of the codec list — the header (version/tick/rng/winnerTeam/count) stays an inline shared helper. The body fields, in current order:

```
pos(fvec2), vel(fvec2), hp(fixed), maxHp(fixed), attackCooldown(i32), gold(i32),
respawnTimer(i32), attackTargetId(i32), statusElement(i32), statusTimer(i32),
reactionIcd(i32), abilityCooldown(i32), target(fvec2, snapshotOnly)
```

The **identity prefix** `id, kind, teamId` is **not** in the codec list — it is read first (to find-or-create the entity by id) and written first, exactly as today. It stays explicit in each method.

### 2.2 How each site uses the list (emitted bytes provably identical)

- **`canonicalBytes`**: header (`kSchemaVersion`, tick, rng lo/hi, winnerTeam, count) → per entity: write id/kind/team, then `for codec where !snapshotOnly: codec.write` → fields trailer.
- **`snapshotBytes`**: header (`kSnapshotVersion`, …) → per entity: write id/kind/team, then `for codec (all): codec.write` → fields trailer.
- **`restoreFromSnapshot`**: header → per entity: read id/kind/team; find `_byId[id]`, else construct with **placeholder** pos/hp/maxHp (immediately overwritten); then `for codec (all): codec.readInto(entity)`; track `seen`; drop absent → fields trailer.
- **`peekEntityPos`** (static, in main): header → per entity: read id/kind/team; `for codec (all): v = codec.read(r)`, capture the `pos` codec's value; return it when `id` matches; else continue. (Reads the full record so the offset advances correctly; no `Entity` allocated.)

The header and the fields trailer (`ownerId, center.x, center.y, element, timer`) are identical across `canonical`/`snapshot`, so they become two tiny shared helpers (or stay inline) — the duplication that matters is the per-entity body, which the codec list eliminates.

**Plan-7 add-a-field = one codec row** (plus `snapshotOnly` if wire-only). Byte-identity is proven by the goldens + the `0x0fbfb7ac` anchor + the `snapshot_test.dart` round-trip tests + cross-runtime `compare_replays.sh`.

### 2.3 Determinism notes

The codec list is a single shared `const`/`final` library-private top-level (e.g. `_entityBodyCodecs`) — built once, iterated in list order (deterministic). Codecs contain only plain getters/setters and `ByteWriter`/`ByteReader` calls; no RNG, no floats. No new allocation in the hot serialize path beyond what exists.

---

## 3. Target 3 — FakeTransport faithful mirror (close the Plan-6 gap)

`packages/netcode/lib/test_support/fake_transport.dart` runs a real server `Simulation` against a real `MatchController`, but its fake-server intent handling is a single per-slot `_serverHeld[slot]` that:

1. **does not model the downed-input drop** (real `Match.addPlayer` ignores an `InputMsg` for a slot whose hero `isDowned`), and
2. **does not model `clearSlot` on death** (real `Match._tick` clears the held order on a `HeroDowned` event), and
3. **re-feeds *every* intent type every tick** — including abilities, which the real `IntentBuffer` treats as **one-shot** (drained once). FakeTransport would auto-recast an ability every tick.

So a `FakeTransport`-based integration test cannot reproduce respawn/death divergence — exactly the gap the Plan-6 whole-branch review flagged.

### 3.1 Constraint — no upward dependency

`netcode` must **not** depend on `apps/server` (apps depend on packages, not vice versa). So `IntentBuffer`/`Match` cannot be imported; their *semantics* are **replicated locally** in `test_support` (FakeTransport already replicates a simplified server loop — this makes the replica faithful).

### 3.2 Changes

- Replace the single `_serverHeld[slot]` with a faithful per-slot model: **held** (move/attack, persistent, last-writer-wins, seq-deduped) + **one-shot pending ability** (drained once per tick). Mirrors `IntentBuffer.accept` + `drainForTick`.
- **Downed-input drop:** when delivering a client→server input, drop it (no held/ability update, **no `lastAckedSeq` advance**) if `server.entity(slot).isDowned` at delivery time. Mirrors `Match.addPlayer`'s guard (a dropped input is *not acked*, robust to loss).
- **clearSlot on death:** capture `server.step(...)`'s returned events (currently discarded) and, for each `HeroDowned`, null that slot's held + pending ability. Mirrors `Match._tick`.
- **`opponentSend`** keeps working through the new held model.
- Light tidy of shared test helpers as encountered (keep minimal).

### 3.3 New test (TDD, failing-first)

A `FakeTransport` integration test that **downs the local hero** (e.g. drive it into an enemy tower / set up lethal damage) and issues a move/attack order **in the death-latency window** (client still predicts alive; server already downed → drops the input unacked), then runs past `kHeroRespawnTicks` and asserts: **no rubber-band** after respawn (the hero stands), reconcile correction ≈ 0 / reconcile == fresh-replay, and a fresh post-respawn order moves it. This test must **fail** against today's FakeTransport (which would re-feed the trapped order) and **pass** after the mirror changes — proving the harness now models the gap.

### 3.4 Golden-neutral

All changes are in `netcode/lib/test_support` + `netcode/test`. No `packages/sim/lib` change → goldens/anchor untouched. Existing netcode/server tests must stay green (verify the ability-split + downed-drop do not perturb death-free tests — confirm no current test relies on the old every-tick ability re-feed).

---

## 4. Target 4 — data/comment tidy (light, golden-neutral)

`packages/sim/lib/src/data/combat.dart` + `elements.dart` are the PLAYTEST-PLACEHOLDER tunables. Lowest leverage — keep light:

- Organize/group the constants consistently; a light comment/convention sweep (section headers, units, spec-target inline notes preserved).
- **No value changes.** The Plan-5 numeric balance pass on `kCastBurstDamage` (10) and `kReactionFlatDamage` (8) is **deferred** to a later, playtest-informed session (no playtest data this session to justify specific numbers). Keeping the values fixed keeps this whole phase golden-neutral and attribution clean. The values + their `// spec §…` target notes stay.
- Do not remove or rename live constants in a way that changes any emitted value or the public `sim` API surface (these are exported via the barrel). Pure comment/ordering/grouping changes only.

No behavior change → goldens unchanged.

---

## 5. Determinism / re-pin scope

- **Byte layout UNCHANGED, no version bump** (kSchemaVersion/kSnapshotVersion stay 3/3). Targets 1 & 2 reorganize the serialization code but emit identical bytes; target 3 is test-only; target 4 is comments/ordering.
- **No golden re-pin this phase.** `smoke 7e4aa28f`, `combat 910ddcfc`, `elemental 8d7fbe1b`, anchor `0x0fbfb7ac` — all stay. Any movement = a behavior regression to fix.
- Determinism rules per §0. The wanderer phase-5 RNG draw is untouched; no new RNG draw anywhere.

---

## 6. Scope

**IN:** split `simulation.dart` into 1 main + 4 `part`/`extension` files (combat, elemental, spawning, serialization); DRY the per-Entity serialization behind one field-descriptor list (canonical/snapshot/restore/peek all derive from it); make FakeTransport a faithful server mirror (held + one-shot ability split, downed-input drop, clearSlot-on-`HeroDowned`) + a new failing-first death/respawn integration test; light data/comment tidy of `combat.dart`/`elements.dart`; full determinism + cross-runtime sweep proving golden-neutrality at each step.

**OUT:** any behavior change in `packages/sim/lib`; any byte-layout change / version bump; any protocol/codec change; any numeric balance change (deferred); any new gameplay, entity kind, or `SimEvent`; removing the forward-scaffolding (`BossSpawned`/`LevelUp`/`TowerDestroyed{killerId}`); any client render/input change (`apps/client` untouched); the respawn-render-delay item (separate render/interpolation concern, not in this phase).

---

## 7. Tests & verification (TDD, evidence-first)

For a **refactor**, the existing suite + goldens **are the spec** — they must stay green/unchanged at every step. New tests are added only for target 3.

- **Per task:** relevant `dart test` (sim / netcode / server) all green; `snapshot_test.dart` anchor `0x0fbfb7ac` unchanged; `bash tooling/compare_replays.sh tooling/replay_fixtures/{smoke,combat,elemental}.json` → byte-identical native/js/wasm **and** golden match; `dart analyze --fatal-infos --fatal-warnings packages apps/server tooling` clean; banned-imports clean.
- **Target 3 specifically:** the new death/respawn FakeTransport test is written first and fails against today's harness, then passes after the mirror; existing netcode/server tests stay green.
- **Final mirror-CI sweep:** `dart analyze --fatal-infos --fatal-warnings packages apps/server tooling`; `tooling/check_no_banned_imports.sh`; sim + protocol + netcode + server tests; the 3 replay compares; `flutter analyze` + `flutter test` (apps/client); cross-runtime sim + netcode (node + dart2wasm).

---

## 8. Task plan (7 tasks)

Each task: existing tests + goldens are the spec; **green + byte-identical (goldens + anchor unchanged) + analyze/banned-imports clean** before it is done. Fresh implementer per task; two-stage review (spec-compliance, then code-quality) with fix loops.

1. **Extract combat → `simulation_combat.dart`** (introduces the `part` machinery). Golden-neutral.
2. **Extract elemental → `simulation_elemental.dart`.** Golden-neutral.
3. **Extract spawning → `simulation_spawning.dart`.** Golden-neutral.
4. **Extract serialization → `simulation_serialization.dart`** (move only, no DRY yet). Golden-neutral.
5. **DRY serialization** behind the field-descriptor list (target 2). Byte-identical (goldens/anchor unchanged).
6. **FakeTransport faithful mirror + new death/respawn integration test** (target 3). Golden-neutral.
7. **Data/comment tidy** of `combat.dart`/`elements.dart` (target 4). Golden-neutral.

Order rationale: the four extractions each shrink `simulation.dart` and are independently golden-verified (easy to bisect if a byte ever moves); DRY (5) needs serialization isolated (4) first; FakeTransport (6) and the tidy (7) are independent and could move anywhere. Tasks 1–5 carry the strictest byte-identity burden; 6–7 are test/comment-only.

---

## 9. Open implementation details to resolve in the plan

- **Imports under parts:** all `import`s consolidate into the main `simulation.dart`; parts carry only `part of 'simulation.dart';`. Confirm no unused-import warnings after each extraction (move/trim as files are emptied).
- **Extension naming & visibility:** name each extension (`SimulationCombat`, etc.) to avoid implicit-extension ambiguity and to keep `isStructureVulnerable` (public) callable by importers (extensions in the exported library are auto-available). Confirm no two extensions declare the same member name.
- **`peekEntityPos` ↔ codec list coupling:** peek stays static in the class but must iterate the same `_entityBodyCodecs`; confirm it reads the full per-entity record (offset stays aligned) and returns `pos` for the matched id, `null` otherwise — identical to today.
- **Restore construct-with-placeholder:** confirm constructing an absent entity with placeholder `pos`/`hp`/`maxHp` then applying all body codecs yields identical state to today's read-then-construct path (the codecs overwrite pos/hp/maxHp unconditionally, as the current code already does).
- **Codec typing:** decide the codec representation (sealed class hierarchy vs a single class with a width enum + getter/setter closures). Prefer the simplest that keeps `write`/`readInto`/`read` exhaustive and the list a flat literal.
- **FakeTransport ability-split fidelity:** confirm `drainForTick` order (held then one-shot) and that the sim re-sorts by (slot, seq) so append order is not load-bearing; confirm `lastAckedSeq`/dedupe semantics match `IntentBuffer.accept` (downed-dropped input does not advance the frontier).
- **Golden attribution:** run `compare_replays.sh` (all three fixtures) after **each** of tasks 1–5 to prove the four hashes are unchanged, so any accidental byte move is caught at the task that introduced it.
</content>
</invoke>
