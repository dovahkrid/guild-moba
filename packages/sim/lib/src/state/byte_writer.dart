import 'dart:typed_data';

import '../math/fixed.dart';

/// Canonical little-endian writer. Every int is emitted as 4 LE bytes of its
/// UNSIGNED 32-bit form. CRITICAL: extracting bytes from a raw negative int via
/// `>>` diverges on dart2js (sign bits lost past 53 bits) — masking to
/// `& 0xFFFFFFFF` first makes the bytes identical on native/js/wasm.
class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void i32(int v) {
    assert(v >= -0x80000000 && v <= 0x7FFFFFFF, 'value $v exceeds int32 range');
    final int u = v & 0xFFFFFFFF; // non-negative in [0, 2^32)
    _b.addByte(u & 0xFF);
    _b.addByte((u >> 8) & 0xFF);
    _b.addByte((u >> 16) & 0xFF);
    _b.addByte((u >> 24) & 0xFF);
  }

  /// Unsigned 32-bit (e.g. RNG state limbs). Same 4 LE bytes as i32's encoding.
  void u32(int v) {
    assert(v >= 0 && v <= 0xFFFFFFFF, 'value $v exceeds uint32 range');
    _b.addByte(v & 0xFF);
    _b.addByte((v >> 8) & 0xFF);
    _b.addByte((v >> 16) & 0xFF);
    _b.addByte((v >> 24) & 0xFF);
  }

  void fixed(Fixed f) => i32(f.raw);

  void bytes(List<int> raw) =>
      _b.add(raw is Uint8List ? raw : Uint8List.fromList(raw));

  Uint8List toBytes() => _b.toBytes();
}

const int _fnvOffset = 0x811C9DC5; // 2166136261
const int _fnvPrime = 0x01000193; // 16777619

/// 32-bit modular multiply via 16-bit halves so no intermediate exceeds ~2^48
/// (< 2^53), guaranteeing identical results on dart2js.
int mul32(int a, int b) {
  a = a & 0xFFFFFFFF;
  b = b & 0xFFFFFFFF;
  final int lo = (a & 0xFFFF) * b;
  final int hi = (((a >>> 16) * b) & 0xFFFF) << 16;
  return (lo + hi) & 0xFFFFFFFF;
}

/// Mirror of ByteWriter. Uses ByteData (typed-data getters are cross-runtime
/// deterministic, unlike Dart's `<<` which is signed-32-bit on dart2js).
class ByteReader {
  final ByteData _bd;
  int _off = 0;
  ByteReader(Uint8List bytes) : _bd = ByteData.sublistView(bytes);

  int u32() {
    final v = _bd.getUint32(_off, Endian.little);
    _off += 4;
    return v;
  }

  int i32() {
    final v = _bd.getInt32(_off, Endian.little);
    _off += 4;
    return v;
  }

  Fixed fixed() => Fixed.raw(i32());

  Uint8List bytes(int n) {
    final out = Uint8List.sublistView(_bd, _off, _off + n);
    _off += n;
    return Uint8List.fromList(out);
  }

  int get offset => _off;
  bool get atEnd => _off >= _bd.lengthInBytes;
}

/// FNV-1a/32 over a byte stream. Dependency-free and identical across runtimes
/// (unlike Object.hashCode). Used for the canonical state fingerprint.
class FnvHasher {
  int _h = _fnvOffset;

  void addByte(int byte) {
    _h = (_h ^ (byte & 0xFF)) & 0xFFFFFFFF;
    _h = mul32(_h, _fnvPrime);
  }

  void addBytes(List<int> bytes) {
    for (final b in bytes) {
      addByte(b);
    }
  }

  void addInt(int v) {
    final int u = v & 0xFFFFFFFF;
    addByte(u & 0xFF);
    addByte((u >> 8) & 0xFF);
    addByte((u >> 16) & 0xFF);
    addByte((u >> 24) & 0xFF);
  }

  int get hash => _h;
  String hex8() => (_h & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
