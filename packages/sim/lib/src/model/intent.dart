enum IntentType { none, move, attack, ability, ultimate }

/// One-shot (edge-triggered) intents fire on their issuing tick and never
/// re-feed; held intents (move/attack) persist. Shared by netcode + server so
/// they classify intents the same way the sim does.
extension IntentTypeX on IntentType {
  bool get isOneShot => this == IntentType.ability || this == IntentType.ultimate;
}

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
