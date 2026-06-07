import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

/// Per-slot input frontier. Dedupes by seq, tracks the ack frontier reported in
/// snapshots, and yields each tick's intents: a HELD move/attack (last-writer-
/// wins, persistent — heroes keep seeking) plus a ONE-SHOT ability that fires the
/// tick it is drained and is then cleared (an ability is an edge-triggered action,
/// not a held state — a held ability would auto-recast every cooldown). PURE.
class IntentBuffer {
  final List<int> lastAckedSeq = [0, 0];
  final List<Intent?> _held = [null, null]; // persistent move/attack
  final List<Intent?> _pendingAbility = [null, null]; // one-shot, cleared on drain

  /// Accept an inbound input. Returns false if stale/duplicate/out-of-range.
  bool accept(InputMsg msg) {
    final slot = msg.slot;
    if (slot < 0 || slot > 1) return false;
    if (msg.type < 0 || msg.type >= IntentType.values.length) return false;
    if (msg.seq <= lastAckedSeq[slot]) return false;
    lastAckedSeq[slot] = msg.seq;
    final intent = Intent(
      playerSlot: slot,
      type: IntentType.values[msg.type],
      aimX: msg.aimX,
      aimY: msg.aimY,
      seq: msg.seq,
      clientTick: msg.clientTick,
    );
    if (intent.type == IntentType.ability) {
      _pendingAbility[slot] = intent; // one-shot
    } else {
      _held[slot] = intent; // move/attack: persistent, last-writer-wins
    }
    return true;
  }

  /// The intents to apply this tick: held move/attack (NOT cleared) + any pending
  /// one-shot ability (cleared after this drain). The sim re-sorts by
  /// (playerSlot, seq), so append order here is not load-bearing.
  List<Intent> drainForTick() {
    final out = <Intent>[];
    for (final i in _held) {
      if (i != null) out.add(i);
    }
    for (var slot = 0; slot < 2; slot++) {
      final a = _pendingAbility[slot];
      if (a != null) {
        out.add(a);
        _pendingAbility[slot] = null; // one-shot: fire once, then clear
      }
    }
    return out;
  }
}
