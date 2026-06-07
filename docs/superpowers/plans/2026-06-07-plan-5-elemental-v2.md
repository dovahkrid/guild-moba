# Guild — Plan 5: Elemental Damage Model v2 (aura-coat + reactions, no field DoT) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Plan 4's two-sided continuous field DoT (which makes a self-placing hero suicide) with a Genshin-style model: a coating (aura) deals **no** damage by itself; damage comes from a one-time **enemy-only cast burst** and from **reactions** (attack-amplify ×1.3 riding autos/burst, plus a field-overlap flat reaction); and **no damage ever lands on the caster's own team**. Folds in the netcode one-shot ability fix (cast fires once per press, not every cooldown). Byte-identical across native/dart2js/dart2wasm; only `elemental.golden` re-pins.

**Architecture:** All gameplay stays in pure-Dart `packages/sim`. The existing `_applyHit` chokepoint (coat-or-amplify) is **retained unchanged** and now serves autos + the new cast burst (both enemy-only by construction → self-safe). `_stepFields` is **rewritten** to do coat-only (2-sided, no DoT) plus a field-overlap **flat** Vaporize whose *damage* is gated to enemies-of-the-owner (owner/own-team take 0 but the reaction still fires + consumes status + stamps ICD + emits). A new `_castBurst` helper deals the one-time enemy-only AoE in `step()`'s `ability` branch. The serialized byte layout (Entity status fields + `_fields` struct-list) is **unchanged** — no version bump. The netcode one-shot fix is golden-neutral: the server `IntentBuffer` holds move/attack but drains a separate one-shot `_pendingAbility`; the client `MatchController` fires the ability only at its exact `clientTick` in both forward prediction and reconcile.

**Tech Stack:** Dart 3.11.5 pub workspace; `packages/sim` (pure, Q16.16 `Fixed`, PCG32 `DetRng`, FNV-1a canonical hash); `packages/protocol` (binary codec — unchanged); `packages/netcode` (predict/reconcile/interpolate); `apps/server` (authoritative match loop); `apps/client` (Flutter + Flame, package `guild_client`). Tests: `package:test`; cross-runtime golden via `tooling/replay_harness.dart` + `tooling/compare_replays.sh` on native/dart2js/dart2wasm.

**Determinism contract (every task obeys this — non-negotiable):**
- **No floating point in gameplay math.** `Fixed` (Q16.16) + `int` only. Every `|value| < 32768`. The cast burst can be amplified → `kCastBurstDamage × kVaporizeMult < 32768` is asserted; `kReactionFlatDamage` is flat (never amplified).
- **No `dart:math`** (`sin/cos/sqrt/pow/atan2/tan`), no `Random(`, no `DateTime`/`Stopwatch` in `packages/sim/lib`. Field/burst membership uses `FVec2.lengthSq()` vs `kFieldRadiusSq` — **never** `length()`/`sqrt`. Enforced by `packages/sim/test/banned_imports_test.dart` + `tooling/check_no_banned_imports.sh`.
- **No new RNG draw.** Reactions/burst are a pure function of state + tick. The only RNG draw stays the phase-5 wanderer (`simulation.dart`) — do not move, skip, or add to it.
- **Deterministic iteration order.** The cast burst and field loops iterate `entityIdsSorted` (ascending id) and the stable `_fields` list; never a `Set`/hash map.
- **`Element` / `Reaction` / `IntentType` / `EntityKind` enum values are APPEND-ONLY** — `.index` is serialized. No new enum values this plan.
- **Byte layout UNCHANGED.** Same Entity status fields + same `_fields` struct → **no `kSchemaVersion`/`kSnapshotVersion` bump.** The four byte sites (`canonicalBytes`, `snapshotBytes`, `restoreFromSnapshot`, `peekEntityPos`) are **not touched** by this plan.
- **Self-safety invariant (the headline).** NO code path may deal cast-burst or field-overlap-reaction damage to a unit on the source's own team (`teamId == sourceTeam`). Cast burst + field-flat reaction are enemy-only (`teamId != sourceTeam`; heroes + neutral creeps qualify). Attack-amplify rides autos/cast hits that already only target enemies. Owner/own-team take **0** (the field reaction still fires + consumes status + stamps ICD on them, just 0 damage).

**Spec:** `docs/superpowers/specs/2026-06-07-plan-5-elemental-v2-design.md`. Predecessors: `docs/superpowers/plans/2026-06-07-plan-4-elemental.md`, `docs/superpowers/specs/2026-06-07-plan-4-elemental-design.md`.

---

## Re-Pin Procedure (referenced by Task 2)

Goldens are **regenerated — never hand-typed** — from a verified green 3-runtime run whenever `canonicalBytes()` *output* changes for a fixture. This plan changes `canonicalBytes()` output **only for `elemental.json`** (it casts overlapping fields → cast bursts + field reactions change its outcome). The byte *layout* is unchanged, so **no in-test literal moves** and **smoke/combat do not move.**

**Pinned values at branch start (MUST hold except where noted):**
- `tooling/replay_fixtures/smoke.golden` = `7e4aa28f` — **MUST NOT move** (move-only).
- `tooling/replay_fixtures/combat.golden` = `04da965a` — **MUST NOT move** (combat autos coat the *same* element each round → no reaction; no fields/casts).
- In-test 300-tick anchor `0x0fbfb7ac` in **both** `packages/sim/test/simulation_test.dart` and `packages/sim/test/snapshot_test.dart` — **MUST NOT move** (move-only, empty `_fields`).
- `tooling/replay_fixtures/elemental.golden` = `041e7a02` — **re-pins** in Task 2.

If smoke/combat/the anchor move at any point, that is a **BUG** — investigate (a stray DoT path firing in a fixture that should not react, a reordered phase, a non-deterministic draw). Do **NOT** re-pin them.

**Procedure (run in bash — Git Bash on Windows; node v22, base64 -w0, awk available):**
```bash
# 1. Prove byte-identical determinism across all three runtimes FIRST.
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
# Expect: "PASS: byte-identical across native/js/wasm: <newhash>" then
#         "FAIL: hash changed vs golden ..." (expected — the golden is now stale).
# A DIVERGENCE across runtimes instead = a non-determinism bug; binary-diff
# canonicalBytes() per tick to find the first divergent field; fix BEFORE pinning.

# 2. Regenerate the golden from the harness (never hand-type the hash).
b64=$(base64 -w0 tooling/replay_fixtures/elemental.json) \
  && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart \
     | awk '/^REPLAY_HASH /{print $2}' > tooling/replay_fixtures/elemental.golden

# 3. Verify green + enforced.
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
# Expect: "PASS: byte-identical ..." then "PASS: matches golden ...".

# 4. Confirm the untouched fixtures did NOT move.
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json   # PASS: matches golden 7e4aa28f
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json  # PASS: matches golden 04da965a
```
Commit the regenerated `elemental.golden` together with the task's code.

---

## File Structure

**Modified (sim — damage model):**
- `packages/sim/lib/src/data/elements.dart` — remove `kFieldDotDamage`; add `kCastBurstDamage`, `kReactionFlatDamage`.
- `packages/sim/lib/src/simulation.dart` — rewrite `_stepFields` (coat-only + field-overlap flat reaction); add `_castBurst` + call it in the `ability` branch; update the `_applyHit` doc comment (body unchanged).
- `packages/sim/test/elements_data_test.dart` — drop `kFieldDotDamage` from the budget test; add a v2-constants budget test.
- `packages/sim/test/reaction_test.dart` — **full rewrite** for the v2 rules.
- `tooling/replay_fixtures/elemental.golden` — re-pinned (Task 2).

**Modified (netcode/server — one-shot ability, golden-neutral):**
- `apps/server/lib/src/loop/intent_buffer.dart` — `_held` (move/attack, persistent) + `_pendingAbility` (one-shot).
- `apps/server/test/intent_buffer_test.dart` — one-shot drain + held-move-persists tests.
- `apps/server/test/match_test.dart` — no-auto-recast integration test.
- `packages/netcode/lib/src/match_controller.dart` — replace `_heldAt` with `_intentsAt` (held move/attack + ability only at its exact `clientTick`); use in `advanceClientTick` + reconcile.
- `packages/netcode/test/match_controller_test.dart` — one-shot + held-move + reconcile-single-cast tests.

**Modified (client — pop-text flat-vs-amplify):**
- `apps/client/lib/render/reaction_label.dart` — add pure `reactionText(int reaction, int multiplierRaw)`.
- `apps/client/lib/render/guild_game.dart` — use `reactionText`; drop the now-unused `kOne` import.
- `apps/client/test/reaction_label_test.dart` — **new**: `reactionText` mapping.

**Untouched (explicitly):** the four byte sites + both versions; `Element`/`Reaction`/`IntentType`/`EntityKind` enums; field placement/duration/cooldown mechanics; `elemental_field.dart`; `match_view.dart`; the protocol/codec; `smoke.golden`/`combat.golden`; the in-test anchor; declared-only hooks (`BossSpawned`/`LevelUp`).

---

## Scope (read before starting)

**IN:** status does no damage; fields coat-only (2-sided, no DoT); enemy-only cast burst; two reaction triggers (attack-amplify ×1.3 + field-flat) sharing the per-unit `reactionIcd`; all damage enemy-only (own-team takes 0); cast burst + field reactions hit creeps; one-shot ability input fix (server + client); `kCastBurstDamage`/`kReactionFlatDamage` tunables (remove `kFieldDotDamage`); client pop-text flat-vs-amplify distinction; full reaction_test rewrite; re-pin `elemental.golden`; full determinism + cross-runtime sweep.

**OUT:** no new elements/reactions; no STRONG potency / provenance split; no new serialized fields or version bump; no boss/XP/shop; no change to `smoke.golden`/`combat.golden`/the in-test anchor; no protocol/codec change; no change to field placement/duration/cooldown mechanics; declared-only hooks untouched.

---

## Task 1: Tunables — add cast-burst + field-flat damage constants (golden-neutral)

**Files:**
- Modify: `packages/sim/lib/src/data/elements.dart`
- Modify: `packages/sim/test/elements_data_test.dart`

> **Golden-neutral & additive.** Adds two new public constants; keeps `kFieldDotDamage` for now (removed in Task 2, when `_stepFields` stops using it — removing it here would break `simulation.dart`/`reaction_test.dart` and turn the build red). Nothing serialized or stepped changes → smoke/combat/anchor untouched. Values are **playtest placeholders** (spec §8).

- [ ] **Step 1: Write the failing test**

Append to `packages/sim/test/elements_data_test.dart` (inside `main()`):
```dart
  test('v2 damage constants obey the Fixed budget (flat + amplifiable burst)', () {
    for (final f in <Fixed>[kCastBurstDamage, kReactionFlatDamage]) {
      expect(f.toDouble().abs() < 32768, isTrue, reason: '$f exceeds the Fixed budget');
    }
    // The cast burst CAN be amplified by a reaction, so burst × mult must fit.
    expect((kCastBurstDamage * kVaporizeMult).toDouble().abs() < 32768, isTrue);
    // The field-overlap reaction is FLAT (never amplified) but must still fit.
    expect(kReactionFlatDamage.toDouble().abs() < 32768, isTrue);
    expect(kCastBurstDamage.toDouble(), greaterThan(0));
    expect(kReactionFlatDamage.toDouble(), greaterThan(0));
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `dart test packages/sim/test/elements_data_test.dart`
Expected: FAIL — "Undefined name 'kCastBurstDamage'" / "Undefined name 'kReactionFlatDamage'".

- [ ] **Step 3: Add the constants**

In `packages/sim/lib/src/data/elements.dart`, replace the `// --- Neutral fields ---` block. Replace:
```dart
// --- Neutral fields ---
final Fixed kFieldRadius = Fixed.fromNum(2.5);
final Fixed kFieldRadiusSq = Fixed.fromNum(2.5 * 2.5); // compare vs lengthSq, no sqrt
final Fixed kFieldDotDamage = Fixed.fromNum(1); // per-tick DoT to HEROES (zero to creeps)
const int kFieldDurationTicks = 120; // ~4s
const int kAbilityCooldownTicks = 240; // ~8s (> field duration → ≤1 active field/hero)
```
with:
```dart
// --- Neutral fields (coat-only; no DoT in v2) ---
final Fixed kFieldRadius = Fixed.fromNum(2.5);
final Fixed kFieldRadiusSq = Fixed.fromNum(2.5 * 2.5); // compare vs lengthSq, no sqrt
final Fixed kFieldDotDamage = Fixed.fromNum(1); // DEPRECATED (Plan 4 DoT); removed in Plan 5 Task 2
const int kFieldDurationTicks = 120; // ~4s
const int kAbilityCooldownTicks = 240; // ~8s (> field duration → ≤1 active field/hero)

// --- Plan 5 damage model (v2) ---
// A one-time, enemy-only AoE dealt on cast, centered on the field. May be
// amplified by an attack-amplify reaction → kCastBurstDamage × kVaporizeMult must
// stay in the Fixed budget.
final Fixed kCastBurstDamage = Fixed.fromNum(10);
// Flat damage from a field-overlap reaction (no triggering hit to amplify);
// dealt only to an ENEMY of the field owner (owner/own-team take 0).
final Fixed kReactionFlatDamage = Fixed.fromNum(8);
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/elements_data_test.dart`
Expected: PASS.

Run: `dart test packages/sim`
Expected: PASS — anchor `0x0fbfb7ac` unchanged (nothing serialized/stepped changed).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/data/elements.dart packages/sim/test/elements_data_test.dart
git commit -m "feat(sim): add v2 cast-burst + field-flat damage tunables (additive, golden-neutral)"
```

---

## Task 2: Damage model v2 — coat-only fields + field-overlap flat reaction + enemy-only cast burst (re-pin elemental.golden)

**Files:**
- Modify: `packages/sim/lib/src/data/elements.dart`
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/elements_data_test.dart`
- Rewrite: `packages/sim/test/reaction_test.dart`
- Modify: `tooling/replay_fixtures/elemental.golden`

> **The heart of the plan + the self-safety invariant.** Removes all field DoT; fields now coat-only (2-sided) and may detonate a field-overlap **flat** Vaporize whose damage lands only on enemies-of-the-owner (owner/own-team take 0 but the reaction still fires + consumes + ICDs + emits). Adds a one-time **enemy-only** cast burst centered on the field. `_applyHit` (attack-amplify) is unchanged and now serves autos + the burst (both enemy-only). **Re-pins `elemental.golden` ONLY.** `combat.golden` stays byte-identical (combat autos coat the same element each round → no reaction; no fields/casts), `smoke.golden` is move-only, and the in-test anchor is move-only with empty `_fields` — all three MUST NOT move (verified in Step 5).

- [ ] **Step 1: Rewrite the failing tests**

Replace the **entire** contents of `packages/sim/test/reaction_test.dart` with:
```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

// Plan 5 (elemental v2) reaction rules:
//   - a bare status deals NO damage;
//   - fields coat 2-sided with NO DoT (the owner is not exempt, takes no self-damage);
//   - a field-overlap reaction deals FLAT kReactionFlatDamage to an ENEMY of the
//     field owner, but 0 to the owner/own-team (status consumed + ICD stamped +
//     event emitted with multiplierRaw 0 either way);
//   - the cast burst is a one-time ENEMY-ONLY AoE (owner/own-team take 0); it
//     coats + can attack-amplify (×kVaporizeMult);
//   - autos attack-amplify (×kVaporizeMult); both reaction paths share reactionIcd;
//   - cast burst + field reactions hit creeps.
void main() {
  // --- Field placement / lifecycle (unchanged mechanics) ---

  test('Marisol (hero 1) casts Tidepool at the aim point with Hydro', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    expect(sim.fields, isEmpty);
    // aim at world (3,0) => Q16.16 raws (3*65536 = 196608). No enemy in range → no burst effect.
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 196608, aimY: 0, seq: 1)]);
    expect(sim.fields, hasLength(1));
    final f = sim.fields.single;
    expect(f.ownerId, 1);
    expect(f.element, Element.hydro.index);
    expect(f.center.x.toDouble(), 3.0); // ranged: placed AT the aim point
    expect(sim.entity(1).abilityCooldown, greaterThan(0));
  });

  test('Cinderfang (hero 0) casts Ember Field at his OWN position (aim ignored)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = FVec2(Fixed.fromInt(-5), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 655360, aimY: 655360, seq: 1)]);
    final f = sim.fields.single;
    expect(f.ownerId, 0);
    expect(f.element, Element.pyro.index);
    expect(f.center.x.toDouble(), -5.0); // self-placed, NOT the (10,10) aim
  });

  test('a field cannot be recast while the ability is on cooldown', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 0, seq: 1)]);
    expect(sim.fields, hasLength(1));
    sim.step(1, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 131072, aimY: 0, seq: 2)]);
    expect(sim.fields, hasLength(1)); // on cooldown → not recast
    expect(sim.fields.single.center.x.toDouble(), 0.0); // original field, not the blocked recast
  });

  test('a field expires after its duration', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 0, seq: 1)]);
    expect(sim.fields, hasLength(1));
    for (var t = 1; t <= kFieldDurationTicks; t++) {
      sim.step(t, const []);
    }
    expect(sim.fields, isEmpty);
  });

  test('respawning clears a hero status and removes their field', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // off-lane, tower-safe
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 10000; // would outlast respawn — only the clear empties it
    sim.fields.add(ElementalField(
        ownerId: 1, center: FVec2.zero, element: Element.hydro.index, timer: 10000));
    h.hp = Fixed.zero; // downable this tick
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []); // death sweep → downed
    expect(h.respawnTimer, kHeroRespawnTicks);
    for (var t = 1; t <= kHeroRespawnTicks; t++) {
      sim.step(t, const []);
    }
    expect(h.respawnTimer, 0); // respawned
    expect(h.statusElement, -1); // cleared on respawn
    expect(sim.fields.where((f) => f.ownerId == 1), isEmpty); // field removed on respawn
  });

  test('a placed field survives a snapshot round-trip', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 196608, aimY: 458752, seq: 1)]);
    expect(sim.fields, hasLength(1));
    final dst = Simulation.create(const SimConfig(seed: 1))
      ..restoreFromSnapshot(sim.snapshotBytes());
    expect(dst.fields, hasLength(1));
    final f = dst.fields.single;
    expect(f.ownerId, 1);
    expect(f.element, Element.hydro.index);
    expect(f.center.x.toDouble(), 3.0);
    expect(f.center.y.toDouble(), 7.0);
    expect(f.timer, sim.fields.single.timer);
    expect(dst.canonicalStateHash(), sim.canonicalStateHash());
  });

  // --- Coating (2-sided, no DoT) ---

  test('a field coats a hero standing inside it (no damage)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // tower-safe off-lane
    h.target = h.pos;
    final hpBefore = h.hp.raw;
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.pyro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(h.statusElement, Element.pyro.index);
    expect(h.statusTimer, greaterThan(0));
    expect(h.hp.raw, hpBefore); // coat is damage-free
  });

  test('a field coats its OWNER 2-sided with NO DoT (the self-suicide bug is gone)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final owner = sim.entity(0); // Cinderfang stands in his own Ember Field
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    owner.pos = spot;
    owner.target = spot;
    final ownerHpBefore = owner.hp.raw;
    sim.fields.add(ElementalField(
        ownerId: 0, center: spot, element: Element.pyro.index, timer: 100));
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const []);
    expect(owner.statusElement, Element.pyro.index); // coated (2-sided: owner not exempt)
    expect(owner.hp.raw, ownerHpBefore); // NO self-damage
  });

  test('a field does not coat a unit outside its radius', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.pos = FVec2(Fixed.fromInt(20), Fixed.fromInt(7));
    h.target = h.pos;
    sim.fields.add(ElementalField(
        ownerId: 0, center: FVec2(Fixed.zero, Fixed.fromInt(7)),
        element: Element.pyro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(h.statusElement, -1); // 20 units from the field center
  });

  test('same-element re-application refreshes the timer (no stacking, no damage)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.hydro.index;
    h.statusTimer = 3;
    final hpBefore = h.hp.raw;
    sim.fields.add(ElementalField(
        ownerId: 1, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(h.statusElement, Element.hydro.index);
    expect(h.statusTimer, kStatusDurationTicks); // refreshed to full
    expect(h.hp.raw, hpBefore); // still no damage
  });

  // --- Bare status / expiry ---

  test('a bare elemental status deals no damage by itself', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 30;
    final hpBefore = h.hp.raw;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []); // no field, no auto — just a status
    expect(h.hp.raw, hpBefore); // status alone never damages
    expect(h.statusElement, Element.pyro.index); // still coated
  });

  test('a status expires to none after its duration', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 3;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    for (var t = 0; t < 3; t++) {
      sim.step(t, const []);
    }
    expect(h.statusElement, -1); // swept after statusTimer hit 0
    expect(h.statusTimer, 0);
  });

  // --- Field-overlap flat reaction (enemy-only damage; owner-safe) ---

  test('field-overlap reaction: FLAT damage to an enemy of the owner, status consumed + event', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // victim (team 1)
    h.target = h.pos;
    h.statusElement = Element.pyro.index; // pre-coated opposite element
    h.statusTimer = 30;
    final hpBefore = h.hp.raw;
    // A Hydro field owned by hero 0 (enemy of hero 1) centered on the victim.
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero); // owner far (no auto)
    sim.entity(0).target = sim.entity(0).pos;
    final events = sim.step(0, const []);
    expect(h.hp.raw, hpBefore - kReactionFlatDamage.raw); // FLAT, not amplified
    expect(h.statusElement, -1); // consumed
    expect(h.reactionIcd, kReactionIcdTicks); // ICD stamped
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.unitId, 1);
    expect(rt.reaction, Reaction.vaporize.index);
    expect(rt.multiplierRaw, 0); // flat marker (client renders "VAPORIZE", no ×)
    expect(rt.sourceId, 0); // the field owner
  });

  test('field-overlap reaction: ZERO damage to the OWNER, but status still consumed + ICD + event', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final cinder = sim.entity(0); // owner == victim (same team)
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    cinder.pos = spot;
    cinder.target = spot;
    cinder.statusElement = Element.hydro.index; // opposite to his own Pyro field
    cinder.statusTimer = 30;
    final hpBefore = cinder.hp.raw;
    sim.fields.add(ElementalField(
        ownerId: 0, center: spot, element: Element.pyro.index, timer: 100)); // his OWN field
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    final events = sim.step(0, const []);
    expect(cinder.hp.raw, hpBefore); // ZERO self-damage (THE headline fix)
    expect(cinder.statusElement, -1); // status still consumed
    expect(cinder.reactionIcd, kReactionIcdTicks); // ICD still stamped
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.unitId, 0);
    expect(rt.multiplierRaw, 0); // flat
  });

  test('a status expiring this tick still field-reacts this tick, then is swept', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // enemy of owner 0
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 1; // decrements to 0 BEFORE the field tick this tick
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    final events = sim.step(0, const []);
    expect(events.whereType<ReactionTriggered>().single.unitId, 1); // reacted before the sweep
    expect(h.statusElement, -1); // then consumed/swept
  });

  test('the reaction ICD blocks a second field reaction until it expires', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    // Overlap: a Pyro field AND a Hydro field on the hero (Pyro listed first).
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.pyro.index, timer: 10000));
    sim.fields.add(ElementalField(
        ownerId: 1, center: h.pos, element: Element.hydro.index, timer: 10000));
    var reactions = 0;
    for (var t = 0; t < kReactionIcdTicks; t++) {
      reactions += sim.step(t, const []).whereType<ReactionTriggered>().length;
    }
    expect(reactions, 1); // exactly one per ICD window, not one per tick
  });

  test('field-overlap reaction damages a neutral creep (enemy of the owner)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final spot = FVec2(Fixed.fromInt(-8), Fixed.zero); // tower-safe (own-team tower won't target a creep)
    final creep = sim.entity(kCreepIdBase)..pos = spot;
    creep.statusElement = Element.pyro.index; // pre-coated opposite
    creep.statusTimer = 30;
    final creepHpBefore = creep.hp.raw;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.fromInt(2));
    sim.entity(1).target = sim.entity(1).pos;
    sim.fields.add(ElementalField(
        ownerId: 1, center: spot, element: Element.hydro.index, timer: 100)); // owner hero 1
    final events = sim.step(kFirstWaveTick + 1, const []);
    expect(creep.hp.raw, creepHpBefore - kReactionFlatDamage.raw); // creep (team 2) is an enemy
    expect(creep.statusElement, -1);
    expect(events.whereType<ReactionTriggered>().single.unitId, kCreepIdBase);
  });

  // --- Auto-attack coat + attack-amplify (retained from Plan 4) ---

  test('a hero auto coats its locked enemy with the hero element', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final a = sim.entity(0); // Cinderfang → Pyro
    final b = sim.entity(1);
    a.pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    b.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    a.target = a.pos;
    b.target = b.pos;
    final bHpBefore = b.hp.raw;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(b.statusElement, Element.pyro.index);
    expect(b.hp.raw, bHpBefore - kHeroAttackDamage.raw); // coat + plain auto damage
  });

  test('auto-attack amplifies (×kVaporizeMult) on a differently-coated enemy', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final a = sim.entity(0); // Pyro auto
    final b = sim.entity(1);
    a.pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    b.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    a.target = a.pos;
    b.target = b.pos;
    b.statusElement = Element.hydro.index; // pre-coated opposite
    b.statusTimer = 30;
    final bHpBefore = b.hp;
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(b.hp.raw, (bHpBefore - (kHeroAttackDamage * kVaporizeMult)).raw); // amplified (no field to re-coat)
    expect(b.statusElement, -1); // consumed
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.multiplierRaw, kVaporizeMult.raw); // amplify marker
    expect(rt.sourceId, 0);
    expect(rt.unitId, 1);
  });

  // --- Cast burst (enemy-only; owner-safe; amplifies; hits creeps) ---

  test('cast burst: enemy-only AoE damages an enemy hero in radius; OWNER takes 0', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final caster = sim.entity(0); // Cinderfang self-places at his feet (0,7)
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    caster.pos = spot;
    caster.target = spot;
    final enemy = sim.entity(1)..pos = FVec2(Fixed.fromNum(1), Fixed.fromInt(7)); // dist 1 < radius 2.5
    enemy.target = enemy.pos;
    final enemyHpBefore = enemy.hp.raw;
    final casterHpBefore = caster.hp.raw;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1)]);
    expect(enemy.hp.raw, enemyHpBefore - kCastBurstDamage.raw); // enemy took the (un-amplified) burst
    expect(enemy.statusElement, Element.pyro.index); // coated by the burst
    expect(caster.hp.raw, casterHpBefore); // OWNER took ZERO (self-safe)
  });

  test('cast burst hits neutral creeps in radius (cooldown-gated AoE farm)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final caster = sim.entity(0);
    final spot = FVec2(Fixed.fromInt(-8), Fixed.zero); // own side, creep tower-safe
    caster.pos = spot;
    caster.target = spot;
    final creep = sim.entity(kCreepIdBase)..pos = spot;
    final creepHpBefore = creep.hp.raw;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(kFirstWaveTick + 1,
        const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 0, seq: 1)]);
    expect(creep.hp.raw, creepHpBefore - kCastBurstDamage.raw); // creep (team 2) is an enemy → hit
    expect(creep.statusElement, Element.pyro.index); // and coated
  });

  test('cast burst amplifies (×kVaporizeMult) when the enemy was pre-coated with a different element', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final caster = sim.entity(0); // Pyro burst
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    caster.pos = spot;
    caster.target = spot;
    final enemy = sim.entity(1)..pos = FVec2(Fixed.fromNum(1), Fixed.fromInt(7));
    enemy.target = enemy.pos;
    enemy.statusElement = Element.hydro.index; // pre-coated opposite
    enemy.statusTimer = 30;
    final enemyHpBefore = enemy.hp;
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1)]);
    // The burst amplifies (×mult); the same-tick field then re-coats the (now -1) enemy with Pyro.
    expect(enemy.hp.raw, (enemyHpBefore - (kCastBurstDamage * kVaporizeMult)).raw);
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.multiplierRaw, kVaporizeMult.raw); // amplify, not flat
    expect(rt.sourceId, 0);
    expect(rt.unitId, 1);
  });

  // --- Shared ICD across both reaction paths ---

  test('shared reactionIcd: a field reaction + an auto in one window yield ONE reaction', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h0 = sim.entity(0); // Pyro field owner + Pyro auto
    final h1 = sim.entity(1); // victim, pre-coated Hydro (opposite)
    h0.pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h1.pos = FVec2(Fixed.fromNum(1), Fixed.fromInt(7)); // in field + auto range
    h0.target = h0.pos;
    h1.target = h1.pos;
    h1.statusElement = Element.hydro.index;
    h1.statusTimer = 30;
    sim.fields.add(ElementalField(
        ownerId: 0, center: h0.pos, element: Element.pyro.index, timer: 100));
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(events.whereType<ReactionTriggered>(), hasLength(1)); // field reacts; the auto is ICD-blocked
  });
}
```

Then update `packages/sim/test/elements_data_test.dart` — the **existing** budget test still lists `kFieldDotDamage` (removed in this task). Replace:
```dart
    for (final f in <Fixed>[kVaporizeMult, kFieldRadius, kFieldRadiusSq, kFieldDotDamage]) {
```
with:
```dart
    for (final f in <Fixed>[kVaporizeMult, kFieldRadius, kFieldRadiusSq]) {
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/reaction_test.dart packages/sim/test/elements_data_test.dart`
Expected: FAIL — the field-flat reaction tests fail (old `_stepFields` deals DoT, not a flat enemy-only reaction); the cast-burst tests fail (no burst); `elements_data_test` may fail to compile until `kFieldDotDamage` is removed in Step 3. (If the compile error blocks the run, that is the expected red — proceed to Step 3.)

- [ ] **Step 3: Implement the v2 damage model**

(a) In `packages/sim/lib/src/data/elements.dart`, remove the deprecated DoT constant. Delete the line:
```dart
final Fixed kFieldDotDamage = Fixed.fromNum(1); // DEPRECATED (Plan 4 DoT); removed in Plan 5 Task 2
```

(b) In `packages/sim/lib/src/simulation.dart`, in `step()`'s phase-1 `ability` branch, deal the cast burst after the cooldown is stamped. Replace:
```dart
        _fields.add(ElementalField(
            ownerId: hero.id,
            center: center,
            element: heroElement(hero.id),
            timer: kFieldDurationTicks));
        hero.abilityCooldown = kAbilityCooldownTicks;
      }
```
with:
```dart
        _fields.add(ElementalField(
            ownerId: hero.id,
            center: center,
            element: heroElement(hero.id),
            timer: kFieldDurationTicks));
        hero.abilityCooldown = kAbilityCooldownTicks;
        // Plan 5: a one-time ENEMY-ONLY burst centered on the field (own-team safe).
        _castBurst(hero, center, heroElement(hero.id), events);
      }
```

(c) In `packages/sim/lib/src/simulation.dart`, update the `_applyHit` **doc comment only** (the method body is unchanged). Replace the doc block above `_applyHit`:
```dart
  /// Element-application chokepoint (Plan 4). Autos + field ticks route through
  /// here; towers (non-elemental) call _applyDamage directly. Only heroes/creeps
  /// carry status. A 0-damage coat (a creep field tick) skips _applyDamage so it
  /// neither last-hits nor spams DamageDealt. A differing element on an already-
  /// coated, ICD-ready unit detonates Vaporize (amplify + consume + emit).
```
with:
```dart
  /// Element-application chokepoint for DAMAGING hits (Plan 5). Autos and the
  /// enemy-only cast burst route through here; towers (non-elemental) call
  /// _applyDamage directly; field ticks coat/react INLINE in _stepFields (they no
  /// longer route here). Only heroes/creeps carry status. A different element on an
  /// already-coated, ICD-ready unit detonates an attack-amplify Vaporize
  /// (×kVaporizeMult on the triggering hit + consume + ICD + emit). Callers only
  /// ever pass ENEMY targets, so the amplified damage is inherently self-safe.
```

(d) In `packages/sim/lib/src/simulation.dart`, replace the entire `_stepFields` method (and add `_castBurst`). Replace:
```dart
  /// Field ticks: every active field coats each hero/creep within its radius
  /// (2-sided — the owner is not exempt). DoT is real on heroes, ZERO on creeps
  /// (coat-not-farm). Iterates entityIdsSorted for determinism.
  void _stepFields(List<SimEvent> events) {
    for (final f in _fields) {
      for (final id in entityIdsSorted) {
        final u = _byId[id]!;
        if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
        if (u.hp.raw <= 0) continue;
        if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
        if ((u.pos - f.center).lengthSq() > kFieldRadiusSq) continue;
        final dot = u.kind == EntityKind.creep ? Fixed.zero : kFieldDotDamage;
        // Owner is always a hero, and heroes are downed-not-removed, so
        // _byId[f.ownerId] is non-null while the field is alive: the respawn
        // block clears _fields for any returning hero, and _removeEntity (creeps/
        // structures) never touches _fields.
        _applyHit(_byId[f.ownerId]!, u, dot, f.element, events);
      }
    }
  }
```
with:
```dart
  /// Field ticks (Plan 5): every active field, in stable list order, processes
  /// each hero/creep within its radius (2-sided — the owner is not exempt). A
  /// field deals NO DoT. If the unit carries a DIFFERENT element and its ICD is
  /// ready it detonates a field-overlap Vaporize: status consumed, ICD stamped,
  /// ReactionTriggered emitted (multiplierRaw 0 = "flat"), and FLAT
  /// kReactionFlatDamage dealt — but ONLY to an enemy of the field owner
  /// (owner/own-team take 0; the self-safety invariant). Otherwise the unit is
  /// coated (set/refresh, no damage). Iterates entityIdsSorted for determinism.
  void _stepFields(List<SimEvent> events) {
    for (final f in _fields) {
      // Owner is always a hero, and heroes are downed-not-removed, so
      // _byId[f.ownerId] is non-null while the field is alive: the respawn block
      // clears _fields for any returning hero, and _removeEntity (creeps/
      // structures) never touches _fields.
      final owner = _byId[f.ownerId]!;
      for (final id in entityIdsSorted) {
        final u = _byId[id]!;
        if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
        if (u.hp.raw <= 0) continue;
        if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
        if ((u.pos - f.center).lengthSq() > kFieldRadiusSq) continue;
        if (u.statusElement != -1 &&
            u.statusElement != f.element &&
            u.reactionIcd == 0) {
          // Field-overlap Vaporize. Fires 2-sided (consume + ICD + event); damage
          // lands ONLY on an enemy of the owner (own-team takes 0).
          u.statusElement = -1;
          u.statusTimer = 0;
          u.reactionIcd = kReactionIcdTicks;
          events.add(ReactionTriggered(
              unitId: u.id,
              reaction: Reaction.vaporize.index,
              multiplierRaw: 0, // flat: no triggering hit to amplify
              sourceId: f.ownerId));
          if (u.teamId != owner.teamId) {
            _applyDamage(owner, u, kReactionFlatDamage, events);
          }
        } else {
          // Coat (set/refresh). No damage. 2-sided. A different element suppressed
          // by an active ICD also lands here (overwrites; ICD gates only detonation).
          u.statusElement = f.element;
          u.statusTimer = kStatusDurationTicks;
        }
      }
    }
  }

  /// Cast burst (Plan 5): a one-time ENEMY-ONLY AoE hit centered on a freshly
  /// placed field. Routes each enemy hero/creep in radius through _applyHit, so it
  /// applies the caster's element AND triggers an attack-amplify Vaporize
  /// (×kVaporizeMult) on an already-differently-coated enemy. Own-team is excluded
  /// → self-safe. Iterates entityIdsSorted for determinism.
  void _castBurst(Entity caster, FVec2 center, int element, List<SimEvent> events) {
    for (final id in entityIdsSorted) {
      final u = _byId[id]!;
      if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
      if (u.hp.raw <= 0) continue;
      if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
      if (u.teamId == caster.teamId) continue; // ENEMY-ONLY (own-team safe)
      if ((u.pos - center).lengthSq() > kFieldRadiusSq) continue;
      _applyHit(caster, u, kCastBurstDamage, element, events);
    }
  }
```

- [ ] **Step 4: Run to verify it passes + confirm no stray references**

Run: `dart test packages/sim/test/reaction_test.dart packages/sim/test/elements_data_test.dart`
Expected: PASS (all reaction + budget tests).

Run (Git Bash): `grep -rn kFieldDotDamage packages/sim apps tooling`
Expected: NO matches (the constant is fully removed).

Run: `dart test packages/sim`
Expected: PASS — incl. the in-test anchor `0x0fbfb7ac` (move-only, empty `_fields` → unchanged) and `elemental_fixture_test` (`reactions > 0` still holds: overlapping opposite fields still detonate, even own-team 0-damage ones).

- [ ] **Step 5: Confirm smoke/combat unchanged, then re-pin elemental.golden**

First prove the untouched fixtures did NOT move (Git Bash):
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json   # PASS: byte-identical ... then PASS: matches golden 7e4aa28f
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json  # PASS: byte-identical ... then PASS: matches golden 04da965a
```
Expected: both end with `PASS: matches golden ...`. **If either FAILs the golden compare, STOP** — that is a bug (a fixture that should not react now reacts, or a phase/draw moved); investigate before touching any golden.

Then re-pin `elemental.golden` via the **Re-Pin Procedure** above:
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json   # PASS byte-identical, then FAIL vs stale golden (expected)
b64=$(base64 -w0 tooling/replay_fixtures/elemental.json) \
  && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart \
     | awk '/^REPLAY_HASH /{print $2}' > tooling/replay_fixtures/elemental.golden
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json   # PASS byte-identical, then PASS: matches golden
```

- [ ] **Step 6: Verify the rest of the workspace still builds/tests**

Run: `dart test packages/netcode && dart test packages/protocol && dart test apps/server`
Expected: PASS (no serialization/protocol change; they round-trip snapshots at the same unchanged version).

- [ ] **Step 7: Commit**
```bash
git add packages/sim/lib/src/data/elements.dart packages/sim/lib/src/simulation.dart \
        packages/sim/test/reaction_test.dart packages/sim/test/elements_data_test.dart \
        tooling/replay_fixtures/elemental.golden
git commit -m "feat(sim): damage model v2 — coat-only fields + enemy-only cast burst + field-flat reaction; re-pin elemental.golden"
```

---

## Task 3: Server one-shot ability — `IntentBuffer` holds move/attack, drains a one-shot ability (golden-neutral)

**Files:**
- Modify: `apps/server/lib/src/loop/intent_buffer.dart`
- Modify: `apps/server/test/intent_buffer_test.dart`
- Modify: `apps/server/test/match_test.dart`

> **Netcode-only, golden-neutral.** Root cause: `drainForTick()` never clears `_current[slot]`, so a still-held `ability` re-fires every `kAbilityCooldownTicks` once its cooldown lapses. Fix: keep `_held[slot]` (move/attack, last-writer-wins, persistent) and a separate one-shot `_pendingAbility[slot]` that `drainForTick` emits once then clears. The sim already sorts intents by `(playerSlot, seq)`, so drain order is normalized. No sim/serialization change.

- [ ] **Step 1: Write the failing tests**

Append to `apps/server/test/intent_buffer_test.dart` (inside `main()`):
```dart
  test('ability is one-shot: drained once then cleared (no auto-recast)', () {
    final b = IntentBuffer();
    b.accept(const InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 0, aimY: 0, type: 3)); // type 3 = ability
    final first = b.drainForTick();
    expect(first.where((i) => i.type == IntentType.ability), hasLength(1)); // fires this tick
    final second = b.drainForTick();
    expect(second.where((i) => i.type == IntentType.ability), isEmpty); // NOT repeated next tick
  });

  test('a held move persists while a one-shot ability fires exactly once', () {
    final b = IntentBuffer();
    b.accept(input(0, 1, aimX: 100)); // move (type 1), held
    b.accept(const InputMsg(
        slot: 0, seq: 2, clientTick: 0, aimX: 5, aimY: 0, type: 3)); // ability
    final t0 = b.drainForTick();
    expect(t0.where((i) => i.type == IntentType.move), hasLength(1));
    expect(t0.where((i) => i.type == IntentType.ability), hasLength(1));
    final t1 = b.drainForTick();
    expect(t1.where((i) => i.type == IntentType.move), hasLength(1)); // move still held
    expect(t1.where((i) => i.type == IntentType.ability), isEmpty); // ability gone
    expect(b.lastAckedSeq[0], 2); // both inputs acked
  });
```

Append to `apps/server/test/match_test.dart` (inside `main()`):
```dart
  test('a held ability does NOT auto-recast after its cooldown (one-shot)', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    final sim = Simulation.create(const SimConfig(seed: 1));
    Match(seed: 1, sim: sim, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..start();
    // Hero 1 casts once (aim irrelevant; no enemy in range → no burst kills).
    p1.receive(ProtocolCodec.encode(InputMsg(
        slot: 1, seq: 1, clientTick: 0, aimX: 0, aimY: 0, type: IntentType.ability.index)));
    driver.pump(1); // tick 0 applies the cast
    expect(sim.fields.where((f) => f.ownerId == 1), hasLength(1));
    // Run past field expiry AND a full ability cooldown. With the one-shot fix the
    // still-held cast must NOT re-fire (creeps spawn at tick 450, well past here).
    driver.pump(kAbilityCooldownTicks + 5);
    expect(sim.fields.where((f) => f.ownerId == 1), isEmpty); // expired, not recast
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test apps/server/test/intent_buffer_test.dart apps/server/test/match_test.dart`
Expected: FAIL — the held ability is re-drained every tick (`second`/`t1` still contain an ability), and the match recasts the field after the cooldown (the new field count is `1`, not `0`).

- [ ] **Step 3: Implement the held/one-shot split**

Replace the entire body of `apps/server/lib/src/loop/intent_buffer.dart`:
```dart
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

/// Per-slot input frontier. Dedupes by seq, tracks the ack frontier reported in
/// snapshots, and yields each tick's intents: a HELD move/attack (last-writer-
/// wins, persistent — heroes keep seeking) plus a ONE-SHOT ability that fires the
/// tick it is drained and is then cleared (an ability is an edge-triggered action,
/// not a held state — a held ability would auto-recast every cooldown). PURE.
class IntentBuffer {
  final List<int> lastAckedSeq = [0, 0];
  final List<Intent?> _held = [null, null]; // persistent move/attack
  final List<Intent?> _pendingAbility = [null, null]; // one-shot, cleared on drain

  /// Accept an inbound input. Returns false if stale/duplicate/out-of-range.
  bool accept(InputMsg msg) {
    final slot = msg.slot;
    if (slot < 0 || slot > 1) return false;
    if (msg.type < 0 || msg.type >= IntentType.values.length) return false;
    if (msg.seq <= lastAckedSeq[slot]) return false;
    lastAckedSeq[slot] = msg.seq;
    final intent = Intent(
      playerSlot: slot,
      type: IntentType.values[msg.type],
      aimX: msg.aimX,
      aimY: msg.aimY,
      seq: msg.seq,
      clientTick: msg.clientTick,
    );
    if (intent.type == IntentType.ability) {
      _pendingAbility[slot] = intent; // one-shot
    } else {
      _held[slot] = intent; // move/attack: persistent, last-writer-wins
    }
    return true;
  }

  /// The intents to apply this tick: held move/attack (NOT cleared) + any pending
  /// one-shot ability (cleared after this drain). The sim re-sorts by
  /// (playerSlot, seq), so append order here is not load-bearing.
  List<Intent> drainForTick() {
    final out = <Intent>[];
    for (final i in _held) {
      if (i != null) out.add(i);
    }
    for (var slot = 0; slot < 2; slot++) {
      final a = _pendingAbility[slot];
      if (a != null) {
        out.add(a);
        _pendingAbility[slot] = null; // one-shot: fire once, then clear
      }
    }
    return out;
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test apps/server/test/intent_buffer_test.dart apps/server/test/match_test.dart`
Expected: PASS (the new tests + the existing held-move/ack/core-destroyed tests).

Run: `dart test apps/server`
Expected: PASS (full server suite).

- [ ] **Step 5: Commit**
```bash
git add apps/server/lib/src/loop/intent_buffer.dart apps/server/test/intent_buffer_test.dart \
        apps/server/test/match_test.dart
git commit -m "fix(server): one-shot ability intent (held move/attack + a drained-once _pendingAbility)"
```

---

## Task 4: Client one-shot ability — `MatchController` fires the ability only at its `clientTick` (golden-neutral)

**Files:**
- Modify: `packages/netcode/lib/src/match_controller.dart`
- Modify: `packages/netcode/test/match_controller_test.dart`

> **Netcode-only, golden-neutral.** The client mirrors the server: `_heldAt(t)` re-feeds the latest pending intent every tick (correct for move/attack, wrong for a one-shot ability → auto-recast). Replace it with `_intentsAt(t)` that returns the held move/attack PLUS any ability whose `clientTick == t`, used in **both** forward prediction (`advanceClientTick`) and reconcile re-steps (`onServerSnapshot`) so prediction matches the authority. Unacked ability intents stay in `_pending` for reconcile re-application and drop on ack as usual.

- [ ] **Step 1: Write the failing tests**

Add the typed-data import at the top of `packages/netcode/test/match_controller_test.dart` (after the existing imports):
```dart
import 'dart:typed_data';
```
Append to `packages/netcode/test/match_controller_test.dart` (inside `main()`):
```dart
  test('one-shot ability: a single cast places ONE field and does NOT auto-recast after cooldown', () {
    final c = MatchController(seed: 1, localSlot: 1, startTick: 0);
    c.applyAbilityInput(0, 458752); // Marisol casts once at world (0,7) on tick 0
    c.advanceClientTick(); // tick 0: the field is placed
    expect(c.update(0).fields, hasLength(1)); // cast fired exactly once
    // Advance through field expiry AND a full ability cooldown cycle.
    for (var i = 0; i < kAbilityCooldownTicks + 5; i++) {
      c.advanceClientTick();
    }
    expect(c.update(0).fields, isEmpty); // expired and NOT auto-recast (the bug)
  });

  test('held move persists across ticks while a one-shot ability fires once', () {
    final c = MatchController(seed: 0, localSlot: 0, startTick: 0);
    final startX = c.debugLocalPos().x.raw;
    c.applyLocalInput(655360, 0); // move right (held)
    c.applyAbilityInput(655360, 0); // and cast once (same tick 0)
    for (var i = 0; i < 30; i++) {
      c.advanceClientTick();
    }
    expect(c.debugLocalPos().x.raw, greaterThan(startX)); // kept moving (move is held)
    expect(c.update(0).fields.where((f) => f.ownerId == 0), hasLength(1)); // one field (duration 120 > 30)
  });

  test('reconcile reproduces a SINGLE cast (no re-fire): exact hash match', () {
    final server = Simulation.create(const SimConfig(seed: 1337));
    final c = MatchController(seed: 1337, localSlot: 0, startTick: 0);
    const cast = Intent(
        playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 0, seq: 1, clientTick: 0);
    c.applyAbilityInput(0, 0); // client casts at tick 0 (seq 1, clientTick 0)
    Uint8List? snapBytes;
    for (var t = 0; t < 10; t++) {
      server.step(t, t == 0 ? const [cast] : const []); // server casts once at tick 0
      if (t == 4) snapBytes = server.snapshotBytes(); // reconcile anchor (tick 4)
      c.advanceClientTick();
    }
    // Snapshot at tick 4 acks the cast (seq 1) → client prunes it; reconcile
    // restores the authoritative (single) field and re-steps 5..9 WITHOUT re-firing.
    // Both server and client end at tick 9, so their canonical state must match.
    final snap = SnapshotMsg(serverTick: 4, ackedSeq: const [1, 0], stateBytes: snapBytes!);
    c.onServerSnapshot(snap);
    expect(c.debugHash(), server.canonicalStateHash()); // EXACT: cast applied once, not re-fired
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/netcode/test/match_controller_test.dart`
Expected: FAIL — with the held-ability behavior, the field auto-recasts after the cooldown (first test sees a non-empty `fields`), and reconcile re-fires the ability during re-steps (hash mismatch).

- [ ] **Step 3: Implement `_intentsAt`**

In `packages/netcode/lib/src/match_controller.dart`, replace the `_heldAt` method:
```dart
  /// The held local intent in effect at tick [t] = latest pending with clientTick <= t.
  Intent? _heldAt(int t) {
    Intent? held;
    for (final p in _pending) {
      if (p.clientTick <= t) {
        held = p.intent;
      } else {
        break;
      }
    }
    return held;
  }
```
with:
```dart
  /// The local intents to apply at client tick [t]: the held move/attack (latest
  /// pending with clientTick <= t, last-writer-wins) PLUS any one-shot ability
  /// whose clientTick == t. Abilities are edge-triggered (fire once on their
  /// issuing tick); move/attack persist. Used in BOTH forward prediction and
  /// reconcile re-steps so prediction matches the server (which one-shots the
  /// ability too). _pending is ordered by clientTick → the break is safe.
  List<Intent> _intentsAt(int t) {
    Intent? held;
    final out = <Intent>[];
    for (final p in _pending) {
      if (p.clientTick > t) break;
      if (p.intent.type == IntentType.ability) {
        if (p.clientTick == t) out.add(p.intent); // one-shot: only on its issuing tick
      } else {
        held = p.intent; // latest move/attack persists
      }
    }
    if (held != null) out.add(held);
    return out;
  }
```

In `advanceClientTick`, replace:
```dart
    final held = _heldAt(_nextTick);
    final events = _predicted.step(_nextTick, held == null ? const [] : [held]);
```
with:
```dart
    final events = _predicted.step(_nextTick, _intentsAt(_nextTick));
```

In `onServerSnapshot`, replace the reconcile re-step loop:
```dart
    for (var t = snap.serverTick + 1; t < _nextTick; t++) {
      final held = _heldAt(t);
      _predicted.step(t, held == null ? const [] : [held]);
    }
```
with:
```dart
    for (var t = snap.serverTick + 1; t < _nextTick; t++) {
      _predicted.step(t, _intentsAt(t));
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/netcode`
Expected: PASS (the 3 new tests + all existing — move/attack still flow through `_intentsAt` as held).

- [ ] **Step 5: Commit**
```bash
git add packages/netcode/lib/src/match_controller.dart packages/netcode/test/match_controller_test.dart
git commit -m "fix(netcode): one-shot ability prediction (_intentsAt fires the cast only at its clientTick)"
```

---

## Task 5: Client pop-text — flat vs amplify ("VAPORIZE" vs "VAPORIZE x1.3")

**Files:**
- Modify: `apps/client/lib/render/reaction_label.dart`
- Modify: `apps/client/lib/render/guild_game.dart`
- Create: `apps/client/test/reaction_label_test.dart`

> Client package is `guild_client`. The field-overlap reaction carries `multiplierRaw == 0` (flat) and the attack-amplify reaction carries `kVaporizeMult.raw`; the pop-text must render `"VAPORIZE"` for flat and `"VAPORIZE x1.3"` for amplify. Extract a pure, testable `reactionText` helper (mirrors Plan 4's pure `elementColor`). Keeps the existing "x" glyph (consistent with the current label).

- [ ] **Step 1: Write the failing test**

Create `apps/client/test/reaction_label_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/render/reaction_label.dart';
import 'package:sim/sim.dart' show Reaction;

void main() {
  test('reactionText shows no multiplier for a flat (field-overlap) reaction', () {
    expect(reactionText(Reaction.vaporize.index, 0), 'VAPORIZE');
  });

  test('reactionText shows x1.3 for an attack-amplify reaction', () {
    // 85197 = Fixed.fromNum(1.3).raw (Q16.16) → 85197 / 65536 ≈ 1.3.
    expect(reactionText(Reaction.vaporize.index, 85197), 'VAPORIZE x1.3');
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd apps/client && flutter test test/reaction_label_test.dart`
Expected: FAIL — "The function 'reactionText' isn't defined".

- [ ] **Step 3: Add the pure helper + use it**

In `apps/client/lib/render/reaction_label.dart`, add the `kOne` import and the helper. Replace the import block:
```dart
import 'package:flame/components.dart';
import 'package:flutter/painting.dart'; // Flame's TextPaint needs Flutter's TextStyle (not exported by dart:ui)
```
with:
```dart
import 'package:flame/components.dart';
import 'package:flutter/painting.dart'; // Flame's TextPaint needs Flutter's TextStyle (not exported by dart:ui)
import 'package:sim/sim.dart' show kOne;

/// Pop-text for a reaction. A flat field-overlap reaction (multiplierRaw == 0)
/// shows no multiplier; an attack-amplify reaction shows "x1.3". (Reaction is
/// Vaporize-only in the slice; the param is kept for forward labels.)
String reactionText(int reaction, int multiplierRaw) {
  if (multiplierRaw == 0) return 'VAPORIZE';
  final mult = multiplierRaw / kOne; // Q16.16 raw → double (int / int = double in Dart)
  return 'VAPORIZE x${mult.toStringAsFixed(1)}';
}
```

In `apps/client/lib/render/guild_game.dart`, drop the now-unused `kOne` import. Replace:
```dart
import 'package:sim/sim.dart' show EntityKind, kOne;
```
with:
```dart
import 'package:sim/sim.dart' show EntityKind;
```
Then replace the reaction pop-text spawn block:
```dart
    // Spawn a pop-text per reaction that fired this frame.
    for (final r in binding.drainReactions()) {
      final mult = r.multiplierRaw / kOne; // Q16.16 raw → double (int / int = double in Dart)
      world.add(ReactionLabel(
        text: 'VAPORIZE x${mult.toStringAsFixed(1)}',
        position: Vector2(worldToFlameX(r.x), worldToFlameY(r.y)),
      ));
    }
```
with:
```dart
    // Spawn a pop-text per reaction that fired this frame (flat vs amplify).
    for (final r in binding.drainReactions()) {
      world.add(ReactionLabel(
        text: reactionText(r.reaction, r.multiplierRaw),
        position: Vector2(worldToFlameX(r.x), worldToFlameY(r.y)),
      ));
    }
```

- [ ] **Step 4: Run analyze + tests**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: analyze clean (no unused-import warning for `kOne`); `reaction_label_test` PASSES; existing client tests PASS.

- [ ] **Step 5: Commit**
```bash
git add apps/client/lib/render/reaction_label.dart apps/client/lib/render/guild_game.dart \
        apps/client/test/reaction_label_test.dart
git commit -m "feat(client): pop-text distinguishes flat 'VAPORIZE' from amplify 'VAPORIZE x1.3'"
```

---

## Task 6: Whole-branch verification + finishing

**Files:** none (verification + integration).

> Final green-everything gate (mirrors CI), whole-branch review, then branch completion. No new code unless the review surfaces a fix (each fix follows TDD; any fix touching `canonicalBytes` re-pins per the Re-Pin Procedure — but this plan does not change the byte layout).

- [ ] **Step 1: Full determinism + test sweep**

Run each and confirm PASS:
```bash
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
dart test packages/sim
dart test packages/protocol
dart test packages/netcode
dart test apps/server
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json      # PASS: matches golden 7e4aa28f
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json     # PASS: matches golden 04da965a
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json  # PASS: matches golden (re-pinned)
( cd apps/client && flutter analyze && flutter test )
```
Expected: every command exits 0; each `compare_replays.sh` prints `PASS: byte-identical ...` then `PASS: matches golden ...`. smoke/combat MUST still read `7e4aa28f`/`04da965a`.

- [ ] **Step 2: Cross-runtime sim + netcode tests (mirror CI)**

```bash
dart test packages/sim -p node
dart test packages/sim -p node -c dart2wasm
dart test packages/netcode -p node
dart test packages/netcode -p node -c dart2wasm
```
Expected: PASS on both node (dart2js) and dart2wasm — proves the v2 damage math (burst multiply, flat subtract, `lengthSq` membership) and the one-shot prediction are bit-identical off-native.

- [ ] **Step 3: Whole-branch review**

Use **superpowers:requesting-code-review** for the whole branch (`main..plan-5-elemental-v2`). Focus the reviewer on: the **self-safety invariant** (no cast-burst or field-flat-reaction damage to `teamId == sourceTeam`; owner/own-team take 0 yet the field reaction still consumes + ICDs + emits); the determinism contract (no `dart:math`, `lengthSq`-only membership, no new RNG draw, `entityIdsSorted`/stable `_fields` iteration); the byte layout being **unchanged** (no version bump; only `elemental.golden` re-pinned; smoke/combat/anchor fixed); and the one-shot ability (server `_pendingAbility` cleared on drain; client `_intentsAt` fires the cast only at its `clientTick` in prediction AND reconcile; held move/attack persist). Address findings via **superpowers:receiving-code-review** (verify before implementing).

- [ ] **Step 4: Finish the branch**

Use **superpowers:finishing-a-development-branch** to present merge/PR/cleanup options. **Do not merge to `main` without the user's choice.**

---

## Plan Self-Review (author check — completed)

- **Spec coverage:** §1 model table → status-no-damage (T2 tests), coat-only no-DoT (T2), enemy-only cast burst (T2), two reaction paths (T2), enemy-only damage (T2), creeps hit (T2), one-shot ability (T3+T4). §2 fields coat-only → T2 `_stepFields`. §3 cast burst → T2 `_castBurst` + ability branch. §4.1 attack-amplify → `_applyHit` retained (T2), tested via auto + burst. §4.2 field-flat (enemy-of-owner, owner 0, consume/ICD/emit, multiplierRaw 0) → T2 `_stepFields`. §5 autos → retained (T2). §6 self-safety → T2 (burst team-gate + field-flat damage gate). §7 one-shot → T3 (server) + T4 (client). §8 tunables → T1 (add) + T2 (remove DoT). §9 determinism/re-pin → T2 Step 5 (elemental only) + T6 cross-runtime. §10 netcode/client → T4 (one-shot) + T5 (pop-text). §12 tests → reaction_test rewrite (T2), netcode/server one-shot (T3/T4), fixture unchanged (`reactions > 0` still holds), client palette unchanged, full sweep (T6).
- **Placeholder scan:** no TBD/TODO/"handle edge cases"; every code step shows complete code; the re-pin step cites the procedure and reads the new hash from harness output (never guessed) — correct for a plan.
- **Type consistency (checked across tasks):** `kCastBurstDamage`/`kReactionFlatDamage` (T1) used in `_castBurst`/`_stepFields` (T2) and reaction_test (T2); `_castBurst(caster, center, element, events)` signature matches its call in the ability branch (T2); `_stepFields(events)` call site unchanged (T2); `_applyHit(source, target, baseDamage, element, events)` unchanged, called by autos (existing) + `_castBurst` (T2); `ReactionTriggered{unitId,reaction,multiplierRaw,sourceId}` emitted with `multiplierRaw: 0` (flat, T2) and `kVaporizeMult.raw` (amplify, existing) → consumed by `reactionText(reaction, multiplierRaw)` (T5); server `_held`/`_pendingAbility` (T3) ↔ client `_intentsAt` (T4) mirror each other; `IntentType.ability.index == 3` used in T3 tests + the codec (unchanged).
- **Golden bookkeeping:** T2 re-pins `elemental.golden` **only**; smoke (`7e4aa28f`), combat (`04da965a`), and the in-test anchor (`0x0fbfb7ac`) are verified UNCHANGED in T2 Step 4/5 and T6 Step 1. T1/T3/T4/T5 are golden-neutral (additive constant / netcode-only / client-only). No version bump, no in-test literal moves (byte layout unchanged).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-07-plan-5-elemental-v2.md`. Per the requested workflow, this will be executed **subagent-driven** (superpowers:subagent-driven-development): a fresh implementer per task, then a two-stage review (spec-compliance, then code-quality) with fix loops, then a final whole-branch review (`main..plan-5-elemental-v2`), then finishing-a-development-branch.
