import 'package:flutter/services.dart' show rootBundle;

import 'svg_pixel_sprite.dart';

/// Loads + parses + caches the pixel sprites once (called from GuildGame.onLoad).
/// Keyed by EntityKind.index. Degrades to a 1×1 placeholder if an asset can't be
/// loaded (e.g. headless test bundle), so the game always mounts.
class SpriteCatalog {
  final Map<int, SvgPixelSprite> _byKind = {};

  // EntityKind: hero=0, wanderer=1, tower=2, creep=3, core=4.
  static const Map<int, String> _assets = {
    0: 'assets/sprites/hero.svg',
    1: 'assets/sprites/wanderer.svg',
    2: 'assets/sprites/tower.svg',
    3: 'assets/sprites/creep.svg',
    4: 'assets/sprites/core.svg',
  };

  bool get isLoaded => _byKind.isNotEmpty;

  Future<void> load() async {
    for (final e in _assets.entries) {
      try {
        _byKind[e.key] = parseSvgPixels(await rootBundle.loadString(e.value));
      } catch (_) {
        _byKind[e.key] = _fallback;
      }
    }
  }

  SvgPixelSprite forKind(int kind) => _byKind[kind] ?? _fallback;

  static const SvgPixelSprite _fallback = SvgPixelSprite(
    vw: 1,
    vh: 1,
    rects: [PixelRect(x: 0, y: 0, w: 1, h: 1, slot: SpriteSlot.teamPrimary)],
  );
}
