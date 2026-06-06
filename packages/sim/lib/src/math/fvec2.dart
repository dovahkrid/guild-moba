import 'fixed.dart';

class FVec2 {
  final Fixed x;
  final Fixed y;
  const FVec2(this.x, this.y);
  static const FVec2 zero = FVec2(Fixed.zero, Fixed.zero);

  FVec2 operator +(FVec2 o) => FVec2(x + o.x, y + o.y);
  FVec2 operator -(FVec2 o) => FVec2(x - o.x, y - o.y);
  FVec2 scale(Fixed s) => FVec2(x * s, y * s);
  Fixed dot(FVec2 o) => x * o.x + y * o.y;

  /// Prefer this for range checks (compare vs a precomputed radius²) — no sqrt.
  Fixed lengthSq() => x * x + y * y;
  Fixed length() => lengthSq().sqrt();

  @override
  bool operator ==(Object o) => o is FVec2 && o.x == x && o.y == y;
  @override
  int get hashCode => x.raw * 31 + y.raw;
  @override
  String toString() => '($x, $y)';
}
