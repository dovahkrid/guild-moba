import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

/// Per-slot input frontier. Dedupes by seq, tracks the ack frontier reported in
/// snapshots, and yields the held (last-writer-wins) move each tick. PURE.
class IntentBuffer {
  final List<int> lastAckedSeq = [0, 0];
  final List<Intent?> _current = [null, null];

  /// Accept an inbound input. Returns false if stale/duplicate/out-of-range.
  bool accept(InputMsg msg) {
    final slot = msg.slot;
    if (slot < 0 || slot > 1) return false;
    if (msg.type < 0 || msg.type >= IntentType.values.length) return false;
    if (msg.seq <= lastAckedSeq[slot]) return false;
    lastAckedSeq[slot] = msg.seq;
    _current[slot] = Intent(
      playerSlot: slot,
      type: IntentType.values[msg.type],
      aimX: msg.aimX,
      aimY: msg.aimY,
      seq: msg.seq,
      clientTick: msg.clientTick,
    );
    return true;
  }

  /// The intents to apply this tick. _current is NOT cleared (a move sets a
  /// persistent target), matching sim seek semantics.
  List<Intent> drainForTick() {
    final out = <Intent>[];
    for (final i in _current) {
      if (i != null) out.add(i);
    }
    return out;
  }
}
