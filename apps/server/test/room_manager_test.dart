import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'fakes.dart';
import 'package:test/test.dart';

void main() {
  test('assigns slots 0 then 1 and starts the match on the 2nd join', () {
    final rm = RoomManager(seed: 7, driverFactory: () => FakeTickDriver());
    final p0 = FakePlayerConn();
    rm.connect(p0);
    expect(p0.sent, isEmpty); // not started yet
    final p1 = FakePlayerConn();
    rm.connect(p1);
    // Both received MATCH_START with their slots.
    final m0 = ProtocolCodec.decode(p0.sent.first) as MatchStartMsg;
    final m1 = ProtocolCodec.decode(p1.sent.first) as MatchStartMsg;
    expect(m0.yourSlot, 0);
    expect(m1.yourSlot, 1);
  });

  test('rejects a 3rd connection with roomFull then closes it', () {
    final rm = RoomManager(seed: 7, driverFactory: () => FakeTickDriver());
    rm.connect(FakePlayerConn());
    rm.connect(FakePlayerConn());
    final p2 = FakePlayerConn();
    rm.connect(p2);
    final end = ProtocolCodec.decode(p2.sent.single) as MatchEndMsg;
    expect(end.reason, EndReason.roomFull);
  });

  test('room resets on match end so a fresh pair can start', () async {
    final rm = RoomManager(seed: 7, driverFactory: () => FakeTickDriver());
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    rm.connect(p0);
    rm.connect(p1);
    // Match is now running; close one player to end it.
    p0.close();
    // Wait one microtask for the onClose future to fire.
    await Future<void>.value();

    // Connect a fresh pair — the room must have reset.
    final p2 = FakePlayerConn(), p3 = FakePlayerConn();
    rm.connect(p2);
    rm.connect(p3);

    final m2 = ProtocolCodec.decode(p2.sent.first) as MatchStartMsg;
    final m3 = ProtocolCodec.decode(p3.sent.first) as MatchStartMsg;
    expect(m2.yourSlot, 0);
    expect(m3.yourSlot, 1);
  });
}
