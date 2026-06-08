# Guild — Balance Pass (placeholder-number tuning) — Design Spec

**Status:** approved 2026-06-08. Branch `feat/balance-pass` off `main` (`2565b9e`).
**Relationship to prior plans:** the **playtest-informed numeric balance pass** the Plan-5 / cleaning-phase specs deferred ("to a later, playtest-informed session"). It is a **deliberate behavior change** to the PLAYTEST-PLACEHOLDER tunables in `packages/sim/lib/src/data/{combat,elements}.dart` — it touches **no mechanics, no code paths, no byte layout** — only constant values. It is the first half of the post-animation roadmap step (the second half, keyboard skill-bind + aiming-mode controls, is a separate client-only spec to follow).

**Predecessor docs:** game spec `docs/superpowers/specs/2026-06-06-elemental-moba-design.md`; plans `…/plans/2026-06-07-plan-3-combat.md`, `2026-06-07-plan-4-elemental.md`, `2026-06-07-plan-5-elemental-v2.md`, `2026-06-07-plan-6-respawn-standstill.md`, `2026-06-08-cleaning-phase.md`. The constants live in `packages/sim/lib/src/data/combat.dart` and `…/elements.dart` (both flagged PLAYTEST PLACEHOLDERS in-code).

---

## 0. The headline — DELIBERATE GOLDEN MOVE (not golden-neutral)

Unlike the animation/art phase, this phase **intentionally changes simulation behavior**, so it makes **sanctioned golden re-pins**. The rules:

- **Two goldens re-pin:** `combat.golden` (currently `910ddcfc`) and `elemental.golden` (currently `8d7fbe1b`). **`smoke.golden` (`7e4aa28f`) and the in-test anchor `0x0fbfb7ac` MUST NOT move** — both are *move-only* fixtures (no combat, no creeps in-window, no elemental), so no tunable in this phase touches them. If either moves, a change leaked beyond its intended fixture and must be investigated.
- **No byte-layout change, no version bump.** Every change is a constant *value*; the wire format, entity field set, and `_entityBodyCodecs` order are untouched. `kSchemaVersion`/`kSnapshotVersion` stay **3/3**.
- **Re-pin procedure (never hand-typed):** for each moved golden, prove byte-identical native / dart2js / dart2wasm via `bash tooling/compare_replays.sh tooling/replay_fixtures/<fixture>.json`, then regenerate the `.golden` from harness output. Change one *attribution group* at a time and verify exactly the expected golden(s) moved (and the others did not) **before** re-pinning — clean attribution, per the Plan-6 re-pin discipline.

Determinism rules unchanged (enforced on every change): **`Fixed` (Q16.16) + `int` only**; all new values obey the Fixed budget `|value| < 32768`; **no** `dart:math`/`Random`/`DateTime`/`Stopwatch` in `packages/sim/lib`; **no new RNG draw** (the phase-5 wanderer draw is untouched); enums append-only (none touched); the 5-phase `step()` order is untouched. The amplify constraint holds: `kCastBurstDamage × kVaporizeMult` must stay in the Fixed budget (`16 × 1.3 = 20.8` ✓).

---

## 1. The changes (4 attribution groups)

Each row is `const`: current value → new value, with the rationale and the golden it moves. Tick rate is 30/s.

### Group 1 — Lane geometry: make the center safe to farm (`combat.dart`)

The enemy outer tower (`kOuterTowerX = ±4`, `kTowerAttackRange = 6`) reaches lane center (x=0) where creeps spawn, so a hero advancing to last-hit sits in enemy tower fire. Push the throat up the lane and shorten tower reach so center clears the enemy outer tower by ~1 unit.

| Const | Now | New | Note |
|---|---|---|---|
| `kOuterTowerX` | `Fixed.fromInt(4)` | `Fixed.fromInt(6)` | team0 −6 / team1 +6 |
| `kTowerAttackRange` | `Fixed.fromNum(6)` | `Fixed.fromNum(5)` | display/reference |
| `kTowerAttackRangeSq` | `Fixed.fromNum(6 * 6)` | `Fixed.fromNum(5 * 5)` | **the actual gate** (lengthSq compare) — MUST change in lockstep with the line above |

Result: enemy outer tower reaches only to x=±1; the center clash (x=0) and a hero standing anywhere on its own side to last-hit it (hero range 3 lets it hit x=0 from x=−1.5, distance 7.5 > 5 to the +6 tower) take no tower fire. Inner (`±10`) + core (`±14`) + hero spawn (`±8`) unchanged and still well-defended (inner range 5 covers the base mouth; diving the enemy throat at ±6 still draws outer+inner fire). **Moves `combat.golden`** (heroes fight at center in `combat.json`, where they currently *are* in old enemy-tower range).

### Group 2 — Creep last-hit: snappier (`combat.dart`)

A 60-hp creep takes ~5 s of hero autos to kill — too slow for last-hit feel.

| Const | Now | New | Note |
|---|---|---|---|
| `kCreepMaxHp` | `Fixed.fromInt(60)` | `Fixed.fromInt(40)` | 4 autos (≈2.4 s) at the new hero damage |

Wave cadence (`kFirstWaveTick = 450`, `kWaveIntervalTicks = 900`) and `kCreepGold = 18` unchanged. **Moves `combat.golden`** — `combat.json` runs 500 ticks and the first wave spawns at 450, so creep entities (hp = maxHp = 40 vs 60) are in the canonical state hash for ticks 450–499 even if none is killed in-window.

### Group 3 — Combat pacing / TTK: decisive duels (`combat.dart`)

| Const | Now | New | Note |
|---|---|---|---|
| `kHeroAttackDamage` | `Fixed.fromNum(8)` | `Fixed.fromNum(10)` | hero-vs-hero ≈ 6 s of pure attacking (was 7.5 s); also speeds creep clears |

Hero hp (100), attack cooldown (18 ticks / 0.6 s), attack range (3), and respawn (150 ticks / 5 s) unchanged — the duel stays "decisive but not instant." **Moves `combat.golden`** (heroes trade autos in `combat.json`).

### Group 4 — Elemental: make the ability hit like an ability (`elements.dart`)

Cast-burst 10 (≈13 Vaporize-amplified) and flat-reaction 8 are barely an auto-attack's worth on an 8 s cooldown.

| Const | Now | New | Note |
|---|---|---|---|
| `kCastBurstDamage` | `Fixed.fromNum(10)` | `Fixed.fromNum(16)` | ≈21 when Vaporize-amplified ×1.3 — a real burst (~2 autos). `16 × 1.3 = 20.8` ✓ Fixed budget |
| `kReactionFlatDamage` | `Fixed.fromNum(8)` | `Fixed.fromNum(12)` | field-overlap reaction now a bit above one auto |

`kVaporizeMult` (1.3), `kStatusDurationTicks` (45 / 1.5 s), `kReactionIcdTicks` (15 / 0.5 s), `kFieldRadius`/`kFieldRadiusSq` (2.5 / 6.25), `kFieldDurationTicks` (120 / 4 s), `kAbilityCooldownTicks` (240 / 8 s) unchanged. **Moves `elemental.golden`** (`elemental.json` casts + reacts). Does **not** touch `combat.golden` (`combat.json` issues no ability casts).

---

## 2. Determinism / re-pin scope

| Golden | Moves? | Driven by |
|---|---|---|
| `smoke.golden` `7e4aa28f` | **NO** | move-only fixture; no tunable here applies — assert unchanged |
| in-test anchor `0x0fbfb7ac` | **NO** | move-only — assert unchanged |
| `combat.golden` `910ddcfc` | **YES** | Groups 1–3 (tower geometry/range, creep hp, hero damage) |
| `elemental.golden` `8d7fbe1b` | **YES** | Group 4 (cast-burst, flat-reaction) |

- **Attribution:** apply the combat groups (1–3) → run all three fixtures + the anchor → confirm **only `combat.golden`** changed (smoke + elemental + anchor byte-identical) → re-pin `combat.golden` cross-runtime. Then apply Group 4 → confirm **only `elemental.golden`** changed → re-pin `elemental.golden` cross-runtime.
- **No byte layout / version change** (3/3). The codec list, header, and entity field set are untouched — only the *values* read into existing `Fixed`/`int` fields differ.
- Determinism rules per §0; no new RNG draw, no `dart:math`, Fixed budget respected.

---

## 3. Scope

**IN:** retune the placeholder constants in `data/combat.dart` (`kOuterTowerX` 4→6, `kTowerAttackRange`/`Sq` 6→5/36→25, `kCreepMaxHp` 60→40, `kHeroAttackDamage` 8→10) and `data/elements.dart` (`kCastBurstDamage` 10→16, `kReactionFlatDamage` 8→12); refresh the inline comments (these are now playtest-tuned, not raw placeholders; keep the `// spec §…` target breadcrumbs); re-pin `combat.golden` + `elemental.golden` cross-runtime with clean attribution; full determinism + cross-runtime sweep.

**OUT:** any mechanic / code-path / phase-order change; any new constant, entity field, enum, or `SimEvent`; any byte-layout or version bump; any change to hero hp/cooldown/range, respawn timing, wave cadence, gold values, field radius/duration, ability cooldown, status/ICD timing, or `kVaporizeMult` (kept this pass — revisit only if a follow-up playtest shows the new burst is too swingy); `smoke.golden` / the anchor (must stay); any client/render change (`apps/client` untouched); the keyboard skill-bind + aiming-mode controls (the separate next cycle); the respawn-render-delay item.

---

## 4. Tests & verification (evidence-first)

- **Existing sim tests are the spec for *mechanics*** — every test in `packages/sim/test` that does not assert a specific damaged-hp / kill-timing value must stay green unchanged; tests that encode the *old* numbers (if any assert exact hp after N hits, exact creep-death tick, or exact reaction damage) are updated to the new values as part of the change that moves them, and the update is called out.
- **Golden attribution gate (per group set):** after the combat changes — `bash tooling/compare_replays.sh tooling/replay_fixtures/{smoke,combat,elemental}.json` shows `smoke` + `elemental` byte-identical AND golden-matched, `combat` byte-identical across runtimes but golden-mismatched (the sanctioned move); the `0x0fbfb7ac` anchor test still passes. Re-pin `combat.golden`. Repeat for Group 4 → `elemental.golden`.
- **Re-pin mechanics:** regenerate each moved `.golden` from harness output after proving cross-runtime byte-identity — never hand-type a hash.
- **Full mirror-CI sweep:** `dart analyze --fatal-infos --fatal-warnings packages apps/server tooling`; `tooling/check_no_banned_imports.sh`; sim + protocol + netcode + server `dart test`; the three replay compares (post-re-pin: all four hashes match the new pins); `flutter analyze` + `flutter test` (apps/client — unchanged, must stay green); cross-runtime sim + netcode (node + dart2wasm).
- **Sanity numbers to eyeball post-change:** creep dies in 4 autos; hero-vs-hero ~6 s pure; a hero last-hitting at center takes no tower fire; a Vaporize-amplified cast-burst does ≈21.

---

## 5. Task plan (2 tasks, attribution-clean)

1. **Combat retune (Groups 1–3) + re-pin `combat.golden`.** Edit `combat.dart` (`kOuterTowerX`, `kTowerAttackRange`, `kTowerAttackRangeSq`, `kCreepMaxHp`, `kHeroAttackDamage`) + comments; update any sim test that asserts an old combat number; verify smoke + elemental + anchor unchanged, combat moves cross-runtime-cleanly; re-pin `combat.golden`.
2. **Elemental retune (Group 4) + re-pin `elemental.golden`.** Edit `elements.dart` (`kCastBurstDamage`, `kReactionFlatDamage`) + comments; update any sim test that asserts an old elemental-damage number; verify smoke + combat + anchor unchanged, elemental moves cross-runtime-cleanly; re-pin `elemental.golden`.

Order rationale: combat and elemental move disjoint goldens, so either order works; doing combat first keeps the two re-pins independent and each task's attribution check is "exactly one golden moved." Final full sweep after both.

---

## 6. Open implementation details to resolve in the plan

- **Which sim tests encode the old numbers?** Grep `packages/sim/test` for literals (`60`, `8`, `10`, tower range/positions) and exact post-hit hp / kill-tick / reaction-damage assertions; the plan enumerates each and updates it in lockstep with the constant that moves it (so a test failure is the *intended* number change, not a regression). Tests asserting *mechanics* (a creep dies eventually, a reaction fires, a hero respawns) need no value edit.
- **`kTowerAttackRange` vs `kTowerAttackRangeSq` usage:** confirm the targeting gate compares `lengthSq` vs `…RangeSq` (so the squared value is load-bearing) and that the non-squared `kTowerAttackRange` is reference-only; update both regardless to stay consistent.
- **Re-pin regeneration command:** confirm the exact harness invocation that emits a fresh `.golden` (per `tooling/`), and that it is run from the native runtime after `compare_replays.sh` proves js/wasm parity.
- **Comment policy:** keep each constant's `// spec §…` target breadcrumb; change the surrounding "PLAYTEST PLACEHOLDER" framing to note the value is now playtest-tuned (2026-06-08) while remaining open to a future pass.
- **Does any creep get last-hit inside `combat.json`'s 450–499 window?** Determine whether the combat re-pin reflects only creep *presence* (hp in state) or an actual creep death; either way the re-pin captures it, but the plan should note the expectation so the new hash is sanity-checkable.
