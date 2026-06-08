import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/render/sprites/svg_pixel_sprite.dart';

void main() {
  const svg = '<svg viewBox="0 0 12 14" shape-rendering="crispEdges">'
      '<rect x="3" y="7" width="6" height="5" fill="#ff00ff"/>'
      '<rect x="4" y="4" width="4" height="2" fill="#f0b88a"/>'
      '</svg>';

  test('parses viewBox into vw/vh', () {
    final s = parseSvgPixels(svg);
    expect(s.vw, 12);
    expect(s.vh, 14);
  });

  test('maps a sentinel fill to a SpriteSlot, a literal fill to argb', () {
    final s = parseSvgPixels(svg);
    expect(s.rects.length, 2);
    expect(s.rects[0].slot, SpriteSlot.teamPrimary);
    expect(s.rects[0].argb, isNull);
    expect(s.rects[0].x, 3);
    expect(s.rects[0].w, 6);
    expect(s.rects[1].slot, isNull);
    expect(s.rects[1].argb, 0xFFF0B88A); // #f0b88a → opaque
  });
}
