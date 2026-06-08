import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim/sim.dart' show Element;
import 'package:guild_client/render/sprites/svg_pixel_sprite.dart';
import 'package:guild_client/render/sprites/sprite_palette.dart';

void main() {
  test('team 0 is blue, team 1 is red, neutral is grey', () {
    expect(spritePalette(0, -1)[SpriteSlot.teamPrimary], const Color(0xFF2196F3));
    expect(spritePalette(1, -1)[SpriteSlot.teamPrimary], const Color(0xFFF44336));
    expect(spritePalette(2, -1)[SpriteSlot.teamPrimary], const Color(0xFF9E9E9E));
  });

  test('element accent follows innate element', () {
    expect(spritePalette(0, Element.pyro.index)[SpriteSlot.elemAccent], const Color(0xFFFF7043));
    expect(spritePalette(0, Element.hydro.index)[SpriteSlot.elemAccent], const Color(0xFF26C6DA));
  });
}
