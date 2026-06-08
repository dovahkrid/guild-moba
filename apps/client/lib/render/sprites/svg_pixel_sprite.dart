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
