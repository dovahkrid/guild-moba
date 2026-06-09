import 'dart:typed_data';

import 'package:netcode/netcode.dart';
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';
import 'package:test/test.dart';

MatchController _ctrl({int slot = 0}) =>
    MatchController(seed: 1337, localSlot: slot, startTick: 0);

void main() {
  test('predicts local hero immediately (moves within a few ticks of input)', () {
    final c = _ctrl();
    final startX = c.debugLocalPos().x.raw;
    c.applyLocalInput(655360, 0); // move right
    for (var i = 0; i < 10; i++) {
      c.advanceClientTick();
    }
    expect(c.debugLocalPos().x.raw, greaterThan(startX));
  });

  test('tick contract: first step is tick 0, _nextTick advances', () {
    final c = _ctrl();
    expect(c.predictedTick, 0); // nothing stepped yet
    c.advanceClientTick();
    expect(c.predictedTick, 1); // completed tick 0, next is 1
  });

  test('applyLocalInput returns an InputMsg stamped with the local slot+seq', () {
    final c = _ctrl(slot: 1);
    final msg = c.applyLocalInput(0, 262144)!;
    expect(msg.slot, 1);
    expect(msg.seq, 1);
    expect(msg.type, IntentType.move.index);
    expect(msg.aimY, 262144);
  });

  test('update() exposes all entities with kind/team/hp and the local/opponent getters', () {
    final c = _ctrl(slot: 0);
    c.advanceClientTick();
    final v = c.update(0);
    // 9 static entities exist at start (2 heroes, wanderer, 2 cores, 4 towers).
    expect(v.entities.length, greaterThanOrEqualTo(9));
    expect(v.localSlot, 0);
    expect(v.local.id, 0);
    expect(v.opponent.id, 1);
    final core = v.entities.firstWhere((e) => e.id == 10);
    expect(core.kind, EntityKind.core.index);
    expect(core.maxHp, greaterThan(0));
    expect(v.localGold, 0);
  });

  test('reconcile to a fresh snapshot with no pending leaves no correction', () {
    // Build an authoritative sim that advanced identically with no input.
    final server = Simulation.create(const SimConfig(seed: 1337));
    final c = _ctrl();
    for (var t = 0; t < 5; t++) {
      server.step(t, const []);
      c.advanceClientTick();
    }
    final snap = SnapshotMsg(
        serverTick: 4, ackedSeq: const [0, 0], stateBytes: server.snapshotBytes());
    c.onServerSnapshot(snap);
    expect(c.lastCorrectionDist, 0.0); // exact at steady state, no pending
    expect(c.debugHash(), server.canonicalStateHash());
  });

  test('applyAbilityInput emits an ability InputMsg carrying the aim point', () {
    final c = MatchController(seed: 1, localSlot: 1, startTick: 0);
    final msg = c.applyAbilityInput(196608, 458752)!;
    expect(msg.type, IntentType.ability.index);
    expect(msg.slot, 1);
    expect(msg.aimX, 196608);
    expect(msg.aimY, 458752);
  });

  test('a cast field appears in the render view; statusElement is exposed', () {
    final c = MatchController(seed: 1, localSlot: 1, startTick: 0);
    c.applyAbilityInput(0, 458752); // Marisol drops Tidepool at world (0,7)
    c.advanceClientTick();
    final v = c.update(0);
    expect(v.fields, isNotEmpty);
    expect(v.fields.first.ownerId, 1);
    expect(v.fields.first.element, Element.hydro.index);
    expect(v.local.statusElement, -1); // no coat yet → none (plumbed through, real value)
  });

  test('drainReactions returns + clears (empty when nothing reacted)', () {
    final c = MatchController(seed: 1, localSlot: 0, startTick: 0);
    c.advanceClientTick();
    expect(c.drainReactions(), isEmpty);
  });

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
    expect(c.applyUltimateInput(0, 0), isNull); // ult gated
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
      c.advanceClientTick(); // ticks 1..150: respawnTimer 150 -> 0
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
    expect(c.applyLocalInput(655360, 0), isNull); // mashed during downtime -> dropped
    expect(c.pendingCount, 0);
    for (var t = 1; t <= kHeroRespawnTicks + 2; t++) {
      c.advanceClientTick();
    }
    expect(c.debugLocalPos().x.raw, kHero0SpawnX.raw); // stood at spawn, never walked
  });

  test('Plan 6: an unacked death-window order does not re-feed after respawn (no rubber-band)', () {
    final c = _ctrl(slot: 0);
    // The player clicks a move while the client still predicts the hero ALIVE,
    // so input-gating does not fire and the order (seq 1) is recorded + "sent".
    expect(c.applyLocalInput(655360, 0), isNotNull); // move right, recorded in _pending
    c.advanceClientTick(); // predicts the move; _nextTick = 1
    // Authoritative truth: the hero was already downed at tick 0, and the server
    // DROPPED that input (downed-slot guard) so it is NEVER acked (ackedSeq stays 0).
    final server = Simulation.create(const SimConfig(seed: 1337));
    server.entity(0).hp = Fixed.zero;
    server.step(0, const []); // downs hero 0
    c.onServerSnapshot(SnapshotMsg(
        serverTick: 0, ackedSeq: const [0, 0], stateBytes: server.snapshotBytes()));
    // Predict forward through respawn with no further reconcile (worst case for drift).
    for (var t = 1; t <= kHeroRespawnTicks + 5; t++) {
      c.advanceClientTick();
    }
    // The trapped order must have been dropped on downing -> hero stands at spawn.
    expect(c.debugLocalPos().x.raw, kHero0SpawnX.raw);
  });

  test('applyUltimateInput emits an ultimate InputMsg carrying the aim point', () {
    final c = _ctrl(slot: 1);
    final msg = c.applyUltimateInput(196608, 458752)!;
    expect(msg.type, IntentType.ultimate.index);
    expect(msg.slot, 1);
    expect(msg.aimX, 196608);
    expect(msg.aimY, 458752);
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
    // Both server and client have completed through tick 9 (nextTick = 10), so
    // their canonical state must match.
    final snap = SnapshotMsg(serverTick: 4, ackedSeq: const [1, 0], stateBytes: snapBytes!);
    c.onServerSnapshot(snap);
    expect(c.debugHash(), server.canonicalStateHash()); // EXACT: cast applied once, not re-fired
  });
}
