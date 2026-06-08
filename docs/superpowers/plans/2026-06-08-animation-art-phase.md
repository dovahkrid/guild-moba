# Animation / Art Phase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Guild client's placeholder geometry with hand-authored pixel-art SVG sprites + life-cycle animation, and add combat VFX driven off `SimEvent`s the sim already emits — entirely client-side, with the simulation, wire format, and replay goldens untouched.

**Architecture:** Sprites are authored as constrained pixel-grid `<rect>` **`.svg` files** (sentinel-colored, recolored per team/element) and rendered by a tiny in-house reader that draws the rects to the Flame canvas — crisp at any zoom, zero new dependencies, fully unit-testable and headless-safe (this realizes the spec's "canvas-rect" renderer as primary; `flame_svg` is unnecessary for pixel-grid art). Combat VFX are surfaced as `RenderFx` value types at the **netcode render boundary** (`MatchView` + a `drainFx()` mirroring the existing `drainReactions()` forward-prediction-once discipline) — additive, never serialized. Motion is procedural Flame transform/opacity effects + particles, not per-frame sprite swaps.

**Tech Stack:** Dart 3.11.5 / Flutter 3.41.9, Flame 1.37.0 (no new deps), pure-Dart `sim`/`netcode` packages. Tests: `flutter_test` (client), `dart test` (netcode).

**Spec:** `docs/superpowers/specs/2026-06-08-animation-art-phase-design.md`. **Branch:** `feat/anim-art-phase` off `main` (`0ff72fc`).

**Determinism invariant (every task):** `packages/sim/lib` and `packages/protocol` are NEVER edited. Goldens `smoke 7e4aa28f` / `combat 910ddcfc` / `elemental 8d7fbe1b` + anchor `0x0fbfb7ac` cannot move; versions stay 3/3. The cheap per-task guard is `git diff --quiet main -- packages/sim packages/protocol` (must exit 0). All visuals are wall-clock cosmetic and cannot reach the sim.

**Gate (every task):** from `apps/client`: `flutter analyze` clean + `flutter test` green (the 5 existing tests stay green); for netcode tasks also `dart test` green in `packages/netcode`. Commit at the end of each task.

---

## File Structure

**New (sprite system):**
- `apps/client/assets/sprites/{hero,creep,tower,core,wanderer}.svg` — pixel-grid rect sprites, sentinel-colored.
- `apps/client/lib/render/sprites/svg_pixel_sprite.dart` — `PixelRect`, `SvgPixelSprite`, `SpriteSlot`, `parseSvgPixels()` (pure).
- `apps/client/lib/render/sprites/sprite_palette.dart` — `spritePalette(teamId, element)` slot→color map (pure).
- `apps/client/lib/render/sprites/sprite_catalog.dart` — `SpriteCatalog` (async asset load + parse + cache + headless fallback).
- `apps/client/lib/render/sprites/pixel_sprite_component.dart` — `PixelSpriteComponent` (render rects, flipX, flash, downed).

**New (VFX consumers):**
- `apps/client/lib/render/fx/damage_number.dart` — `DamageNumber` floating text + `damageText`/`damageColor` (pure helpers).
- `apps/client/lib/render/fx/attack_streak.dart` — `AttackStreak` line-flash.
- `apps/client/lib/render/fx/burst.dart` — `spawnBurst()` particle helper.

**New (netcode boundary):** types added inside `packages/netcode/lib/src/match_view.dart` (`RenderFx` sealed family, `EntitySnap`, `projectFx()`).

**Modified:**
- `apps/client/pubspec.yaml` — declare `assets/sprites/`.
- `apps/client/lib/render/entity_view.dart` — sprite-based; facing; idle/walk bob; status-coat aura tween; spawn/death/downed; `facingFor()` pure helper.
- `apps/client/lib/render/guild_game.dart` — load catalog; build sprite actors; drain + dispatch FX; animated despawn; camera shake.
- `apps/client/lib/render/field_view.dart` — breathing pulse + inner ring.
- `apps/client/lib/render/world_backdrop.dart` — tiled pixel lane.
- `apps/client/lib/ui/result_overlay.dart` — pixel-art victory/defeat.
- `packages/netcode/lib/src/match_controller.dart` — collect FX (forward-only) + `drainFx()`.
- `apps/client/lib/match/match_binding.dart` — `drainFx()` passthrough.

**New tests:**
- `apps/client/test/svg_pixel_sprite_test.dart`, `sprite_palette_test.dart`, `facing_test.dart`, `damage_number_test.dart`.
- `packages/netcode/test/render_fx_test.dart`.

---

## Task 1: Sprite foundation (parse + palette + component + assets)

Pure, self-contained value types + renderer + the SVG asset set. Nothing in the live game wires to it yet, so the running game is unchanged and all existing tests stay green.

**Files:**
- Create: `apps/client/lib/render/sprites/svg_pixel_sprite.dart`
- Create: `apps/client/lib/render/sprites/sprite_palette.dart`
- Create: `apps/client/lib/render/sprites/pixel_sprite_component.dart`
- Create: `apps/client/lib/render/sprites/sprite_catalog.dart`
- Create: `apps/client/assets/sprites/{hero,creep,tower,core,wanderer}.svg`
- Modify: `apps/client/pubspec.yaml`
- Test: `apps/client/test/svg_pixel_sprite_test.dart`, `apps/client/test/sprite_palette_test.dart`

- [ ] **Step 1: Write the failing parse/palette tests**

Create `apps/client/test/svg_pixel_sprite_test.dart`:

```dart
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
```

Create `apps/client/test/sprite_palette_test.dart`:

```dart
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd apps/client && flutter test test/svg_pixel_sprite_test.dart test/sprite_palette_test.dart`
Expected: FAIL — `Target of URI doesn't exist` (files not created yet).

- [ ] **Step 3: Implement `svg_pixel_sprite.dart`**

Create `apps/client/lib/render/sprites/svg_pixel_sprite.dart`:

```dart
/// A recolorable region of a pixel sprite. Either references a palette [slot]
/// (recolored per team/element) or carries a literal [argb] color.
class PixelRect {
  final int x, y, w, h;
  final SpriteSlot? slot;
  final int? argb;
  const PixelRect({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.slot,
    this.argb,
  });
}

/// Palette slots that recolor per (team, element). Non-slot rects keep their
/// literal color.
enum SpriteSlot { teamPrimary, teamShadow, elemAccent, elemLight }

/// A parsed pixel sprite: a viewBox (vw×vh grid) and the rects that fill it.
class SvgPixelSprite {
  final int vw, vh;
  final List<PixelRect> rects;
  const SvgPixelSprite({required this.vw, required this.vh, required this.rects});
}

/// Sentinel fills in the authored SVGs → palette slots (valid hex so each file
/// is still a viewable standalone SVG).
const Map<String, SpriteSlot> _sentinels = {
  '#ff00ff': SpriteSlot.teamPrimary,
  '#cc00cc': SpriteSlot.teamShadow,
  '#00ff66': SpriteSlot.elemAccent,
  '#66ffcc': SpriteSlot.elemLight,
};

final RegExp _rectRe = RegExp(r'<rect\b([^>/]*)/?>');
final RegExp _viewBoxRe = RegExp(r'viewBox="0 0 (\d+) (\d+)"');

/// Parse our constrained pixel-grid SVG form (a viewBox + flat <rect> list) into
/// a [SvgPixelSprite]. Pure; no Flame/Flutter dependency.
SvgPixelSprite parseSvgPixels(String svg) {
  final vb = _viewBoxRe.firstMatch(svg);
  final vw = vb != null ? int.parse(vb.group(1)!) : 16;
  final vh = vb != null ? int.parse(vb.group(2)!) : 16;
  final rects = <PixelRect>[];
  for (final m in _rectRe.allMatches(svg)) {
    final a = m.group(1)!;
    final fill = (_attr(a, 'fill') ?? '#000000').toLowerCase();
    final slot = _sentinels[fill];
    rects.add(PixelRect(
      x: _attrInt(a, 'x') ?? 0,
      y: _attrInt(a, 'y') ?? 0,
      w: _attrInt(a, 'width') ?? 1,
      h: _attrInt(a, 'height') ?? 1,
      slot: slot,
      argb: slot == null ? _hexToArgb(fill) : null,
    ));
  }
  return SvgPixelSprite(vw: vw, vh: vh, rects: rects);
}

String? _attr(String attrs, String name) =>
    RegExp('$name="([^"]*)"').firstMatch(attrs)?.group(1);
int? _attrInt(String attrs, String name) {
  final v = _attr(attrs, name);
  return v == null ? null : int.tryParse(v);
}

int _hexToArgb(String hex) {
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'ff$h';
  return int.parse(h, radix: 16);
}
```

- [ ] **Step 4: Implement `sprite_palette.dart`**

Create `apps/client/lib/render/sprites/sprite_palette.dart`:

```dart
import 'dart:ui';

import 'package:sim/sim.dart' show Element;

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
```

*(Element.pyro.index == 0, Element.hydro.index == 1 — confirmed in `packages/sim/lib/src/model/element.dart`.)*

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd apps/client && flutter test test/svg_pixel_sprite_test.dart test/sprite_palette_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 6: Implement `pixel_sprite_component.dart`**

Create `apps/client/lib/render/sprites/pixel_sprite_component.dart`:

```dart
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
```

- [ ] **Step 7: Implement `sprite_catalog.dart`**

Create `apps/client/lib/render/sprites/sprite_catalog.dart`:

```dart
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
```

- [ ] **Step 8: Create the five SVG sprite assets**

Create `apps/client/assets/sprites/hero.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 14" shape-rendering="crispEdges">
<rect x="5" y="0" width="2" height="1" fill="#cc00cc"/>
<rect x="4" y="1" width="4" height="1" fill="#ff00ff"/>
<rect x="3" y="2" width="6" height="1" fill="#ff00ff"/>
<rect x="2" y="3" width="8" height="1" fill="#cc00cc"/>
<rect x="4" y="4" width="4" height="2" fill="#f0b88a"/>
<rect x="6" y="5" width="1" height="1" fill="#3a2a1a"/>
<rect x="3" y="6" width="6" height="1" fill="#00ff66"/>
<rect x="3" y="7" width="6" height="5" fill="#ff00ff"/>
<rect x="3" y="7" width="1" height="5" fill="#cc00cc"/>
<rect x="3" y="9" width="6" height="1" fill="#cc00cc"/>
<rect x="3" y="12" width="2" height="1" fill="#5a3a22"/>
<rect x="7" y="12" width="2" height="1" fill="#5a3a22"/>
<rect x="10" y="3" width="1" height="9" fill="#7a4a28"/>
<rect x="9" y="1" width="3" height="1" fill="#00ff66"/>
<rect x="9" y="2" width="3" height="1" fill="#66ffcc"/>
<rect x="10" y="1" width="1" height="1" fill="#ffffff"/>
</svg>
```

Create `apps/client/assets/sprites/creep.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 10" shape-rendering="crispEdges">
<rect x="3" y="3" width="6" height="1" fill="#ff00ff"/>
<rect x="2" y="4" width="8" height="1" fill="#ff00ff"/>
<rect x="2" y="5" width="8" height="3" fill="#cc00cc"/>
<rect x="3" y="3" width="2" height="1" fill="#ffffff"/>
<rect x="2" y="8" width="8" height="1" fill="#cc00cc"/>
<rect x="4" y="5" width="1" height="1" fill="#1a240f"/>
<rect x="7" y="5" width="1" height="1" fill="#1a240f"/>
</svg>
```

Create `apps/client/assets/sprites/tower.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 16" shape-rendering="crispEdges">
<rect x="2" y="11" width="8" height="5" fill="#5c6470"/>
<rect x="2" y="10" width="8" height="1" fill="#8a93a0"/>
<rect x="3" y="4" width="6" height="6" fill="#7a828f"/>
<rect x="3" y="3" width="2" height="1" fill="#8a93a0"/>
<rect x="7" y="3" width="2" height="1" fill="#8a93a0"/>
<rect x="3" y="4" width="1" height="6" fill="#5c6470"/>
<rect x="5" y="5" width="2" height="2" fill="#ff00ff"/>
<rect x="5" y="5" width="1" height="1" fill="#66ffcc"/>
</svg>
```

Create `apps/client/assets/sprites/core.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 14" shape-rendering="crispEdges">
<rect x="5" y="1" width="2" height="1" fill="#66ffcc"/>
<rect x="4" y="2" width="4" height="1" fill="#ff00ff"/>
<rect x="3" y="3" width="6" height="1" fill="#ff00ff"/>
<rect x="2" y="4" width="8" height="3" fill="#ff00ff"/>
<rect x="3" y="7" width="6" height="1" fill="#cc00cc"/>
<rect x="4" y="8" width="4" height="1" fill="#cc00cc"/>
<rect x="5" y="9" width="2" height="1" fill="#cc00cc"/>
<rect x="4" y="2" width="1" height="2" fill="#ffffff"/>
</svg>
```

Create `apps/client/assets/sprites/wanderer.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 14" shape-rendering="crispEdges">
<rect x="4" y="2" width="4" height="1" fill="#ff00ff"/>
<rect x="3" y="3" width="6" height="1" fill="#ff00ff"/>
<rect x="3" y="4" width="6" height="6" fill="#ff00ff"/>
<rect x="3" y="4" width="1" height="6" fill="#cc00cc"/>
<rect x="3" y="10" width="6" height="1" fill="#cc00cc"/>
<rect x="4" y="6" width="1" height="1" fill="#1a1a1a"/>
<rect x="7" y="6" width="1" height="1" fill="#1a1a1a"/>
</svg>
```

- [ ] **Step 9: Declare the assets in `pubspec.yaml`**

Modify `apps/client/pubspec.yaml` — replace the `flutter:` block:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/sprites/
```

- [ ] **Step 10: Verify, analyze, commit**

Run: `cd apps/client && flutter pub get && flutter analyze && flutter test`
Expected: analyze clean; all tests PASS (5 existing + 4 new). Then:

Run: `git diff --quiet main -- packages/sim packages/protocol` (Expected: exit 0 — no sim/protocol change.)

```bash
git add apps/client/lib/render/sprites apps/client/assets/sprites apps/client/pubspec.yaml apps/client/test/svg_pixel_sprite_test.dart apps/client/test/sprite_palette_test.dart
git commit -m "feat(client): pixel-sprite foundation (SVG reader, palette, component, assets)"
```

---

## Task 2: Sprite-based entity rendering (facing, idle/walk, status aura)

Swap `EntityView`'s flat shapes for the sprite component; add left/right facing, idle/walk bob, and a tweened status-coat aura. Wire `GuildGame` to load the catalog and pass each hero's innate element.

**Files:**
- Modify: `apps/client/lib/render/entity_view.dart`
- Modify: `apps/client/lib/render/guild_game.dart:23-54`
- Test: `apps/client/test/facing_test.dart`

- [ ] **Step 1: Write the failing facing test**

Create `apps/client/test/facing_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/render/entity_view.dart';

void main() {
  test('faces right on positive dx, left on negative dx', () {
    expect(facingFor(0.5, 1), 1);
    expect(facingFor(-0.5, 1), -1);
  });

  test('holds previous facing inside the deadzone', () {
    expect(facingFor(0.0, -1), -1);
    expect(facingFor(0.01, 1), 1);
  });

  test('defaults to right when previous facing is 0', () {
    expect(facingFor(0.0, 0), 1);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd apps/client && flutter test test/facing_test.dart`
Expected: FAIL — `facingFor` undefined.

- [ ] **Step 3: Rewrite `entity_view.dart`**

Replace the entire contents of `apps/client/lib/render/entity_view.dart`:

```dart
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
```

*Note:* `EntityView` keeps the original **center-origin** child convention — children are positioned relative to the parent's center `(0,0)` (parent anchor `center`), so the sprite + rings sit at `(0,0)` and the health bar at `(-_barW/2, top)` with `top = -size.y/2 - _kBarH - 2`. The idle/walk bob nudges only the sprite's `position.y` around that center. No extra centering step is needed.

- [ ] **Step 4: Run the facing test + existing tests**

Run: `cd apps/client && flutter test test/facing_test.dart test/widget_smoke_test.dart`
Expected: PASS — facing logic correct; `GuildGame` still mounts (the catalog falls back to the placeholder sprite under the test bundle, so `EntityView` construction is safe). If `widget_smoke_test` fails because `GuildGame` doesn't yet pass the new `EntityView` args, that's fixed in Step 6.

- [ ] **Step 5: Wire `GuildGame` to load the catalog + pass element**

In `apps/client/lib/render/guild_game.dart`, update the imports and `onLoad`/diff. Change the sim import (line 5) to also bring in `heroElement`:

```dart
import 'package:sim/sim.dart' show EntityKind, heroElement;
```

Add a catalog field after line 21 (`final Map<int, FieldView> _fieldViews = {};`):

```dart
  final SpriteCatalog _catalog = SpriteCatalog();
```

Add the import near the other render imports:

```dart
import 'sprites/sprite_catalog.dart';
```

Replace `onLoad` (lines 23-27):

```dart
  @override
  Future<void> onLoad() async {
    camera = CameraComponent.withFixedResolution(width: 960, height: 540, world: world);
    await _catalog.load();
    await world.add(WorldBackdrop());
  }
```

Replace the EntityView construction (lines 45-50) inside the diff loop:

```dart
      if (view == null) {
        view = EntityView(
          kind: re.kind,
          teamId: re.teamId,
          element: re.kind == EntityKind.hero.index ? heroElement(re.id) : -1,
          isLocal: re.id == v.localSlot,
          catalog: _catalog,
        );
        _views[re.id] = view;
        world.add(view);
        if (re.id == v.localSlot) camera.follow(view);
      }
```

- [ ] **Step 6: Analyze, test, commit**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: analyze clean; all tests PASS (existing 5 + Task-1's 4 + facing's 3).

Run: `git diff --quiet main -- packages/sim packages/protocol` (Expected: exit 0.)

```bash
git add apps/client/lib/render/entity_view.dart apps/client/lib/render/guild_game.dart apps/client/test/facing_test.dart
git commit -m "feat(client): sprite-based entities with facing, idle/walk bob, status aura"
```

---

## Task 3: Netcode render-FX boundary

Surface the already-emitted combat events as `RenderFx` at the render boundary, resolving positions from a pre-step entity snapshot (so dead entities still resolve). Collected during forward prediction only — mirrors `ReactionTriggered`.

**Files:**
- Modify: `packages/netcode/lib/src/match_view.dart`
- Modify: `packages/netcode/lib/src/match_controller.dart:26,144-170`
- Modify: `apps/client/lib/match/match_binding.dart:79-80`
- Test: `packages/netcode/test/render_fx_test.dart`

- [ ] **Step 1: Write the failing projection test**

Create `packages/netcode/test/render_fx_test.dart`:

```dart
import 'package:netcode/netcode.dart';
import 'package:sim/sim.dart';
import 'package:test/test.dart';

EntitySnap _snap(double x, int kind, int team) =>
    EntitySnap(x: x, y: 0, kind: kind, teamId: team);

void main() {
  test('DamageDealt -> HitFx at the victim position, with source kind', () {
    final before = {
      0: _snap(-2, EntityKind.hero.index, 0),
      1: _snap(3, EntityKind.hero.index, 1),
    };
    final fx = projectFx(
      const [DamageDealt(sourceId: 0, targetId: 1, amountRaw: 524288)], // 8.0
      before,
      before,
    );
    expect(fx, hasLength(1));
    final hit = fx.single as HitFx;
    expect(hit.victimId, 1);
    expect(hit.sourceKind, EntityKind.hero.index);
    expect(hit.x, 3);
    expect(hit.amountRaw, 524288);
  });

  test('CreepKilled resolves position from the BEFORE snapshot (entity gone after)', () {
    final before = {7: _snap(1, EntityKind.creep.index, 2)};
    final after = <int, EntitySnap>{}; // creep removed by the death sweep
    final fx = projectFx(
      const [CreepKilled(creepId: 7, killerId: 0, gold: 1)],
      before,
      after,
    );
    expect((fx.single as KillFx).x, 1);
  });

  test('CoreDestroyed finds the core position by team', () {
    final before = {
      15: _snap(11, EntityKind.core.index, 1),
    };
    final fx = projectFx(
      const [CoreDestroyed(teamId: 1, winnerTeam: 0)],
      before,
      before,
    );
    final core = fx.single as CoreFx;
    expect(core.winnerTeam, 0);
    expect(core.x, 11);
  });

  test('ReactionTriggered / LevelUp / BossSpawned produce no RenderFx', () {
    final fx = projectFx(
      const [
        ReactionTriggered(unitId: 0, reaction: 0, multiplierRaw: 0, sourceId: 1),
        LevelUp(heroId: 0, level: 2),
        BossSpawned(bossId: 9, teamId: 0),
      ],
      const {},
      const {},
    );
    expect(fx, isEmpty);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/netcode && dart test test/render_fx_test.dart`
Expected: FAIL — `EntitySnap`, `projectFx`, `HitFx`… undefined.

- [ ] **Step 3: Add the FX types + projection to `match_view.dart`**

Append to `packages/netcode/lib/src/match_view.dart` (and add the import at the top):

```dart
import 'package:sim/sim.dart';
```

```dart
/// A pre/post-step positional snapshot of one entity (for resolving FX origins,
/// including entities removed by the same step's death sweep).
class EntitySnap {
  final double x, y;
  final int kind, teamId;
  const EntitySnap({required this.x, required this.y, required this.kind, required this.teamId});
}

/// Cosmetic combat FX surfaced at the render boundary. Built client-side from
/// already-emitted SimEvents during FORWARD prediction only (reconcile re-steps
/// do NOT collect), so each surfaces exactly once. NEVER serialized / sent.
sealed class RenderFx {
  const RenderFx();
}

class HitFx extends RenderFx {
  final int victimId, sourceId, sourceKind, amountRaw;
  final double x, y; // victim impact position (world)
  const HitFx({
    required this.victimId,
    required this.sourceId,
    required this.sourceKind,
    required this.amountRaw,
    required this.x,
    required this.y,
  });
}

class KillFx extends RenderFx {
  final double x, y;
  const KillFx({required this.x, required this.y});
}

class TowerFallFx extends RenderFx {
  final int teamId;
  final double x, y;
  const TowerFallFx({required this.teamId, required this.x, required this.y});
}

class CoreFx extends RenderFx {
  final int teamId, winnerTeam;
  final double x, y;
  const CoreFx({required this.teamId, required this.winnerTeam, required this.x, required this.y});
}

class HeroDownFx extends RenderFx {
  final int heroId;
  final double x, y;
  const HeroDownFx({required this.heroId, required this.x, required this.y});
}

/// Project the cosmetic combat [events] into [RenderFx], resolving positions
/// from [after] (falling back to [before] for entities removed this step). Pure;
/// unit-tested. ReactionTriggered is handled separately (drainReactions); the
/// declared-but-unemitted LevelUp/BossSpawned are ignored.
List<RenderFx> projectFx(
  Iterable<SimEvent> events,
  Map<int, EntitySnap> before,
  Map<int, EntitySnap> after,
) {
  EntitySnap? at(int id) => after[id] ?? before[id];
  final out = <RenderFx>[];
  for (final e in events) {
    switch (e) {
      case DamageDealt(:final sourceId, :final targetId, :final amountRaw):
        final p = at(targetId);
        if (p == null) break;
        out.add(HitFx(
          victimId: targetId,
          sourceId: sourceId,
          sourceKind: at(sourceId)?.kind ?? -1,
          amountRaw: amountRaw,
          x: p.x,
          y: p.y,
        ));
      case CreepKilled(:final creepId):
        final p = at(creepId);
        if (p != null) out.add(KillFx(x: p.x, y: p.y));
      case TowerDestroyed(:final towerId, :final teamId):
        final p = at(towerId);
        if (p != null) out.add(TowerFallFx(teamId: teamId, x: p.x, y: p.y));
      case CoreDestroyed(:final teamId, :final winnerTeam):
        final p = _coreOf(after, teamId) ?? _coreOf(before, teamId);
        out.add(CoreFx(teamId: teamId, winnerTeam: winnerTeam, x: p?.x ?? 0, y: p?.y ?? 0));
      case HeroDowned(:final heroId):
        final p = at(heroId);
        if (p != null) out.add(HeroDownFx(heroId: heroId, x: p.x, y: p.y));
      default:
        break; // ReactionTriggered / LevelUp / BossSpawned: no FX here
    }
  }
  return out;
}

EntitySnap? _coreOf(Map<int, EntitySnap> m, int teamId) {
  for (final s in m.values) {
    if (s.kind == EntityKind.core.index && s.teamId == teamId) return s;
  }
  return null;
}
```

- [ ] **Step 4: Run the projection test**

Run: `cd packages/netcode && dart test test/render_fx_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Collect FX in `advanceClientTick`**

In `packages/netcode/lib/src/match_controller.dart`, add the FX buffer next to `_recentReactions` (after line 26):

```dart
  final List<RenderFx> _recentFx = []; // collected each advanceClientTick (forward only)
```

Replace `advanceClientTick` (lines 144-160) so it snapshots positions around the step and projects FX:

```dart
  void advanceClientTick() {
    final before = _snapshot();
    final events = _predicted.step(_nextTick, _intentsAt(_nextTick));
    final after = _snapshot();
    final presentIds = after.keys.toSet();
    for (final e in events) {
      if (e is! ReactionTriggered) continue;
      if (!presentIds.contains(e.unitId)) continue; // reacting unit gone — skip pop-text
      final pos = _predicted.entity(e.unitId).pos;
      _recentReactions.add(RenderReaction(
        x: pos.x.toDouble(),
        y: pos.y.toDouble(),
        reaction: e.reaction,
        multiplierRaw: e.multiplierRaw,
      ));
    }
    _recentFx.addAll(projectFx(events, before, after));
    _nextTick++;
    _dropHeldWhileLocalDowned();
  }

  Map<int, EntitySnap> _snapshot() {
    final m = <int, EntitySnap>{};
    for (final id in _predicted.entityIdsSorted) {
      final e = _predicted.entity(id);
      m[id] = EntitySnap(
        x: e.pos.x.toDouble(),
        y: e.pos.y.toDouble(),
        kind: e.kind.index,
        teamId: e.teamId,
      );
    }
    return m;
  }
```

Add `drainFx()` after `drainReactions()` (after line 170):

```dart
  /// Drain combat FX collected since the last call (host spawns them once/frame).
  /// Like drainReactions(): forward-prediction-only, so each surfaces once.
  List<RenderFx> drainFx() {
    if (_recentFx.isEmpty) return const [];
    final out = List<RenderFx>.of(_recentFx);
    _recentFx.clear();
    return out;
  }
```

*(No change to `onServerSnapshot` — reconcile re-steps still call only `_predicted.step(...)`, never `projectFx`, so FX are never double-collected.)*

- [ ] **Step 6: Pass FX through `MatchBinding`**

In `apps/client/lib/match/match_binding.dart`, after `drainReactions()` (line 80) add:

```dart
  /// Combat FX surfaced since the last frame (host spawns them once/frame).
  List<RenderFx> drainFx() => _controller?.drainFx() ?? const [];
```

- [ ] **Step 7: Analyze, test, commit**

Run: `cd packages/netcode && dart analyze && dart test`
Then: `cd ../../apps/client && flutter analyze && flutter test`
Expected: all green (existing netcode/server tests unaffected — the change is additive; existing client tests unaffected).

Run: `git diff --quiet main -- packages/sim packages/protocol` (Expected: exit 0 — only `packages/netcode` + `apps/client` changed.)

```bash
git add packages/netcode/lib/src/match_view.dart packages/netcode/lib/src/match_controller.dart packages/netcode/test/render_fx_test.dart apps/client/lib/match/match_binding.dart
git commit -m "feat(netcode): surface combat events as RenderFx at the render boundary"
```

---

## Task 4: Spawn / death / downed life-cycle

Use the FX stream + the entity diff to animate creep death (collapse-then-remove), hero downed/respawn, and keep the spawn-in pop (added in Task 2).

**Files:**
- Modify: `apps/client/lib/render/guild_game.dart:38-83`

- [ ] **Step 1: Animate despawns + handle downed/respawn**

In `apps/client/lib/render/guild_game.dart`, add a downed-tracking set after `_catalog` field:

```dart
  final Set<int> _downed = {};
```

Replace the despawn loop (lines 55-59) so views collapse instead of vanishing:

```dart
    // Despawn (animate) views whose entity is gone (dead creep / fallen tower / dead core).
    final gone = _views.keys.where((id) => !seen.contains(id)).toList();
    for (final id in gone) {
      _views.remove(id)?.playDeathAndRemove();
      _downed.remove(id);
    }
```

After the entity diff loop (right before the field diff, after line 54), add respawn detection for heroes that were downed and are now back up:

```dart
    // Respawn: a hero that was downed and now has hp pops back in.
    for (final re in v.entities) {
      if (_downed.contains(re.id) && re.hp > 0) {
        _downed.remove(re.id);
        _views[re.id]?.respawn();
      }
    }
```

Replace the reaction-drain block (lines 77-83) with a combined FX + reaction dispatch:

```dart
    // Combat FX surfaced this frame.
    for (final fx in binding.drainFx()) {
      _handleFx(fx);
    }
    // Reaction pop-text (flat vs amplify).
    for (final r in binding.drainReactions()) {
      world.add(ReactionLabel(
        text: reactionText(r.reaction, r.multiplierRaw),
        position: Vector2(worldToFlameX(r.x), worldToFlameY(r.y)),
      ));
    }
```

Add the FX handler method (initially handling only the life-cycle events; combat/structure FX are added in Tasks 5–6). Place it after `update`:

```dart
  void _handleFx(RenderFx fx) {
    switch (fx) {
      case HeroDownFx(:final heroId):
        _downed.add(heroId);
        _views[heroId]?.setDowned(true);
      case HitFx():
      case KillFx():
      case TowerFallFx():
      case CoreFx():
        break; // wired in Tasks 5–6
    }
  }
```

Add the netcode FX import to the existing netcode import (line 4):

```dart
import 'package:netcode/netcode.dart'
    show MatchView, RenderEntity, RenderFx, HitFx, KillFx, TowerFallFx, CoreFx, HeroDownFx;
```

- [ ] **Step 2: Analyze, test, commit**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: green (no new unit test — life-cycle animation is verified by eye in Task 8; the smoke test still mounts).

Run: `git diff --quiet main -- packages/sim packages/protocol` (Expected: exit 0.)

```bash
git add apps/client/lib/render/guild_game.dart
git commit -m "feat(client): animate creep death, hero downed/respawn life-cycle"
```

---

## Task 5: Combat VFX consumers (hit-flash, damage numbers, attack streak, reaction burst)

Consume `HitFx` and the reaction stream into on-screen feedback.

**Files:**
- Create: `apps/client/lib/render/fx/damage_number.dart`
- Create: `apps/client/lib/render/fx/attack_streak.dart`
- Create: `apps/client/lib/render/fx/burst.dart`
- Modify: `apps/client/lib/render/guild_game.dart` (`_handleFx`)
- Test: `apps/client/test/damage_number_test.dart`

- [ ] **Step 1: Write the failing damage-number test**

Create `apps/client/test/damage_number_test.dart`:

```dart
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim/sim.dart' show EntityKind;
import 'package:guild_client/render/fx/damage_number.dart';

void main() {
  test('damageText rounds Q16.16 raw to a whole number', () {
    expect(damageText(524288), '8'); // 8.0 * 65536
    expect(damageText(851968), '13'); // 13.0
  });

  test('damageColor: hero source vs structure source differ', () {
    expect(damageColor(EntityKind.hero.index), isA<Color>());
    expect(damageColor(EntityKind.tower.index), isNot(damageColor(EntityKind.hero.index)));
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd apps/client && flutter test test/damage_number_test.dart`
Expected: FAIL — file/symbols missing.

- [ ] **Step 3: Implement `damage_number.dart`**

Create `apps/client/lib/render/fx/damage_number.dart`:

```dart
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter/painting.dart';
import 'package:sim/sim.dart' show EntityKind, kOne;

/// Q16.16 raw damage → whole-number string.
String damageText(int amountRaw) => (amountRaw / kOne).round().toString();

/// Number color by the source's EntityKind.index (hero = white, structure = amber).
Color damageColor(int sourceKind) {
  if (sourceKind == EntityKind.tower.index || sourceKind == EntityKind.core.index) {
    return const Color(0xFFFFC107);
  }
  return const Color(0xFFFFFFFF);
}

/// A floating damage number. Rises + fades, then self-removes (modeled on
/// ReactionLabel).
class DamageNumber extends TextComponent {
  DamageNumber({required int amountRaw, required int sourceKind, required Vector2 position})
      : super(
          text: damageText(amountRaw),
          position: position,
          anchor: Anchor.center,
          textRenderer: TextPaint(
            style: TextStyle(
              color: damageColor(sourceKind),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        );

  double _age = 0;
  static const double _life = 0.7;

  @override
  void update(double dt) {
    super.update(dt);
    _age += dt;
    position.y -= 28 * dt;
    if (_age >= _life) removeFromParent();
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/client && flutter test test/damage_number_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Implement the burst + streak helpers**

Create `apps/client/lib/render/fx/burst.dart`:

```dart
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/particles.dart';

/// Spawn a short radial particle burst at [position] (Flame coords). Self-removes.
ParticleSystemComponent spawnBurst(Vector2 position, Color color, {int count = 10, double speed = 60}) {
  final rng = math.Random();
  return ParticleSystemComponent(
    position: position,
    particle: Particle.generate(
      count: count,
      lifespan: 0.4,
      generator: (i) {
        final a = (i / count) * 2 * math.pi + rng.nextDouble();
        final v = Vector2(math.cos(a), math.sin(a)) * speed;
        return AcceleratedParticle(
          speed: v,
          child: CircleParticle(radius: 1.6, paint: Paint()..color = color),
        );
      },
    ),
  );
}
```

Create `apps/client/lib/render/fx/attack_streak.dart`:

```dart
import 'dart:ui';

import 'package:flame/components.dart';

/// A brief line-flash from attacker to target (Flame coords). Fades then removes.
class AttackStreak extends PositionComponent {
  AttackStreak({required this.from, required this.to, required this.color});

  final Vector2 from;
  final Vector2 to;
  final Color color;
  double _age = 0;
  static const double _life = 0.14;

  @override
  void update(double dt) {
    super.update(dt);
    _age += dt;
    if (_age >= _life) removeFromParent();
  }

  @override
  void render(Canvas canvas) {
    final t = (1 - _age / _life).clamp(0.0, 1.0);
    final p = Paint()
      ..color = color.withValues(alpha: t)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(from.x, from.y), Offset(to.x, to.y), p);
  }
}
```

- [ ] **Step 6: Wire `HitFx` into `_handleFx`**

In `apps/client/lib/render/guild_game.dart`, add the imports:

```dart
import 'dart:ui'; // Color for the FX tints (flame/components does not re-export it)

import 'fx/attack_streak.dart';
import 'fx/burst.dart';
import 'fx/damage_number.dart';
```

*(The sim import in `guild_game.dart` already shows `EntityKind, heroElement` from Task 2 — don't duplicate it. Place `dart:ui` at the top with the other `dart:`/`package:` imports.)*

Replace the `HitFx()` arm of `_handleFx` and fill the reaction burst. Update `_handleFx`:

```dart
  void _handleFx(RenderFx fx) {
    switch (fx) {
      case HeroDownFx(:final heroId):
        _downed.add(heroId);
        _views[heroId]?.setDowned(true);
      case HitFx(:final victimId, :final sourceId, :final sourceKind, :final amountRaw, :final x, :final y):
        final pos = Vector2(worldToFlameX(x), worldToFlameY(y));
        _views[victimId]?.flash();
        world.add(DamageNumber(amountRaw: amountRaw, sourceKind: sourceKind, position: pos.clone()..y -= 14));
        final src = _views[sourceId];
        if (src != null &&
            (sourceKind == EntityKind.hero.index || sourceKind == EntityKind.tower.index)) {
          world.add(AttackStreak(from: src.position.clone(), to: pos, color: const Color(0xCCFFF0B0)));
        }
        world.add(spawnBurst(pos, const Color(0xFFFFE082), count: 6, speed: 40));
      case KillFx(:final x, :final y):
        world.add(spawnBurst(
          Vector2(worldToFlameX(x), worldToFlameY(y)),
          const Color(0xFFB0BEC5),
          count: 12,
          speed: 80,
        ));
      case TowerFallFx():
      case CoreFx():
        break; // wired in Task 6
    }
  }
```

Add a reaction burst next to the existing reaction pop-text (in the reaction drain loop):

```dart
    for (final r in binding.drainReactions()) {
      final pos = Vector2(worldToFlameX(r.x), worldToFlameY(r.y));
      world.add(ReactionLabel(text: reactionText(r.reaction, r.multiplierRaw), position: pos.clone()));
      world.add(spawnBurst(pos, const Color(0xFFFFD54F), count: 12, speed: 70));
    }
```

- [ ] **Step 7: Analyze, test, commit**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: green (existing + Task-1/2 + damage-number's 2).

Run: `git diff --quiet main -- packages/sim packages/protocol` (Expected: exit 0.)

```bash
git add apps/client/lib/render/fx apps/client/lib/render/guild_game.dart apps/client/test/damage_number_test.dart
git commit -m "feat(client): hit-flash, floating damage numbers, attack streak, reaction burst"
```

---

## Task 6: Structures finale + camera juice + victory/defeat

Tower-fall + core-destruction VFX, decaying screen-shake, and a restyled result screen.

**Files:**
- Modify: `apps/client/lib/render/guild_game.dart` (`_handleFx`, `update`, shake)
- Modify: `apps/client/lib/ui/result_overlay.dart`

- [ ] **Step 1: Add camera shake to `GuildGame`**

In `apps/client/lib/render/guild_game.dart`, add `import 'dart:math' as math;` at the top and fields after `_downed`:

```dart
  double _shake = 0; // 0..1
  double _shakeT = 0;
```

Add a public trigger after `_handleFx`:

```dart
  void _addShake(double amount) {
    if (amount > _shake) _shake = amount.clamp(0.0, 1.0);
  }
```

At the very end of `update(dt)` (after the FX/reaction loops), apply the shake (camera.follow has already set the viewfinder this frame in `super.update`):

```dart
    if (_shake > 0) {
      _shake = (_shake - dt * 4).clamp(0.0, 1.0);
      _shakeT += dt;
      final mag = _shake * 9.0;
      camera.viewfinder.position += Vector2(
        math.sin(_shakeT * 97) * mag,
        math.cos(_shakeT * 131) * mag,
      );
    }
```

- [ ] **Step 2: Fill the structure FX arms**

Replace the `TowerFallFx()` / `CoreFx()` arms of `_handleFx`:

```dart
      case TowerFallFx(:final x, :final y):
        final pos = Vector2(worldToFlameX(x), worldToFlameY(y));
        world.add(spawnBurst(pos, const Color(0xFFB0BEC5), count: 18, speed: 90));
        _addShake(0.6);
      case CoreFx(:final x, :final y):
        final pos = Vector2(worldToFlameX(x), worldToFlameY(y));
        world.add(spawnBurst(pos, const Color(0xFFFFF59D), count: 40, speed: 140));
        world.add(spawnBurst(pos, const Color(0xFF80DEEA), count: 30, speed: 100));
        _addShake(1.0);
```

*(Tower/core views still collapse via the Task-4 despawn path when their entity leaves the view; these FX add the burst + shake on top.)*

- [ ] **Step 3: Restyle the result overlay**

Replace the build body of `apps/client/lib/ui/result_overlay.dart`:

```dart
import 'package:flutter/material.dart';

import '../match/match_binding.dart';

/// Full-screen victory/defeat banner shown when the match ends.
class ResultOverlay extends StatelessWidget {
  const ResultOverlay({super.key, required this.binding});

  final MatchBinding binding;

  @override
  Widget build(BuildContext context) {
    final winner = binding.winnerSlot;
    final me = binding.localSlot;
    final bool won = winner != null && winner >= 0 && winner == me;
    final bool decided = winner != null && winner >= 0;
    final String text = !decided ? 'MATCH ENDED' : (won ? 'VICTORY' : 'DEFEAT');
    final Color accent = !decided
        ? const Color(0xFFB0BEC5)
        : (won ? const Color(0xFF7CD06B) : const Color(0xFFF44336));

    return Container(
      color: const Color(0xCC0B0F12),
      alignment: Alignment.center,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1.0),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        builder: (context, s, child) => Transform.scale(scale: s, child: child),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 28),
          decoration: BoxDecoration(
            color: const Color(0xFF12181D),
            border: Border.all(color: accent, width: 4),
            boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 24)],
          ),
          child: Text(
            text,
            style: TextStyle(
              color: accent,
              fontSize: 52,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              letterSpacing: 4,
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Analyze, test, commit**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: green.

Run: `git diff --quiet main -- packages/sim packages/protocol` (Expected: exit 0.)

```bash
git add apps/client/lib/render/guild_game.dart apps/client/lib/ui/result_overlay.dart
git commit -m "feat(client): tower/core finale VFX, screen-shake, pixel victory/defeat"
```

---

## Task 7: Environment — tiled backdrop + field polish

**Files:**
- Modify: `apps/client/lib/render/world_backdrop.dart`
- Modify: `apps/client/lib/render/field_view.dart`

- [ ] **Step 1: Tiled pixel backdrop**

Replace the contents of `apps/client/lib/render/world_backdrop.dart`:

```dart
import 'dart:ui';

import 'package:flame/components.dart';

import 'coord.dart';

/// Tiled pixel-art lane: a checkered ground, an edge border, and a center line.
/// Centered on world (0,0); drawn first (under entities). Purely cosmetic.
class WorldBackdrop extends PositionComponent {
  WorldBackdrop() : super(anchor: Anchor.center);

  static const double _laneW = 24.0; // world units
  static const double _laneH = 8.0;
  static const double _tile = 1.0; // world units per tile

  @override
  void render(Canvas canvas) {
    final w = _laneW * kPixelsPerUnit;
    final h = _laneH * kPixelsPerUnit;
    final left = -w / 2, top = -h / 2;
    final ts = _tile * kPixelsPerUnit;
    final cols = (_laneW / _tile).round();
    final rows = (_laneH / _tile).round();

    final a = Paint()..color = const Color(0xFF26333B);
    final b = Paint()..color = const Color(0xFF2C3A42);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        canvas.drawRect(
          Rect.fromLTWH(left + c * ts, top + r * ts, ts, ts),
          (r + c).isEven ? a : b,
        );
      }
    }
    // Edge border.
    canvas.drawRect(
      Rect.fromLTWH(left, top, w, h),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFF3E535E),
    );
    // Center divider.
    canvas.drawRect(
      Rect.fromLTWH(-1, top, 2, h),
      Paint()..color = const Color(0xFF55707D),
    );
  }
}
```

- [ ] **Step 2: Field breathing pulse**

Replace the contents of `apps/client/lib/render/field_view.dart`:

```dart
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import 'coord.dart';
import 'element_palette.dart';

/// A translucent element-tinted field zone (Plan 4) with a breathing pulse + a
/// pulsing inner ring. Position is set each frame by GuildGame. Purely cosmetic.
class FieldView extends PositionComponent {
  FieldView({required this.element, required double radius}) : _r = radius * kPixelsPerUnit;

  final int element; // Element.index
  final double _r;
  double _t = 0;
  late final CircleComponent _fill;
  late final CircleComponent _ring;

  @override
  Future<void> onLoad() async {
    _fill = CircleComponent(
      radius: _r,
      anchor: Anchor.center,
      paint: Paint()..color = fieldColor(element),
    );
    _ring = CircleComponent(
      radius: _r,
      anchor: Anchor.center,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = elementColor(element) ?? const Color(0xFF9E9E9E),
    );
    await addAll([_fill, _ring]);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _t += dt;
    final breathe = 1 + 0.05 * math.sin(_t * 3);
    _fill.scale = Vector2.all(breathe);
    final ringPulse = 1 + 0.12 * (0.5 + 0.5 * math.sin(_t * 3));
    _ring.scale = Vector2.all(ringPulse);
  }
}
```

- [ ] **Step 3: Analyze, test, commit**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: green (element_palette_test unaffected — `fieldColor`/`elementColor` unchanged).

Run: `git diff --quiet main -- packages/sim packages/protocol` (Expected: exit 0.)

```bash
git add apps/client/lib/render/world_backdrop.dart apps/client/lib/render/field_view.dart
git commit -m "feat(client): tiled pixel backdrop + breathing elemental fields"
```

---

## Task 8: Visual QA + tuning pass

The spec makes visual verification first-class. No code is required to *start*; this task launches the real app, walks the checklist, captures screenshots, and tunes constants from what's observed.

**Files (tuning, as needed):** `entity_view.dart` (bob amp/period, `_kLerpSpeed`), `damage_number.dart` (size/life), `burst.dart` (count/speed), `guild_game.dart` (shake magnitudes), `world_backdrop.dart` (tile tones).

- [ ] **Step 1: Launch the app (two clients)**

Run a local server, then the client:
```bash
dart run apps/server/bin/server.dart 8080
cd apps/client && flutter run -d chrome
```
Open the served URL in a second tab to get player 1 (see `apps/README.md`). Use the dev panel to inject latency/loss while observing.

- [ ] **Step 2: Walk the QA checklist, capture screenshots**

Verify each, screenshotting: sprites render per kind/team (blue vs red) and per element (pyro vs hydro hero accent); local-hero ring present; **walk + facing flip** (move left vs right); idle bob; **basic attack** → attacker streak + victim hit-flash + floating damage number; **left-click ability** → field appears + breathes, vaporize → reaction pop-text + burst + coat aura fade-in then fade-out; **creep last-hit** → collapse + kill burst; **tower fall** → burst + screen-shake; **core kill** → big finale + shake → VICTORY/DEFEAT card. Confirm the camera still smoothly follows the local hero through a shake.

- [ ] **Step 3: Tune + commit any adjustments**

Adjust the constants above to taste. After each change: `cd apps/client && flutter analyze && flutter test` (green), `git diff --quiet main -- packages/sim packages/protocol` (exit 0), then:

```bash
git add -A apps/client
git commit -m "polish(client): tune animation/VFX timings + magnitudes from visual QA"
```

- [ ] **Step 4: Final full sweep (mirror CI) before whole-branch review**

```bash
cd apps/client && flutter analyze && flutter test
cd ../../packages/netcode && dart analyze && dart test
cd ../.. && bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json tooling/replay_fixtures/combat.json tooling/replay_fixtures/elemental.json
```
Expected: client + netcode green; the three replays byte-identical AND golden-matched (`smoke 7e4aa28f`, `combat 910ddcfc`, `elemental 8d7fbe1b`) — proof the sim never moved. Then proceed to the whole-branch review (superpowers:requesting-code-review) and finishing-a-development-branch.

---

## Notes for the implementer

- **Never edit `packages/sim` or `packages/protocol`.** If a task seems to need it, stop — the design is wrong, not the rule. The `git diff --quiet main -- packages/sim packages/protocol` guard catches accidental edits.
- **Flame coords vs world coords:** `worldToFlameX/Y` (`coord.dart`, 28 px/unit) convert sim-world doubles → Flame pixels. FX positions arrive as world doubles in `RenderFx`; convert before placing components.
- **Headless tests:** `SpriteCatalog.load()` swallows asset-load failures and falls back to a 1×1 placeholder, so `widget_smoke_test` mounts without bundled assets. Don't "fix" this by asserting assets load in unit tests.
- **Effects leak if not auto-removed:** `ScaleEffect`/`RemoveEffect` here either complete-and-stay-harmless or self-remove; `DamageNumber`/`AttackStreak`/`ReactionLabel` self-remove in `update`; `ParticleSystemComponent` from `Particle.generate` self-removes on lifespan end. Don't add infinite effects.
- **`heroElement(id)`** (from `package:sim/sim.dart`) maps heroId 0→pyro, 1→hydro; hero entity ids are the slots (0/1) in 1v1, so `heroElement(re.id)` is correct for `EntityKind.hero`.
