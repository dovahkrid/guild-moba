import 'dart:ui';

import 'package:flame/components.dart';

/// A brief line-flash from attacker to target (Flame coords). Fades then removes.
class AttackStreak extends PositionComponent {
  AttackStreak({required this.from, required this.to, required this.color});

  final Vector2 from;
  final Vector2 to;
  final Color color;
  double _age = 0;
  static const double _life = 0.14;

  @override
  void update(double dt) {
    super.update(dt);
    _age += dt;
    if (_age >= _life) removeFromParent();
  }

  @override
  void render(Canvas canvas) {
    final t = (1 - _age / _life).clamp(0.0, 1.0);
    final p = Paint()
      ..color = color.withValues(alpha: t)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(from.x, from.y), Offset(to.x, to.y), p);
  }
}
