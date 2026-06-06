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
}
