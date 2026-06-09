# Guild — Plan 7 (Part 1): Combat-feel + Controls Completion — Design Spec

**Status:** approved 2026-06-09. Branch `feat/plan7-combat-feel-controls` off `main` (`71bd68e`).

**Relationship to prior work:** the **first sub-plan of "Plan 7"** (roadmap step 2). Plan 7's full scope is four parts — **A** right-click attack-move-to-range, **B** live aim reticle, **C** Q second-skill binding, **D** real hero kits / ults + more reactions. Patrick's decomposition (2026-06-09): **A + B + C ship now as this sub-plan; D is deferred to its own brainstorm→spec→plan.** Q is scaffolded here as a **placeholder ultimate**; D later swaps in the true ult content (Pyre Unchained / Maelstrom) as behavior/data without re-touching byte layout. Predecessors: `docs/superpowers/specs/2026-06-09-controls-and-lane-range-design.md` (which set tower range 5→4, added the `DashedCircle` component, and added the E-cast `SkillInputController` with the *deferred* aim-reticle fallback this spec now completes) and `docs/superpowers/specs/2026-06-08-balance-pass-design.md`.

**Three parts, one spec** (Patrick's call, 2026-06-09):
- **Part A — sim:** right-click attack-move stops at the furthest in-range point instead of overrunning onto the enemy. A pursuit/stop behavior change → re-pins `combat.golden` (and `elemental.golden` only if its fixture exercises attack-lock pursuit) at **schema v3**.
- **Part B — client:** the live cursor aim reticle deferred by the controls pass — a translucent dashed circle tracking the mouse while a skill is armed. Determinism-neutral.
- **Part C — sim + netcode + server + client:** bind **Q** to a **placeholder ultimate** (a stronger/larger field-burst on a long, independent cooldown). Adds one serialized `Entity.ultCooldown` field → the **single sanctioned version bump 3/3 → 4/4** and a **deliberate re-pin of ALL goldens + the `0x0fbfb7ac` anchor**, plus a new `ult` fixture to lock the mechanic cross-runtime.

Part B is entirely `apps/client`. Part A is `packages/sim` behavior only. Part C reaches `packages/sim` (field + intent + byte layout), `packages/netcode`, `apps/server`, and `apps/client`, but **no protocol byte-layout/version change** (the intent `type` already rides the wire as a raw i32).

---

## 0. Motivation

1. **"Right-click an enemy should stop in range, not run onto them."** (Patrick, 2026-06-09 playtest.) Today a locked hero pursues the enemy's exact position and keeps closing while it auto-attacks — it overruns into point-blank instead of holding at attack range. Standard MOBA attack-move stops at the furthest point still in range and fires from there.
2. **"Show me where the skill will land before I click."** The 2026-06-09 controls pass shipped E-cast with **no live aim preview** (a sanctioned fallback): an aim-placed skill (Marisol's Tidepool) arms on E and casts on the next left-click, but the player sees nothing until it lands. A reticle tracking the cursor closes that gap.
3. **"Wire up the second skill (Q)."** Q has been reserved/unbound since the controls pass. Each hero's kit is `auto + ability (E) + ultimate (Q)` (design spec §2/§5); Q is the ult slot. The real ults are Plan 7 **D**; this pass scaffolds the slot end-to-end with a placeholder so the determinism/serialization cost (a new serialized cooldown → version bump) is paid **once, now**, and D fills in content cheaply.

---

## 1. Part A — Attack-move-to-range (sim; sanctioned golden re-pin at v3)

### 1.1 Current behavior (grounded)
`Simulation.step()` phase 2 — pursue (`packages/sim/lib/src/simulation.dart:141-151`):
```dart
for (final e in _entities) {
  if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
  if (e.attackTargetId == -1) continue;
  final tgt = _byId[e.attackTargetId];
  if (tgt == null || !_isAttackable(e, tgt)) {
    e.attackTargetId = -1;
    e.target = e.pos; // hold position
  } else {
    e.target = tgt.pos; // pursue the locked target  <-- always chases onto the enemy
  }
}
```
Phase 3 then steps the hero toward `target` at `_kHeroStep` (0.15/tick); phase-4 combat (`simulation_combat.dart:41-50`) fires when `(tgt.pos - e.pos).lengthSq() <= kHeroAttackRangeSq` (range 3). Because `target` is the enemy's exact position, the hero keeps walking *past* the range boundary down toward distance 0 even while attacking — the overrun.

### 1.2 The fix
In phase-2 pursue, when the locked target is valid **and already within `kHeroAttackRangeSq`**, hold position instead of chasing:
```dart
} else if ((tgt.pos - e.pos).lengthSq() <= kHeroAttackRangeSq) {
  e.target = e.pos; // in attack range: stop here and fire (don't overrun onto the enemy)
} else {
  e.target = tgt.pos; // out of range: close the distance
}
```
**Behavior:** approaching from outside range, the hero stops the first tick it crosses the boundary — at distance ∈ `[range − _kHeroStep, range]` from the enemy, i.e. the **furthest point still in range** when approaching — and phase-4 combat fires that same tick (it tests the same `rangeSq`). If the enemy walks out of range, pursuit resumes next tick (distance > range → `target = tgt.pos`). Result is standard MOBA stop-at-range with a sticky chase.

### 1.3 Determinism
Pure behavior change in `lengthSq`/`Fixed`/`int` (the comparison is already used in combat). **No** new constant, field, enum, byte-layout, or version change (stays at the v3 layout for Part A). Phase order unchanged.

| Golden / anchor | Moves at v3? | Why |
|---|---|---|
| `smoke.golden` `7e4aa28f` | **NO** | move-only fixture — no attack lock, no pursuit |
| in-test anchor `0x0fbfb7ac` | **NO** | move-only; pursuit path not exercised |
| `combat.golden` `030f2343` | **YES** | the center brawl locks + pursues; heroes now stop at range instead of stacking on the enemy → positions diverge |
| `elemental.golden` `717305eb` | **only if** its fixture uses an attack lock | the **attribution gate decides** — re-pin whichever moved; do not assume |

**Re-pin procedure (v3, identical to the balance/controls passes):** run the native replay harness over all three fixtures, prove the attribution (smoke + anchor byte-identical; whichever of combat/elemental actually changed), regenerate the moved golden(s) with `printf '%s\n'` (single LF), then prove byte-identical native/dart2js/dart2wasm via `bash tooling/compare_replays.sh`. **If smoke or the anchor changes, STOP** — a behavior leak; investigate before re-pinning.

> **Note:** this v3 `combat.golden` re-pin is a verification checkpoint. Part C's version bump re-pins `combat.golden` again at v4 (the committed-final value). Doing A at v3 first keeps A's attribution clean — it isolates "did the pursuit change leak beyond combat?" before C's bump moves *everything*.

---

## 2. Part B — Live aim reticle (client; determinism-neutral)

Completes the controls-pass §3.3 deferred preview. **No sim/protocol/golden impact.**

- **What:** while a skill is armed (`SkillInputController.aimPending`), draw a translucent **`DashedCircle`** (the component added in the controls pass, `apps/client/lib/render/dashed_circle.dart`) centered on the **cursor's world position**, so the player sees where and how big the placement is. Hidden when not aiming.
- **Radius = the pending cast's effect radius:** `kFieldRadius` (2.5 → 70px) when E armed Marisol's Tidepool; the larger `kUltRadius` (Part C) when Q armed the ult. Radius is read from the shared sim constant via `coord.dart` (`× kPixelsPerUnit`), mirroring Part B of the controls pass — so it auto-tracks any future tuning.
- **Cursor tracking:** add a Flame pointer/hover handler (e.g. `PointerMoveCallbacks.onPointerMove` on `GuildGame`, or a `MouseRegion`/hover wrapper) to capture the cursor's canvas position each move and convert to world via `camera.globalToLocal` + `flameToWorld` (the same conversion `onTapUp` already uses). If no pointer-move stream is wired today, add the minimal handler.
- **Self-placed skills don't aim** (Cinderfang casts immediately on E/Q) → no reticle for them; the reticle is exclusively for the `aimPending` state (Marisol's E and Q).
- **"For now" hook:** gate the reticle behind a single named `const`/flag, a one-line removal later (matching the controls pass's `kShowTowerRangeRings` convention).
- **Fallback unchanged:** if live cursor tracking proves impractical on web, the cast still works on click (the controls-pass behavior); the reticle is desired, not load-bearing.

---

## 3. Part C — Q = placeholder ultimate (sim + netcode + server + client) + the version bump

LoL-style: **E = ability** (existing field), **Q = ultimate** (new). The placeholder ult is deliberately "**E, but bigger, on a long independent cooldown**," reusing the proven field + cast-burst + 2-sided-reaction machinery so the new surface is the *plumbing* (a serialized cooldown, an intent type, one-shot handling), not new combat math.

### 3.1 Sim
- **New serialized field `Entity.ultCooldown`** (`int`, ticks until the ult is ready; 0 = ready), mirroring `abilityCooldown`. Added as a **one-row `_entityBodyCodecs` insert** (an `_i32Codec`) placed immediately **after** the `abilityCooldown` codec so the canonical body stays grouped and `target` remains the trailing snapshot-only field. **This changes the entity byte layout** → the version bump (§3.5).
- **New `IntentType.ultimate`** — appended to the enum (`none, move, attack, ability, ultimate` → index 4). Append-only; rides the existing wire as a raw i32 (no protocol change). Carries the aim point in `aimX/aimY` like `ability`.
- **`step()` intent handling** (phase 1, alongside the `ability` branch): on an `ultimate` intent, if `hero.ultCooldown == 0` and the hero is not downed: remove the hero's prior field (the existing ≤1-field-per-hero `removeWhere(ownerId)` invariant — the ult shares the field slot), place an ult-tier `ElementalField` (`kUltRadius`-implied, `kUltFieldDurationTicks`), set `hero.ultCooldown = kUltCooldownTicks`, and fire a **larger/stronger enemy-only burst** centered on the placement (`kUltBurstDamage` over `kUltRadiusSq`). Self-place (Cinderfang) uses `hero.pos`; aim-place (Marisol) uses the intent aim.
- **`_castBurst` parametrized:** add optional `{Fixed? radiusSq, Fixed? damage}` (defaulting to `kFieldRadiusSq` / `kCastBurstDamage`) so the ult passes ult-tier values and the **E path stays byte-identical** when defaults are used. Keeps the self-safety invariant (enemy-only) and ICD/reaction semantics intact.
- **Cooldown tick-down:** add `if (e.ultCooldown > 0) e.ultCooldown -= 1;` to the per-unit timer loop in `_stepCombat` (`simulation_combat.dart:28-33`), next to `abilityCooldown`. **Not** reset on respawn — mirrors `abilityCooldown` (the respawn block at `simulation_combat.dart:9-23` resets `attackCooldown` but deliberately not `abilityCooldown`); so the respawn block is **unchanged**.
- **New constants** (placeholder-tuned, all within the Fixed budget `|value| < 32768`; `× kVaporizeMult` stays in budget): `kUltCooldownTicks` (long, e.g. ~30 s = 900), `kUltBurstDamage` (Fixed, > `kCastBurstDamage`), `kUltRadius`/`kUltRadiusSq` (Fixed, > `kFieldRadius`), `kUltFieldDurationTicks` (> `kFieldDurationTicks`). Constants are **not serialized** → golden-neutral by themselves; only the new `ultCooldown` field + version header move the goldens.

### 3.2 Netcode (`packages/netcode`)
- **`applyUltimateInput(aimX, aimY)`** on `MatchController`, mirroring `applyAbilityInput` (`match_controller.dart:87-105`) but `type: IntentType.ultimate`. Downed-gated (returns null while downed, same as the others).
- **One-shot handling:** the ult is edge-triggered like the ability (fires once on its issuing tick, never re-feeds). Update `_dropHeldWhileLocalDowned` (`match_controller.dart:115-119`) and `_intentsAt` (`match_controller.dart:127-140`) to treat `ultimate` as one-shot. Replace the bare `== IntentType.ability` checks with a shared "is this a one-shot intent" predicate (`ability || ultimate`) so future one-shot skills are a one-line addition. Its home is an open detail (§7) — a sim-side `IntentType.isOneShot` extension getter (which netcode and the server both already depend on) is the natural shared place.
- **`FakeTransport`** mirrors the server faithfully (cleaning phase) → it must forward/echo the `ultimate` intent exactly as it does `ability` (one-shot, downed-drop, clearSlot). Update its intent handling in lockstep.

### 3.3 Server (`apps/server`)
- **`IntentBuffer`** must treat `ultimate` as a one-shot intent identically to `ability` (one-shot vs. held order, clearSlot-on-death), via the same shared one-shot predicate (§3.2/§7).

### 3.4 Client (`apps/client`)
- **`MatchBinding.submitUltimate(rawX, rawY)`** mirroring `submitAbility` (`match_binding.dart:71`) → `controller.applyUltimateInput`.
- **`SkillInputController`** extended for Q: a second armed slot with the same `idle ↔ aimPending` state machine as E (self-place → `castAtSelf`; aim-place → `enterAim` then left-click → `castAtPoint`; E-again/right-click cancel; downed-gated). The controller must track **which** skill is pending (E vs Q) so the left-click confirm and the reticle radius (Part B) resolve to the right cast. Keep it a pure, unit-tested state machine (no Flame harness) as established by the controls pass.
- **`GuildGame`** Q key (`LogicalKeyboardKey.keyQ`) wired through `onKeyEvent` next to E, routing to `submitUltimate` for `castAtSelf`/`castAtPoint`, exactly as E routes to `submitAbility`.

### 3.5 Determinism & golden plan (the load-bearing part)
- **Bump `kSchemaVersion` 3 → 4 AND `kSnapshotVersion` 3 → 4** (`simulation.dart:22/27`). The version header + the new `ultCooldown` i32 per entity change the bytes of **every** snapshot/canonical encoding.
- **Deliberately re-pin ALL goldens + the anchor at v4:** `smoke`, `combat`, `elemental` **and** the in-test `0x0fbfb7ac` canonical-state-hash anchor (`simulation_test.dart`) — all move purely structurally (version + new field; the cooldown tick-down is a no-op in every existing fixture because no ult is cast, so `ultCooldown` stays 0). Re-pin each golden cross-runtime (native + dart2js + dart2wasm via `compare_replays.sh`); update the anchor literal to its new v4 value.
- **New `ult` fixture + golden (additive):** add `tooling/replay_fixtures/ult.json` (a short scenario that casts the placeholder ult — both self-place and aim-place if practical) and pin `ult.golden`, proving the new mechanic is byte-identical native/js/wasm. Wire it into `compare_replays.sh`/CI alongside the existing three.
- **No protocol version bump:** intents are not in the determinism/snapshot byte stream; the intent `type` is a raw i32 (`codec.dart:31/64`), so `IntentType.ultimate` round-trips with no codec/version change (a round-trip test is added for coverage).

---

## 4. Scope

**IN:**
- **A:** stop-at-range pursuit fix in `simulation.dart` phase 2; v3 attribution gate + re-pin of the moved golden(s) cross-runtime.
- **B:** live cursor aim reticle in `apps/client` (translucent `DashedCircle` tracking the mouse while `aimPending`, radius from the pending cast's constant), behind a one-line flag; pointer-move handler; sanctioned no-preview fallback retained.
- **C:** `Entity.ultCooldown` (one-row codec insert) + `IntentType.ultimate` + `step()` ult handling + parametrized `_castBurst` + ult constants; **version bump 3/3→4/4 + re-pin ALL goldens + the `0x0fbfb7ac` anchor + a new `ult` fixture/golden**, all cross-runtime; netcode `applyUltimateInput` + `_isOneShot` one-shot handling + `FakeTransport` mirror; server `IntentBuffer` one-shot treatment; client `submitUltimate` + `SkillInputController` Q slot + `GuildGame` Q key.

**OUT (→ Plan 7 D, or never):**
- Real kit/ult **content** (Pyre Unchained, Maelstrom, Ember Hook), per-hero ult differentiation beyond "bigger field-burst," any ult that isn't a field/burst.
- New reaction **types** (Melt/Overload/…); the ×2.0/×1.5/×1.3 **provenance/potency split**; STRONG-tier application; any reaction change.
- New **elements**, heroes, or elemental creeps; any second-element source beyond today's two heroes' fields.
- XP / leveling / shop; the revenge boss; any 3v3 logic.
- Any **protocol** byte-layout/version change; any cooldown/HUD UI for the ult (pressing Q on cooldown simply sends an intent the sim ignores — no client cooldown prediction).
- Speculative serialized fields for D (no XP/level fields now — D owns its own v4→v5 bump if it needs them).

**Known limitation (accepted for the placeholder; → D backlog):** the server `IntentBuffer` and `FakeTransport` hold **one one-shot intent per slot per tick**, so pressing **E and Q within the same ~33 ms tick** keeps only the latter authoritatively, while the client predicts both fire — a transient predicted-vs-authoritative divergence that **reconcile self-heals** (both seqs are acked → both pending entries prune → the next snapshot re-anchors). Acceptable here (ults are a placeholder, casts on the same tick are a rare human input); when D adds real ults, the per-slot one-shot store likely needs to become **per-intent-type** (E vs Q) so simultaneous casts both land.

---

## 5. Tests & verification (evidence-first)

- **Sim (Part A):** add/extend a test asserting a locked hero **stops at range** (final distance to target ≥ ~`range − _kHeroStep`, never collapses toward 0) and still fires; existing symbolic assertions stay green. `cd packages/sim && dart analyze && dart test`.
- **Golden attribution (Part A, v3):** native hashes show `smoke 7e4aa28f` + anchor `0x0fbfb7ac` byte-identical; `combat` (and `elemental` iff its fixture pursues) golden-mismatched (the sanctioned move) and byte-identical across runtimes; re-pin the moved golden(s).
- **Sim (Part C):** unit tests for the ult — cooldown gates a second cast; `ultCooldown` ticks down and is **not** reset on respawn; self-place vs aim-place placement; the ult burst is enemy-only (self-safety) and amplifies a coated enemy; `_castBurst` defaults leave the E path unchanged. Snapshot/round-trip tests cover the new `ultCooldown` field and `IntentType.ultimate`. The `0x0fbfb7ac` anchor test asserts the **new v4** value.
- **Golden re-pin (Part C, v4):** all three existing goldens + the new `ult.golden` pinned cross-runtime via `compare_replays.sh`; CI gate updated to include `ult`.
- **Netcode/server:** `applyUltimateInput` records + sends a one-shot intent; the ult is dropped-if-downed correctly and replays once (mirrors the ability tests); `FakeTransport` and `IntentBuffer` forward `ultimate` as one-shot. `dart test` green in `netcode` + `server`.
- **Protocol:** an `InputMsg`/intent round-trip test covers `type == IntentType.ultimate.index`. `dart test` green in `protocol`.
- **Client (Parts B, C):** `SkillInputController` unit tests extended for the Q slot (E and Q armed independently; left-click confirms the armed slot; cancel; downed gate). `flutter analyze && flutter test` green. A render/widget assertion that the reticle component exists while `aimPending` and carries the pending cast's radius.
- **Full mirror-CI sweep:** `dart analyze --fatal-infos --fatal-warnings packages apps/server tooling`; `bash tooling/check_no_banned_imports.sh`; sim + protocol + netcode + server `dart test`; `compare_replays.sh` over smoke/combat/elemental/**ult** (all byte-identical native/js/wasm + matching their v4 goldens); `flutter analyze` + `flutter test`.
- **Eyeball post-change:** right-clicking the enemy walks the hero to range and **stops** (no overrun); arming Marisol's E/Q shows a dashed reticle following the cursor (field-sized for E, larger for the ult); pressing **Q** off cooldown fires the placeholder ult (bigger burst), and on cooldown does nothing.

---

## 6. Task plan (outline — `writing-plans` expands this)

1. **Part A — attack-move-to-range** (sim; pursue stop-at-range branch, stop-at-range test, v3 attribution gate + cross-runtime re-pin of the moved golden(s), commit).
2. **Part C — Q placeholder ultimate** (sim field + codec row + intent + `step()` handling + parametrized `_castBurst` + constants; **version bump 3/3→4/4 + re-pin ALL goldens + anchor + new `ult` fixture**; netcode `applyUltimateInput` + `_isOneShot` + `FakeTransport`; server `IntentBuffer`; client `submitUltimate` + `SkillInputController` Q slot + `GuildGame` Q key; full sim/netcode/server/protocol/client tests).
3. **Part B — live aim reticle** (client; pointer-move handler + reticle `DashedCircle` while `aimPending`, radius from the pending cast's constant — E-field and Q-ult — behind a flag; reuses C's aim plumbing + ult radius).
4. **Full mirror-CI sweep** → whole-branch review (`requesting-code-review` over `main..HEAD`) → `finishing-a-development-branch` (present options; do **not** merge/push without Patrick's explicit choice).

**Order rationale:** A is the only v3 golden-attributable change — do it first, attribution-clean, *before* C's version bump moves everything. C does the structural version bump + re-pins all goldens + lands the ult plumbing/radius. B is pure client polish and reads C's ult radius → last. Final full mirror-CI + cross-runtime sweep after all three.

---

## 7. Open implementation details to resolve in the plan

- **`_entityBodyCodecs` insertion point:** confirm `ultCooldown`'s row goes immediately after `abilityCooldown` and before the snapshot-only `target` row; re-pin expectations derive from this exact order.
- **`_castBurst` signature:** the cleanest way to parametrize radius+damage without disturbing the E path's byte-for-byte behavior (optional named params defaulting to the field constants).
- **Ult field vs. E field coexistence:** this pass uses the existing ≤1-field-per-hero `removeWhere(ownerId)` (ult shares the slot). Confirm that's acceptable for the placeholder (D may introduce coexisting fields).
- **`SkillInputController` two-slot model:** whether to generalize the existing single-skill state machine to an `{E, Q}`-indexed armed slot, or add a parallel Q machine — pick the lower-churn fit while keeping it pure/unit-testable.
- **Reticle radius source:** the exact `Fixed → pixels` accessor for `kFieldRadius`/`kUltRadius` through `coord.dart` (reuse the controls-pass `towerRangeRingRadiusPx`-style helper).
- **Pointer-move plumbing:** which Flame mechanism captures the cursor reliably on web alongside the existing tap/keyboard handlers; the documented fallback if it's impractical.
- **`ult.json` fixture shape:** a short, deterministic scenario that casts the placeholder ult (ideally both self-place and aim-place) so `ult.golden` meaningfully locks the new path cross-runtime.
- **One-shot predicate placement:** where the shared "is this a one-shot intent" check (`ability || ultimate`) lives so netcode (`MatchController`, `FakeTransport`) and the server (`IntentBuffer`) share one definition rather than re-deriving it — likely a sim-side `IntentType.isOneShot` extension getter.
