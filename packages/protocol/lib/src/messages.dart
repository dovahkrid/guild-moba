import 'dart:typed_data';

enum EndReason { opponentLeft, roomFull, serverShutdown, coreDestroyed }

/// Wire messages. Integer-only fields (Q16.16 raws for aim). Sealed so the
/// codec switch is exhaustive.
sealed class Msg {
  const Msg();
}

class MatchStartMsg extends Msg {
  final int yourSlot, seed, tickRateHz, snapshotRateHz, startTick;
  const MatchStartMsg({
    required this.yourSlot,
    required this.seed,
    required this.tickRateHz,
    required this.snapshotRateHz,
    required this.startTick,
  });
}

class InputMsg extends Msg {
  final int slot, seq, clientTick, aimX, aimY, type;
  const InputMsg({
    required this.slot,
    required this.seq,
    required this.clientTick,
    required this.aimX,
    required this.aimY,
    required this.type,
  });
}

class SnapshotMsg extends Msg {
  final int serverTick;
  final List<int> ackedSeq; // length 2: [slot0, slot1]
  final Uint8List stateBytes; // Simulation.snapshotBytes()
  const SnapshotMsg({
    required this.serverTick,
    required this.ackedSeq,
    required this.stateBytes,
  });
}

class MatchEndMsg extends Msg {
  final EndReason reason;
  final int winnerSlot; // slot of the winning player; -1 unless reason == coreDestroyed
  const MatchEndMsg({required this.reason, this.winnerSlot = -1});
}
