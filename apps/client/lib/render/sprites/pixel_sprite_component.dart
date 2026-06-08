import 'dart:ui';

import 'package:flame/components.dart';

import 'svg_pixel_sprite.dart';

/// Draws a [SvgPixelSprite]'s rects to the Flame canvas, scaled to [size].
/// Supports a horizontal flip (facing), a decaying white flash (hit feedback),
/// and a downed dim. Purely cosmetic.
class PixelSpriteComponent extends PositionComponent {
  PixelSpriteComponent({
    required this.sprite,
    required this.slotColors,
    required Vector2 size,
  }) : super(size: size, anchor: Anchor.center);

  SvgPixelSprite sprite;
  Map<SpriteSlot, Color> slotColors;
  bool flipX = false;
  bool downed = false;
  double flash = 0; // 0..1 white overlay
  static const double _flashDecay = 6.0; // per second

  void hit() => flash = 1.0;

  @override
  void update(double dt) {
    super.update(dt);
    if (flash > 0) flash = (flash - _flashDecay * dt).clamp(0.0, 1.0);
  }

  @override
  void render(Canvas canvas) {
    final cw = size.x / sprite.vw;
    final ch = size.y / sprite.vh;
    canvas.save();
    if (flipX) {
      canvas.translate(size.x, 0);
      canvas.scale(-1, 1);
    }
    final p = Paint();
    for (final r in sprite.rects) {
      p.color = r.slot != null
          ? (slotColors[r.slot] ?? const Color(0xFFFF00FF))
          : Color(r.argb ?? 0xFF000000);
      canvas.drawRect(Rect.fromLTWH(r.x * cw, r.y * ch, r.w * cw, r.h * ch), p);
    }
    if (downed) {
      final dim = Paint()..color = const Color(0x88101418);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), dim);
    }
    if (flash > 0) {
      final fp = Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: flash);
      for (final r in sprite.rects) {
        canvas.drawRect(Rect.fromLTWH(r.x * cw, r.y * ch, r.w * cw, r.h * ch), fp);
      }
    }
    canvas.restore();
  }
}
