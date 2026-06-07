import 'dart:ui';

import 'package:flame/components.dart';
import 'package:sim/sim.dart' show EntityKind;

import 'element_palette.dart';

/// A Flame view of one sim entity. Branches its shape/color on (kind, teamId)
/// and renders a health bar. Purely cosmetic — never feeds back into the sim.
class EntityView extends PositionComponent {
  EntityView({required this.kind, required this.teamId, required this.isLocal})
      : super(anchor: Anchor.center, size: Vector2.all(_sizeFor(kind)));

  static const double _kLerpSpeed = 12.0;
  static const double _kBarH = 3.0;

  final int kind; // EntityKind.index
  final int teamId;
  final bool isLocal;

  /// Target in Flame coords (set from MatchView each frame).
  final Vector2 target = Vector2.zero();

  /// 0..1 health fraction (set from MatchView each frame).
  double hpRatio = 1.0;

  /// Elemental status (Element.index, -1 = none); set from MatchView each frame.
  int statusElement = -1;
  CircleComponent? _statusRing;

  RectangleComponent? _hpFg;
  double _barW = 0;

  static double _sizeFor(int kind) {
    if (kind == EntityKind.core.index) return 28;
    if (kind == EntityKind.tower.index) return 22;
    if (kind == EntityKind.creep.index) return 12;
    return 20; // hero / wanderer
  }

  @override
  Future<void> onLoad() async {
    final paint = Paint()..color = _color();
    if (kind == EntityKind.tower.index || kind == EntityKind.core.index) {
      await add(RectangleComponent(size: size, anchor: Anchor.center, paint: paint));
    } else {
      await add(CircleComponent(radius: size.x / 2, anchor: Anchor.center, paint: paint));
    }
    if (isLocal) {
      await add(CircleComponent(
        radius: size.x / 2 + 2,
        anchor: Anchor.center,
        paint: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFFFFFFF),
      ));
    }
    // Elemental-status ring (Plan 4): colour set each frame from statusElement.
    _statusRing = CircleComponent(
      radius: size.x / 2 + 4,
      anchor: Anchor.center,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x00000000), // transparent until coated
    );
    await add(_statusRing!);
    // Health bar (skip the neutral wanderer — it has no combat role).
    if (kind != EntityKind.wanderer.index) {
      _barW = size.x;
      final top = -size.y / 2 - _kBarH - 2;
      await add(RectangleComponent(
        position: Vector2(-_barW / 2, top),
        size: Vector2(_barW, _kBarH),
        paint: Paint()..color = const Color(0x88000000),
      ));
      _hpFg = RectangleComponent(
        position: Vector2(-_barW / 2, top),
        size: Vector2(_barW, _kBarH),
        paint: Paint()..color = const Color(0xFF4CAF50),
      );
      await add(_hpFg!);
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    position.lerp(target, (_kLerpSpeed * dt).clamp(0.0, 1.0));
    final fg = _hpFg;
    if (fg != null) fg.size.x = _barW * hpRatio.clamp(0.0, 1.0);
    final ring = _statusRing;
    if (ring != null) {
      ring.paint.color = elementColor(statusElement) ?? const Color(0x00000000);
    }
  }

  Color _color() {
    switch (teamId) {
      case 0:
        return const Color(0xFF2196F3); // blue
      case 1:
        return const Color(0xFFF44336); // red
      default:
        return const Color(0xFF9E9E9E); // neutral grey
    }
  }
}
