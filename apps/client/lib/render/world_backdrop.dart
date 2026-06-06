import 'dart:ui';

import 'package:flame/components.dart';

import 'coord.dart';

/// Static lane rectangle + center line. Placeholder art only.
class WorldBackdrop extends PositionComponent {
  WorldBackdrop() : super(anchor: Anchor.center);

  // Lane dimensions in world units.
  static const double _laneW = 24.0;
  static const double _laneH = 8.0;

  late final RectangleComponent _lane;
  late final RectangleComponent _centerLine;

  @override
  Future<void> onLoad() async {
    _lane = RectangleComponent(
      size: Vector2(
        _laneW * kPixelsPerUnit,
        _laneH * kPixelsPerUnit,
      ),
      anchor: Anchor.center,
      paint: Paint()..color = const Color(0xFF263238),
    );
    _centerLine = RectangleComponent(
      size: Vector2(2.0, _laneH * kPixelsPerUnit),
      anchor: Anchor.center,
      paint: Paint()..color = const Color(0xFF546E7A),
    );
    await addAll([_lane, _centerLine]);
  }
}
