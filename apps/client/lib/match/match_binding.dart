import 'dart:async';

import 'package:netcode/netcode.dart';
import 'package:protocol/protocol.dart';

import '../net/transport.dart';

/// Glue between the network Transport and the pure MatchController. Holds NO
/// gameplay truth — it only pumps bytes and the 30 Hz client tick.
class MatchBinding {
  MatchBinding(this._transport) {
    _sub = _transport.inbound.listen(_onFrame);
  }

  final Transport _transport;
  late final StreamSubscription<List<int>> _sub;

  MatchController? _controller;
  int _renderTimeMs = 0;
  int _accMs = 0;
  static const int _tickMs = 33; // ~30 Hz

  bool _ended = false;
  int _winnerSlot = -1;

  bool get isReady => _controller != null;
  MatchView? get view => _controller?.update(_renderTimeMs);

  bool get isOver => _ended;
  int? get winnerSlot => _ended ? _winnerSlot : null;
  int? get localSlot => _controller?.localSlot;

  void _onFrame(List<int> frame) {
    final msg = ProtocolCodec.decode(frame);
    if (msg is MatchStartMsg) {
      _controller = MatchController(
        seed: msg.seed,
        localSlot: msg.yourSlot,
        startTick: msg.startTick,
      );
    } else if (msg is SnapshotMsg) {
      _controller?.onServerSnapshot(msg);
    } else if (msg is MatchEndMsg) {
      _winnerSlot = msg.winnerSlot;
      _ended = true; // keep the controller so the final frame stays rendered
    }
  }

  /// Local input: a world point (Q16.16 raw). Predict immediately + send.
  void submitMoveTo(int aimXRaw, int aimYRaw) {
    if (_ended) return; // no input after the match ends
    final c = _controller;
    if (c == null) return;
    final input = c.applyLocalInput(aimXRaw, aimYRaw);
    if (input == null) return; // Plan 6: dead hero -> nothing to send
    _transport.send(ProtocolCodec.encode(input));
  }

  /// Local input: right-click an enemy entity id -> attack-lock. Predict + send.
  void submitAttack(int targetId) {
    if (_ended) return; // no input after the match ends
    final c = _controller;
    if (c == null) return;
    final input = c.applyAttackInput(targetId);
    if (input == null) return; // Plan 6: dead hero -> nothing to send
    _transport.send(ProtocolCodec.encode(input));
  }

  /// Local input: ability cast at a world point (Q16.16 raw), from an E-cast
  /// (self-placed at the hero) or a left-click aim-confirm. Predict + send.
  void submitAbility(int aimXRaw, int aimYRaw) {
    if (_ended) return; // no input after the match ends
    final c = _controller;
    if (c == null) return;
    final input = c.applyAbilityInput(aimXRaw, aimYRaw);
    if (input == null) return; // Plan 6: dead hero -> nothing to send
    _transport.send(ProtocolCodec.encode(input));
  }

  /// Local input: ULT cast at a world point (Q16.16 raw), from a Q-cast
  /// (self-placed at the hero) or a left-click aim-confirm. Predict + send.
  void submitUltimate(int aimXRaw, int aimYRaw) {
    if (_ended) return;
    final c = _controller;
    if (c == null) return;
    final input = c.applyUltimateInput(aimXRaw, aimYRaw);
    if (input == null) return; // Plan 6: dead hero -> nothing to send
    _transport.send(ProtocolCodec.encode(input));
  }

  /// Reactions that fired since the last frame (host spawns pop-text once/frame).
  List<RenderReaction> drainReactions() => _controller?.drainReactions() ?? const [];

  /// Combat FX surfaced since the last frame (host spawns them once/frame).
  List<RenderFx> drainFx() => _controller?.drainFx() ?? const [];

  /// Advance by [dtMs] of real time: accumulate and step the predicted sim at
  /// a fixed 30 Hz; advance the render clock for interpolation.
  ///
  /// A backgrounded browser tab throttles its frame loop, so on refocus the
  /// first frame can carry a multi-second [dtMs]. Cap it so we don't run a
  /// catch-up storm of prediction steps (a "spiral of death"): the predicted
  /// clock simply resumes slightly behind real time, and the next server
  /// snapshot re-anchors it via reconcile (which runs independently of this
  /// loop, off the WebSocket).
  static const int _maxFrameMs = 100; // at most ~3 catch-up ticks per frame
  void tick(int dtMs) {
    if (dtMs > _maxFrameMs) dtMs = _maxFrameMs;
    _renderTimeMs += dtMs;
    if (_ended) return;
    _accMs += dtMs;
    while (_accMs >= _tickMs) {
      _accMs -= _tickMs;
      _controller?.advanceClientTick();
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    await _transport.close();
  }
}
