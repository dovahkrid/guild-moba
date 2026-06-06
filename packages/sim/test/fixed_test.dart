import 'package:sim/src/math/fixed.dart';
import 'package:test/test.dart';

void main() {
  test('fromInt and toDouble round-trip', () {
    expect(Fixed.fromInt(7).toDouble(), 7.0);
    expect(Fixed.fromInt(-3).toDouble(), -3.0);
  });

  test('add and sub', () {
    expect((Fixed.fromInt(5) + Fixed.fromInt(3)).toDouble(), 8.0);
    expect((Fixed.fromInt(5) - Fixed.fromInt(8)).toDouble(), -3.0);
  });

  test('multiply stays exact within contract', () {
    expect((Fixed.fromNum(3.5) * Fixed.fromNum(2.25)).toDouble(), 7.875);
    expect((Fixed.fromInt(-4) * Fixed.fromNum(2.5)).toDouble(), -10.0);
  });

  test('divide', () {
    expect((Fixed.fromInt(9) / Fixed.fromInt(2)).toDouble(), 4.5);
    expect((Fixed.fromInt(-9) / Fixed.fromInt(2)).toDouble(), -4.5);
  });

  test('sqrt via integer Newton', () {
    expect((Fixed.fromInt(16).sqrt()).toDouble(), closeTo(4.0, 0.001));
    expect((Fixed.fromInt(2).sqrt()).toDouble(), closeTo(1.41421, 0.001));
  });

  test('floorDiv floors toward negative infinity (unlike ~/)', () {
    expect(floorDiv(-7, 2), -4);
    expect(floorDiv(7, 2), 3);
  });

  test('floorToInt floors', () {
    expect(Fixed.fromNum(2.9).floorToInt(), 2);
    expect(Fixed.fromNum(-2.1).floorToInt(), -3);
  });
}
