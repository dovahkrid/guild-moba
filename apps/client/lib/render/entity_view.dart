import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flutter/animation.dart' show Curves;
import 'package:sim/sim.dart' show EntityKind;

import 'element_palette.dart';
import 'sprites/pixel_sprite_component.dart';
import 'sprites/sprite_catalog.dart';
import 'sprites/sprite_palette.dart';

/// Returns the facing (±1) for horizontal delta [dx]; holds [prev] inside the
/// deadzone (defaults to right when prev is 0). Pure — unit-tested.
int facingFor(double dx, int prev, {double deadzone = 0.02}) {
  if (dx > deadzone) return 1;
  if (dx < -deadzone) return -1;
  return prev == 0 ? 1 : prev;
}

/// A Flame view of one sim entity: a recolored pixel sprite + health bar + a
/// tweened elemental-status aura. Animates facing, an idle/walk bob, spawn-in,
/// death, and a downed dim. Purely cosmetic — never feeds back into the sim.
class EntityView extends PositionComponent {
  EntityView({
    required this.kind,
    required this.teamId,
    required this.element,
    required this.isLocal,
    required this.catalog,
  }) : super(anchor: Anchor.center, size: Vector2.all(_sizeFor(kind)));

  static const double _kLerpSpeed = 12.0;
  static const double _kBarH = 3.0;
  static const double _moveEps = 0.05;

  final int kind; // EntityKind.index
  final int teamId;
  final int element; // innate element for heroes, -1 otherwise
  final bool isLocal;
  final SpriteCatalog catalog;

  final Vector2 target = Vector2.zero();
  double hpRatio = 1.0;
  int statusElement = -1;

  late final PixelSpriteComponent _sprite;
  CircleComponent? _aura;
  RectangleComponent? _hpFg;
  double _barW = 0;

  int _facing = 1;
  double _bob = 0;
  bool _downed = false;
  Color _auraColor = const Color(0xFF000000);
  double _auraAlpha = 0;

  static double _sizeFor(int kind) {
    if (kind == EntityKind.core.index) return 30;
    if (kind == EntityKind.tower.index) return 26;
    if (kind == EntityKind.creep.index) return 14;
    return 22; // hero / wanderer
  }

  @override
  Future<void> onLoad() async {
    _sprite = PixelSpriteComponent(
      sprite: catalog.forKind(kind),
      slotColors: spritePalette(teamId, element),
      size: size.clone(),
    );
    await add(_sprite);

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

    _aura = CircleComponent(
      radius: size.x / 2 + 4,
      anchor: Anchor.center,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0x00000000),
    );
    await add(_aura!);

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
        paint: Paint()..color = const Color(0xFF7CD06B),
      );
      await add(_hpFg!);
    }

    // Spawn-in pop.
    scale = Vector2.zero();
    add(ScaleEffect.to(
      Vector2.all(1),
      EffectController(duration: 0.18, curve: Curves.easeOutBack),
    ));
  }

  @override
  void update(double dt) {
    super.update(dt);
    final dx = target.x - position.x;
    final dy = target.y - position.y;
    position.lerp(target, (_kLerpSpeed * dt).clamp(0.0, 1.0));

    _facing = facingFor(dx, _facing);
    _sprite.flipX = _facing < 0;
    _sprite.downed = _downed;

    final moving = !_downed && (dx.abs() + dy.abs() > _moveEps);
    _bob += dt * (moving ? 11.0 : 4.0);
    final amp = _downed ? 0.0 : (moving ? 2.0 : 1.0);
    _sprite.position.setValues(0, -(math.sin(_bob).abs()) * amp); // bob around center

    final fg = _hpFg;
    if (fg != null) fg.size.x = _barW * hpRatio.clamp(0.0, 1.0);

    final tgt = elementColor(statusElement);
    if (tgt != null) _auraColor = tgt;
    final goal = tgt != null ? 1.0 : 0.0;
    _auraAlpha += (goal - _auraAlpha) * (8 * dt).clamp(0.0, 1.0);
    _aura?.paint.color = _auraColor.withValues(alpha: _auraAlpha * 0.9);
  }

  /// Mark/unmark the downed (dead/respawning) dim. Used by GuildGame on HeroDowned.
  void setDowned(bool d) => _downed = d;

  /// Re-pop on respawn (clears the downed dim).
  void respawn() {
    _downed = false;
    add(ScaleEffect.to(
      Vector2.all(1),
      EffectController(duration: 0.18, curve: Curves.easeOutBack),
    ));
  }

  /// White hit-flash (driven by a HitFx).
  void flash() => _sprite.hit();

  /// Collapse + remove (creep/structure death). Detached from the live map first.
  void playDeathAndRemove() {
    add(ScaleEffect.to(Vector2.zero(), EffectController(duration: 0.22, curve: Curves.easeIn)));
    add(RemoveEffect(delay: 0.24));
  }
}
