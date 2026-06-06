import 'dart:ui';

import 'package:flame/components.dart';

/// Entity roles, determines the render color.
enum EntityRole { local, opponent, wanderer }

/// A Flame PositionComponent that renders a colored circle and cosmetically
/// lerps its [position] toward a [target] each frame.
///
/// NEVER feeds position data back into the sim — purely cosmetic 60fps glide.
class EntityView extends PositionComponent {
  EntityView({required this.role})
    : super(anchor: Anchor.center, size: Vector2.all(_kSize));

  static const double _kSize = 20.0;
  static const double _kLerpSpeed = 12.0; // world units/sec (screen-space)

  final EntityRole role;

  /// The authoritative target in Flame coordinates. Updated from MatchView.
  final Vector2 target = Vector2.zero();

  late final CircleComponent _circle;

  @override
  Future<void> onLoad() async {
    _circle = CircleComponent(
      radius: _kSize / 2,
      paint: Paint()..color = _colorForRole(role),
      anchor: Anchor.center,
    );
    await add(_circle);
  }

  @override
  void update(double dt) {
    super.update(dt);
    // Cosmetic lerp toward target — never touches simulation state.
    position.lerp(target, (_kLerpSpeed * dt).clamp(0.0, 1.0));
  }

  static Color _colorForRole(EntityRole r) {
    switch (r) {
      case EntityRole.local:
        return const Color(0xFF2196F3); // blue
      case EntityRole.opponent:
        return const Color(0xFFF44336); // red
      case EntityRole.wanderer:
        return const Color(0xFF9E9E9E); // grey
    }
  }
}
