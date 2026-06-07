import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:sim/sim.dart';
import 'fakes.dart';

import 'package:test/test.dart';

void main() {
  test('steps deterministically and emits 20Hz snapshots with ackedSeq', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    Match(seed: 1337, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..start();

    // p0 sends a move at "now".
    p0.receive(ProtocolCodec.encode(const InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 655360, aimY: 0, type: 1)));

    driver.pump(30); // 30 ticks

    // 20 snapshots per 30 ticks (2-of-3 cadence).
    final snaps0 = p0.sent.map(ProtocolCodec.decode).whereType<SnapshotMsg>().toList();
    expect(snaps0.length, 20);
    expect(snaps0.last.ackedSeq[0], 1); // p0's input was acked
    expect(snaps0.last.serverTick, greaterThan(0));

    // Authoritative state is reconstructable and hero 0 moved right.
    final s = Simulation.create(const SimConfig(seed: 1337))
      ..restoreFromSnapshot(snaps0.last.stateBytes);
    expect(s.entity(0).pos.x.toDouble(), greaterThan(-8.0));
  });

  test('match end on player disconnect notifies survivor', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    final match = Match(seed: 1, driver: driver)..addPlayer(0, p0)..addPlayer(1, p1)..start();
    driver.pump(3);
    p1.close(); // disconnect
    // Allow the onClose handler to run, then assert survivor got MatchEndMsg.
    return Future(() {
      final ended = p0.sent.map(ProtocolCodec.decode).whereType<MatchEndMsg>();
      expect(ended.isNotEmpty, isTrue);
      expect(match.ended, isTrue);
    });
  });

  test('malformed frame is ignored and does not crash or end the match', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    final match = Match(seed: 42, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..start();

    // Send a malformed frame with unknown tag 255 — must not throw.
    p0.receive([255]);

    // Send a valid input after the bad frame.
    p0.receive(ProtocolCodec.encode(const InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 0, aimY: 0, type: 1)));

    driver.pump(3);

    // Match must still be running (not ended).
    expect(match.ended, isFalse);

    // Snapshots are still emitted — the match loop is alive.
    final snaps = p0.sent.map(ProtocolCodec.decode).whereType<SnapshotMsg>().toList();
    expect(snaps, isNotEmpty);

    // The valid input after the bad frame was acked.
    expect(snaps.last.ackedSeq[0], 1);
  });

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

  test('core destroyed ends the match and notifies BOTH players with the winner', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    // Inject a sim with team1's core exposed + nearly dead, hero 0 adjacent.
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(kOuterTower1Id).hp = Fixed.zero;
    sim.entity(kInnerTower1Id).hp = Fixed.zero;
    sim.entity(kCore1Id).hp = Fixed.fromInt(5);
    sim.entity(0).pos = FVec2(Fixed.fromInt(13), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    var endedCb = false;
    final match = Match(seed: 1, sim: sim, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..onEnded = () => endedCb = true;
    match.start();
    // Hero 0 right-clicks (locks) the enemy core; the held intent persists each
    // tick, re-establishing the lock after the (hp-0) towers are swept on tick 0.
    p0.receive(ProtocolCodec.encode(InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: kCore1Id, aimY: 0,
        type: IntentType.attack.index)));
    driver.pump(5);

    expect(match.ended, isTrue);
    expect(endedCb, isTrue);
    for (final p in [p0, p1]) {
      final end = p.sent.map(ProtocolCodec.decode).whereType<MatchEndMsg>().single;
      expect(end.reason, EndReason.coreDestroyed);
      expect(end.winnerSlot, 0);
    }
  });
}
