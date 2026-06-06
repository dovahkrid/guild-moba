enum IntentType { none, move }

/// A player command for a tick. Aim values are Q16.16 raw ints.
class Intent {
  final int playerSlot;
  final IntentType type;
  final int aimX;
  final int aimY;
  final int seq;
  final int clientTick;

  const Intent({
    required this.playerSlot,
    required this.type,
    this.aimX = 0,
    this.aimY = 0,
    this.seq = 0,
    this.clientTick = 0,
  });
}
