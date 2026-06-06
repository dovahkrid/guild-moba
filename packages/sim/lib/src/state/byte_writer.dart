import 'dart:typed_data';

import '../math/fixed.dart';

/// Canonical little-endian writer. Every int is emitted as 4 LE bytes of its
/// UNSIGNED 32-bit form. CRITICAL: extracting bytes from a raw negative int via
/// `>>` diverges on dart2js (sign bits lost past 53 bits) — masking to
/// `& 0xFFFFFFFF` first makes the bytes identical on native/js/wasm.
class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void i32(int v) {
    assert(v > -0x80000000 && v < 0x80000000, 'value $v exceeds int32 range');
    final int u = v & 0xFFFFFFFF; // non-negative in [0, 2^32)
    _b.addByte(u & 0xFF);
    _b.addByte((u >> 8) & 0xFF);
    _b.addByte((u >> 16) & 0xFF);
    _b.addByte((u >> 24) & 0xFF);
  }

  void fixed(Fixed f) => i32(f.raw);

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
