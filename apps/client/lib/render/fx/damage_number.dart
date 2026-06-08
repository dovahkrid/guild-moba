import 'package:flame/components.dart';
import 'package:flutter/painting.dart';
import 'package:sim/sim.dart' show EntityKind, kOne;

/// Q16.16 raw damage → whole-number string.
String damageText(int amountRaw) => (amountRaw / kOne).round().toString();

/// Number color by the source's EntityKind.index (hero = white, structure = amber).
Color damageColor(int sourceKind) {
  if (sourceKind == EntityKind.tower.index || sourceKind == EntityKind.core.index) {
    return const Color(0xFFFFC107);
  }
  return const Color(0xFFFFFFFF);
}

/// A floating damage number. Rises + fades, then self-removes (modeled on
/// ReactionLabel).
class DamageNumber extends TextComponent {
  DamageNumber({required int amountRaw, required int sourceKind, required Vector2 position})
      : super(
          text: damageText(amountRaw),
          position: position,
          anchor: Anchor.center,
          textRenderer: TextPaint(
            style: TextStyle(
              color: damageColor(sourceKind),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        );

  double _age = 0;
  static const double _life = 0.7;

  @override
  void update(double dt) {
    super.update(dt);
    _age += dt;
    position.y -= 28 * dt;
    if (_age >= _life) removeFromParent();
  }
}
