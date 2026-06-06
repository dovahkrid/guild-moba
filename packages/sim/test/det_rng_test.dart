import 'package:sim/src/math/det_rng.dart';
import 'package:test/test.dart';

void main() {
  test('same seed produces identical sequence', () {
    final a = DetRng.fromInt(1337);
    final b = DetRng.fromInt(1337);
    for (var i = 0; i < 1000; i++) {
      expect(a.nextU32(), b.nextU32());
    }
  });

  test('different seeds diverge', () {
    final a = DetRng.fromInt(1);
    final b = DetRng.fromInt(2);
    expect(a.nextU32() == b.nextU32(), isFalse);
  });

  test('nextU32 stays in 32-bit unsigned range', () {
    final r = DetRng.fromInt(42);
    for (var i = 0; i < 1000; i++) {
      final v = r.nextU32();
      expect(v >= 0 && v <= 0xFFFFFFFF, isTrue);
    }
  });

  test('nextInt respects bound', () {
    final r = DetRng.fromInt(99);
    for (var i = 0; i < 1000; i++) {
      final v = r.nextInt(6);
      expect(v >= 0 && v < 6, isTrue);
    }
  });

  test('pinned regression vector (defends cross-runtime identity)', () {
    // After implementing, run once to capture the real values, paste them here,
    // and keep them as a regression pin. These constants are placeholders to be
    // replaced with the first green run's output (Step 4 prints them).
    final r = DetRng.fromInt(1337);
    final got = <int>[r.nextU32(), r.nextU32(), r.nextU32()];
    expect(got, [708451831, 3264970190, 1489975032]);
  });
}
