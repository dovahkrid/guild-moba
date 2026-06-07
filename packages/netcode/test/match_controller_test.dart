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
    final msg = c.applyLocalInput(0, 262144);
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
    final msg = c.applyAbilityInput(196608, 458752);
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
    expect(v.local.statusElement, isA<int>()); // plumbed (−1 until coated)
  });

  test('drainReactions returns + clears (empty when nothing reacted)', () {
    final c = MatchController(seed: 1, localSlot: 0, startTick: 0);
    c.advanceClientTick();
    expect(c.drainReactions(), isEmpty);
  });
}
