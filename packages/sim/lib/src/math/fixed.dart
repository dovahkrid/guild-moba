/// Q16.16 fixed-point. value = raw / 65536.
const int kFracBits = 16;
const int kOne = 1 << kFracBits; // 65536

/// Signed floor-division. `~/` truncates toward zero and the shift operators
/// diverge on dart2js for negatives — this is the one true floor for the sim.
int floorDiv(int a, int d) => a >= 0 ? a ~/ d : -((-a + d - 1) ~/ d);

/// Fixed-point scalar. SAFETY CONTRACT: callers keep |value| < 32768, so
/// |raw| < 2^31 and every intermediate below stays < 2^53 (dart2js-safe).
class Fixed {
  final int raw;
  const Fixed.raw(this.raw);

  static const Fixed zero = Fixed.raw(0);
  static const Fixed one = Fixed.raw(kOne);

  factory Fixed.fromInt(int v) {
    assert(v > -32768 && v < 32768, 'Fixed range overflow: $v');
    return Fixed.raw(v * kOne);
  }

  /// AUTHORING ONLY (config/tests). `.round()` is identical on all targets.
  factory Fixed.fromNum(num v) {
    assert(v > -32768 && v < 32768, 'Fixed range overflow: $v');
    return Fixed.raw((v * kOne).round());
  }

  Fixed operator -() => Fixed.raw(-raw);
  Fixed operator +(Fixed o) => Fixed.raw(raw + o.raw);
  Fixed operator -(Fixed o) => Fixed.raw(raw - o.raw);

  /// Limb-split multiply: largest intermediate is aLo*ub < 2^47. Recombine with
  /// `~/ kOne` (NEVER `>>`, which diverges on dart2js for >32-bit values).
  Fixed operator *(Fixed o) {
    final int sign = ((raw < 0) ^ (o.raw < 0)) ? -1 : 1;
    final int ua = raw < 0 ? -raw : raw;
    final int ub = o.raw < 0 ? -o.raw : o.raw;
    final int aHi = ua ~/ kOne;
    final int aLo = ua % kOne;
    final int mag = aHi * ub + (aLo * ub) ~/ kOne;
    return Fixed.raw(sign * mag);
  }

  Fixed operator /(Fixed o) {
    assert(o.raw != 0, 'Fixed division by zero');
    final int sign = ((raw < 0) ^ (o.raw < 0)) ? -1 : 1;
    final int ua = raw < 0 ? -raw : raw;
    final int ub = o.raw < 0 ? -o.raw : o.raw;
    return Fixed.raw(sign * ((ua * kOne) ~/ ub));
  }

  /// Deterministic fixed-point sqrt (integer Newton). dart:math.sqrt is NOT
  /// bit-identical across targets — never use it in the sim.
  Fixed sqrt() {
    if (raw <= 0) return Fixed.zero;
    final int n = raw * kOne; // < 2^31 * 2^16 = 2^47, safe
    int x = n;
    int y = (x + 1) ~/ 2;
    while (y < x) {
      x = y;
      y = (x + n ~/ x) ~/ 2;
    }
    return Fixed.raw(x);
  }

  Fixed abs() => raw < 0 ? Fixed.raw(-raw) : this;

  bool operator <(Fixed o) => raw < o.raw;
  bool operator <=(Fixed o) => raw <= o.raw;
  bool operator >(Fixed o) => raw > o.raw;
  bool operator >=(Fixed o) => raw >= o.raw;

  @override
  bool operator ==(Object o) => o is Fixed && o.raw == raw;
  @override
  int get hashCode => raw; // value-based; NEVER branch on this in sim logic

  double toDouble() => raw / kOne; // rendering / tests only
  int floorToInt() => floorDiv(raw, kOne);

  @override
  String toString() => toDouble().toStringAsFixed(5);
}
