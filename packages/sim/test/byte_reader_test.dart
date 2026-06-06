import 'dart:typed_data';
import 'package:sim/src/state/byte_writer.dart';
import 'package:test/test.dart';

void main() {
  test('ByteReader round-trips i32 incl. negatives and INT32 extremes', () {
    final w = ByteWriter()..i32(0x01020304)..i32(-12345)..i32(-0x80000000)..i32(0x7FFFFFFF);
    final r = ByteReader(w.toBytes());
    expect(r.i32(), 0x01020304);
    expect(r.i32(), -12345);
    expect(r.i32(), -0x80000000);
    expect(r.i32(), 0x7FFFFFFF);
  });

  test('ByteReader round-trips u32 incl. high bit set', () {
    final w = ByteWriter()..u32(0xFFFFFFFF)..u32(0x80000000)..u32(0);
    final r = ByteReader(w.toBytes());
    expect(r.u32(), 0xFFFFFFFF);
    expect(r.u32(), 0x80000000);
    expect(r.u32(), 0);
  });

  test('bytes() appends and reads raw payloads', () {
    final payload = Uint8List.fromList([9, 8, 7, 6, 5]);
    final w = ByteWriter()..i32(42)..bytes(payload);
    final r = ByteReader(w.toBytes());
    expect(r.i32(), 42);
    expect(r.bytes(5), payload);
  });
}
