/// Render-boundary value types. Doubles ONLY (never fed back into the sim).
class RenderEntity {
  final double x, y;
  const RenderEntity(this.x, this.y);
}

class MatchView {
  final RenderEntity local;
  final RenderEntity opponent;
  final RenderEntity wanderer;
  final int predictedTick;
  final int lastServerTick;
  final int pendingInputCount;
  final double lastCorrectionDist; // world units corrected on the last reconcile
  const MatchView({
    required this.local,
    required this.opponent,
    required this.wanderer,
    required this.predictedTick,
    required this.lastServerTick,
    required this.pendingInputCount,
    required this.lastCorrectionDist,
  });
}
