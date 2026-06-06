# Guild — Plan 1: Foundation (Deterministic Sim Core + Cross-Platform Replay Gate) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Dart monorepo and a pure-Dart `sim` package whose deterministic simulation produces byte-identical results across native, dart2js, and dart2wasm — enforced by a CI replay-golden gate and a platform-purity gate.

**Architecture:** A Dart 3 pub workspace. `packages/sim` is pure Dart (no flutter/flame/dart:io/dart:ui) holding fixed-point math (Q16.16), a hand-rolled deterministic PCG32 RNG, a minimal entity simulation with a fixed-timestep `step()`, and a canonical integer-only state encoder + FNV-1a/32 hash. A replay harness runs the same sim on all three runtimes; CI asserts the three hashes match. This proves the project's #1 architectural bet ("one sim, both sides") before any gameplay is built.

**Tech Stack:** Dart 3.11.5 (pinned), `package:test`, `package:lints`; Node 22 for running compiled JS/WASM; GitHub Actions for CI. No third-party runtime deps in `sim`.

**Determinism contract (every task obeys this):** No `double` in gameplay math (Q16.16 `Fixed` only; `fromNum` is authoring-only). All scalars keep `|value| < 32768` so `|raw| < 2^31`. NEVER use `<<`/`>>`/`>>>` on a value that may be negative or exceed 32 bits — use `~/`, `%`, and the explicit `floorDiv`. Shifts/masks are allowed only on values already masked with `& 0xFFFFFFFF` and proven non-negative (inside RNG/hash). No `DateTime`/`Timer`/`Stopwatch`, no `dart:math.Random`, no `dart:math` transcendentals, no `Object.hashCode`-dependent control flow, no `HashMap`/`HashSet` iteration during `step()` (iterate `List` by ascending int id).

---

## File Structure

**Created in this plan:**

- `pubspec.yaml` — workspace root (lists members; NO `resolution:` key).
- `analysis_options.yaml` — shared strict lints.
- `packages/sim/pubspec.yaml` — pure-Dart member.
- `packages/sim/lib/src/math/fixed.dart` — `Fixed` (Q16.16) + `floorDiv`.
- `packages/sim/lib/src/math/fvec2.dart` — `FVec2`.
- `packages/sim/lib/src/math/det_rng.dart` — `DetRng` (PCG32, 32-bit limbs).
- `packages/sim/lib/src/state/byte_writer.dart` — `ByteWriter` (i32 LE) + `FnvHasher` (FNV-1a/32 via `mul32`).
- `packages/sim/lib/src/model/entity.dart` — `Entity`, `EntityKind`.
- `packages/sim/lib/src/model/intent.dart` — `Intent`, `IntentType`.
- `packages/sim/lib/src/model/sim_config.dart` — `SimConfig`.
- `packages/sim/lib/src/simulation.dart` — `Simulation` (`step`, `canonicalBytes`, `canonicalStateHash`, `entityIdsSorted`).
- `packages/sim/lib/sim.dart` — public barrel export.
- `packages/protocol/pubspec.yaml` + `packages/protocol/lib/protocol.dart` — stub member (depends on `sim`).
- `packages/sim/test/fixed_test.dart`, `fvec2_test.dart`, `det_rng_test.dart`, `byte_writer_test.dart`, `simulation_test.dart`, `banned_imports_test.dart`.
- `tooling/replay_harness.dart` — pure-Dart replay entrypoint (3 runtimes).
- `tooling/wasm_entry.mjs` — Node ESM host for the dart2wasm output.
- `tooling/compare_replays.sh` — builds + runs all 3 runtimes, asserts identical hash.
- `tooling/check_no_banned_imports.sh` — CI purity grep.
- `tooling/replay_fixtures/smoke.json` — committed replay input log.
- `.github/workflows/sim-determinism.yml` — the two CI gates.

---

## Task 0: Workspace scaffold

**Files:**
- Create: `pubspec.yaml`, `analysis_options.yaml`, `packages/sim/pubspec.yaml`, `packages/sim/lib/sim.dart`, `packages/protocol/pubspec.yaml`, `packages/protocol/lib/protocol.dart`

- [ ] **Step 1: Write the workspace root pubspec**

`pubspec.yaml` (repo root) — note: **no `resolution:` key on the root** (that makes `dart pub get` fail with exit 66):

```yaml
name: guild_workspace
publish_to: none

environment:
  sdk: ^3.6.0

# Explicit member paths (glob `packages/*` needs SDK >= 3.11).
workspace:
  - packages/sim
  - packages/protocol

dev_dependencies:
  test: ^1.25.0
  lints: ^4.0.0
```

- [ ] **Step 2: Write the shared analyzer config**

`analysis_options.yaml`:

```yaml
include: package:lints/recommended.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true

linter:
  rules:
    - avoid_dynamic_calls
    - prefer_final_locals
```

- [ ] **Step 3: Write the two member packages**

`packages/sim/pubspec.yaml` (members carry `resolution: workspace`, no `workspace:` key):

```yaml
name: sim
description: Deterministic, platform-agnostic MOBA simulation (pure Dart).
publish_to: none
version: 0.0.1

environment:
  sdk: ^3.6.0

resolution: workspace

dev_dependencies:
  test: ^1.25.0
```

`packages/sim/lib/sim.dart` (temporary stub; real exports added in Task 8):

```dart
// Public API barrel for the pure-Dart simulation package.
// Exports are filled in as each module lands.
library;
```

`packages/protocol/pubspec.yaml`:

```yaml
name: protocol
description: Wire protocol / message types shared by server and client.
publish_to: none
version: 0.0.1

environment:
  sdk: ^3.6.0

resolution: workspace

dependencies:
  sim:
    path: ../sim

dev_dependencies:
  test: ^1.25.0
```

`packages/protocol/lib/protocol.dart`:

```dart
// Wire protocol stub. Message types land in Plan 2 (Netcode).
library;
```

- [ ] **Step 4: Resolve and analyze**

Run: `dart pub get`
Expected: `Resolving dependencies...` then `Got dependencies!` with no error; a single root `pubspec.lock` and `.dart_tool/package_config.json` are created.

Run: `dart analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml analysis_options.yaml packages/sim/pubspec.yaml packages/sim/lib/sim.dart packages/protocol/pubspec.yaml packages/protocol/lib/protocol.dart
git commit -m "chore: scaffold Dart pub workspace (sim + protocol)"
```

---

## Task 1: Fixed-point `Fixed` (Q16.16) + `floorDiv`

**Files:**
- Create: `packages/sim/lib/src/math/fixed.dart`
- Test: `packages/sim/test/fixed_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/fixed_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/fixed_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'sim'` is gone (Task 0 fixed it), but compilation fails with "Target of URI doesn't exist: 'package:sim/src/math/fixed.dart'".

- [ ] **Step 3: Write minimal implementation**

`packages/sim/lib/src/math/fixed.dart`:

```dart
/// Q16.16 fixed-point. value = raw / 65536.
const int kFracBits = 16;
const int kOne = 1 << kFracBits; // 65536

/// Signed floor-division. `~/` truncates toward zero and the shift operators
/// diverge on dart2js for negatives — this is the one true floor for the sim.
int floorDiv(int a, int d) => a >= 0 ? a ~/ d : -((-a + d - 1) ~/ d);

/// Fixed-point scalar. SAFETY CONTRACT: callers keep |value| < 32768, so
/// |raw| < 2^31 and every intermediate below stays < 2^53 (dart2js-safe).
class Fixed {
  final int raw;
  const Fixed.raw(this.raw);

  static const Fixed zero = Fixed.raw(0);
  static const Fixed one = Fixed.raw(kOne);

  factory Fixed.fromInt(int v) {
    assert(v > -32768 && v < 32768, 'Fixed range overflow: $v');
    return Fixed.raw(v * kOne);
  }

  /// AUTHORING ONLY (config/tests). `.round()` is identical on all targets.
  factory Fixed.fromNum(num v) {
    assert(v > -32768 && v < 32768, 'Fixed range overflow: $v');
    return Fixed.raw((v * kOne).round());
  }

  Fixed operator -() => Fixed.raw(-raw);
  Fixed operator +(Fixed o) => Fixed.raw(raw + o.raw);
  Fixed operator -(Fixed o) => Fixed.raw(raw - o.raw);

  /// Limb-split multiply: largest intermediate is aLo*ub < 2^47. Recombine with
  /// `~/ kOne` (NEVER `>>`, which diverges on dart2js for >32-bit values).
  Fixed operator *(Fixed o) {
    final int sign = ((raw < 0) ^ (o.raw < 0)) ? -1 : 1;
    final int ua = raw < 0 ? -raw : raw;
    final int ub = o.raw < 0 ? -o.raw : o.raw;
    final int aHi = ua ~/ kOne;
    final int aLo = ua % kOne;
    final int mag = aHi * ub + (aLo * ub) ~/ kOne;
    return Fixed.raw(sign * mag);
  }

  Fixed operator /(Fixed o) {
    assert(o.raw != 0, 'Fixed division by zero');
    final int sign = ((raw < 0) ^ (o.raw < 0)) ? -1 : 1;
    final int ua = raw < 0 ? -raw : raw;
    final int ub = o.raw < 0 ? -o.raw : o.raw;
    return Fixed.raw(sign * ((ua * kOne) ~/ ub));
  }

  /// Deterministic fixed-point sqrt (integer Newton). dart:math.sqrt is NOT
  /// bit-identical across targets — never use it in the sim.
  Fixed sqrt() {
    if (raw <= 0) return Fixed.zero;
    final int n = raw * kOne; // < 2^31 * 2^16 = 2^47, safe
    int x = n;
    int y = (x + 1) ~/ 2;
    while (y < x) {
      x = y;
      y = (x + n ~/ x) ~/ 2;
    }
    return Fixed.raw(x);
  }

  Fixed abs() => raw < 0 ? Fixed.raw(-raw) : this;

  bool operator <(Fixed o) => raw < o.raw;
  bool operator <=(Fixed o) => raw <= o.raw;
  bool operator >(Fixed o) => raw > o.raw;
  bool operator >=(Fixed o) => raw >= o.raw;

  @override
  bool operator ==(Object o) => o is Fixed && o.raw == raw;
  @override
  int get hashCode => raw; // value-based; NEVER branch on this in sim logic

  double toDouble() => raw / kOne; // rendering / tests only
  int floorToInt() => floorDiv(raw, kOne);

  @override
  String toString() => toDouble().toStringAsFixed(5);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim/test/fixed_test.dart`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/math/fixed.dart packages/sim/test/fixed_test.dart
git commit -m "feat(sim): deterministic Q16.16 Fixed type + floorDiv"
```

---

## Task 2: `FVec2`

**Files:**
- Create: `packages/sim/lib/src/math/fvec2.dart`
- Test: `packages/sim/test/fvec2_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/fvec2_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/fvec2_test.dart`
Expected: FAIL — "Target of URI doesn't exist: 'package:sim/src/math/fvec2.dart'".

- [ ] **Step 3: Write minimal implementation**

`packages/sim/lib/src/math/fvec2.dart`:

```dart
import 'fixed.dart';

class FVec2 {
  final Fixed x;
  final Fixed y;
  const FVec2(this.x, this.y);
  static const FVec2 zero = FVec2(Fixed.zero, Fixed.zero);

  FVec2 operator +(FVec2 o) => FVec2(x + o.x, y + o.y);
  FVec2 operator -(FVec2 o) => FVec2(x - o.x, y - o.y);
  FVec2 scale(Fixed s) => FVec2(x * s, y * s);
  Fixed dot(FVec2 o) => x * o.x + y * o.y;

  /// Prefer this for range checks (compare vs a precomputed radius²) — no sqrt.
  Fixed lengthSq() => x * x + y * y;
  Fixed length() => lengthSq().sqrt();

  @override
  bool operator ==(Object o) => o is FVec2 && o.x == x && o.y == y;
  @override
  int get hashCode => x.raw * 31 + y.raw;
  @override
  String toString() => '($x, $y)';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim/test/fvec2_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/math/fvec2.dart packages/sim/test/fvec2_test.dart
git commit -m "feat(sim): FVec2 fixed-point vector"
```

---

## Task 3: `DetRng` (PCG32 with 32-bit limbs)

**Files:**
- Create: `packages/sim/lib/src/math/det_rng.dart`
- Test: `packages/sim/test/det_rng_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/det_rng_test.dart`:

```dart
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
    expect(got, [2061311525, 1832813570, 3733242598]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/det_rng_test.dart`
Expected: FAIL — "Target of URI doesn't exist: 'package:sim/src/math/det_rng.dart'".

- [ ] **Step 3: Write minimal implementation**

`packages/sim/lib/src/math/det_rng.dart`:

```dart
import 'fixed.dart';

int _u32(int x) => x & 0xFFFFFFFF;

/// Low 64 bits of (a*b) as [lo32, hi32]. Schoolbook on 16-bit chunks so every
/// partial product < 2^32 and every column sum < 2^34 — never near 2^53.
List<int> _mul64(int aLo, int aHi, int bLo, int bHi) {
  final a0 = aLo & 0xFFFF, a1 = aLo >>> 16, a2 = aHi & 0xFFFF, a3 = aHi >>> 16;
  final b0 = bLo & 0xFFFF, b1 = bLo >>> 16, b2 = bHi & 0xFFFF, b3 = bHi >>> 16;
  final int c0 = a0 * b0;
  final int c1 = a0 * b1 + a1 * b0;
  final int c2 = a0 * b2 + a1 * b1 + a2 * b0;
  final int c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0;
  final int r0 = c0 & 0xFFFF;
  int carry = c0 >>> 16;
  final int t1 = c1 + carry;
  final int r1 = t1 & 0xFFFF;
  carry = (t1 - r1) ~/ 65536;
  final int t2 = c2 + carry;
  final int r2 = t2 & 0xFFFF;
  carry = (t2 - r2) ~/ 65536;
  final int t3 = c3 + carry;
  final int r3 = t3 & 0xFFFF;
  return [_u32(r0 | (r1 << 16)), _u32(r2 | (r3 << 16))];
}

List<int> _add64(int aLo, int aHi, int bLo, int bHi) {
  final int lo = aLo + bLo; // < 2^33, safe
  final int loW = _u32(lo);
  final int carry = (lo - loW) ~/ 4294967296;
  return [loW, _u32(aHi + bHi + carry)];
}

// PCG multiplier 6364136223846793005 = 0x5851F42D4C957F2D
const int _mulLo = 0x4C957F2D, _mulHi = 0x5851F42D;
// PCG increment 1442695040888963407 = 0x14057B7F82F2B65D (odd)
const int _incLo = 0x82F2B65D, _incHi = 0x14057B7F;

/// PCG-XSH-RR 32-bit-output RNG. The 64-bit LCG state lives in two 32-bit limbs
/// so no operation depends on true 64-bit ints (which dart2js lacks).
class DetRng {
  int _sLo, _sHi;

  DetRng.fromLimbs(int seedLo, int seedHi)
      : _sLo = 0,
        _sHi = 0 {
    _step();
    final a = _add64(_sLo, _sHi, _u32(seedLo), _u32(seedHi));
    _sLo = a[0];
    _sHi = a[1];
    _step();
  }

  factory DetRng.fromInt(int seed) {
    assert(seed >= 0 && seed < 0x20000000000000, '<2^53 only');
    return DetRng.fromLimbs(_u32(seed), seed ~/ 4294967296);
  }

  int get stateLo => _sLo;
  int get stateHi => _sHi;

  void _step() {
    final m = _mul64(_sLo, _sHi, _mulLo, _mulHi);
    final a = _add64(m[0], m[1], _incLo, _incHi);
    _sLo = a[0];
    _sHi = a[1];
  }

  int nextU32() {
    final int oLo = _sLo, oHi = _sHi;
    _step();
    final int x18Lo = _u32((oLo >>> 18) | ((oHi << 14) & 0xFFFFFFFF));
    final int x18Hi = oHi >>> 18;
    final int xLo = x18Lo ^ oLo, xHi = x18Hi ^ oHi;
    final int xshift = _u32((xLo >>> 27) | ((xHi << 5) & 0xFFFFFFFF));
    final int rot = oHi >>> 27;
    final int r = rot & 31;
    if (r == 0) return xshift;
    return _u32((xshift >>> r) | ((xshift << (32 - r)) & 0xFFFFFFFF));
  }

  int nextInt(int bound) {
    assert(bound > 0 && bound <= 0x100000000);
    final int threshold = _u32(-bound) % bound;
    while (true) {
      final int v = nextU32();
      if (v >= threshold) return v % bound;
    }
  }

  Fixed nextFixedUnit() => Fixed.raw(nextU32() >>> 16);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim/test/det_rng_test.dart`
Expected: The first four tests PASS; the pinned-vector test may FAIL with the actual values printed in the diff. Copy the three actual numbers from the failure message into the `expect(got, [...])` list in the test, then re-run:

Run: `dart test packages/sim/test/det_rng_test.dart`
Expected: PASS (5 tests). (The pinned vector is now a real cross-runtime regression guard — Task 11's gate proves it matches on JS/WASM too.)

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/math/det_rng.dart packages/sim/test/det_rng_test.dart
git commit -m "feat(sim): deterministic PCG32 RNG (32-bit limbs)"
```

---

## Task 4: Canonical byte writer + FNV-1a/32 hash

**Files:**
- Create: `packages/sim/lib/src/state/byte_writer.dart`
- Test: `packages/sim/test/byte_writer_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/byte_writer_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/byte_writer_test.dart`
Expected: FAIL — "Target of URI doesn't exist: 'package:sim/src/state/byte_writer.dart'".

- [ ] **Step 3: Write minimal implementation**

`packages/sim/lib/src/state/byte_writer.dart`:

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim/test/byte_writer_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/state/byte_writer.dart packages/sim/test/byte_writer_test.dart
git commit -m "feat(sim): canonical byte writer + FNV-1a/32 hash"
```

---

## Task 5: Sim model — `Entity`, `Intent`, `SimConfig`

**Files:**
- Create: `packages/sim/lib/src/model/entity.dart`, `packages/sim/lib/src/model/intent.dart`, `packages/sim/lib/src/model/sim_config.dart`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/model_test.dart`:

```dart
import 'package:sim/src/math/fixed.dart';
import 'package:sim/src/model/entity.dart';
import 'package:sim/src/model/intent.dart';
import 'package:sim/src/model/sim_config.dart';
import 'package:test/test.dart';

void main() {
  test('Entity holds mutable fixed-point position', () {
    final e = Entity(id: 0, kind: EntityKind.hero, teamId: 0,
        pos: FVec2(Fixed.fromInt(1), Fixed.fromInt(2)), hp: Fixed.fromInt(100));
    e.pos = FVec2(Fixed.fromInt(3), Fixed.fromInt(4));
    expect(e.pos.x.toDouble(), 3.0);
  });

  test('Intent carries slot, type and aim', () {
    const i = Intent(playerSlot: 1, type: IntentType.move, aimX: 65536, aimY: 0, seq: 7);
    expect(i.playerSlot, 1);
    expect(i.type, IntentType.move);
    expect(i.aimX, 65536);
  });

  test('SimConfig carries a seed', () {
    const c = SimConfig(seed: 1337);
    expect(c.seed, 1337);
  });
}
```

(Also add `import 'package:sim/src/math/fvec2.dart';` — included implicitly via entity, but import it explicitly:)

```dart
import 'package:sim/src/math/fvec2.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/model_test.dart`
Expected: FAIL — "Target of URI doesn't exist: 'package:sim/src/model/entity.dart'".

- [ ] **Step 3: Write minimal implementation**

`packages/sim/lib/src/model/entity.dart`:

```dart
import '../math/fixed.dart';
import '../math/fvec2.dart';

enum EntityKind { hero, wanderer }

/// A simulated unit. Plan 1 only moves entities; combat fields arrive in Plan 3.
class Entity {
  final int id;
  final EntityKind kind;
  final int teamId;

  FVec2 pos;
  FVec2 vel;
  Fixed hp;

  // Heroes seek toward this point (set by a move intent).
  FVec2 target;

  Entity({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.pos,
    required this.hp,
    FVec2? vel,
    FVec2? target,
  })  : vel = vel ?? FVec2.zero,
        target = target ?? pos;
}
```

`packages/sim/lib/src/model/intent.dart`:

```dart
enum IntentType { none, move }

/// A player command for a tick. Aim values are Q16.16 raw ints.
class Intent {
  final int playerSlot;
  final IntentType type;
  final int aimX;
  final int aimY;
  final int seq;
  final int clientTick;

  const Intent({
    required this.playerSlot,
    required this.type,
    this.aimX = 0,
    this.aimY = 0,
    this.seq = 0,
    this.clientTick = 0,
  });
}
```

`packages/sim/lib/src/model/sim_config.dart`:

```dart
/// Immutable match configuration. `seed` drives the deterministic RNG.
class SimConfig {
  final int seed;
  const SimConfig({required this.seed});
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim/test/model_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/model/ packages/sim/test/model_test.dart
git commit -m "feat(sim): entity, intent and sim-config model"
```

---

## Task 6: `Simulation` (deterministic step + canonical hash)

**Files:**
- Create: `packages/sim/lib/src/simulation.dart`
- Test: `packages/sim/test/simulation_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/simulation_test.dart`:

```dart
import 'package:sim/src/model/intent.dart';
import 'package:sim/src/model/sim_config.dart';
import 'package:sim/src/simulation.dart';
import 'package:test/test.dart';

void main() {
  test('starts with two heroes and one wanderer in id order', () {
    final sim = Simulation.create(const SimConfig(seed: 1337));
    expect(sim.entityIdsSorted, [0, 1, 2]);
  });

  test('a move intent pulls the hero toward its aim over ticks', () {
    final sim = Simulation.create(const SimConfig(seed: 1337));
    final startX = sim.entity(0).pos.x.toDouble();
    // aim far to the right: (10.0, 0.0) in Q16.16 => 655360, 0.
    const move = Intent(playerSlot: 0, type: IntentType.move, aimX: 655360, aimY: 0, seq: 1);
    for (var t = 0; t < 30; t++) {
      sim.step(t, [move]);
    }
    expect(sim.entity(0).pos.x.toDouble(), greaterThan(startX));
  });

  test('identical seed + inputs produce identical state hash (determinism)', () {
    Simulation run() {
      final s = Simulation.create(const SimConfig(seed: 1337));
      const m0 = Intent(playerSlot: 0, type: IntentType.move, aimX: 655360, aimY: 131072, seq: 1);
      const m1 = Intent(playerSlot: 1, type: IntentType.move, aimX: -655360, aimY: 131072, seq: 1);
      for (var t = 0; t < 300; t++) {
        s.step(t, [m0, m1]);
      }
      return s;
    }
    expect(run().canonicalStateHash(), run().canonicalStateHash());
  });

  test('canonicalStateHash changes when state changes', () {
    final a = Simulation.create(const SimConfig(seed: 1337))..step(0, const []);
    final b = Simulation.create(const SimConfig(seed: 1337));
    expect(a.canonicalStateHash() == b.canonicalStateHash(), isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/simulation_test.dart`
Expected: FAIL — "Target of URI doesn't exist: 'package:sim/src/simulation.dart'".

- [ ] **Step 3: Write minimal implementation**

`packages/sim/lib/src/simulation.dart`:

```dart
import 'dart:typed_data';

import 'math/det_rng.dart';
import 'math/fixed.dart';
import 'math/fvec2.dart';
import 'model/entity.dart';
import 'model/intent.dart';
import 'model/sim_config.dart';
import 'state/byte_writer.dart';

const int kSchemaVersion = 1;

/// Per-tick max movement step (Q16.16). Authoring constant.
final Fixed _kHeroStep = Fixed.fromNum(0.15);
final Fixed _kWanderStep = Fixed.fromNum(0.05);

/// The authoritative, deterministic simulation. Runs identically on server and
/// client. Plan 1 only moves entities; it exists to prove cross-runtime
/// determinism end-to-end.
class Simulation {
  int tick = 0;
  final DetRng _rng;
  final List<Entity> _entities;
  final Map<int, Entity> _byId;

  Simulation._(this._rng, this._entities)
      : _byId = {for (final e in _entities) e.id: e};

  factory Simulation.create(SimConfig config) {
    final entities = <Entity>[
      Entity(
        id: 0,
        kind: EntityKind.hero,
        teamId: 0,
        pos: FVec2(Fixed.fromInt(-8), Fixed.zero),
        hp: Fixed.fromInt(100),
      ),
      Entity(
        id: 1,
        kind: EntityKind.hero,
        teamId: 1,
        pos: FVec2(Fixed.fromInt(8), Fixed.zero),
        hp: Fixed.fromInt(100),
      ),
      Entity(
        id: 2,
        kind: EntityKind.wanderer,
        teamId: 2,
        pos: FVec2.zero,
        hp: Fixed.fromInt(50),
      ),
    ];
    return Simulation._(DetRng.fromInt(config.seed), entities);
  }

  List<int> get entityIdsSorted => _entities.map((e) => e.id).toList()..sort();
  Entity entity(int id) => _byId[id]!;

  /// Advance one fixed tick. `intents` are applied in a canonical order so the
  /// result never depends on arrival order.
  void step(int currentTick, List<Intent> intents) {
    tick = currentTick;

    final ordered = [...intents]..sort((a, b) =>
        a.playerSlot != b.playerSlot ? a.playerSlot - b.playerSlot : a.seq - b.seq);
    for (final it in ordered) {
      if (it.type == IntentType.move && it.playerSlot >= 0 && it.playerSlot < 2) {
        final hero = _byId[it.playerSlot]!;
        hero.target = FVec2(Fixed.raw(it.aimX), Fixed.raw(it.aimY));
      }
    }

    // Heroes seek their target by a capped per-axis step.
    for (final e in _entities) {
      if (e.kind != EntityKind.hero) continue;
      e.pos = FVec2(
        _stepToward(e.pos.x, e.target.x, _kHeroStep),
        _stepToward(e.pos.y, e.target.y, _kHeroStep),
      );
    }

    // The wanderer drifts by an RNG-derived direction — puts the RNG through
    // the determinism gate every tick.
    final w = _byId[2]!;
    final dx = _rng.nextInt(3) - 1; // -1, 0, +1
    final dy = _rng.nextInt(3) - 1;
    w.pos = FVec2(
      w.pos.x + Fixed.fromInt(dx) * _kWanderStep,
      w.pos.y + Fixed.fromInt(dy) * _kWanderStep,
    );
  }

  Fixed _stepToward(Fixed cur, Fixed target, Fixed step) {
    final diff = target - cur;
    if (diff > step) return cur + step;
    if (-diff > step) return cur - step;
    return target;
  }

  /// Canonical, integer-only, ordered byte encoding of the full state.
  Uint8List canonicalBytes() {
    final w = ByteWriter();
    w.i32(kSchemaVersion);
    w.i32(tick);
    w.i32(_rng.stateLo);
    w.i32(_rng.stateHi);

    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      w.fixed(e.pos.x);
      w.fixed(e.pos.y);
      w.fixed(e.vel.x);
      w.fixed(e.vel.y);
      w.fixed(e.hp);
    }
    return w.toBytes();
  }

  int canonicalStateHash() => (FnvHasher()..addBytes(canonicalBytes())).hash;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim/test/simulation_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/simulation_test.dart
git commit -m "feat(sim): deterministic Simulation with canonical state hash"
```

---

## Task 7: Public barrel export

**Files:**
- Modify: `packages/sim/lib/sim.dart`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/barrel_test.dart`:

```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('public API is reachable through the barrel', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    const move = Intent(playerSlot: 0, type: IntentType.move, aimX: 65536, aimY: 0);
    sim.step(0, [move]);
    expect(sim.entityIdsSorted, [0, 1, 2]);
    expect(Fixed.fromInt(2).toDouble(), 2.0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/barrel_test.dart`
Expected: FAIL — undefined names `Simulation`, `SimConfig`, `Intent`, `Fixed` (the barrel is still an empty stub).

- [ ] **Step 3: Write minimal implementation**

`packages/sim/lib/sim.dart` (replace the stub):

```dart
/// Public API for the pure-Dart deterministic simulation.
library;

export 'src/math/fixed.dart';
export 'src/math/fvec2.dart';
export 'src/math/det_rng.dart';
export 'src/state/byte_writer.dart';
export 'src/model/entity.dart';
export 'src/model/intent.dart';
export 'src/model/sim_config.dart';
export 'src/simulation.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim`
Expected: PASS — every sim test (including the new barrel test) green.

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/sim.dart packages/sim/test/barrel_test.dart
git commit -m "feat(sim): public API barrel"
```

---

## Task 8: Platform-purity gate (`sim` stays pure Dart)

**Files:**
- Create: `packages/sim/test/banned_imports_test.dart`, `tooling/check_no_banned_imports.sh`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/banned_imports_test.dart` (a test may use `dart:io`; it scans `lib/` only):

```dart
import 'dart:io';
import 'package:test/test.dart';

final _banned = <RegExp>[
  RegExp(r'''^\s*(import|export)\s+['"]package:flutter/'''),
  RegExp(r'''^\s*(import|export)\s+['"]package:flame'''),
  RegExp(r'''^\s*(import|export)\s+['"]package:web/'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:ui'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:io'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:html'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:js'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:ffi'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:isolate'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:mirrors'''),
];

final _bannedApis = <RegExp>[
  RegExp(r'\bRandom\s*\('),
  RegExp(r'\bmath\.(sin|cos|sqrt|pow|atan2|tan)\b'),
  RegExp(r'\b(DateTime|Stopwatch)\b'),
];

void main() {
  test('packages/sim/lib is platform-pure and determinism-safe', () {
    final libDir = Directory('lib');
    final offenders = <String>[];
    for (final f in libDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      var n = 0;
      for (final line in f.readAsLinesSync()) {
        n++;
        for (final re in _banned) {
          if (re.hasMatch(line)) offenders.add('${f.path}:$n (import) $line');
        }
        for (final re in _bannedApis) {
          if (re.hasMatch(line)) offenders.add('${f.path}:$n (api) $line');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'determinism/purity violations in packages/sim/lib:\n${offenders.join('\n')}');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

First introduce a deliberate violation to prove the gate bites: temporarily add `import 'dart:io';` to the top of `packages/sim/lib/src/simulation.dart`.

Run: `dart test packages/sim/test/banned_imports_test.dart` (from `packages/sim`)
Expected: FAIL listing `lib/src/simulation.dart:... (import) import 'dart:io';`.

- [ ] **Step 3: Remove the violation + add the bash gate**

Remove the temporary `import 'dart:io';` from `simulation.dart`.

`tooling/check_no_banned_imports.sh`:

```bash
#!/usr/bin/env bash
# FAILS if any file under packages/sim/lib imports a platform-bound library or
# uses a non-deterministic API. packages/sim MUST be pure & deterministic.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/packages/sim/lib"

IMPORTS="^[[:space:]]*(import|export)[[:space:]]+['\"](package:flutter/|package:flame|package:web/|dart:ui|dart:io|dart:html|dart:js|dart:ffi|dart:isolate|dart:mirrors)"
APIS="\\bRandom[[:space:]]*\\(|\\bmath\\.(sin|cos|sqrt|pow|atan2|tan)\\b|\\b(DateTime|Stopwatch)\\b"

fail=0
if grep -REn --include='*.dart' "$IMPORTS" "$TARGET"; then fail=1; fi
if grep -REn --include='*.dart' "$APIS" "$TARGET"; then fail=1; fi
if [ "$fail" -ne 0 ]; then
  echo "FAIL: packages/sim/lib has banned imports or non-deterministic APIs (above)." >&2
  exit 1
fi
echo "PASS: packages/sim/lib is pure and determinism-safe."
```

- [ ] **Step 4: Run both gate forms to verify they pass**

Run: `dart test packages/sim/test/banned_imports_test.dart` (from `packages/sim`)
Expected: PASS.

Run: `bash tooling/check_no_banned_imports.sh`
Expected: `PASS: packages/sim/lib is pure and determinism-safe.`

- [ ] **Step 5: Commit**

```bash
git add packages/sim/test/banned_imports_test.dart tooling/check_no_banned_imports.sh
git commit -m "test(sim): platform-purity + determinism-safety gate"
```

---

## Task 9: Replay harness + smoke fixture

**Files:**
- Create: `tooling/replay_harness.dart`, `tooling/replay_fixtures/smoke.json`

- [ ] **Step 1: Write the failing test (the harness is exercised by a runtime check, not a unit test)**

Create the committed fixture `tooling/replay_fixtures/smoke.json`:

```json
{
  "seed": 1337,
  "ticks": 300,
  "inputLog": {
    "0":  [{"playerSlot":0,"type":1,"aimX":655360,"aimY":131072,"seq":1,"clientTick":0},
           {"playerSlot":1,"type":1,"aimX":-655360,"aimY":131072,"seq":1,"clientTick":0}],
    "120":[{"playerSlot":0,"type":1,"aimX":0,"aimY":-262144,"seq":2,"clientTick":120}]
  }
}
```

- [ ] **Step 2: Verify there is no harness yet**

Run: `dart run tooling/replay_harness.dart`
Expected: FAIL — "Error when reading 'tooling/replay_harness.dart': No such file or directory".

- [ ] **Step 3: Write the harness**

`tooling/replay_harness.dart` (pure Dart; fixture injected at compile time so the same binary runs on native/js/wasm):

```dart
// Cross-platform deterministic replay harness. Prints exactly one line:
//   REPLAY_HASH <8-hex>
// The fixture is injected as a base64 -D define so all three runtimes read
// byte-identical input (no dart:io, so it compiles to js & wasm).
import 'dart:convert';

import 'package:sim/sim.dart';

const String _fixtureB64 = String.fromEnvironment('FIXTURE_JSON', defaultValue: '');

void main(List<String> args) {
  if (_fixtureB64.isEmpty) {
    throw StateError('no fixture: pass -DFIXTURE_JSON=<base64 of replay json>');
  }
  final fx = jsonDecode(utf8.decode(base64Decode(_fixtureB64))) as Map<String, dynamic>;
  final seed = (fx['seed'] as num).toInt();
  final ticks = (fx['ticks'] as num).toInt();
  final inputLog = _parseInputLog(fx['inputLog']);

  final sim = Simulation.create(SimConfig(seed: seed));
  final hasher = FnvHasher();
  for (var t = 0; t < ticks; t++) {
    sim.step(t, inputLog[t] ?? const <Intent>[]);
    hasher.addBytes(sim.canonicalBytes()); // chain every tick (catches mid-replay drift)
  }
  print('REPLAY_HASH ${hasher.hex8()}');
}

Map<int, List<Intent>> _parseInputLog(dynamic raw) {
  final map = <int, List<Intent>>{};
  if (raw == null) return map;
  (raw as Map<String, dynamic>).forEach((k, v) {
    final tick = int.parse(k);
    final list = <Intent>[
      for (final item in (v as List))
        Intent(
          playerSlot: ((item as Map<String, dynamic>)['playerSlot'] as num).toInt(),
          type: IntentType.values[(item['type'] as num).toInt()],
          aimX: (item['aimX'] as num?)?.toInt() ?? 0,
          aimY: (item['aimY'] as num?)?.toInt() ?? 0,
          seq: (item['seq'] as num?)?.toInt() ?? 0,
          clientTick: (item['clientTick'] as num?)?.toInt() ?? tick,
        ),
    ]..sort((a, b) =>
        a.playerSlot != b.playerSlot ? a.playerSlot - b.playerSlot : a.seq - b.seq);
    map[tick] = list;
  });
  return map;
}
```

- [ ] **Step 4: Run the harness natively**

Run (bash): `b64=$(base64 -w0 tooling/replay_fixtures/smoke.json) && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart`
Expected: a single line like `REPLAY_HASH 1a2b3c4d` (the exact hash is whatever this build produces — it gets pinned in Task 11).

- [ ] **Step 5: Commit**

```bash
git add tooling/replay_harness.dart tooling/replay_fixtures/smoke.json
git commit -m "feat(tooling): cross-platform replay harness + smoke fixture"
```

---

## Task 10: WASM Node host + 3-runtime compare driver

**Files:**
- Create: `tooling/wasm_entry.mjs`, `tooling/compare_replays.sh`

- [ ] **Step 1: Write the WASM Node host**

`tooling/wasm_entry.mjs` (uses the verified `compile`/`instantiate`/`invoke` API — there is no `.invokeMain()`):

```javascript
// Node ESM host for the dart2wasm output (replay_harness.wasm + .mjs loader).
import { readFileSync } from 'node:fs';
import { compile, instantiate, invoke } from './build/replay_harness.mjs';

const bytes = readFileSync(new URL('./build/replay_harness.wasm', import.meta.url));
invoke(await instantiate(await compile(bytes), {}));
```

- [ ] **Step 2: Write the compare driver**

`tooling/compare_replays.sh`:

```bash
#!/usr/bin/env bash
# Builds & runs tooling/replay_harness.dart on native, dart2js(node),
# dart2wasm(node); FAILS if the three REPLAY_HASH values are not identical.
# Also compares against a committed golden if present.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/tooling"
OUT="$TOOL/build"
FIXTURE="${1:-$TOOL/replay_fixtures/smoke.json}"
mkdir -p "$OUT"

B64="$(base64 -w0 "$FIXTURE" 2>/dev/null || base64 "$FIXTURE" | tr -d '\n')"
DEF="-DFIXTURE_JSON=$B64"

echo "==> [native]"
NATIVE="$(dart run "$DEF" "$TOOL/replay_harness.dart" | grep '^REPLAY_HASH ' | awk '{print $2}')"

echo "==> [js]"
dart compile js -O2 "$DEF" -o "$OUT/replay_harness.js" "$TOOL/replay_harness.dart" >/dev/null
JS="$(node "$OUT/replay_harness.js" | grep '^REPLAY_HASH ' | awk '{print $2}')"

echo "==> [wasm]"
dart compile wasm "$DEF" -o "$OUT/replay_harness.wasm" "$TOOL/replay_harness.dart" >/dev/null
WASM="$(node "$TOOL/wasm_entry.mjs" | grep '^REPLAY_HASH ' | awk '{print $2}')"

printf 'native : %s\njs     : %s\nwasm   : %s\n' "$NATIVE" "$JS" "$WASM"

if [ -z "$NATIVE" ] || [ -z "$JS" ] || [ -z "$WASM" ]; then
  echo "FAIL: a target produced no REPLAY_HASH" >&2; exit 2
fi
if [ "$NATIVE" != "$JS" ] || [ "$JS" != "$WASM" ]; then
  echo "FAIL: determinism divergence across runtimes" >&2; exit 1
fi
echo "PASS: byte-identical across native/js/wasm: $NATIVE"

GOLD="$TOOL/replay_fixtures/$(basename "${FIXTURE%.json}").golden"
if [ -f "$GOLD" ]; then
  if [ "$NATIVE" != "$(cat "$GOLD")" ]; then
    echo "FAIL: hash changed vs golden $GOLD (got $NATIVE)" >&2; exit 3
  fi
  echo "PASS: matches golden $GOLD"
fi
```

- [ ] **Step 3: Run the driver — the moment of truth (all three must match)**

Run (bash): `bash tooling/compare_replays.sh`
Expected: three identical hashes and `PASS: byte-identical across native/js/wasm: <hash>`.
**If they diverge:** the simulation has a non-determinism bug — do NOT pin a golden; binary-diff `canonicalBytes()` per tick to find the first divergent field, fix it (almost always a stray shift/double/HashMap-iteration), and re-run before proceeding.

- [ ] **Step 4: Make the scripts executable (CI/Linux)**

Run: `chmod +x tooling/compare_replays.sh tooling/check_no_banned_imports.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tooling/wasm_entry.mjs tooling/compare_replays.sh
git commit -m "feat(tooling): wasm node host + 3-runtime replay compare driver"
```

---

## Task 11: Pin the golden hash

**Files:**
- Create: `tooling/replay_fixtures/smoke.golden`

- [ ] **Step 1: Confirm a green 3-way run**

Run (bash): `bash tooling/compare_replays.sh`
Expected: `PASS: byte-identical across native/js/wasm: <hash>`.

- [ ] **Step 2: Capture the agreed hash into the golden file**

Run (bash): `b64=$(base64 -w0 tooling/replay_fixtures/smoke.json) && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart | awk '/^REPLAY_HASH /{print $2}' > tooling/replay_fixtures/smoke.golden`
Expected: `tooling/replay_fixtures/smoke.golden` now contains the single hash string.

- [ ] **Step 3: Verify the golden is now enforced**

Run (bash): `bash tooling/compare_replays.sh`
Expected: `PASS: byte-identical ...` followed by `PASS: matches golden .../smoke.golden`.

- [ ] **Step 4: Sanity-check the golden actually guards (optional, revert after)**

Temporarily change `_kWanderStep` in `simulation.dart` to `Fixed.fromNum(0.06)`, run `bash tooling/compare_replays.sh`, and confirm it now FAILS with `hash changed vs golden`. Then revert the change and confirm PASS again.

- [ ] **Step 5: Commit**

```bash
git add tooling/replay_fixtures/smoke.golden
git commit -m "test(tooling): pin replay golden hash"
```

---

## Task 12: CI workflow (the two gates)

**Files:**
- Create: `.github/workflows/sim-determinism.yml`

- [ ] **Step 1: Write the workflow**

`.github/workflows/sim-determinism.yml`:

```yaml
name: sim-determinism
on:
  push:
    branches: [main]
  pull_request:

jobs:
  purity-gate:
    name: packages/sim purity + determinism-safety
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with: { sdk: 3.11.5 }
      - run: dart pub get
      - run: dart analyze --fatal-infos --fatal-warnings
      - run: bash tooling/check_no_banned_imports.sh
      - run: dart test
        working-directory: packages/sim

  replay-golden:
    name: cross-platform replay golden (native + js + wasm)
    runs-on: ubuntu-latest
    needs: purity-gate
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with: { sdk: 3.11.5 }
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      - run: dart pub get
      - run: bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
```

- [ ] **Step 2: Validate the workflow locally (the commands it runs)**

Run: `dart pub get && dart analyze --fatal-infos --fatal-warnings`
Expected: `No issues found!`

Run (bash): `bash tooling/check_no_banned_imports.sh && (cd packages/sim && dart test) && bash tooling/compare_replays.sh`
Expected: all gates print PASS.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/sim-determinism.yml
git commit -m "ci: sim purity + cross-platform replay determinism gates"
```

- [ ] **Step 4: Push and confirm CI is green**

```bash
git push
```
Expected: on GitHub, the `sim-determinism` workflow runs both jobs and they pass.

- [ ] **Step 5: Update `.gitignore` for tooling build artifacts**

Append to `.gitignore`:

```
# tooling build output (compiled harness)
tooling/build/
```

```bash
git add .gitignore
git commit -m "chore: ignore tooling build output"
git push
```

---

## Self-Review

**Spec coverage (§8.1, §8.8, §11 gate 1 of the design doc):**
- Pure-Dart `sim` package, no platform deps → Tasks 0, 5–8 (+ purity gate Task 8). ✓
- Fixed-point determinism, seeded RNG, ordered iteration → Tasks 1, 3, 6. ✓
- Fixed-timestep `step()` + canonical encoder/hash → Tasks 4, 6. ✓
- Cross-platform replay golden test (native + JS + WASM) as the week-1 CI gate → Tasks 9–12. ✓
- Monorepo layout (`packages/sim`, `packages/protocol`, `tooling/`) → Task 0. ✓
- Deferred to later plans (correctly out of scope here): `apps/server`, `apps/client`, Flame, prediction/reconciliation, protocol wire encoding, combat/elemental systems. ✓

**Placeholder scan:** The only intentional "fill in after first run" values are the RNG regression vector (Task 3, Step 4) and the golden hash (Task 11) — both are *captured from a real run by design*, not guesses, and the steps say exactly how to obtain them. No `TODO`/`TBD` left.

**Type consistency:** `Fixed.raw`/`fromInt`/`fromNum`/`sqrt`/`floorToInt`, `floorDiv`, `FVec2(x,y)`/`scale`/`lengthSq`/`length`, `DetRng.fromInt`/`nextU32`/`nextInt`/`stateLo`/`stateHi`, `ByteWriter.i32`/`fixed`/`toBytes`, `FnvHasher.addBytes`/`addInt`/`hash`/`hex8`, `Entity{id,kind,teamId,pos,vel,hp,target}`, `Intent{playerSlot,type,aimX,aimY,seq,clientTick}`, `SimConfig{seed}`, `Simulation.create`/`step`/`entity`/`entityIdsSorted`/`canonicalBytes`/`canonicalStateHash` are used identically in every task that references them. The harness (Task 9) and tests consume exactly these signatures. ✓
