import 'dart:ui';

import 'svg_pixel_sprite.dart';

/// Resolve the four recolor slots for a unit of [teamId] with innate [element]
/// (Element.index, -1 = none). Pure.
Map<SpriteSlot, Color> spritePalette(int teamId, int element) {
  final (Color primary, Color shadow) = switch (teamId) {
    0 => (const Color(0xFF2196F3), const Color(0xFF1565C0)), // blue
    1 => (const Color(0xFFF44336), const Color(0xFFB71C1C)), // red
    _ => (const Color(0xFF9E9E9E), const Color(0xFF616161)), // neutral
  };
  final (Color accent, Color light) = switch (element) {
    0 => (const Color(0xFFFF7043), const Color(0xFFFFCCBC)), // pyro
    1 => (const Color(0xFF26C6DA), const Color(0xFFB2EBF2)), // hydro
    _ => (const Color(0xFFBDBDBD), const Color(0xFFEEEEEE)), // none
  };
  return {
    SpriteSlot.teamPrimary: primary,
    SpriteSlot.teamShadow: shadow,
    SpriteSlot.elemAccent: accent,
    SpriteSlot.elemLight: light,
  };
}
