import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

import 'interpolation_buffer.dart';
import 'match_view.dart';

class _Pending {
  final int clientTick;
  final Intent intent;
  const _Pending(this.clientTick, this.intent);
}

/// Owns the predicted sim + prediction/reconciliation/interpolation. Pure: the
/// HOST drives advanceClientTick() (per 33ms) and update(renderMs) (per frame).
/// Uses Fixed.sqrt (not dart:math) so the correction-dist metric stays pure.
class MatchController {
  final int localSlot;
  final Simulation _predicted;
  final InterpolationBuffer _interp = InterpolationBuffer();

  int _nextTick; // next tick to step; completed up to _nextTick-1
  int _localSeq = 0;
  final List<_Pending> _pending = []; // ordered by clientTick
  int _lastReconciledServerTick = -1;
  double _lastCorrectionDist = 0.0;

  MatchController({required int seed, required this.localSlot, required int startTick})
      : _predicted = Simulation.create(SimConfig(seed: seed)),
        _nextTick = startTick;

  int get predictedTick => _nextTick;
  int get lastServerTick => _lastReconciledServerTick;
  int get pendingCount => _pending.length;
  double get lastCorrectionDist => _lastCorrectionDist;

  // --- test seams ---
  int debugHash() => _predicted.canonicalStateHash();
  FVec2 debugLocalPos() => _predicted.entity(localSlot).pos;

  /// Record + apply a local move. Returns the InputMsg the host must send.
  InputMsg applyLocalInput(int aimX, int aimY) {
    final seq = ++_localSeq;
    final intent = Intent(
        playerSlot: localSlot,
        type: IntentType.move,
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
        type: IntentType.move.index);
  }

  /// The held local intent in effect at tick [t] = latest pending with clientTick <= t.
  Intent? _heldAt(int t) {
    Intent? held;
    for (final p in _pending) {
      if (p.clientTick <= t) {
        held = p.intent;
      } else {
        break;
      }
    }
    return held;
  }

  /// Advance the predicted sim one tick (host calls at 30Hz).
  void advanceClientTick() {
    final held = _heldAt(_nextTick);
    _predicted.step(_nextTick, held == null ? const [] : [held]);
    _nextTick++;
  }

  /// Reconcile to an authoritative snapshot.
  void onServerSnapshot(SnapshotMsg snap) {
    // Interpolation always sees fresh ticks (dedupe handled inside).
    final opp = Simulation.peekEntityPos(snap.stateBytes, 1 - localSlot);
    _interp.add(snap.serverTick, opp.x.toDouble(), opp.y.toDouble());

    if (snap.serverTick <= _lastReconciledServerTick) return; // stale/dup guard

    // Pre-reconcile local pos (for correction distance).
    final before = _predicted.entity(localSlot).pos;

    // Drop acked pending intents.
    final acked = snap.ackedSeq[localSlot];
    _pending.removeWhere((p) => p.intent.seq <= acked);

    // Restore to authoritative state, then re-step to "now".
    // Note: acked-and-pruned intents are correctly reproduced here because the
    // authoritative target is carried in snapshotBytes()/restoreFromSnapshot();
    // if a future entity gains intent-derived state NOT stored in the snapshot,
    // this re-step loop would need that state too.
    _predicted.restoreFromSnapshot(snap.stateBytes);
    for (var t = snap.serverTick + 1; t < _nextTick; t++) {
      final held = _heldAt(t);
      _predicted.step(t, held == null ? const [] : [held]);
    }

    // Compute correction distance using Fixed.sqrt (pure, no dart:math).
    final after = _predicted.entity(localSlot).pos;
    _lastCorrectionDist = (after - before).length().toDouble();
    _lastReconciledServerTick = snap.serverTick;
  }

  /// Render view (host calls per frame). Opponent interpolated ~100ms behind.
  MatchView update(int renderTimeMs) {
    final local = _predicted.entity(localSlot).pos;
    final wanderer = _predicted.entity(kWandererEntityId).pos;
    final opp = _interp.sample(renderTimeMs - 100);
    return MatchView(
      local: RenderEntity(local.x.toDouble(), local.y.toDouble()),
      opponent: opp,
      wanderer: RenderEntity(wanderer.x.toDouble(), wanderer.y.toDouble()),
      predictedTick: _nextTick,
      lastServerTick: _lastReconciledServerTick,
      pendingInputCount: _pending.length,
      lastCorrectionDist: _lastCorrectionDist,
    );
  }
}
