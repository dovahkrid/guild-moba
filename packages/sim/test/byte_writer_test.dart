import 'package:sim/src/math/fixed.dart';
import 'package:sim/src/state/byte_writer.dart';
import 'package:test/test.dart';

void main() {
  test('i32 writes little-endian unsigned bytes for positives', () {
    final w = ByteWriter();
    w.i32(0x01020304);
    expect(w.toBytes(), [0x04, 0x03, 0x02, 0x01]);
  });

  test('i32 encodes negatives via two-complement 32-bit form (no sign loss)', () {
    final w = ByteWriter();
    w.i32(-12345); // 0xFFFFCFC7
    expect(w.toBytes(), [0xC7, 0xCF, 0xFF, 0xFF]);
  });

  test('FnvHasher is order-sensitive and stable', () {
    final a = FnvHasher()..addBytes([1, 2, 3]);
    final b = FnvHasher()..addBytes([1, 2, 3]);
    final c = FnvHasher()..addBytes([3, 2, 1]);
    expect(a.hash, b.hash);
    expect(a.hash == c.hash, isFalse);
  });

  test('FnvHasher hex8 is 8 zero-padded hex chars', () {
    final h = FnvHasher()..addInt(42);
    expect(h.hex8().length, 8);
    expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(h.hex8()), isTrue);
  });

  test('FnvHasher matches standard FNV-1a/32 vectors', () {
    expect((FnvHasher()..addByte(0x61)).hash, 0xe40c292c); // "a"
    final foobar = FnvHasher()..addBytes('foobar'.codeUnits);
    expect(foobar.hash, 0xbf9cf968); // "foobar"
  });

  test('fixed() encodes the raw the same as i32', () {
    final a = ByteWriter()..fixed(Fixed.fromNum(1.5));
    final b = ByteWriter()..i32(Fixed.fromNum(1.5).raw);
    expect(a.toBytes(), b.toBytes());
  });

  test('u32 round-trips a high value', () {
    expect((ByteWriter()..u32(0xFFFFFFFF)).toBytes(), [0xFF, 0xFF, 0xFF, 0xFF]);
  });

  test('i32 accepts INT32_MIN', () {
    expect((ByteWriter()..i32(-0x80000000)).toBytes(), [0x00, 0x00, 0x00, 0x80]);
  });
}
