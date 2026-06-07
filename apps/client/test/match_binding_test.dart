import 'dart:async';
import 'package:guild_client/match/match_binding.dart';
import 'package:guild_client/net/transport.dart';
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemTransport implements Transport {
  final _in = StreamController<List<int>>.broadcast();
  final List<List<int>> sent = [];
  @override
  Stream<List<int>> get inbound => _in.stream;
  @override
  void send(List<int> f) => sent.add(f);
  @override
  Future<void> close() async => _in.close();
  void serverPush(List<int> f) => _in.add(f);
}

void main() {
  test('constructs controller on MatchStart, then predicts + sends input',
      () async {
    final mem = _MemTransport();
    final binding = MatchBinding(mem);
    mem.serverPush(ProtocolCodec.encode(const MatchStartMsg(
        yourSlot: 0,
        seed: 1337,
        tickRateHz: 30,
        snapshotRateHz: 20,
        startTick: 0)));
    await Future<void>.delayed(Duration.zero); // deliver inbound

    expect(binding.isReady, isTrue);
    binding.submitMoveTo(655360, 0); // click far right
    // An InputMsg frame was sent to the server.
    final sent = mem.sent.map(ProtocolCodec.decode).whereType<InputMsg>().toList();
    expect(sent.single.aimX, 655360);

    // Advance ~10 ticks of client time; the local hero predicts movement.
    binding.tick(330); // 10 * 33ms
    final v = binding.view!;
    expect(v.local.x, greaterThan(-8.0));
  });

  test('forwards server snapshots into reconciliation', () async {
    final mem = _MemTransport();
    final binding = MatchBinding(mem);
    mem.serverPush(ProtocolCodec.encode(const MatchStartMsg(
        yourSlot: 0,
        seed: 1337,
        tickRateHz: 30,
        snapshotRateHz: 20,
        startTick: 0)));
    await Future<void>.delayed(Duration.zero);
    binding.tick(330);
    // A no-input authoritative snapshot at tick 5.
    final srv = Simulation.create(const SimConfig(seed: 1337));
    for (var t = 0; t < 6; t++) {
      srv.step(t, const []);
    }
    mem.serverPush(ProtocolCodec.encode(SnapshotMsg(
        serverTick: 5,
        ackedSeq: const [0, 0],
        stateBytes: srv.snapshotBytes())));
    await Future<void>.delayed(Duration.zero);
    expect(binding.view!.lastServerTick, 5);
  });

  test('surfaces the winner from a MatchEndMsg', () async {
    final mem = _MemTransport();
    final binding = MatchBinding(mem);
    mem.serverPush(ProtocolCodec.encode(const MatchStartMsg(
        yourSlot: 0, seed: 1337, tickRateHz: 30, snapshotRateHz: 20, startTick: 0)));
    await Future<void>.delayed(Duration.zero);
    expect(binding.isOver, isFalse);
    mem.serverPush(ProtocolCodec.encode(
        const MatchEndMsg(reason: EndReason.coreDestroyed, winnerSlot: 0)));
    await Future<void>.delayed(Duration.zero);
    expect(binding.isOver, isTrue);
    expect(binding.winnerSlot, 0);
    expect(binding.localSlot, 0);
  });
}
