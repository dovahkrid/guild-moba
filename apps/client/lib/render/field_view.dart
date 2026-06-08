import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import 'coord.dart';
import 'element_palette.dart';

/// A translucent element-tinted field zone (Plan 4) with a breathing pulse + a
/// pulsing inner ring. Position is set each frame by GuildGame. Purely cosmetic.
class FieldView extends PositionComponent {
  FieldView({required this.element, required double radius}) : _r = radius * kPixelsPerUnit;

  final int element; // Element.index
  final double _r;
  double _t = 0;
  late final CircleComponent _fill;
  late final CircleComponent _ring;

  @override
  Future<void> onLoad() async {
    _fill = CircleComponent(
      radius: _r,
      anchor: Anchor.center,
      paint: Paint()..color = fieldColor(element),
    );
    _ring = CircleComponent(
      radius: _r,
      anchor: Anchor.center,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = elementColor(element) ?? const Color(0xFF9E9E9E),
    );
    await addAll([_fill, _ring]);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _t += dt;
    final breathe = 1 + 0.05 * math.sin(_t * 3);
    _fill.scale = Vector2.all(breathe);
    final ringPulse = 1 + 0.12 * (0.5 + 0.5 * math.sin(_t * 3));
    _ring.scale = Vector2.all(ringPulse);
  }
}
