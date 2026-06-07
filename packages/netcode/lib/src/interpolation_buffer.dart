class _Sample {
  final int tick;
  final int timeMs;
  final double x, y;
  const _Sample(this.tick, this.timeMs, this.x, this.y);
}

/// Opponent interpolation buffer. Logical time = serverTick * dtMs. Render-only
/// doubles; never extrapolates (holds at the newest sample under loss).
class InterpolationBuffer {
  static const int dtMs = 33; // ~1/30s, integer; matches the shared tick clock
  final List<_Sample> _samples = []; // ascending tick, capped
  static const int _cap = 64;
  int _newestTick = -1;

  void add(int serverTick, double x, double y) {
    if (serverTick <= _newestTick) return; // dedupe + drop stale
    _newestTick = serverTick;
    _samples.add(_Sample(serverTick, serverTick * dtMs, x, y));
    if (_samples.length > _cap) _samples.removeAt(0);
  }

  int get length => _samples.length;

  /// Sample the opponent position at logical time [targetTimeMs]. Returns (x, y).
  ({double x, double y}) sample(int targetTimeMs) {
    if (_samples.isEmpty) return (x: 0.0, y: 0.0);
    if (targetTimeMs <= _samples.first.timeMs) {
      final s = _samples.first;
      return (x: s.x, y: s.y);
    }
    if (targetTimeMs >= _samples.last.timeMs) {
      final s = _samples.last; // HOLD — never extrapolate
      return (x: s.x, y: s.y);
    }
    for (var i = 0; i < _samples.length - 1; i++) {
      final a = _samples[i], b = _samples[i + 1];
      if (targetTimeMs >= a.timeMs && targetTimeMs <= b.timeMs) {
        final span = (b.timeMs - a.timeMs);
        final alpha = span == 0 ? 0.0 : (targetTimeMs - a.timeMs) / span;
        return (x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha);
      }
    }
    final s = _samples.last;
    return (x: s.x, y: s.y);
  }
}
