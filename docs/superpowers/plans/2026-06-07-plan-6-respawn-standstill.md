# Plan 6: Respawn Stand-Still — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A respawned hero stands still at its spawn until the player issues a new order, instead of auto-walking back to its pre-death move/attack order.

**Architecture:** Three layers, smallest-blast-radius first. (1) **Sim** clears the serialized `attackTargetId` on death and emits an off-wire `HeroDowned` event. (2) **Server** cancels the slot's held order when it sees `HeroDowned`, and ignores input for a downed slot. (3) **Client** ignores local input while its hero is downed. The only golden that moves is `combat.golden` (its fixture has hero deaths); no byte-layout change, no version bump.

**Tech Stack:** Dart 3.11.5 (pure `sim`/`protocol`/`netcode`/`server` packages), Flutter 3.41.9 (`apps/client`), Q16.16 fixed-point determinism, cross-runtime replay goldens (native / dart2js+node / dart2wasm+node), git bash for tooling scripts on Windows.

**Spec:** `docs/superpowers/specs/2026-06-07-plan-6-respawn-standstill-design.md`

---

## Determinism guardrails (apply to EVERY task)

- `packages/sim/lib` stays pure: **no** `dart:math`, `Random(`, `DateTime`, `Stopwatch`; Q16.16 `Fixed` + `int` only; `lengthSq` for membership; iterate `entityIdsSorted` / the stable `_entities` list; **no new RNG draw** (the phase-5 wanderer is untouched); enums are append-only (none are touched here).
- `SimEvent`s are off-wire: never serialized, never in `canonicalBytes()`/`snapshotBytes()`. Adding `HeroDowned` does **not** bump `kSchemaVersion`/`kSnapshotVersion` (stays 3/3).
- **Golden contract:** `smoke.golden` (`7e4aa28f`), `elemental.golden` (`8d7fbe1b`), and the in-test anchor `0x0fbfb7ac` MUST NOT move. **Only `combat.golden` (`04da965a`) is allowed to move**, and only in Task 3, re-pinned via the cross-runtime procedure — never hand-typed.
- Each task is its own red→green→commit. Every commit must leave `dart analyze --fatal-infos --fatal-warnings packages apps/server tooling` clean (and, for the client task, `flutter analyze` clean).

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `packages/sim/lib/src/model/entity.dart` | add `isDowned` getter | 1 |
| `packages/sim/lib/src/simulation.dart` | use `isDowned` at downed-checks (1); clear `attackTargetId` + emit `HeroDowned` on death (3) | 1, 3 |
| `packages/sim/lib/src/events.dart` | declare the `HeroDowned` event | 2 |
| `packages/sim/test/is_downed_test.dart` | `isDowned` truth table | 1 |
| `packages/sim/test/events_test.dart` | `HeroDowned` payload | 2 |
| `packages/sim/test/combat_test.dart` | death drops lock + emits + stands after respawn | 3 |
| `tooling/replay_fixtures/combat.golden` | re-pinned hash | 3 |
| `apps/server/lib/src/loop/intent_buffer.dart` | add `clearSlot` | 4 |
| `apps/server/test/intent_buffer_test.dart` | `clearSlot` behavior | 4 |
| `apps/server/lib/src/loop/match.dart` | consume `HeroDowned` → `clearSlot`; ignore input for a downed slot | 5 |
| `apps/server/test/match_test.dart` | held order cancelled; downed input ignored; alive re-feed intact | 5 |
| `packages/netcode/lib/src/match_controller.dart` | `applyLocalInput/Attack/Ability` → `InputMsg?`, gated on `isDowned` | 6 |
| `packages/netcode/test/match_controller_test.dart` | gating + post-respawn honored | 6 |
| `apps/client/lib/match/match_binding.dart` | skip send when controller returns `null` | 6 |
| `apps/client/test/match_binding_test.dart` | no send while downed | 6 |

---

## Task 1: `Entity.isDowned` getter (golden-neutral refactor)

Add one named predicate for "this hero is dead/respawning" and substitute it at the two sim sites that already inline the **full** predicate (`respawnTimer != 0 || hp.raw <= 0`). This is a pure rename → all four hashes must be unchanged. Sites that use only *part* of the predicate (e.g. `respawnTimer != 0` alone) are intentionally left untouched.

**Files:**
- Modify: `packages/sim/lib/src/model/entity.dart`
- Modify: `packages/sim/lib/src/simulation.dart:108`, `:242`
- Test: `packages/sim/test/is_downed_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `packages/sim/test/is_downed_test.dart`:

```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  Entity hero({int respawnTimer = 0, int hpRaw = 100 * 65536}) => Entity(
        id: 0,
        kind: EntityKind.hero,
        teamId: 0,
        pos: FVec2.zero,
        hp: Fixed.raw(hpRaw),
        respawnTimer: respawnTimer,
      );

  test('isDowned is true while respawning or at/below 0 hp, false when alive', () {
    expect(hero().isDowned, isFalse); // alive, full hp
    expect(hero(respawnTimer: 1).isDowned, isTrue); // respawning
    expect(hero(hpRaw: 0).isDowned, isTrue); // dropped to 0 (death tick)
    expect(hero(hpRaw: -65536).isDowned, isTrue); // overkilled
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/is_downed_test.dart`
Expected: FAIL — compile error, `isDowned` is not defined on `Entity`.

- [ ] **Step 3: Add the getter**

In `packages/sim/lib/src/model/entity.dart`, immediately after the constructor (after the line `        target = target ?? pos;` and its closing `}` near line 73), add:

```dart

  /// True while a hero is dead/respawning: untargetable, ignores input, does not
  /// pursue or attack. respawnTimer>0 after the death sweep; hp<=0 on the death
  /// tick itself (or from a same-tick burst) before the sweep parks it.
  bool get isDowned => respawnTimer != 0 || hp.raw <= 0;
```

- [ ] **Step 4: Substitute the two full-predicate sites in `simulation.dart`**

At `packages/sim/lib/src/simulation.dart:108`, replace:

```dart
      if (hero.respawnTimer != 0 || hero.hp.raw <= 0) continue; // downed (incl. dropped to 0 by a same-tick burst): ignore input
```

with:

```dart
      if (hero.isDowned) continue; // downed (incl. dropped to 0 by a same-tick burst): ignore input
```

At `packages/sim/lib/src/simulation.dart:242`, replace:

```dart
      if (e.kind != EntityKind.hero || e.respawnTimer != 0 || e.hp.raw <= 0) continue;
```

with:

```dart
      if (e.kind != EntityKind.hero || e.isDowned) continue;
```

- [ ] **Step 5: Run the new test + the whole sim suite (prove golden-neutral)**

Run: `dart test packages/sim`
Expected: PASS — including `is_downed_test.dart`, the pinned anchor test `pinned 300-tick canonical state hash` (`0x0fbfb7ac`), and `canonicalBytes/hash unchanged (golden untouched)` (`0x0fbfb7ac`). No hash moved.

- [ ] **Step 6: Prove the three replay goldens are unchanged**

Run (git bash):
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
```
Expected: each ends with `PASS: byte-identical across native/js/wasm: <hash>` **and** `PASS: matches golden ...`. (`combat.golden` still matches here — the behavioral change is Task 3.)

- [ ] **Step 7: Commit**

```bash
git add packages/sim/lib/src/model/entity.dart packages/sim/lib/src/simulation.dart packages/sim/test/is_downed_test.dart
git commit -m "refactor(sim): add Entity.isDowned getter (golden-neutral)"
```

---

## Task 2: declare the `HeroDowned` event

A new off-wire `SimEvent`. Declaration only here (emission is Task 3); events are never serialized/hashed, so this is golden-neutral.

**Files:**
- Modify: `packages/sim/lib/src/events.dart`
- Test: `packages/sim/test/events_test.dart:14` (append a test)

- [ ] **Step 1: Write the failing test**

In `packages/sim/test/events_test.dart`, add a new test inside `main()` (after the existing test, before the final `}`):

```dart
  test('HeroDowned carries the downed hero id and is a SimEvent', () {
    const e = HeroDowned(heroId: 1);
    expect(e.heroId, 1);
    expect(e, isA<SimEvent>());
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/events_test.dart`
Expected: FAIL — compile error, `HeroDowned` is not defined.

- [ ] **Step 3: Declare the event**

In `packages/sim/lib/src/events.dart`, append after the `LevelUp` class (end of file):

```dart

/// Emitted on the tick a hero transitions to downed (hp reaches 0). Off-wire /
/// cosmetic like the other SimEvents (never serialized, never hashed). Lets the
/// server cancel that hero's held order at the death tick so a respawn stands
/// still (Plan 6).
class HeroDowned extends SimEvent {
  final int heroId;
  const HeroDowned({required this.heroId});
}
```

(`events.dart` is re-exported by `package:sim/sim.dart:15`, so `HeroDowned` is public automatically.)

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim/test/events_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/events.dart packages/sim/test/events_test.dart
git commit -m "feat(sim): declare off-wire HeroDowned event"
```

---

## Task 3: clear the attack lock + emit `HeroDowned` on death (re-pins `combat.golden`)

The behavioral sim change. On the death transition, drop `attackTargetId` and emit `HeroDowned`. This is the only task that moves a golden — `combat.golden`, because `combat.json`'s heroes die and respawn (~tick 450) and now stand instead of re-pursuing.

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart` (`_sweepDeadHeroes` + its caller)
- Test: `packages/sim/test/combat_test.dart` (append 3 tests before the final `}` at line 306)
- Modify: `tooling/replay_fixtures/combat.golden`

- [ ] **Step 1: Write the failing tests**

In `packages/sim/test/combat_test.dart`, add these three tests inside `main()` (before the closing `}`):

```dart
  test('Plan 6: a killed hero drops its attack lock and stands at spawn after respawn', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h1 = sim.entity(1);
    h1.attackTargetId = 0; // was locked onto hero 0
    h1.hp = Fixed.zero; // dies this tick
    h1.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7)); // off-lane, tower-safe
    h1.target = h1.pos;
    sim.entity(0).pos = FVec2(Fixed.fromInt(2), Fixed.fromInt(7)); // a valid nearby enemy
    sim.entity(0).target = sim.entity(0).pos;
    final ev = sim.step(0, const []);
    expect(h1.respawnTimer, kHeroRespawnTicks);
    expect(h1.attackTargetId, -1); // lock dropped on death
    expect(ev.whereType<HeroDowned>().single.heroId, 1);
    for (var t = 1; t <= kHeroRespawnTicks; t++) {
      sim.step(t, const []);
    }
    expect(sim.entity(1).respawnTimer, 0); // respawned
    expect(sim.entity(1).attackTargetId, -1); // still no lock
    expect(sim.entity(1).pos.x.raw, kHero1SpawnX.raw); // stood at spawn (did NOT re-pursue)
  });

  test('Plan 6: HeroDowned fires once on the death transition, not on later downed ticks', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h1 = sim.entity(1);
    h1.hp = Fixed.zero;
    h1.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    h1.target = h1.pos;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero); // keep apart
    sim.entity(0).target = sim.entity(0).pos;
    expect(sim.step(0, const []).whereType<HeroDowned>().map((e) => e.heroId), [1]);
    expect(sim.step(1, const []).whereType<HeroDowned>(), isEmpty); // not re-emitted while downed
  });

  test('Plan 6: a killed hero with a move target does not walk back after respawn', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h1 = sim.entity(1);
    h1.target = FVec2(Fixed.fromInt(-20), Fixed.zero); // had a move order toward the far side
    h1.hp = Fixed.zero;
    h1.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    for (var t = 0; t <= kHeroRespawnTicks; t++) {
      sim.step(t, const []);
    }
    expect(sim.entity(1).pos.x.raw, kHero1SpawnX.raw); // stood at spawn, not at the old target
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: the first two new tests FAIL — `HeroDowned` is never emitted (`whereType<HeroDowned>().single` throws / the emission expect sees `[]` not `[1]`) and `attackTargetId` is not cleared, so the locked hero re-pursues after respawn (`pos.x.raw != kHero1SpawnX.raw`). The third test (move-target guard) already passes in the raw sim — the death sweep already resets `target = pos`, so a *move*-order walk-back is a netcode behavior covered in Tasks 5/6; this test guards that the sim half stays correct. Run it green here too.

- [ ] **Step 3: Clear the lock + emit on death**

In `packages/sim/lib/src/simulation.dart`, change the `_sweepDeadHeroes` definition (currently around line 271) from:

```dart
  void _sweepDeadHeroes() {
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      if (e.hp.raw > 0) continue;
      e.respawnTimer = kHeroRespawnTicks;
      e.pos = FVec2(_heroSpawnX(e), Fixed.zero); // park at base while downed
      e.target = e.pos;
    }
  }
```

to:

```dart
  void _sweepDeadHeroes(List<SimEvent> events) {
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      if (e.hp.raw > 0) continue;
      e.respawnTimer = kHeroRespawnTicks;
      e.pos = FVec2(_heroSpawnX(e), Fixed.zero); // park at base while downed
      e.target = e.pos;
      e.attackTargetId = -1; // Plan 6: drop the attack lock so a respawn stands still
      events.add(HeroDowned(heroId: e.id)); // off-wire: lets the server cancel the held order
    }
  }
```

- [ ] **Step 4: Pass `events` at the call site**

In `packages/sim/lib/src/simulation.dart` (inside `_stepCombat`, currently line 267), change:

```dart
    _sweepDeadHeroes();
```

to:

```dart
    _sweepDeadHeroes(events);
```

- [ ] **Step 5: Run the sim suite — new tests pass, anchor + smoke/elemental intact**

Run: `dart test packages/sim`
Expected: PASS — the three new tests pass; the pinned anchor `0x0fbfb7ac` tests still pass (move-only, no death); the existing `a hero reduced to 0 hp is downed and respawns after the timer` still passes. (`combat.golden` is a tooling check, not a unit test — handled next.)

- [ ] **Step 6: Confirm smoke + elemental goldens unchanged**

Run (git bash):
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
```
Expected: both end with `PASS: matches golden ...` (no death in either fixture → unchanged).

- [ ] **Step 7: Re-pin `combat.golden` cross-runtime**

Run (git bash):
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
```
Expected: a `PASS: byte-identical across native/js/wasm: <NEWHASH>` line (determinism intact across all three runtimes) followed by `FAIL: hash changed vs golden ... (got <NEWHASH>)` (the behavioral change moved the hash). Copy `<NEWHASH>` from the PASS line.

Write it to the golden (preserving the one-line format), substituting the captured hash:

```bash
printf '%s\n' <NEWHASH> > tooling/replay_fixtures/combat.golden
```

Re-run to confirm a full pass:

```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
```
Expected: `PASS: byte-identical across native/js/wasm: <NEWHASH>` **and** `PASS: matches golden ...`.

- [ ] **Step 8: Commit**

```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/combat_test.dart tooling/replay_fixtures/combat.golden
git commit -m "fix(sim): clear attackTargetId + emit HeroDowned on death (re-pin combat.golden)"
```

---

## Task 4: `IntentBuffer.clearSlot`

A pure server helper to drop a slot's held move/attack and any pending one-shot ability. Server-only, golden-neutral.

**Files:**
- Modify: `apps/server/lib/src/loop/intent_buffer.dart`
- Test: `apps/server/test/intent_buffer_test.dart` (append a test before the final `}` at line 71)

- [ ] **Step 1: Write the failing test**

In `apps/server/test/intent_buffer_test.dart`, add inside `main()`:

```dart
  test('clearSlot drops the held move/attack AND any pending ability for that slot only', () {
    final b = IntentBuffer();
    b.accept(input(0, 1, aimX: 100)); // held move on slot 0
    b.accept(InputMsg(
        slot: 0, seq: 2, clientTick: 0, aimX: 5, aimY: 0, type: IntentType.ability.index));
    b.accept(input(1, 1, aimX: 200)); // held move on slot 1
    b.clearSlot(0);
    final out = b.drainForTick();
    expect(out.where((i) => i.playerSlot == 0), isEmpty); // slot 0 fully cleared
    expect(out.where((i) => i.playerSlot == 1), hasLength(1)); // slot 1 untouched
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test apps/server/test/intent_buffer_test.dart`
Expected: FAIL — `clearSlot` is not defined on `IntentBuffer`.

- [ ] **Step 3: Implement `clearSlot`**

In `apps/server/lib/src/loop/intent_buffer.dart`, add this method inside the `IntentBuffer` class (e.g. after `accept`, before `drainForTick`):

```dart
  /// Plan 6: drop a slot's held move/attack and any pending one-shot ability.
  /// Called when a hero is downed so a respawn does not resume the old order.
  void clearSlot(int slot) {
    if (slot < 0 || slot > 1) return;
    _held[slot] = null;
    _pendingAbility[slot] = null;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test apps/server/test/intent_buffer_test.dart`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add apps/server/lib/src/loop/intent_buffer.dart apps/server/test/intent_buffer_test.dart
git commit -m "feat(server): IntentBuffer.clearSlot drops a slot's held + pending intents"
```

---

## Task 5: `Match` cancels the held order on `HeroDowned` + ignores downed input

Two rules in `Match`: on a `HeroDowned` event, `clearSlot` the held order; in the message listener, drop input for a slot whose hero `isDowned`. Alive heroes keep their per-tick re-feed.

**Files:**
- Modify: `apps/server/lib/src/loop/match.dart` (`_tick` ~line 68; `addPlayer` listener ~line 42)
- Test: `apps/server/test/match_test.dart` (append 3 tests before the final `}` at line 131)

- [ ] **Step 1: Write the failing tests**

In `apps/server/test/match_test.dart`, add inside `main()`:

```dart
  test('Plan 6: a held move order is cancelled when the hero dies — stands at spawn after respawn', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero); // keep hero 0 away
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(8), Fixed.fromInt(7)); // hero 1 tower-safe
    sim.entity(1).target = sim.entity(1).pos;
    Match(seed: 1, sim: sim, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..start();
    // Hero 1 orders a move far to the left (held), then moves a bit.
    p1.receive(ProtocolCodec.encode(const InputMsg(
        slot: 1, seq: 1, clientTick: 0, aimX: -1310720, aimY: 458752, type: 1)));
    driver.pump(3);
    expect(sim.entity(1).pos.x.toDouble(), lessThan(8.0)); // it moved left
    // Now hero 1 takes a lethal hit (from anywhere).
    sim.entity(1).hp = Fixed.zero;
    driver.pump(1); // death tick → HeroDowned → clearSlot(1)
    expect(sim.entity(1).respawnTimer, kHeroRespawnTicks);
    driver.pump(kHeroRespawnTicks); // run out the timer
    expect(sim.entity(1).respawnTimer, 0);
    expect(sim.entity(1).pos.x.raw, kHero1SpawnX.raw); // stood at spawn (held order cancelled)
  });

  test('Plan 6: input arriving while a hero is downed is ignored (no order on respawn)', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).hp = Fixed.zero; // hero 1 downs on tick 0
    sim.entity(1).pos = FVec2(Fixed.fromInt(8), Fixed.fromInt(7));
    sim.entity(1).target = sim.entity(1).pos;
    Match(seed: 1, sim: sim, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..start();
    driver.pump(1);
    expect(sim.entity(1).respawnTimer, kHeroRespawnTicks); // downed
    // While downed, hero 1 clicks a move far away — must be IGNORED.
    p1.receive(ProtocolCodec.encode(const InputMsg(
        slot: 1, seq: 1, clientTick: 0, aimX: -1310720, aimY: 0, type: 1)));
    driver.pump(kHeroRespawnTicks);
    expect(sim.entity(1).respawnTimer, 0);
    expect(sim.entity(1).pos.x.raw, kHero1SpawnX.raw); // stood still: the downed click was dropped
  });

  test('Plan 6: an ALIVE hero keeps its held move re-fed every tick', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    final sim = Simulation.create(const SimConfig(seed: 1));
    Match(seed: 1, sim: sim, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..start();
    final startX = sim.entity(0).pos.x.raw;
    p0.receive(ProtocolCodec.encode(const InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 655360, aimY: 0, type: 1))); // move right, once
    driver.pump(10); // no further input; the held move must keep re-feeding
    expect(sim.entity(0).pos.x.raw, greaterThan(startX));
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test apps/server/test/match_test.dart`
Expected: the first two new tests FAIL — without the wiring, the held move re-feeds after respawn (test 1) and the downed click is accepted and re-fed (test 2), so `pos.x.raw != kHero1SpawnX.raw`. The third ("ALIVE hero…") PASSES already (regression guard). The existing match tests still pass.

- [ ] **Step 3: Consume `HeroDowned` in `_tick`**

In `apps/server/lib/src/loop/match.dart`, in `_tick()` (line 68), change:

```dart
    final intents = _buffer.drainForTick();
    _sim.step(_currentTick, intents);
```

to:

```dart
    final intents = _buffer.drainForTick();
    final events = _sim.step(_currentTick, intents);
    for (final e in events) {
      if (e is HeroDowned) _buffer.clearSlot(e.heroId); // death cancels the held order
    }
```

- [ ] **Step 4: Ignore input for a downed slot in the listener**

In `apps/server/lib/src/loop/match.dart`, in `addPlayer`'s message handler (line 42), change:

```dart
      if (msg is InputMsg) {
        // Server is authoritative on slot: stamp with the assigned slot.
        _buffer.accept(InputMsg(
```

to:

```dart
      if (msg is InputMsg) {
        if (_sim.entity(slot).isDowned) return; // Plan 6: dead heroes take no orders
        // Server is authoritative on slot: stamp with the assigned slot.
        _buffer.accept(InputMsg(
```

- [ ] **Step 5: Run the server suite to verify it passes**

Run: `dart test apps/server`
Expected: PASS — all three new tests and all existing match/intent/room/integration tests.

- [ ] **Step 6: Commit**

```bash
git add apps/server/lib/src/loop/match.dart apps/server/test/match_test.dart
git commit -m "fix(server): cancel held order on HeroDowned; ignore input for a downed slot"
```

---

## Task 6: Client gates input while the local hero is downed

`MatchController`'s three input methods return `InputMsg?` (null while the local hero `isDowned`); `MatchBinding` skips the send on null. Done together so the whole repo compiles at this commit. No barrier is needed — the pre-death order is already ack-pruned and the standing state is inherited via reconcile.

**Files:**
- Modify: `packages/netcode/lib/src/match_controller.dart` (`applyLocalInput` ~line 42, `applyAttackInput` ~line 63, `applyAbilityInput` ~line 83)
- Modify: `packages/netcode/test/match_controller_test.dart` (update 2 existing call sites + add 3 tests)
- Modify: `apps/client/lib/match/match_binding.dart` (`submitMoveTo`/`submitAttack`/`submitAbility`)
- Modify: `apps/client/test/match_binding_test.dart` (add 1 test)

- [ ] **Step 1: Write the failing netcode tests**

In `packages/netcode/test/match_controller_test.dart`, add inside `main()`:

```dart
  test('Plan 6: input is gated (returns null, nothing pending) while the local hero is downed', () {
    final c = _ctrl(slot: 0);
    final server = Simulation.create(const SimConfig(seed: 1337));
    server.entity(0).hp = Fixed.zero;
    server.step(0, const []); // server downs hero 0
    c.onServerSnapshot(SnapshotMsg(
        serverTick: 0, ackedSeq: const [0, 0], stateBytes: server.snapshotBytes()));
    expect(c.applyLocalInput(655360, 0), isNull); // move gated
    expect(c.applyAttackInput(1), isNull); // attack gated
    expect(c.applyAbilityInput(0, 0), isNull); // ability gated
    expect(c.pendingCount, 0); // nothing recorded
  });

  test('Plan 6: a fresh post-respawn click is honored (gating only applies while downed)', () {
    final c = _ctrl(slot: 0);
    final server = Simulation.create(const SimConfig(seed: 1337));
    server.entity(0).hp = Fixed.zero;
    server.step(0, const []); // server completes tick 0 with hero 0 downed
    c.advanceClientTick(); // client completes tick 0, _nextTick = 1
    c.onServerSnapshot(SnapshotMsg(
        serverTick: 0, ackedSeq: const [0, 0], stateBytes: server.snapshotBytes()));
    for (var t = 1; t <= kHeroRespawnTicks; t++) {
      c.advanceClientTick(); // ticks 1..150: respawnTimer 150 → 0
    }
    expect(c.update(0).local.hp, greaterThan(0.0)); // back alive
    final msg = c.applyLocalInput(655360, 0);
    expect(msg, isNotNull); // honored now
    final startX = c.debugLocalPos().x.raw;
    for (var i = 0; i < 5; i++) {
      c.advanceClientTick();
    }
    expect(c.debugLocalPos().x.raw, greaterThan(startX)); // moved
  });

  test('Plan 6: clicks during downtime are dropped; the hero still stands after respawn', () {
    final c = _ctrl(slot: 0);
    final server = Simulation.create(const SimConfig(seed: 1337));
    server.entity(0).hp = Fixed.zero;
    server.step(0, const []);
    c.advanceClientTick();
    c.onServerSnapshot(SnapshotMsg(
        serverTick: 0, ackedSeq: const [0, 0], stateBytes: server.snapshotBytes()));
    expect(c.applyLocalInput(655360, 0), isNull); // mashed during downtime → dropped
    expect(c.pendingCount, 0);
    for (var t = 1; t <= kHeroRespawnTicks + 2; t++) {
      c.advanceClientTick();
    }
    expect(c.debugLocalPos().x.raw, kHero0SpawnX.raw); // stood at spawn, never walked
  });
```

- [ ] **Step 2: Update the 2 existing tests that read the return value**

The return type becomes `InputMsg?`, so two existing tests that access fields on the result need a `!`. In `packages/netcode/test/match_controller_test.dart`:

At line 31, change `final msg = c.applyLocalInput(0, 262144);` to:
```dart
    final msg = c.applyLocalInput(0, 262144)!;
```
At line 70, change `final msg = c.applyAbilityInput(196608, 458752);` to:
```dart
    final msg = c.applyAbilityInput(196608, 458752)!;
```

- [ ] **Step 3: Run the netcode tests to verify the new ones fail**

Run: `dart test packages/netcode/test/match_controller_test.dart`
Expected: FAIL — `applyLocalInput`/`applyAttackInput`/`applyAbilityInput` still return non-null `InputMsg`, so the gating tests fail (`expect(..., isNull)`), and the `!` edits don't yet compile against a non-nullable return (analyzer warns). This drives the signature change.

- [ ] **Step 4: Gate the three controller methods**

In `packages/netcode/lib/src/match_controller.dart`, change each method's signature to `InputMsg?` and add the downed guard as the first line.

`applyLocalInput` (line 42):
```dart
  InputMsg? applyLocalInput(int aimX, int aimY) {
    if (_predicted.entity(localSlot).isDowned) return null; // Plan 6: dead → ignore input
    final seq = ++_localSeq;
```
`applyAttackInput` (line 63):
```dart
  InputMsg? applyAttackInput(int targetId) {
    if (_predicted.entity(localSlot).isDowned) return null; // Plan 6: dead → ignore input
    final seq = ++_localSeq;
```
`applyAbilityInput` (line 83):
```dart
  InputMsg? applyAbilityInput(int aimX, int aimY) {
    if (_predicted.entity(localSlot).isDowned) return null; // Plan 6: dead → ignore input
    final seq = ++_localSeq;
```
(Leave each method body otherwise unchanged — the existing `return InputMsg(...)` at the end is fine under the nullable return type.)

- [ ] **Step 5: Run the netcode tests to verify they pass**

Run: `dart test packages/netcode`
Expected: PASS — the three new tests, the two `!`-updated tests, and all existing tests.

- [ ] **Step 6: Skip the send on null in `MatchBinding`**

In `apps/client/lib/match/match_binding.dart`, update the three submit methods.

`submitMoveTo` (line 50):
```dart
  void submitMoveTo(int aimXRaw, int aimYRaw) {
    if (_ended) return; // no input after the match ends
    final c = _controller;
    if (c == null) return;
    final input = c.applyLocalInput(aimXRaw, aimYRaw);
    if (input == null) return; // Plan 6: dead hero → nothing to send
    _transport.send(ProtocolCodec.encode(input));
  }
```
`submitAttack` (line 59):
```dart
  void submitAttack(int targetId) {
    if (_ended) return; // no input after the match ends
    final c = _controller;
    if (c == null) return;
    final input = c.applyAttackInput(targetId);
    if (input == null) return; // Plan 6: dead hero → nothing to send
    _transport.send(ProtocolCodec.encode(input));
  }
```
`submitAbility` (line 67):
```dart
  void submitAbility(int aimXRaw, int aimYRaw) {
    if (_ended) return; // no input after the match ends
    final c = _controller;
    if (c == null) return;
    final input = c.applyAbilityInput(aimXRaw, aimYRaw);
    if (input == null) return; // Plan 6: dead hero → nothing to send
    _transport.send(ProtocolCodec.encode(input));
  }
```

- [ ] **Step 7: Add the binding test**

In `apps/client/test/match_binding_test.dart`, add inside `main()`:

```dart
  test('Plan 6: no input is sent while the local hero is downed', () async {
    final mem = _MemTransport();
    final binding = MatchBinding(mem);
    mem.serverPush(ProtocolCodec.encode(const MatchStartMsg(
        yourSlot: 0, seed: 1337, tickRateHz: 30, snapshotRateHz: 20, startTick: 0)));
    await Future<void>.delayed(Duration.zero);
    // Authoritative snapshot: hero 0 is downed.
    final srv = Simulation.create(const SimConfig(seed: 1337));
    srv.entity(0).hp = Fixed.zero;
    srv.step(0, const []);
    mem.serverPush(ProtocolCodec.encode(SnapshotMsg(
        serverTick: 0, ackedSeq: const [0, 0], stateBytes: srv.snapshotBytes())));
    await Future<void>.delayed(Duration.zero);
    binding.submitMoveTo(655360, 0); // click while dead
    final sent = mem.sent.map(ProtocolCodec.decode).whereType<InputMsg>().toList();
    expect(sent, isEmpty); // nothing sent
  });
```

- [ ] **Step 8: Run the client tests + analyze**

Run:
```bash
dart test packages/netcode
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
(cd apps/client && flutter analyze && flutter test)
```
Expected: all PASS (netcode green, analyze clean, `flutter analyze` clean, `flutter test` green including the new binding test).

- [ ] **Step 9: Commit**

```bash
git add packages/netcode/lib/src/match_controller.dart packages/netcode/test/match_controller_test.dart apps/client/lib/match/match_binding.dart apps/client/test/match_binding_test.dart
git commit -m "fix(client): gate local input while the hero is downed (no send/predict)"
```

---

## Task 7: full mirror-CI sweep

No code change — prove the whole change is green across every gate the CI runs (mirrors `.github/workflows/sim-determinism.yml`).

**Files:** none (verification only).

- [ ] **Step 1: Purity + determinism-safety gate**

Run:
```bash
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
dart test packages/sim
dart test packages/protocol
dart test packages/netcode
dart test apps/server
```
Expected: analyze clean; banned-imports clean; all four suites green.

- [ ] **Step 2: Cross-runtime suites (node + dart2wasm)**

Run:
```bash
dart test packages/sim -p node
dart test packages/sim -p node -c dart2wasm
dart test packages/netcode -p node
dart test packages/netcode -p node -c dart2wasm
```
Expected: all green (determinism holds on dart2js + dart2wasm).

- [ ] **Step 3: Replay goldens (native + js + wasm, vs committed golden)**

Run:
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
```
Expected: each ends with `PASS: byte-identical across native/js/wasm` **and** `PASS: matches golden`. `smoke`/`elemental` match their old hashes (`7e4aa28f`/`8d7fbe1b`); `combat` matches the new hash pinned in Task 3.

- [ ] **Step 4: Flutter client**

Run:
```bash
cd apps/client && flutter analyze && flutter test
```
Expected: analyze clean, all widget/binding tests green.

- [ ] **Step 5: Confirm version + golden invariants by inspection**

- `kSchemaVersion` / `kSnapshotVersion` are still `3` (no bump) — confirm no edit touched them.
- `smoke.golden` = `7e4aa28f`, `elemental.golden` = `8d7fbe1b` (unchanged); `combat.golden` = the new Task-3 hash.
- The branch is ready for whole-branch review → `superpowers:finishing-a-development-branch`.

---

## Self-review notes (author)

- **Spec coverage:** §3.1 sim (Tasks 1, 3) · §3.2 server (Tasks 4, 5) · §3.3 client gating (Task 6) · §3.4 binding (Task 6) · §4 HeroDowned (Tasks 2, 3) · §5 determinism/re-pin (Tasks 1, 3, 7) · §7 tests (each task) — all mapped.
- **Type consistency:** `isDowned` (getter), `HeroDowned({required int heroId})`, `IntentBuffer.clearSlot(int)`, `InputMsg?` returns — used identically across tasks.
- **Golden discipline:** Task 1 proves the refactor moves nothing; Task 3 is the only golden-moving task and re-pins `combat.golden` from harness output (never hand-typed); Task 7 re-verifies all three + the anchor.
