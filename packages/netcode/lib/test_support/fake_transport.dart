import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

import '../src/interpolation_buffer.dart';
import '../src/match_controller.dart';

class _InFlight<T> {
  final int deliverAtMs;
  final T payload;
  _InFlight(this.deliverAtMs, this.payload);
}

/// Headless server<->client link with a virtual integer-ms clock, injectable
/// one-way latency and deterministic loss. Drives a real server Simulation
/// against a real MatchController. dtMs=33 matches InterpolationBuffer.dtMs.
class FakeTransport {
  static const int dtMs = InterpolationBuffer.dtMs;
  final int seed;
  final int oneWayLatencyMs;
  final double lossRate; // 0..1, applied to BOTH directions
  final MatchController client;
  final Simulation server;
  final int localSlot;

  final DetRng _loss;
  int _nowMs = 0;
  int _serverNextTick = 0;
  int _accMs = 0;
  final List<_InFlight<InputMsg>> _toServer = [];
  final List<_InFlight<SnapshotMsg>> _toClient = [];
  // Nullable: server may have received no input for a slot yet.
  final List<Intent?> _serverHeld = [null, null];
  final List<int> _ackedSeq = [0, 0];

  /// The exact merged authoritative intents the server stepped at each tick,
  /// indexed by tick number. Enables genuine independent replay in tests.
  final List<List<Intent>> serverInputLog = [];

  int _oppSeq = 0;

  FakeTransport({
    required this.seed,
    required this.client,
    required this.localSlot,
    this.oneWayLatencyMs = 75,
    this.lossRate = 0.0,
  })  : server = Simulation.create(SimConfig(seed: seed)),
        _loss = DetRng.fromInt(seed ^ 0x5EED);

  bool _drop() =>
      lossRate > 0 && (_loss.nextU32() / 0x100000000) < lossRate;

  /// Client sends an input now (subject to latency + loss).
  void clientSend(InputMsg msg) {
    if (_drop()) return;
    _toServer.add(_InFlight(_nowMs + oneWayLatencyMs, msg));
  }

  /// Opponent (the OTHER slot, not the local client) sends an input now
  /// (subject to the same latency + loss). Enables tests to drive the opponent
  /// in a straight line and assert real interpolation on a moving segment.
  void opponentSend(int aimX, int aimY) {
    if (_drop()) return;
    _oppSeq++;
    final slot = 1 - localSlot;
    _toServer.add(_InFlight(_nowMs + oneWayLatencyMs,
        InputMsg(slot: slot, seq: _oppSeq, clientTick: 0, aimX: aimX, aimY: aimY, type: IntentType.move.index)));
  }

  /// Advance the whole world by one 33ms client frame: deliver due packets,
  /// step the server on tick boundaries, broadcast snapshots, pump the client.
  ///
  /// Order within a frame:
  ///   1. Advance clock.
  ///   2. Client predicts one tick (runs ahead of server — ensures client is
  ///      always at least 1 tick ahead when a zero-latency snapshot arrives).
  ///   3. Deliver pending client→server inputs.
  ///   4. Step the server forward.
  ///   5. Deliver pending server→client snapshots (client reconciles).
  void tickWorld() {
    _nowMs += dtMs;
    _accMs += dtMs;

    // Advance the client's predicted sim one tick first, so it is always
    // at least one tick ahead of the server when snapshots are delivered.
    client.advanceClientTick();

    // Deliver due client->server inputs into the server's held-intent slots.
    _toServer.removeWhere((f) {
      if (f.deliverAtMs <= _nowMs) {
        final m = f.payload;
        if (m.seq > _ackedSeq[m.slot]) {
          _serverHeld[m.slot] = Intent(
              playerSlot: m.slot,
              type: IntentType.values[m.type],
              aimX: m.aimX,
              aimY: m.aimY,
              seq: m.seq,
              clientTick: m.clientTick);
          _ackedSeq[m.slot] = m.seq;
        }
        return true;
      }
      return false;
    });

    // Step the server forward by whole ticks accumulated.
    while (_accMs >= dtMs) {
      _accMs -= dtMs;
      final intents = <Intent>[
        for (final h in _serverHeld)
          if (h != null) h,
      ];
      final tick = _serverNextTick;
      server.step(tick, intents);
      // Record the merged authoritative input list for independent replay.
      serverInputLog.add(List.of(intents));
      if (shouldSnapshot(tick) && !_drop()) {
        _toClient.add(_InFlight(
          _nowMs + oneWayLatencyMs,
          SnapshotMsg(
              serverTick: tick,
              ackedSeq: [_ackedSeq[0], _ackedSeq[1]],
              stateBytes: server.snapshotBytes()),
        ));
      }
      _serverNextTick++;
    }

    // Deliver due server->client snapshots (client reconciles if needed).
    _toClient.removeWhere((f) {
      if (f.deliverAtMs <= _nowMs) {
        client.onServerSnapshot(f.payload);
        return true;
      }
      return false;
    });
  }

  int get nowMs => _nowMs;
  int get serverTick => _serverNextTick - 1;
  int serverHash() => server.canonicalStateHash();
}
