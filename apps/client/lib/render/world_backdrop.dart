import 'dart:ui';

import 'package:flame/components.dart';

import 'coord.dart';

/// Tiled pixel-art lane: a checkered ground, an edge border, and a center line.
/// Centered on world (0,0); drawn first (under entities). Purely cosmetic.
class WorldBackdrop extends PositionComponent {
  WorldBackdrop() : super(anchor: Anchor.center);

  static const double _laneW = 24.0; // world units
  static const double _laneH = 8.0;
  static const double _tile = 1.0; // world units per tile

  @override
  void render(Canvas canvas) {
    const w = _laneW * kPixelsPerUnit;
    const h = _laneH * kPixelsPerUnit;
    const left = -w / 2, top = -h / 2;
    const ts = _tile * kPixelsPerUnit;
    final cols = (_laneW / _tile).round();
    final rows = (_laneH / _tile).round();

    final a = Paint()..color = const Color(0xFF26333B);
    final b = Paint()..color = const Color(0xFF2C3A42);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        canvas.drawRect(
          Rect.fromLTWH(left + c * ts, top + r * ts, ts, ts),
          (r + c).isEven ? a : b,
        );
      }
    }
    // Edge border.
    canvas.drawRect(
      const Rect.fromLTWH(left, top, w, h),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFF3E535E),
    );
    // Center divider.
    canvas.drawRect(
      const Rect.fromLTWH(-1, top, 2, h),
      Paint()..color = const Color(0xFF55707D),
    );
  }
}
