import 'fixed.dart';

int _u32(int x) => x & 0xFFFFFFFF;

/// Low 64 bits of (a*b) as [lo32, hi32]. Schoolbook on 16-bit chunks so every
/// partial product < 2^32 and every column sum < 2^34 — never near 2^53.
List<int> _mul64(int aLo, int aHi, int bLo, int bHi) {
  final a0 = aLo & 0xFFFF, a1 = aLo >>> 16, a2 = aHi & 0xFFFF, a3 = aHi >>> 16;
  final b0 = bLo & 0xFFFF, b1 = bLo >>> 16, b2 = bHi & 0xFFFF, b3 = bHi >>> 16;
  final int c0 = a0 * b0;
  final int c1 = a0 * b1 + a1 * b0;
  final int c2 = a0 * b2 + a1 * b1 + a2 * b0;
  final int c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0;
  final int r0 = c0 & 0xFFFF;
  int carry = c0 >>> 16;
  final int t1 = c1 + carry;
  final int r1 = t1 & 0xFFFF;
  carry = (t1 - r1) ~/ 65536;
  final int t2 = c2 + carry;
  final int r2 = t2 & 0xFFFF;
  carry = (t2 - r2) ~/ 65536;
  final int t3 = c3 + carry;
  final int r3 = t3 & 0xFFFF;
  return [_u32(r0 | (r1 << 16)), _u32(r2 | (r3 << 16))];
}

List<int> _add64(int aLo, int aHi, int bLo, int bHi) {
  final int lo = aLo + bLo; // < 2^33, safe
  final int loW = _u32(lo);
  final int carry = (lo - loW) ~/ 4294967296;
  return [loW, _u32(aHi + bHi + carry)];
}

// PCG multiplier 6364136223846793005 = 0x5851F42D4C957F2D
const int _mulLo = 0x4C957F2D, _mulHi = 0x5851F42D;
// PCG increment 1442695040888963407 = 0x14057B7EF767814F (must be odd)
const int _incLo = 0xF767814F, _incHi = 0x14057B7E;

/// PCG-XSH-RR 32-bit-output RNG. The 64-bit LCG state lives in two 32-bit limbs
/// so no operation depends on true 64-bit ints (which dart2js lacks).
class DetRng {
  int _sLo, _sHi;

  DetRng.fromLimbs(int seedLo, int seedHi)
      : _sLo = 0,
        _sHi = 0 {
    _step();
    final a = _add64(_sLo, _sHi, _u32(seedLo), _u32(seedHi));
    _sLo = a[0];
    _sHi = a[1];
    _step();
  }

  factory DetRng.fromInt(int seed) {
    assert(seed >= 0 && seed < 0x20000000000000, '<2^53 only');
    return DetRng.fromLimbs(_u32(seed), seed ~/ 4294967296);
  }

  /// Restore raw internal state verbatim — NO _step(), NO seed mixing.
  /// (fromLimbs/fromInt advance + mix and so cannot resume an exact state.)
  /// Required for exact reconciliation re-stepping (the wanderer is RNG-driven).
  DetRng.fromState(int lo, int hi)
      : _sLo = lo,
        _sHi = hi;

  int get stateLo => _sLo;
  int get stateHi => _sHi;

  void _step() {
    final m = _mul64(_sLo, _sHi, _mulLo, _mulHi);
    final a = _add64(m[0], m[1], _incLo, _incHi);
    _sLo = a[0];
    _sHi = a[1];
  }

  int nextU32() {
    final int oLo = _sLo, oHi = _sHi;
    _step();
    final int x18Lo = _u32((oLo >>> 18) | ((oHi << 14) & 0xFFFFFFFF));
    final int x18Hi = oHi >>> 18;
    final int xLo = x18Lo ^ oLo, xHi = x18Hi ^ oHi;
    final int xshift = _u32((xLo >>> 27) | ((xHi << 5) & 0xFFFFFFFF));
    final int rot = oHi >>> 27;
    final int r = rot & 31;
    if (r == 0) return xshift;
    return _u32((xshift >>> r) | ((xshift << (32 - r)) & 0xFFFFFFFF));
  }

  int nextInt(int bound) {
    assert(bound > 0 && bound <= 0x100000000);
    final int threshold = _u32(-bound) % bound;
    while (true) {
      final int v = nextU32();
      if (v >= threshold) return v % bound;
    }
  }

  Fixed nextFixedUnit() => Fixed.raw(nextU32() >>> 16);
}
