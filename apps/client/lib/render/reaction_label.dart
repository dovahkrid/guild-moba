import 'package:flame/components.dart';
import 'package:flutter/painting.dart'; // Flame's TextPaint needs Flutter's TextStyle (not exported by dart:ui)
import 'package:sim/sim.dart' show kOne;

/// Pop-text for a reaction. A flat field-overlap reaction (multiplierRaw == 0)
/// shows no multiplier; an attack-amplify reaction shows "x1.3". (Reaction is
/// Vaporize-only in the slice; the param is kept for forward labels.)
String reactionText(int reaction, int multiplierRaw) {
  if (multiplierRaw == 0) return 'VAPORIZE';
  final mult = multiplierRaw / kOne; // Q16.16 raw → double (int / int = double in Dart)
  return 'VAPORIZE x${mult.toStringAsFixed(1)}';
}

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
