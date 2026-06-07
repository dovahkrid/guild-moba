import 'package:flame/components.dart';
import 'package:flutter/painting.dart';

/// A transient floating reaction pop-text (Plan 4). Rises, then self-removes.
class ReactionLabel extends TextComponent {
  ReactionLabel({required super.text, required Vector2 position})
      : super(
          position: position,
          anchor: Anchor.center,
          textRenderer: TextPaint(
            style: const TextStyle(
              color: Color(0xFFFFE082),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        );

  double _age = 0;
  static const double _life = 0.8;

  @override
  void update(double dt) {
    super.update(dt);
    _age += dt;
    position.y -= 24 * dt; // rise
    if (_age >= _life) removeFromParent();
  }
}
