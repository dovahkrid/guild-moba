import 'package:sim/src/math/fixed.dart';
import 'package:sim/src/math/fvec2.dart';
import 'package:test/test.dart';

void main() {
  FVec2 v(num x, num y) => FVec2(Fixed.fromNum(x), Fixed.fromNum(y));

  test('add and sub', () {
    final r = v(1, 2) + v(3, 4);
    expect(r.x.toDouble(), 4.0);
    expect(r.y.toDouble(), 6.0);
  });

  test('scale', () {
    final r = v(2, -3).scale(Fixed.fromNum(1.5));
    expect(r.x.toDouble(), 3.0);
    expect(r.y.toDouble(), -4.5);
  });

  test('lengthSq avoids sqrt', () {
    expect(v(3, 4).lengthSq().toDouble(), closeTo(25.0, 0.001));
  });

  test('length uses Fixed.sqrt', () {
    expect(v(3, 4).length().toDouble(), closeTo(5.0, 0.01));
    // Exact raw pin — a sub-ULP cross-runtime divergence would change this.
    expect(v(3, 4).length().raw, 327680); // 5.0 exactly
  });

  test('equality is value-based', () {
    expect(v(1, 2) == v(1, 2), isTrue);
  });

  test('dot product', () {
    expect(v(1, 0).dot(v(0, 1)).toDouble(), 0.0); // perpendicular
    expect(v(2, 3).dot(v(4, 5)).toDouble(), closeTo(23.0, 0.001));
  });

  test('zero constant', () {
    expect(FVec2.zero.x.toDouble(), 0.0);
    expect(FVec2.zero.y.toDouble(), 0.0);
  });
}
