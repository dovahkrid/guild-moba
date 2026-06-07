import 'dart:ui';

import 'package:flame/components.dart';

import 'coord.dart';
import 'element_palette.dart';

/// A translucent element-tinted field zone (Plan 4). Purely cosmetic; position
/// is set each frame by GuildGame (the field is stationary in the sim).
class FieldView extends PositionComponent {
  FieldView({required this.element, required double radius})
      : _r = radius * kPixelsPerUnit,
        super(anchor: Anchor.center);

  final int element; // Element.index
  final double _r;

  @override
  Future<void> onLoad() async {
    await add(CircleComponent(
      radius: _r,
      anchor: Anchor.center,
      paint: Paint()..color = fieldColor(element),
    ));
    await add(CircleComponent(
      radius: _r,
      anchor: Anchor.center,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = elementColor(element) ?? const Color(0xFF9E9E9E),
    ));
  }
}
