# Plan 7 (Part 1): Combat-feel + Controls Completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make right-click attack-move stop at attack range (sim), bind **Q** to a placeholder ultimate (a bigger field-burst on a long independent cooldown), and show a live cursor aim reticle while a skill is armed.

**Architecture:** Three slices. **Part A** is a one-branch pursuit change in `Simulation.step()` (stop when already in range) → re-pins `combat.golden` at schema **v3**. **Part C** adds one serialized `Entity.ultCooldown` field + an `IntentType.ultimate` + ult constants → the single sanctioned **version bump 3/3→4/4**, a deliberate re-pin of ALL goldens + both `0x0fbfb7ac` anchors + a new `ult` fixture, then the cross-package one-shot plumbing (netcode/server/protocol) and client Q input. **Part B** is an `apps/client`-only reticle reusing the `DashedCircle` component. Order **A → C(sim) → C(plumbing) → B** so A's golden move is attribution-clean *before* C's version bump, and B reads C's ult radius.

**Tech Stack:** Dart 3.11.5 pure-Dart `sim` (Q16.16 `Fixed` + int only); `protocol`/`netcode`/`apps/server` Dart; Flutter + Flame `^1.30.0` client (`flutter_test` only — no Flame test harness); `tooling/replay_harness.dart` + `tooling/compare_replays.sh` (native + dart2js/node + dart2wasm/node, all present locally).

**Spec:** `docs/superpowers/specs/2026-06-09-plan7-combat-feel-controls-design.md`. **Branch:** `feat/plan7-combat-feel-controls` off `main` (`71bd68e`) — already checked out.

**Determinism invariants:** `packages/sim/lib` is Q16.16 `Fixed` + `int` only, `|value| < 32768`; no `dart:math`/`Random`/`DateTime`/`Stopwatch`; no new RNG draw; iterate `entityIdsSorted`/stable lists; append-only enums; preserve the 5-phase `step()` order. Part A changes behavior only (no field/constant/version). Part C adds exactly **one** serialized field (`ultCooldown`) → bump `kSchemaVersion` **and** `kSnapshotVersion` 3→4 and re-pin **every** golden + the in-test anchor. **No protocol byte-layout/version change** — the intent `type` already rides the wire as a raw i32 (`codec.dart:31/64`).

**Important for the implementer:** the repo is already on `feat/plan7-combat-feel-controls` — **do NOT run `git checkout`/`git switch`**. Sim unit assertions are mostly symbolic; the in-test anchor `0x0fbfb7ac` is the one literal that is deliberately re-pinned (Task 2). If any OTHER sim test fails after a change, that is a real regression to investigate, not a literal to edit.

---

## File Structure

**Part A (Task 1) — sim behavior + v3 re-pin:**
- Modify: `packages/sim/lib/src/simulation.dart` — phase-2 pursue (lines 141-151): stop-at-range branch.
- Test: `packages/sim/test/combat_test.dart` — add a stop-at-range test.
- Re-pin: `tooling/replay_fixtures/combat.golden` (v3; `030f2343` → derived).

**Part C sim (Task 2) — the version bump:**
- Modify: `packages/sim/lib/src/model/entity.dart` — `int ultCooldown` field.
- Modify: `packages/sim/lib/src/model/intent.dart` — `IntentType.ultimate` + `IntentTypeX.isOneShot`.
- Modify: `packages/sim/lib/src/data/elements.dart` — ult constants.
- Modify: `packages/sim/lib/src/simulation.dart` — `kSchemaVersion`/`kSnapshotVersion` 3→4; phase-1 `ultimate` intent branch.
- Modify: `packages/sim/lib/src/simulation_combat.dart` — `ultCooldown` tick-down.
- Modify: `packages/sim/lib/src/simulation_elemental.dart` — parametrize `_castBurst`.
- Modify: `packages/sim/lib/src/simulation_serialization.dart` — `ultCooldown` codec row.
- Test: `packages/sim/test/combat_test.dart`, `packages/sim/test/snapshot_test.dart`, `packages/sim/test/model_test.dart` (or `intent`-focused) — ult behavior + round-trip + `isOneShot`.
- Re-pin: `tooling/replay_fixtures/{smoke,combat,elemental}.golden` (v4) + **both** anchor literals (`packages/sim/test/simulation_test.dart:59`, `packages/sim/test/snapshot_test.dart:54`).
- Create: `tooling/replay_fixtures/ult.json` + `tooling/replay_fixtures/ult.golden`.
- Modify: `.github/workflows/sim-determinism.yml` — add the `ult` fixture compare.

**Part C plumbing (Task 3) — cross-package, determinism-neutral:**
- Modify: `packages/netcode/lib/src/match_controller.dart` — `applyUltimateInput` + `isOneShot` usage.
- Modify: `packages/netcode/lib/test_support/fake_transport.dart` — mirror the ultimate one-shot.
- Modify: `apps/server/lib/src/loop/intent_buffer.dart` — `isOneShot` for one-shot routing.
- Modify: `apps/client/lib/match/match_binding.dart` — `submitUltimate`.
- Modify: `apps/client/lib/match/skill_input.dart` — `SkillSlot` + two-slot arming.
- Modify: `apps/client/lib/render/guild_game.dart` — Q key.
- Test: `packages/netcode/test/match_controller_test.dart`, `packages/protocol/test/codec_test.dart`, `apps/client/test/skill_input_test.dart`.

**Part B (Task 4) — client reticle:**
- Modify: `apps/client/lib/render/coord.dart` — `fieldRingRadiusPx()` / `ultRingRadiusPx()`.
- Modify: `apps/client/lib/render/guild_game.dart` — pointer-move + reticle behind `kShowAimReticle`.
- Test: `apps/client/test/tower_range_ring_test.dart` (extend) or a new `aim_reticle_test.dart`.

**Untouched (asserted unchanged):** `packages/protocol/lib` wire layout, `apps/server/lib/src/loop/match.dart` tick order, the `byte_*`/`det_rng` unit-test hashes (FNV of fixed inputs — unaffected by the entity layout).

---

## Task 1: Part A — attack-move-to-range (sim; v3 `combat.golden` re-pin)

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart` (lines 141-151)
- Test: `packages/sim/test/combat_test.dart`
- Re-pin: `tooling/replay_fixtures/combat.golden`

- [ ] **Step 1: Write the failing stop-at-range test**

Append inside `main()` in `packages/sim/test/combat_test.dart`:
```dart
  test('a locked hero stops at attack range instead of overrunning onto the enemy', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Off-lane at y=7 so no tower fires (towers at y=0, range 4). Hero 1 stays put
    // (no intent → holds), hero 0 locks + pursues it from 5 units away.
    sim.entity(0).pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(5), Fixed.fromInt(7));
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    for (var t = 1; t < 120; t++) {
      sim.step(t, const []);
    }
    final dsq = (sim.entity(1).pos - sim.entity(0).pos).lengthSq().toDouble();
    final rangeSq = kHeroAttackRangeSq.toDouble(); // 9.0 (range 3)
    expect(dsq, lessThanOrEqualTo(rangeSq + 0.1), reason: 'must end within attack range');
    expect(dsq, greaterThan(7.0), reason: 'must stop at the range edge, not overrun to point-blank');
    expect(sim.entity(1).hp.toDouble(), lessThan(kHeroMaxHp.toDouble()), reason: 'fired while stopped');
  });
```

- [ ] **Step 2: Run it — expect FAIL (the hero overruns today)**

Run: `cd packages/sim && dart test test/combat_test.dart -p vm`
Expected: the new test FAILS — today pursue chases `tgt.pos`, so `dsq` collapses toward 0 (`greaterThan(7.0)` fails). All other tests still pass.

- [ ] **Step 3: Add the stop-at-range branch in pursue**

In `packages/sim/lib/src/simulation.dart`, phase 2 (lines 141-151), change the `else` so an in-range hero holds instead of chasing onto the enemy:
```dart
    // 2. Resolve pursue: a hero locked onto a valid enemy seeks its position;
    //    an invalid lock is dropped and the hero holds. Once within attack range
    //    the hero STOPS at the range edge (does not overrun onto the enemy).
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      if (e.attackTargetId == -1) continue;
      final tgt = _byId[e.attackTargetId];
      if (tgt == null || !_isAttackable(e, tgt)) {
        e.attackTargetId = -1;
        e.target = e.pos; // hold position
      } else if ((tgt.pos - e.pos).lengthSq() <= kHeroAttackRangeSq) {
        e.target = e.pos; // in range: stop here and fire (combat fires this tick too)
      } else {
        e.target = tgt.pos; // out of range: close the distance
      }
    }
```
No other change — no new field, constant, enum, or version.

- [ ] **Step 4: Run the sim suite + analyze — expect ALL GREEN**

Run: `cd packages/sim && dart analyze && dart test`
Expected: analyze clean; the new stop-at-range test passes; all other sim tests pass (the symbolic combat/last-hit/elemental assertions are unaffected by where a pursuing hero stops; the anchor `0x0fbfb7ac` is move-only, untouched).

- [ ] **Step 5: Attribution gate — confirm ONLY `combat.golden` moves at v3 (native hashes)**

Run from repo root (Bash tool):
```bash
for f in smoke combat elemental; do
  B64=$(base64 -w0 tooling/replay_fixtures/$f.json 2>/dev/null || base64 tooling/replay_fixtures/$f.json | tr -d '\n')
  H=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
  echo "$f -> $H (committed golden: $(tr -d '\r\n' < tooling/replay_fixtures/$f.golden))"
done
```
Expected: `smoke -> 7e4aa28f` (UNCHANGED — move-only), `elemental -> 717305eb` (UNCHANGED — its fixture uses only move+ability, no attack lock), `combat -> <NEW>` (CHANGED vs `030f2343` — the center brawl locks/pursues, so heroes now stop at range). **If smoke or elemental changed, STOP** — the pursuit change leaked; investigate before re-pinning.

Anchor check: `cd packages/sim && dart test test/simulation_test.dart test/snapshot_test.dart` → both `0x0fbfb7ac` anchors still PASS (move-only).

- [ ] **Step 6: Re-pin `combat.golden` (v3, native hash, single LF)**

Run from repo root:
```bash
B64=$(base64 -w0 tooling/replay_fixtures/combat.json 2>/dev/null || base64 tooling/replay_fixtures/combat.json | tr -d '\n')
NEW=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
printf '%s\n' "$NEW" > tooling/replay_fixtures/combat.golden
echo "re-pinned combat.golden -> $NEW"
git --no-pager diff -- tooling/replay_fixtures/combat.golden
```
Expected: the diff shows only the single hash line changing from `030f2343`.

- [ ] **Step 7: Cross-runtime parity**

Run:
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
```
Expected: combat → `PASS: byte-identical across native/js/wasm` + `PASS: matches golden`; smoke + elemental → both `PASS: matches golden` (`7e4aa28f` / `717305eb`).

- [ ] **Step 8: Scope guard + commit**

```bash
git diff --quiet main -- packages/netcode packages/protocol apps/server packages/sim/lib/src/model && echo "SCOPE OK (behavior-only)"
git add packages/sim/lib/src/simulation.dart packages/sim/test/combat_test.dart tooling/replay_fixtures/combat.golden
git commit -m "feat(sim): right-click attack-move stops at range (no overrun) + re-pin combat.golden"
```
`SCOPE OK` must print. Commit only those three files.

> Note: this v3 `combat.golden` value is re-pinned again at v4 in Task 2. Doing it here keeps the repo green per-commit AND proves Part A's behavior change is attribution-clean before the version bump moves everything.

---

## Task 2: Part C (sim) — Q placeholder ultimate + version bump 3/3→4/4 + re-pin ALL goldens

**Files:** `entity.dart`, `intent.dart`, `data/elements.dart`, `simulation.dart`, `simulation_combat.dart`, `simulation_elemental.dart`, `simulation_serialization.dart`; tests in `combat_test.dart`, `snapshot_test.dart`, `model_test.dart`; re-pin `{smoke,combat,elemental}.golden` + both anchors; create `ult.json`/`ult.golden`; edit the CI workflow.

- [ ] **Step 1: Add `IntentType.ultimate` + the shared `isOneShot` predicate**

In `packages/sim/lib/src/model/intent.dart`, change line 1 and append the extension:
```dart
enum IntentType { none, move, attack, ability, ultimate }

/// One-shot (edge-triggered) intents fire on their issuing tick and never
/// re-feed; held intents (move/attack) persist. Shared by netcode + server so
/// they classify intents the same way the sim does.
extension IntentTypeX on IntentType {
  bool get isOneShot => this == IntentType.ability || this == IntentType.ultimate;
}
```
(`ultimate` is appended → index 4, append-only-safe; it rides the existing i32 `type` on the wire.)

- [ ] **Step 2: Add the `ultCooldown` field to `Entity`**

In `packages/sim/lib/src/model/entity.dart`, after the `abilityCooldown` field (line 49) add:
```dart
  /// Ticks until this hero's ULT (Q) is ready (0 = ready). Independent of
  /// [abilityCooldown]. Serialized (Plan 7 part 1; the v3→v4 byte-layout change).
  int ultCooldown;
```
And in the constructor (after `this.abilityCooldown = 0,`, line 68) add:
```dart
    this.ultCooldown = 0,
```

- [ ] **Step 3: Add the ult constants**

In `packages/sim/lib/src/data/elements.dart`, append after the existing damage-model block (after line 28):
```dart
// --- Plan 7 part 1: placeholder ultimate (Q) — "E, but bigger, on a long CD" ---
// Reuses the field + cast-burst machinery with ult-tier numbers; D replaces this
// content. Constants are NOT serialized → golden-neutral by themselves (only the
// new Entity.ultCooldown field + the version header move the goldens).
const int kUltCooldownTicks = 900; // ~30s, independent of the ability cooldown
final Fixed kUltBurstDamage = Fixed.fromNum(30); // > kCastBurstDamage; ×kVaporizeMult=39 stays < 32768
final Fixed kUltRadius = Fixed.fromNum(4); // world-units (> kFieldRadius 2.5)
final Fixed kUltRadiusSq = Fixed.fromNum(4 * 4); // compare vs lengthSq, no sqrt
const int kUltFieldDurationTicks = 180; // ~6s (> kFieldDurationTicks 120)
```

- [ ] **Step 4: Parametrize `_castBurst` (E path stays byte-identical)**

In `packages/sim/lib/src/simulation_elemental.dart`, change the `_castBurst` signature + the two values it uses (lines 59-69):
```dart
  void _castBurst(Entity caster, FVec2 center, int element, List<SimEvent> events,
      {Fixed? radiusSq, Fixed? damage}) {
    final rSq = radiusSq ?? kFieldRadiusSq;
    final dmg = damage ?? kCastBurstDamage;
    for (final id in entityIdsSorted) {
      final u = _byId[id]!;
      if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
      if (u.hp.raw <= 0) continue;
      if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
      if (u.teamId == caster.teamId) continue; // ENEMY-ONLY (own-team safe)
      if ((u.pos - center).lengthSq() > rSq) continue;
      _applyHit(caster, u, dmg, element, events);
    }
  }
```
(Callers passing no named args — the E path at `simulation.dart:135` — get the field defaults, so its bytes are unchanged.)

- [ ] **Step 5: Handle the `ultimate` intent in `step()` phase 1**

In `packages/sim/lib/src/simulation.dart`, in the intent loop (after the `ability` branch closes at line 136, before the loop's closing `}` at line 137) add:
```dart
      } else if (it.type == IntentType.ultimate) {
        if (hero.ultCooldown != 0) continue; // on cooldown → ignore
        _fields.removeWhere((f) => f.ownerId == hero.id); // ult shares the ≤1-field/hero slot
        final center = heroPlacesAtSelf(hero.id)
            ? hero.pos // Cinderfang: at his feet
            : FVec2(Fixed.raw(it.aimX), Fixed.raw(it.aimY)); // Marisol: at aim
        _fields.add(ElementalField(
            ownerId: hero.id,
            center: center,
            element: heroElement(hero.id),
            timer: kUltFieldDurationTicks));
        hero.ultCooldown = kUltCooldownTicks;
        // Bigger, enemy-only burst (own-team safe; may amplify a coated enemy).
        _castBurst(hero, center, heroElement(hero.id), events,
            radiusSq: kUltRadiusSq, damage: kUltBurstDamage);
```
(The existing `else if (it.type == IntentType.ability) { ... }` block stays; this chains onto it.)

- [ ] **Step 6: Tick `ultCooldown` down each tick**

In `packages/sim/lib/src/simulation_combat.dart`, the per-unit timer loop (lines 28-33), add next to `abilityCooldown`:
```dart
      if (e.abilityCooldown > 0) e.abilityCooldown -= 1;
      if (e.ultCooldown > 0) e.ultCooldown -= 1;
```
(Do NOT reset `ultCooldown` on respawn — it mirrors `abilityCooldown`, which the respawn block at lines 9-23 deliberately leaves alone. The respawn block is unchanged.)

- [ ] **Step 7: Add the `ultCooldown` serialization codec row**

In `packages/sim/lib/src/simulation_serialization.dart`, in `_entityBodyCodecs` add the row immediately after `abilityCooldown` (line 77) and before the snapshot-only `target` row (line 78):
```dart
  _i32Codec((e) => e.abilityCooldown, (e, v) => e.abilityCooldown = v),
  _i32Codec((e) => e.ultCooldown, (e, v) => e.ultCooldown = v),
  _fvecCodec((e) => e.target, (e, v) => e.target = v, snapshotOnly: true),
```
Update the layout comment above the list (lines 61-64) to add `ultCooldown` in the field-order list (`… abilityCooldown, ultCooldown, target[snapshot-only]`).

- [ ] **Step 8: Bump both versions 3 → 4**

In `packages/sim/lib/src/simulation.dart` (lines 22 and 27):
```dart
const int kSchemaVersion = 4;
```
```dart
const int kSnapshotVersion = 4;
```

- [ ] **Step 9: Write the ult behavior + round-trip + isOneShot tests**

Append to `packages/sim/test/combat_test.dart`:
```dart
  test('isOneShot is true for ability + ultimate only', () {
    expect(IntentType.ability.isOneShot, isTrue);
    expect(IntentType.ultimate.isOneShot, isTrue);
    expect(IntentType.move.isOneShot, isFalse);
    expect(IntentType.attack.isOneShot, isFalse);
    expect(IntentType.none.isOneShot, isFalse);
  });

  test('ultimate places a field + sets its own cooldown (independent of ability)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Marisol (slot 1, aim-place) ults at world (0,7) = (0, 458752 raw).
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ultimate, aimX: 0, aimY: 458752, seq: 1)]);
    expect(sim.fields.where((f) => f.ownerId == 1).length, 1);
    expect(sim.entity(1).ultCooldown, kUltCooldownTicks - 1); // set in phase 1, ticked once in combat
    expect(sim.entity(1).abilityCooldown, 0); // E still ready — independent cooldown
  });

  test('ultimate is gated by its own cooldown (immediate re-cast ignored)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ultimate, aimX: 0, aimY: 458752, seq: 1)]);
    final centerAfterFirst = sim.fields.firstWhere((f) => f.ownerId == 1).center.x.raw;
    sim.step(1, const [Intent(playerSlot: 1, type: IntentType.ultimate, aimX: 131072, aimY: 458752, seq: 2)]);
    expect(sim.fields.where((f) => f.ownerId == 1).length, 1);
    expect(sim.fields.firstWhere((f) => f.ownerId == 1).center.x.raw, centerAfterFirst); // not replaced
  });

  test('ultimate burst is enemy-only (caster takes no self-damage)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Cinderfang (slot 0, self-place) ults at his own position.
    final selfHp = sim.entity(0).hp.raw;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.ultimate, aimX: 0, aimY: 0, seq: 1)]);
    expect(sim.entity(0).hp.raw, selfHp);
  });
```
Append to `packages/sim/test/snapshot_test.dart` (inside `main()`):
```dart
  test('ultCooldown survives a snapshot round-trip', () {
    final a = Simulation.create(const SimConfig(seed: 1));
    a.entity(0).ultCooldown = 123;
    final b = Simulation.create(const SimConfig(seed: 1));
    b.restoreFromSnapshot(a.snapshotBytes());
    expect(b.entity(0).ultCooldown, 123);
  });
```

- [ ] **Step 10: Run sim analyze + tests — expect the TWO anchors to FAIL, everything else PASS**

Run: `cd packages/sim && dart analyze && dart test`
Expected: analyze clean; the new ult/round-trip/isOneShot tests pass; **exactly two tests fail** — the pinned anchors (`simulation_test.dart:59` and `snapshot_test.dart:54`), each reporting `Expected: <0x0fbfb7ac> Actual: <0xNEWHASH>` (same `0xNEWHASH` in both, since both run the identical 300-tick move-only scenario). This is the sanctioned version-bump move. If any OTHER test fails, investigate — the field/intent/burst change leaked.

- [ ] **Step 11: Re-pin both anchor literals to the new v4 hash**

Copy the `Actual:` hash printed in Step 10. Replace `0x0fbfb7ac` with `0x<NEWHASH>` (lowercase, 8 hex) at:
- `packages/sim/test/simulation_test.dart:59` — `expect(s.canonicalStateHash(), 0x<NEWHASH>);`
- `packages/sim/test/snapshot_test.dart:54` — `expect(_run(300).canonicalStateHash(), 0x<NEWHASH>);`

Re-run: `cd packages/sim && dart test test/simulation_test.dart test/snapshot_test.dart` → both PASS.

- [ ] **Step 12: Re-pin all three existing goldens to v4 (native hash, single LF)**

Run from repo root:
```bash
for f in smoke combat elemental; do
  B64=$(base64 -w0 tooling/replay_fixtures/$f.json 2>/dev/null || base64 tooling/replay_fixtures/$f.json | tr -d '\n')
  NEW=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
  printf '%s\n' "$NEW" > tooling/replay_fixtures/$f.golden
  echo "re-pinned $f.golden -> $NEW"
done
git --no-pager diff -- tooling/replay_fixtures/smoke.golden tooling/replay_fixtures/combat.golden tooling/replay_fixtures/elemental.golden
```
Expected: all three hash lines change (the version header + the new per-entity `ultCooldown` i32 move every encoding; no ult is cast in these fixtures so the change is purely structural).

- [ ] **Step 13: Create the `ult` fixture + pin its golden**

Create `tooling/replay_fixtures/ult.json` (both heroes move to center, then both ult on tick 60 — Cinderfang self-places, Marisol aim-places; `type:4` = ultimate):
```json
{
  "seed": 1337,
  "ticks": 120,
  "inputLog": {
    "0": [{"playerSlot":0,"type":1,"aimX":0,"aimY":458752,"seq":1,"clientTick":0},
          {"playerSlot":1,"type":1,"aimX":0,"aimY":458752,"seq":1,"clientTick":0}],
    "60":[{"playerSlot":0,"type":4,"aimX":0,"aimY":458752,"seq":2,"clientTick":60},
          {"playerSlot":1,"type":4,"aimX":0,"aimY":458752,"seq":2,"clientTick":60}]
  }
}
```
Pin its golden:
```bash
B64=$(base64 -w0 tooling/replay_fixtures/ult.json 2>/dev/null || base64 tooling/replay_fixtures/ult.json | tr -d '\n')
NEW=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
printf '%s\n' "$NEW" > tooling/replay_fixtures/ult.golden
echo "pinned ult.golden -> $NEW"
```

- [ ] **Step 14: Cross-runtime parity for all four fixtures**

```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
bash tooling/compare_replays.sh tooling/replay_fixtures/ult.json
```
Expected: each prints `PASS: byte-identical across native/js/wasm` + `PASS: matches golden`. (If `ult` diverges across runtimes, the ult path has a non-determinism bug — investigate before proceeding; this fixture exists to catch exactly that.)

- [ ] **Step 15: Add the `ult` fixture to CI**

In `.github/workflows/sim-determinism.yml`, after line 44 (the `elemental.json` compare) add:
```yaml
      - run: bash tooling/compare_replays.sh tooling/replay_fixtures/ult.json
```

- [ ] **Step 16: Commit**

```bash
git add packages/sim/lib tooling/replay_fixtures packages/sim/test/combat_test.dart packages/sim/test/snapshot_test.dart packages/sim/test/simulation_test.dart .github/workflows/sim-determinism.yml
git commit -m "feat(sim): Q placeholder ultimate + bump schema/snapshot 3->4, re-pin all goldens + anchor"
```

---

## Task 3: Part C (plumbing) — netcode / server / protocol / client Q input (determinism-neutral)

**Files:** `match_controller.dart`, `fake_transport.dart`, `intent_buffer.dart`, `match_binding.dart`, `skill_input.dart`, `guild_game.dart`; tests in `match_controller_test.dart`, `codec_test.dart`, `skill_input_test.dart`.

- [ ] **Step 1: Write the failing netcode + protocol + client tests**

Append to `packages/netcode/test/match_controller_test.dart`:
```dart
  test('applyUltimateInput emits an ultimate InputMsg carrying the aim point', () {
    final c = _ctrl(slot: 1);
    final msg = c.applyUltimateInput(196608, 458752)!;
    expect(msg.type, IntentType.ultimate.index);
    expect(msg.slot, 1);
    expect(msg.aimX, 196608);
    expect(msg.aimY, 458752);
  });
```
Append to `packages/protocol/test/codec_test.dart` (inside `main()`):
```dart
  test('InputMsg round-trips an ultimate intent type', () {
    final m = InputMsg(slot: 0, seq: 1, clientTick: 0, aimX: 5, aimY: 6, type: IntentType.ultimate.index);
    final back = ProtocolCodec.decode(ProtocolCodec.encode(m)) as InputMsg;
    expect(back.type, IntentType.ultimate.index);
    expect(back.aimX, 5);
    expect(back.aimY, 6);
  });
```
Append to `apps/client/test/skill_input_test.dart`:
```dart
  test('Q (ult slot) aim-places, then a left-click casts at the point', () {
    final s = SkillInputController();
    expect(s.onSkillKey(downed: false, placesAtSelf: false, slot: SkillSlot.ult), SkillAction.enterAim);
    expect(s.armedSlot, SkillSlot.ult);
    expect(s.onLeftClick(), SkillAction.castAtPoint);
    expect(s.armedSlot, isNull);
  });

  test('Q self-place casts immediately, no aim', () {
    final s = SkillInputController();
    expect(s.onSkillKey(downed: false, placesAtSelf: true, slot: SkillSlot.ult), SkillAction.castAtSelf);
    expect(s.aimPending, isFalse);
  });

  test('pressing any skill key while aiming cancels (E armed, Q pressed)', () {
    final s = SkillInputController();
    s.onSkillKey(downed: false, placesAtSelf: false, slot: SkillSlot.ability);
    expect(s.onSkillKey(downed: false, placesAtSelf: false, slot: SkillSlot.ult), SkillAction.cancel);
    expect(s.aimPending, isFalse);
  });
```

- [ ] **Step 2: Run the three suites — expect FAIL (undefined symbols)**

Run:
```bash
(cd packages/netcode && dart test test/match_controller_test.dart) ; \
(cd packages/protocol && dart test test/codec_test.dart) ; \
(cd apps/client && flutter test test/skill_input_test.dart)
```
Expected: netcode FAILS (`applyUltimateInput` undefined); protocol PASSES already (the codec writes `type` as a raw i32, so `ultimate` round-trips with no code change — this test just locks that in); client FAILS (`SkillSlot` undefined / `onSkillKey` has no `slot` param).

- [ ] **Step 3: Add `applyUltimateInput` + use `isOneShot` in `match_controller.dart`**

In `packages/netcode/lib/src/match_controller.dart`, add after `applyAbilityInput` (line 105):
```dart
  /// Record + apply a local ULT cast at world point (aimX,aimY) (Q16.16 raw);
  /// returns the InputMsg to send. One-shot like the ability. Null while downed.
  InputMsg? applyUltimateInput(int aimX, int aimY) {
    if (_predicted.entity(localSlot).isDowned) return null; // Plan 6: dead -> ignore
    final seq = ++_localSeq;
    final intent = Intent(
        playerSlot: localSlot,
        type: IntentType.ultimate,
        aimX: aimX,
        aimY: aimY,
        seq: seq,
        clientTick: _nextTick);
    _pending.add(_Pending(_nextTick, intent));
    return InputMsg(
        slot: localSlot,
        seq: seq,
        clientTick: _nextTick,
        aimX: aimX,
        aimY: aimY,
        type: IntentType.ultimate.index);
  }
```
Change the one-shot checks to the shared predicate so the ult is treated like the ability:
- Line 117: `_pending.removeWhere((p) => p.intent.type != IntentType.ability);` → `_pending.removeWhere((p) => !p.intent.type.isOneShot);`
- Line 132: `if (p.intent.type == IntentType.ability) {` → `if (p.intent.type.isOneShot) {`

Update the doc comments at lines 107-114 and 121-126 to say "one-shot ability/ult" instead of "ability".

- [ ] **Step 4: Mirror the ult one-shot in `FakeTransport`**

In `packages/netcode/lib/test_support/fake_transport.dart`, line 115, change:
```dart
        if (intent.type == IntentType.ability) {
```
to:
```dart
        if (intent.type.isOneShot) {
```
(The field name `_pendingAbility` now holds the latest one-shot — ability OR ult — per slot. Update its declaring comment at lines 37-41 and line 116 to read "one-shot ability/ult". Same one-per-slot-per-tick semantics the real server has; pressing E and Q in the *same* 33ms tick keeps only the latter — an accepted placeholder limitation that reconcile self-corrects.)

- [ ] **Step 5: Use `isOneShot` in the server `IntentBuffer`**

In `apps/server/lib/src/loop/intent_buffer.dart`, line 29:
```dart
    if (intent.type == IntentType.ability) {
```
→
```dart
    if (intent.type.isOneShot) {
```
Update the class doc (lines 4-8) + the `_pendingAbility` comment (line 12) to say "one-shot ability/ult". (Keep the field name; renaming is gratuitous churn.)

- [ ] **Step 6: Add `submitUltimate` to `MatchBinding`**

In `apps/client/lib/match/match_binding.dart`, after `submitAbility` (line 78) add:
```dart
  /// Local input: ULT cast at a world point (Q16.16 raw), from a Q-cast
  /// (self-placed at the hero) or a left-click aim-confirm. Predict + send.
  void submitUltimate(int aimXRaw, int aimYRaw) {
    if (_ended) return;
    final c = _controller;
    if (c == null) return;
    final input = c.applyUltimateInput(aimXRaw, aimYRaw);
    if (input == null) return; // Plan 6: dead hero -> nothing to send
    _transport.send(ProtocolCodec.encode(input));
  }
```

- [ ] **Step 7: Extend `SkillInputController` to two slots (E ability / Q ult)**

Replace `apps/client/lib/match/skill_input.dart` entirely:
```dart
/// Which skill slot an aim is armed for: E = ability, Q = ult.
enum SkillSlot { ability, ult }

/// The action GuildGame should take in response to a skill-input event.
enum SkillAction {
  none, // do nothing
  castAtSelf, // cast immediately at the hero's own position
  enterAim, // begin aiming (wait for a left-click)
  castAtPoint, // cast at the just-clicked world point
  cancel, // abort a pending aim
}

/// Pure state machine for the E/Q-cast + left-click-aim control scheme (spec
/// 2026-06-09 §3 + Plan 7 part 1). One aim may be armed at a time, for the
/// ability (E) or the ult (Q). Holds no rendering/network concerns — GuildGame
/// maps [SkillAction] + [armedSlot] onto submitAbility / submitUltimate.
class SkillInputController {
  SkillSlot? _armed;
  bool get aimPending => _armed != null;

  /// Which slot is currently armed (null = idle). Read BEFORE [onLeftClick] to
  /// route a castAtPoint to the right submit call.
  SkillSlot? get armedSlot => _armed;

  /// A skill key was pressed for [slot]. [downed] gates all casting (Plan 6);
  /// [placesAtSelf] is `heroPlacesAtSelf(localHeroId)`.
  SkillAction onSkillKey({
    required bool downed,
    required bool placesAtSelf,
    SkillSlot slot = SkillSlot.ability,
  }) {
    if (downed) {
      final was = _armed != null;
      _armed = null;
      return was ? SkillAction.cancel : SkillAction.none;
    }
    if (_armed != null) {
      _armed = null; // any skill key while aiming cancels the pending aim
      return SkillAction.cancel;
    }
    if (placesAtSelf) return SkillAction.castAtSelf; // immediate; stays idle
    _armed = slot;
    return SkillAction.enterAim;
  }

  /// A left-click happened. Only meaningful while aiming.
  SkillAction onLeftClick() {
    if (_armed == null) return SkillAction.none; // bare left-click does nothing
    _armed = null;
    return SkillAction.castAtPoint;
  }

  /// A right-click happened. Returns true if it was consumed as an aim-cancel
  /// (the caller must then NOT issue a move); false if there was no pending aim.
  bool onRightClickConsumedAsCancel() {
    if (_armed == null) return false;
    _armed = null;
    return true;
  }

  /// Force-clear a pending aim (e.g. the local hero became downed mid-aim).
  /// Returns true if an aim was actually cancelled.
  bool clearAim() {
    if (_armed == null) return false;
    _armed = null;
    return true;
  }
}
```
(The existing E tests in `skill_input_test.dart` call `onSkillKey` without `slot` and read `aimPending` — both still compile/pass via the `slot` default and the unchanged `aimPending` getter.)

- [ ] **Step 8: Wire the Q key into `GuildGame`**

In `apps/client/lib/render/guild_game.dart`, line 7, extend the keyboard import to add `keyQ` (already imports `LogicalKeyboardKey`). Replace the whole `onKeyEvent` method (lines 170-190) to handle both E and Q:
```dart
  /// E = cast the ability, Q = cast the ult. Self-placed skills (Cinderfang)
  /// fire at once; aim-placed skills (Marisol) arm aim mode, then a left-click
  /// places them (the reticle follows the cursor — see update()).
  @override
  KeyEventResult onKeyEvent(KeyEvent event, Set<LogicalKeyboardKey> keysPressed) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final SkillSlot slot;
    if (event.logicalKey == LogicalKeyboardKey.keyE) {
      slot = SkillSlot.ability;
    } else if (event.logicalKey == LogicalKeyboardKey.keyQ) {
      slot = SkillSlot.ult;
    } else {
      return KeyEventResult.ignored;
    }
    final v = binding.view;
    if (v != null) {
      final downed = _downed.contains(v.localSlot);
      final action = _skill.onSkillKey(
          downed: downed, placesAtSelf: heroPlacesAtSelf(v.localSlot), slot: slot);
      if (action == SkillAction.castAtSelf) {
        final rx = worldToRaw(v.local.x), ry = worldToRaw(v.local.y);
        if (slot == SkillSlot.ult) {
          binding.submitUltimate(rx, ry);
        } else {
          binding.submitAbility(rx, ry);
        }
      }
    }
    return KeyEventResult.handled;
  }
```
And replace `onTapUp` (lines 214-220) so the left-click confirm routes to the armed slot:
```dart
  /// Left-click = aim-confirm. Only casts when a skill is armed (by E/Q);
  /// otherwise does nothing.
  @override
  void onTapUp(TapUpEvent event) {
    final slot = _skill.armedSlot; // capture before onLeftClick consumes it
    if (_skill.onLeftClick() != SkillAction.castAtPoint) return;
    final worldPos = camera.globalToLocal(event.canvasPosition);
    final rx = worldToRaw(flameToWorld(worldPos.x));
    final ry = worldToRaw(flameToWorld(worldPos.y));
    if (slot == SkillSlot.ult) {
      binding.submitUltimate(rx, ry);
    } else {
      binding.submitAbility(rx, ry);
    }
  }
```

- [ ] **Step 9: Run all four suites — expect GREEN**

Run:
```bash
(cd packages/sim && dart test) && \
(cd packages/protocol && dart test) && \
(cd packages/netcode && dart test) && \
(cd apps/server && dart test) && \
(cd apps/client && flutter analyze && flutter test)
```
Expected: every suite green — the new netcode/protocol/client tests pass; the existing ability/one-shot tests still pass (the ult is treated identically); `widget_smoke_test` still mounts `GuildGame` (now with the Q key + two-slot controller).

- [ ] **Step 10: Scope guard + commit**

Confirm this task touched NO `packages/sim/lib` files (Task 3 is pure plumbing — all sim mechanics landed in Task 2):
```bash
git status --porcelain packages/sim/lib | grep . && echo "LEAK: sim/lib changed in Task 3 — investigate" || echo "SCOPE OK: no sim/lib changes"
git add packages/netcode apps/server apps/client/lib/match apps/client/lib/render/guild_game.dart \
  packages/netcode/test/match_controller_test.dart packages/protocol/test/codec_test.dart apps/client/test/skill_input_test.dart
git commit -m "feat: bind Q to the placeholder ult across netcode/server/client (one-shot plumbing)"
```
Expected: `SCOPE OK: no sim/lib changes`.

---

## Task 4: Part B — live aim reticle (client; determinism-neutral)

**Files:** `coord.dart`, `guild_game.dart`; test `apps/client/test/tower_range_ring_test.dart`.

- [ ] **Step 1: Write the failing radius-helper test**

Append to `apps/client/test/tower_range_ring_test.dart` (inside `main()`):
```dart
  test('aim ring radii read the sim field + ult constants', () {
    expect(fieldRingRadiusPx(), kFieldRadius.toDouble() * kPixelsPerUnit);
    expect(ultRingRadiusPx(), kUltRadius.toDouble() * kPixelsPerUnit);
    expect(ultRingRadiusPx(), greaterThan(fieldRingRadiusPx())); // ult is bigger
  });
```

- [ ] **Step 2: Run it — expect FAIL (undefined helpers)**

Run: `cd apps/client && flutter test test/tower_range_ring_test.dart`
Expected: FAIL — `fieldRingRadiusPx` / `ultRingRadiusPx` undefined.

- [ ] **Step 3: Add the radius helpers to `coord.dart`**

Append to `apps/client/lib/render/coord.dart`:
```dart
/// Pixel radius of the ability (E) field aim reticle — `kFieldRadius` scaled.
double fieldRingRadiusPx() => kFieldRadius.toDouble() * kPixelsPerUnit;

/// Pixel radius of the ult (Q) aim reticle — `kUltRadius` scaled.
double ultRingRadiusPx() => kUltRadius.toDouble() * kPixelsPerUnit;
```

- [ ] **Step 4: Run it — expect PASS**

Run: `cd apps/client && flutter test test/tower_range_ring_test.dart`
Expected: PASS.

- [ ] **Step 5: Add pointer-move tracking + the reticle to `GuildGame`**

In `apps/client/lib/render/guild_game.dart`:

(a) Add `import 'dashed_circle.dart';` with the other `render/` imports (near line 16).

(b) Add `PointerMoveCallbacks` to the mixin list (line 27):
```dart
class GuildGame extends FlameGame
    with SecondaryTapCallbacks, TapCallbacks, KeyboardEvents, PointerMoveCallbacks {
```

(c) Add a one-line toggle above the class (near line 25) and two fields next to `_skill` (line 35):
```dart
/// Debug/tuning aid: draw a dashed reticle at the cursor while a skill is armed.
/// Flip to false to remove it.
const bool kShowAimReticle = true;
```
```dart
  Vector2? _cursorFlame; // latest cursor position in world/flame space
  DashedCircle? _reticle;
```

(d) Add the pointer-move handler (next to the other input handlers, e.g. after `onKeyEvent`):
```dart
  @override
  void onPointerMove(PointerMoveEvent event) {
    _cursorFlame = camera.globalToLocal(event.canvasPosition);
  }
```

(e) In `update`, right after the downed-clear line (line 93 `if (_downed.contains(v.localSlot) && _skill.aimPending) _skill.clearAim();`), add reticle management:
```dart
    // Aim reticle: a dashed circle at the cursor while a skill is armed, sized
    // to the pending cast (field for E, larger for the ult).
    final showReticle = kShowAimReticle && _skill.aimPending && _cursorFlame != null;
    if (showReticle) {
      final r = _skill.armedSlot == SkillSlot.ult ? ultRingRadiusPx() : fieldRingRadiusPx();
      if (_reticle == null) {
        _reticle = DashedCircle(radius: r, color: const Color(0x66FFFFFF));
        world.add(_reticle!);
      } else {
        _reticle!.radius = r;
      }
      _reticle!.position = _cursorFlame!.clone();
    } else if (_reticle != null) {
      _reticle!.removeFromParent();
      _reticle = null;
    }
```

- [ ] **Step 6: Analyze + full client suite**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: analyze clean (if `flutter analyze` flags `PointerMoveCallbacks`/`PointerMoveEvent`, they come from `package:flame/events.dart`, already imported at line 5 — confirm the symbol is exported there; otherwise add `package:flame/input.dart`). All tests pass — the new radius test + the existing client suite (`widget_smoke_test` mounts `GuildGame` with the new mixin/fields).

- [ ] **Step 7: Commit**

```bash
git add apps/client/lib/render/coord.dart apps/client/lib/render/guild_game.dart apps/client/test/tower_range_ring_test.dart
git commit -m "feat(client): live aim reticle tracking the cursor while a skill is armed"
```

---

## Task 5: Full mirror-CI sweep → review → finishing

Mirrors `.github/workflows/sim-determinism.yml` plus the client gates; confirms the whole branch is green, the version bump is clean, and nothing leaked.

- [ ] **Step 1: Scope / changed-file audit**

```bash
git --no-pager diff --name-only main..HEAD
```
Expected files only: `packages/sim/lib/src/{simulation,simulation_combat,simulation_elemental,simulation_serialization}.dart`, `packages/sim/lib/src/model/{entity,intent}.dart`, `packages/sim/lib/src/data/elements.dart`, `packages/sim/test/{combat,snapshot,simulation}_test.dart`, `tooling/replay_fixtures/{smoke,combat,elemental,ult}.golden`, `tooling/replay_fixtures/ult.json`, `.github/workflows/sim-determinism.yml`, `packages/netcode/lib/src/match_controller.dart`, `packages/netcode/lib/test_support/fake_transport.dart`, `packages/netcode/test/match_controller_test.dart`, `apps/server/lib/src/loop/intent_buffer.dart`, `packages/protocol/test/codec_test.dart`, `apps/client/lib/match/{match_binding,skill_input}.dart`, `apps/client/lib/render/{coord,guild_game}.dart`, `apps/client/test/{skill_input,tower_range_ring}_test.dart`, plus the spec + this plan.

- [ ] **Step 2: All package suites + analyze + banned imports**

```bash
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
(cd packages/sim && dart test)
(cd packages/protocol && dart test)
(cd packages/netcode && dart test)
(cd apps/server && dart test)
(cd apps/client && flutter analyze && flutter test)
```
Expected: analyze clean; banned-imports clean; every suite green.

- [ ] **Step 3: Cross-runtime golden gate (all four)**

```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
bash tooling/compare_replays.sh tooling/replay_fixtures/ult.json
```
Expected: each `PASS: byte-identical across native/js/wasm` + `PASS: matches golden` (all at v4).

- [ ] **Step 4: Hand off (no commit)**

Proceed to the whole-branch review (superpowers:requesting-code-review over `main..HEAD`), then superpowers:finishing-a-development-branch (present options; do **NOT** merge/push without Patrick's explicit choice).

---

## Notes for the implementer

- **Subagents (implementers AND reviewers) must NEVER run `git checkout`/`git switch`.** The branch is already checked out.
- **Symbolic sim tests are a feature:** the only sim-test literal deliberately changed is the `0x0fbfb7ac` anchor (two files, Task 2). Any OTHER sim-test failure after a change is a real regression — investigate, don't edit the expectation.
- **The v3 `combat.golden` (Task 1) is superseded by v4 (Task 2).** That double re-pin is intentional — Task 1 proves Part A is attribution-clean *before* the version bump; Task 2 carries the final v4 value.
- **No protocol version bump:** the intent `type` rides the wire as a raw i32 (`codec.dart`), so `IntentType.ultimate` round-trips with zero codec change. The Task 3 protocol test locks that in.
- **`_castBurst` defaults keep the E path byte-identical** — only the ult passes `radiusSq`/`damage`. If the elemental golden moved by anything other than the version+field structural delta, the default path was disturbed — investigate.
- **Same-tick E+Q is an accepted placeholder limitation:** the server/FakeTransport hold one one-shot per slot per tick, so casting both within one 33ms tick keeps only the latter; reconcile self-corrects. D can revisit.
- **Reticle is cosmetic + flagged:** `kShowAimReticle` is a one-line removal, mirroring the controls pass's `kShowTowerRangeRings`.

---

## Self-Review (against the spec)

- **Spec §1 (Part A stop-at-range, v3 re-pin):** Task 1 — pursue branch + stop-at-range test + attribution gate (smoke/elemental/anchor unchanged, combat moved) + cross-runtime re-pin. ✓
- **Spec §2 (Part B live reticle, radius from the pending cast, flagged, fallback):** Task 4 — `field/ultRingRadiusPx` + `PointerMoveCallbacks` + reticle behind `kShowAimReticle`; cast-still-works fallback retained (reticle is additive). ✓
- **Spec §3.1 (sim: ultCooldown field + codec row, IntentType.ultimate, step handling, parametrized _castBurst, constants, cooldown tick, no respawn reset):** Task 2 Steps 1-8. ✓
- **Spec §3.2/§3.3 (netcode applyUltimateInput + one-shot predicate + FakeTransport; server IntentBuffer):** Task 3 Steps 3-5, via `IntentType.isOneShot`. ✓
- **Spec §3.4 (client submitUltimate + SkillInputController Q slot + GuildGame Q key):** Task 3 Steps 6-8. ✓
- **Spec §3.5 (version bump 3/3→4/4, re-pin ALL goldens + anchor, new ult fixture, no protocol bump):** Task 2 Steps 8-15 (both anchor literals; smoke/combat/elemental + ult; CI line). ✓
- **Spec §5 (tests):** stop-at-range (T1); ult behavior/round-trip/isOneShot (T2); netcode/protocol/client input (T3); reticle radius (T4); full mirror-CI + cross-runtime (T5). ✓
- **Spec §4 (OUT): no real kit/ult content, no new reaction types/provenance split, no new elements, no XP/shop/boss, no protocol byte-layout change** — none present. ✓
- **Placeholder scan:** no TBD/TODO; golden hashes are derived by exact commands; the two anchor literals are read from the Step-10 failure (standard re-pin), not invented. ✓
- **Type/name consistency:** `SkillSlot`/`armedSlot`/`onSkillKey(slot:)` match between `skill_input.dart`, `guild_game.dart`, and the tests; `applyUltimateInput`/`submitUltimate`/`IntentType.ultimate`/`ultCooldown`/`isOneShot`/`kUlt*` consistent across sim, netcode, server, client, and tests; `_castBurst(..., radiusSq:, damage:)` matches its one ult call site. ✓
