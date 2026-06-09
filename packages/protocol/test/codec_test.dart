import 'dart:typed_data';
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart' show IntentType;
import 'package:test/test.dart';

void main() {
  T roundTrip<T extends Msg>(T msg) =>
      ProtocolCodec.decode(ProtocolCodec.encode(msg)) as T;

  test('MatchStartMsg round-trips', () {
    final m = roundTrip(const MatchStartMsg(
        yourSlot: 1, seed: 1337, tickRateHz: 30, snapshotRateHz: 20, startTick: 0));
    expect(m.yourSlot, 1);
    expect(m.seed, 1337);
    expect(m.tickRateHz, 30);
    expect(m.snapshotRateHz, 20);
    expect(m.startTick, 0);
  });

  test('InputMsg round-trips', () {
    final m = roundTrip(const InputMsg(
        slot: 0, seq: 7, clientTick: 42, aimX: 655360, aimY: -131072, type: 1));
    expect(m.slot, 0);
    expect(m.seq, 7);
    expect(m.clientTick, 42);
    expect(m.aimX, 655360);
    expect(m.aimY, -131072);
    expect(m.type, 1);
  });

  test('SnapshotMsg round-trips incl. raw stateBytes', () {
    final state = Uint8List.fromList(List.generate(40, (i) => i));
    final m = roundTrip(SnapshotMsg(serverTick: 99, ackedSeq: const [3, 5], stateBytes: state));
    expect(m.serverTick, 99);
    expect(m.ackedSeq, [3, 5]);
    expect(m.stateBytes, state);
  });

  test('MatchEndMsg round-trips reason', () {
    final m = roundTrip(const MatchEndMsg(reason: EndReason.opponentLeft));
    expect(m.reason, EndReason.opponentLeft);
  });

  test('MatchEndMsg round-trips reason + winnerSlot', () {
    final m = roundTrip(const MatchEndMsg(reason: EndReason.coreDestroyed, winnerSlot: 1));
    expect(m.reason, EndReason.coreDestroyed);
    expect(m.winnerSlot, 1);
  });

  test('MatchEndMsg winnerSlot defaults to -1', () {
    final m = roundTrip(const MatchEndMsg(reason: EndReason.opponentLeft));
    expect(m.winnerSlot, -1);
  });

  test('InputMsg round-trips an ultimate intent type', () {
    final m = InputMsg(slot: 0, seq: 1, clientTick: 0, aimX: 5, aimY: 6, type: IntentType.ultimate.index);
    final back = ProtocolCodec.decode(ProtocolCodec.encode(m)) as InputMsg;
    expect(back.type, IntentType.ultimate.index);
    expect(back.aimX, 5);
    expect(back.aimY, 6);
  });

  test('decode throws on a text frame', () {
    expect(() => ProtocolCodec.decode('not bytes'), throwsArgumentError);
  });

  test('decode throws on an empty frame', () {
    expect(() => ProtocolCodec.decode(<int>[]), throwsArgumentError);
  });

  test('InputMsg golden bytes are stable', () {
    final bytes = ProtocolCodec.encode(const InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 65536, aimY: 0, type: 1));
    // tag(1)=0x02, then i32 LE: slot,seq,clientTick,aimX,aimY,type
    expect(bytes, [
      0x02,
      0,0,0,0,        // slot 0
      1,0,0,0,        // seq 1
      0,0,0,0,        // clientTick 0
      0,0,1,0,        // aimX 65536
      0,0,0,0,        // aimY 0
      1,0,0,0,        // type 1
    ]);
  });
}
