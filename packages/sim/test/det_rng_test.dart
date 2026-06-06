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
    // Pinned from first native run; guards cross-runtime identity.
    final r = DetRng.fromInt(1337);
    final got = <int>[r.nextU32(), r.nextU32(), r.nextU32()];
    expect(got, [2497197284, 1507425053, 1617594380]);
  });

  test('nextFixedUnit returns raw in [0, 65535]', () {
    final r = DetRng.fromInt(42);
    for (var i = 0; i < 1000; i++) {
      final v = r.nextFixedUnit();
      expect(v.raw >= 0 && v.raw <= 65535, isTrue);
    }
  });

  test('nextFixedUnit pinned first value equals nextU32() >>> 16', () {
    // Pinned from first native run; guards cross-runtime identity.
    final r1 = DetRng.fromInt(1337);
    final fuRaw = r1.nextFixedUnit().raw;

    final r2 = DetRng.fromInt(1337);
    final u32first = r2.nextU32();
    expect(fuRaw, u32first >>> 16); // exact extraction
    expect(fuRaw, 38104); // pinned value
  });

  test('fromState restores raw limbs verbatim (resumes identical sequence)', () {
    final a = DetRng.fromInt(1337);
    a.nextU32();
    a.nextU32();
    final lo = a.stateLo, hi = a.stateHi;
    final tail = [a.nextU32(), a.nextU32(), a.nextU32()];

    final restored = DetRng.fromState(lo, hi);
    expect([restored.nextU32(), restored.nextU32(), restored.nextU32()], tail);
  });
}
