import 'dart:async';

import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

import '../net/player_conn.dart';
import 'intent_buffer.dart';
import 'tick_driver.dart';

/// Pure-ish authoritative match loop. Owns one Simulation + an IntentBuffer.
/// Time enters only via the injected TickDriver; connections only via PlayerConn.
class Match {
  Match({required this.seed, required TickDriver driver, Simulation? sim})
      : _driver = driver,
        _sim = sim ?? Simulation.create(SimConfig(seed: seed));

  final int seed;
  final TickDriver _driver;
  final Simulation _sim;
  final IntentBuffer _buffer = IntentBuffer();
  final List<PlayerConn?> _players = [null, null];
  final List<StreamSubscription<List<int>>> _subs = [];

  int _currentTick = 0;
  bool started = false;
  bool ended = false;

  /// Called synchronously when the match ends (both win/loss paths).
  void Function()? onEnded;

  int get serverTick => _currentTick;

  void addPlayer(int slot, PlayerConn conn) {
    _players[slot] = conn;
    _subs.add(conn.messages.listen((frame) {
      final Msg msg;
      try {
        msg = ProtocolCodec.decode(frame);
      } catch (_) {
        return; // malformed frame: ignore, keep the match alive
      }
      if (msg is InputMsg) {
        // Server is authoritative on slot: stamp with the assigned slot.
        _buffer.accept(InputMsg(
          slot: slot,
          seq: msg.seq,
          clientTick: msg.clientTick,
          aimX: msg.aimX,
          aimY: msg.aimY,
          type: msg.type,
        ));
      }
    }, onError: (Object _) => conn.close())); // stream/socket error: drop that conn
    conn.onClose.then((_) => _onPlayerLeft(slot));
  }

  void start() {
    if (started) return;
    started = true;
    // Tell each player its slot + the seed (client constructs its MatchController).
    for (var slot = 0; slot < 2; slot++) {
      _players[slot]?.send(ProtocolCodec.encode(MatchStartMsg(
          yourSlot: slot, seed: seed, tickRateHz: 30, snapshotRateHz: 20, startTick: 0)));
    }
    _driver.start(_tick);
  }

  void _tick() {
    if (ended) return;
    final intents = _buffer.drainForTick();
    _sim.step(_currentTick, intents);
    if (_sim.winnerTeam != -1) {
      _endWithWin(_sim.winnerTeam); // teamId == slot in 1v1
      return;
    }
    if (shouldSnapshot(_currentTick)) {
      final snap = ProtocolCodec.encode(SnapshotMsg(
        serverTick: _currentTick,
        ackedSeq: [_buffer.lastAckedSeq[0], _buffer.lastAckedSeq[1]],
        stateBytes: _sim.snapshotBytes(),
      ));
      for (final p in _players) {
        p?.send(snap);
      }
    }
    _currentTick++;
  }

  void _endWithWin(int winnerSlot) {
    if (ended) return;
    ended = true;
    _driver.stop();
    final snap = ProtocolCodec.encode(SnapshotMsg(
      serverTick: _currentTick,
      ackedSeq: [_buffer.lastAckedSeq[0], _buffer.lastAckedSeq[1]],
      stateBytes: _sim.snapshotBytes(),
    ));
    final end = ProtocolCodec.encode(
        MatchEndMsg(reason: EndReason.coreDestroyed, winnerSlot: winnerSlot));
    for (final p in _players) {
      p?.send(snap);
      p?.send(end);
      p?.close();
    }
    for (final sub in _subs) {
      sub.cancel();
    }
    onEnded?.call();
  }

  void _onPlayerLeft(int slot) {
    if (ended) return;
    ended = true;
    _driver.stop();
    for (var s = 0; s < 2; s++) {
      if (s != slot) {
        _players[s]?.send(ProtocolCodec.encode(
            const MatchEndMsg(reason: EndReason.opponentLeft)));
      }
      _players[s]?.close();
    }
    for (final sub in _subs) {
      sub.cancel();
    }
    onEnded?.call();
  }
}
