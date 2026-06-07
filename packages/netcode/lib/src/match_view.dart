/// Render-boundary value types. Doubles/ints ONLY (never fed back into the sim).
class RenderEntity {
  final int id;
  final int kind; // EntityKind.index
  final int teamId; // 0/1 players, 2 neutral
  final double x, y;
  final double hp, maxHp;
  const RenderEntity({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.x,
    required this.y,
    required this.hp,
    required this.maxHp,
  });
}

class MatchView {
  /// All LIVE entities (local hero predicted; opponent hero interpolated;
  /// others straight from the predicted sim). Discrete fields (hp) are snapshot
  /// values — never interpolated.
  final List<RenderEntity> entities;
  final int localSlot;
  final int localGold;
  final int predictedTick;
  final int lastServerTick;
  final int pendingInputCount;
  final double lastCorrectionDist;
  const MatchView({
    required this.entities,
    required this.localSlot,
    required this.localGold,
    required this.predictedTick,
    required this.lastServerTick,
    required this.pendingInputCount,
    required this.lastCorrectionDist,
  });

  /// The local hero's render entity (predicted).
  RenderEntity get local => entities.firstWhere((e) => e.id == localSlot);

  /// The opponent hero's render entity (interpolated). Always present (heroes
  /// respawn rather than despawn).
  RenderEntity get opponent => entities.firstWhere((e) => e.id == 1 - localSlot);
}
