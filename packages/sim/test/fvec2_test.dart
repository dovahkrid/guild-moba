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
  });

  test('equality is value-based', () {
    expect(v(1, 2) == v(1, 2), isTrue);
  });
}
