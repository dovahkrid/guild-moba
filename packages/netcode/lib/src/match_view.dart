/// Render-boundary value types. Doubles/ints ONLY (never fed back into the sim).
class RenderEntity {
  final int id;
  final int kind; // EntityKind.index
  final int teamId; // 0/1 players, 2 neutral
  final double x, y;
  final double hp, maxHp;
  final int statusElement; // Plan 4: Element.index of the status, -1 = none
  const RenderEntity({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.x,
    required this.y,
    required this.hp,
    required this.maxHp,
    this.statusElement = -1,
  });
}

/// A stationary elemental field zone (Plan 4) for the client to draw.
class RenderField {
  final int ownerId;
  final double x, y;
  final int element; // Element.index
  final double radius;
  const RenderField({
    required this.ownerId,
    required this.x,
    required this.y,
    required this.element,
    required this.radius,
  });
}

/// A reaction that fired this tick (Plan 4) — drives a transient pop-text.
class RenderReaction {
  final double x, y;
  final int reaction; // Reaction.index
  final int multiplierRaw; // Q16.16 raw of the multiplier (e.g. ×1.3)
  const RenderReaction({
    required this.x,
    required this.y,
    required this.reaction,
    required this.multiplierRaw,
  });
}

class MatchView {
  /// All LIVE entities (local hero predicted; opponent hero interpolated;
  /// others straight from the predicted sim). Discrete fields (hp, statusElement)
  /// are snapshot values — never interpolated.
  final List<RenderEntity> entities;
  final int localSlot;
  final int localGold;
  final int predictedTick;
  final int lastServerTick;
  final int pendingInputCount;
  final double lastCorrectionDist;
  final List<RenderField> fields; // Plan 4: active elemental field zones
  const MatchView({
    required this.entities,
    required this.localSlot,
    required this.localGold,
    required this.predictedTick,
    required this.lastServerTick,
    required this.pendingInputCount,
    required this.lastCorrectionDist,
    this.fields = const [],
  });

  /// The local hero's render entity (predicted).
  RenderEntity get local => entities.firstWhere((e) => e.id == localSlot);

  /// The opponent hero's render entity (interpolated). Always present.
  RenderEntity get opponent => entities.firstWhere((e) => e.id == 1 - localSlot);
}
