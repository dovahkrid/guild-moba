# Guild — Plan 2a: Netcode Core (Pure-Dart Predict/Reconcile, Headless) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build and *prove* — entirely in pure-Dart headless unit tests — the client-side prediction / server-reconciliation / opponent-interpolation netcode against the existing deterministic sim, smooth under 150 ms latency + packet loss. No sockets, no Flutter (those are Plan 2b).

**Architecture:** Three additive pieces. (A) `packages/sim` gains a restorable snapshot path (`ByteReader`, `DetRng.fromState`, `snapshotBytes()`/`restoreFromSnapshot()`, `peekEntityPos()`) — leaving the Plan-1 determinism golden (`canonicalBytes()`, hash `0xa00d6337`, replay golden `caf9858f`) **untouched**. (B) `packages/protocol` gains the wire messages + one `ProtocolCodec`. (C) a new pure-Dart `packages/netcode` holds `MatchController` (predict/reconcile/interpolate) + `InterpolationBuffer` + `MatchView` + a `FakeTransport` test harness (virtual integer-ms clock, injectable latency/loss) that drives a server `Simulation` against the controller and asserts convergence.

**Tech Stack:** Dart 3.11.5, `package:test`, `dart:typed_data`. No third-party runtime deps. Everything stays pure (no `dart:io`/`flutter`/`flame`/`DateTime`/`Random`).

---

## The Tick Contract (read first — every task depends on it)

- The sim advances at a fixed **30 Hz**. Authoritative **tick N is the state AFTER `sim.step(N, intents)`**. The first tick is **N = 0 on both server and client** (seed the client from `MatchStartMsg.startTick`, which is 0 for the slice).
- Client loop: `advanceClientTick()` does `_predicted.step(_nextTick, held); _nextTick++;` — so after stepping, the client has *completed* ticks `0 .. _nextTick-1`.
- A server `SnapshotMsg.serverTick` equals the `N` that produced it.
- **Reconcile:** restore predicted sim to `serverTick` (so `_predicted.tick == serverTick`), then re-step `t = serverTick+1 .. _nextTick-1`, applying the local held intent in effect at each `t`.
- **Snapshot cadence: 20 Hz via the predicate `(tick % 3) < 2`** — this exact predicate lives in shared code and is used by *both* the server (Plan 2b) and `FakeTransport`, so the harness exercises what production emits.
- **Correction is BOUNDED, not zero.** Because the server applies a click ~2 ticks after the client predicted it, during travel the local hero leads truth by a bounded amount (≈ unacked-in-flight ticks × the per-tick step, well under 0.5 world units at 150 ms), collapsing to **exactly 0 at steady state**. Tests assert: steady-state correction `== 0` (the determinism proof); in-motion correction stays `< 0.5` and does not grow. **Never assert `== 0` in motion.**
- **Frames are binary only.** Anything that decodes a frame throws on a `String` (never silently `codeUnits`-convert).

---

## File Structure

**`packages/sim` (modify):**
- `lib/src/state/byte_writer.dart` — add `ByteWriter.bytes(List<int>)`; add `ByteReader` (ByteData-backed).
- `lib/src/math/det_rng.dart` — add `DetRng.fromState(int lo, int hi)`.
- `lib/src/simulation.dart` — make `_rng` non-final; add `snapshotBytes()`, `restoreFromSnapshot(Uint8List)`, `static FVec2 peekEntityPos(Uint8List, int id)`; add `const kSnapshotVersion = 1`.
- Tests: `test/byte_reader_test.dart`, `test/snapshot_test.dart` (+ extend `det_rng_test.dart`).

**`packages/protocol` (build out the stub):**
- `lib/src/messages.dart` — sealed `Msg` + `MatchStartMsg`, `InputMsg`, `SnapshotMsg`, `MatchEndMsg`, `EndReason`.
- `lib/src/codec.dart` — `ProtocolCodec.encode/decode` (1-byte tag + ByteWriter/ByteReader).
- `lib/protocol.dart` — barrel. Tests: `test/codec_test.dart`.

**`packages/netcode` (new pure-Dart package; add to root `workspace:`):**
- `pubspec.yaml`, `lib/netcode.dart` (barrel).
- `lib/src/match_view.dart` — `MatchView`, `RenderEntity` (doubles only).
- `lib/src/interpolation_buffer.dart` — `InterpolationBuffer`.
- `lib/src/snapshot_cadence.dart` — `bool shouldSnapshot(int tick)` (the shared `(tick%3)<2` predicate).
- `lib/src/match_controller.dart` — `MatchController`.
- `lib/test_support/fake_transport.dart` — `FakeTransport` (shipped in lib/test_support so tests in any package can reuse it).
- Tests: `test/banned_imports_test.dart`, `test/interpolation_buffer_test.dart`, `test/match_controller_test.dart`, `test/netcode_integration_test.dart` (the 9 cases).

**Root (modify):** `pubspec.yaml` (`workspace:` + `dependencies:` add `protocol`, `netcode`); `.github/workflows/sim-determinism.yml` (run protocol + netcode tests, incl. `-p node`/`-c dart2wasm`).

---

## Task 1: `ByteReader` + `ByteWriter.bytes()`

**Files:** Modify `packages/sim/lib/src/state/byte_writer.dart`; Test `packages/sim/test/byte_reader_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/sim/test/byte_reader_test.dart`:

```dart
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `dart test packages/sim/test/byte_reader_test.dart`
Expected: FAIL — `ByteReader` undefined; `bytes` not defined on `ByteWriter`.

- [ ] **Step 3: Implement**

Append to `packages/sim/lib/src/state/byte_writer.dart` (keep existing `ByteWriter`, `mul32`, `FnvHasher`). Add `bytes` to `ByteWriter` and a new `ByteReader`:

```dart
// Add this method inside the existing ByteWriter class:
//   void bytes(List<int> raw) => _b.add(raw is Uint8List ? raw : Uint8List.fromList(raw));

/// Mirror of ByteWriter. Uses ByteData (typed-data getters are cross-runtime
/// deterministic, unlike Dart's `<<` which is signed-32-bit on dart2js).
class ByteReader {
  final ByteData _bd;
  int _off = 0;
  ByteReader(Uint8List bytes)
      : _bd = ByteData.sublistView(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

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
```

Add the `bytes` method to `ByteWriter` (place after `fixed`):

```dart
  void bytes(List<int> raw) =>
      _b.add(raw is Uint8List ? raw : Uint8List.fromList(raw));
```

Ensure `import '../math/fixed.dart';` exists (it already does for `ByteWriter.fixed`).

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/byte_reader_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/state/byte_writer.dart packages/sim/test/byte_reader_test.dart
git commit -m "feat(sim): ByteReader + ByteWriter.bytes for snapshot decode"
```

---

## Task 2: `DetRng.fromState` (verbatim limb restore)

**Files:** Modify `packages/sim/lib/src/math/det_rng.dart`; Test extend `packages/sim/test/det_rng_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `packages/sim/test/det_rng_test.dart`:

```dart
  test('fromState restores raw limbs verbatim (resumes identical sequence)', () {
    final a = DetRng.fromInt(1337);
    a.nextU32();
    a.nextU32();
    final lo = a.stateLo, hi = a.stateHi;
    final tail = [a.nextU32(), a.nextU32(), a.nextU32()];

    final restored = DetRng.fromState(lo, hi);
    expect([restored.nextU32(), restored.nextU32(), restored.nextU32()], tail);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `dart test packages/sim/test/det_rng_test.dart`
Expected: FAIL — `DetRng.fromState` not defined.

- [ ] **Step 3: Implement**

In `packages/sim/lib/src/math/det_rng.dart`, add a constructor to `DetRng` (next to `fromLimbs`/`fromInt`):

```dart
  /// Restore raw internal state verbatim — NO _step(), NO seed mixing.
  /// (fromLimbs/fromInt advance + mix and so cannot resume an exact state.)
  /// Required for exact reconciliation re-stepping (the wanderer is RNG-driven).
  DetRng.fromState(int lo, int hi)
      : _sLo = lo,
        _sHi = hi;
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/det_rng_test.dart`
Expected: PASS (all prior + the new test).

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/math/det_rng.dart packages/sim/test/det_rng_test.dart
git commit -m "feat(sim): DetRng.fromState for exact RNG restore"
```

---

## Task 3: `snapshotBytes()` / `restoreFromSnapshot()` / `peekEntityPos()`

**Files:** Modify `packages/sim/lib/src/simulation.dart`; Test `packages/sim/test/snapshot_test.dart`

This is the netcode wire+restore format. It is a **superset** of `canonicalBytes()` that additionally encodes `Entity.target`. `canonicalBytes()`, the pinned hash `0xa00d6337`, and the replay golden stay **untouched**.

- [ ] **Step 1: Write the failing test**

`packages/sim/test/snapshot_test.dart`:

```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

Simulation _run(int ticks) {
  final s = Simulation.create(const SimConfig(seed: 1337));
  const m0 = Intent(playerSlot: 0, type: IntentType.move, aimX: 655360, aimY: 131072, seq: 1);
  const m1 = Intent(playerSlot: 1, type: IntentType.move, aimX: -655360, aimY: 131072, seq: 1);
  for (var t = 0; t < ticks; t++) {
    s.step(t, [m0, m1]);
  }
  return s;
}

void main() {
  test('restoreFromSnapshot reproduces full state incl. tick, RNG, target', () {
    final src = _run(120);
    final dst = Simulation.create(const SimConfig(seed: 1337)); // different state
    dst.step(0, const []);

    dst.restoreFromSnapshot(src.snapshotBytes());

    // Canonical hash (pos/vel/hp/tick/rng) must match exactly.
    expect(dst.canonicalStateHash(), src.canonicalStateHash());
    expect(dst.tick, src.tick);
    // Target restored: stepping both one more tick with no intent stays in lockstep.
    src.step(120, const []);
    dst.step(120, const []);
    expect(dst.canonicalStateHash(), src.canonicalStateHash());
  });

  test('snapshot round-trips through bytes and continues deterministically', () {
    final src = _run(90);
    final bytes = src.snapshotBytes();
    final dst = Simulation.create(const SimConfig(seed: 1337))..restoreFromSnapshot(bytes);
    for (var t = 90; t < 200; t++) {
      src.step(t, const []);
      dst.step(t, const []);
    }
    expect(dst.canonicalStateHash(), src.canonicalStateHash());
  });

  test('peekEntityPos reads an entity pos from snapshot bytes', () {
    final src = _run(60);
    final bytes = src.snapshotBytes();
    final p1 = Simulation.peekEntityPos(bytes, 1);
    expect(p1.x.raw, src.entity(1).pos.x.raw);
    expect(p1.y.raw, src.entity(1).pos.y.raw);
  });

  test('canonicalBytes/hash unchanged (golden untouched)', () {
    expect(_run(300).canonicalStateHash(), 0xa00d6337);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `dart test packages/sim/test/snapshot_test.dart`
Expected: FAIL — `snapshotBytes`, `restoreFromSnapshot`, `peekEntityPos` undefined.

- [ ] **Step 3: Implement**

In `packages/sim/lib/src/simulation.dart`:

1. Change `final DetRng _rng;` to `DetRng _rng;` (non-final, so restore can swap it).
2. Add `const int kSnapshotVersion = 1;` near `kSchemaVersion`.
3. Add these members to `Simulation` (the snapshot format mirrors `canonicalBytes()` field order, then appends `target.x`, `target.y` per entity):

```dart
  /// Netcode wire + restore format. Superset of canonicalBytes() that also
  /// carries Entity.target so reconciliation can resume authoritative seeking
  /// (esp. the opponent's target, which the client cannot re-derive). Distinct
  /// from canonicalBytes() so the Plan-1 determinism golden stays fixed.
  Uint8List snapshotBytes() {
    final w = ByteWriter();
    w.i32(kSnapshotVersion);
    w.i32(tick);
    w.u32(_rng.stateLo);
    w.u32(_rng.stateHi);
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
      w.fixed(e.target.x);
      w.fixed(e.target.y);
    }
    return w.toBytes();
  }

  /// Overwrite this sim's entire state from snapshotBytes(). Reuses the existing
  /// Entity instances (ids are stable from create()). FVec2 is immutable, so we
  /// reassign Entity.pos/vel/target (all mutable fields).
  void restoreFromSnapshot(Uint8List bytes) {
    final r = ByteReader(bytes);
    final version = r.i32();
    assert(version == kSnapshotVersion, 'snapshot version $version');
    tick = r.i32();
    final lo = r.u32();
    final hi = r.u32();
    _rng = DetRng.fromState(lo, hi);
    final count = r.i32();
    for (var i = 0; i < count; i++) {
      final id = r.i32();
      r.i32(); // kind.index (stable; advance cursor)
      r.i32(); // teamId (stable)
      final e = _byId[id]!;
      e.pos = FVec2(r.fixed(), r.fixed());
      e.vel = FVec2(r.fixed(), r.fixed());
      e.hp = r.fixed();
      e.target = FVec2(r.fixed(), r.fixed());
    }
  }

  /// Decode just one entity's pos from snapshotBytes() (for the interpolation
  /// buffer) without allocating a Simulation.
  static FVec2 peekEntityPos(Uint8List bytes, int id) {
    final r = ByteReader(bytes);
    r.i32(); // version
    r.i32(); // tick
    r.u32(); // rng lo
    r.u32(); // rng hi
    final count = r.i32();
    for (var i = 0; i < count; i++) {
      final eid = r.i32();
      r.i32(); // kind
      r.i32(); // team
      final pos = FVec2(r.fixed(), r.fixed());
      r.fixed(); r.fixed(); // vel
      r.fixed(); // hp
      r.fixed(); r.fixed(); // target
      if (eid == id) return pos;
    }
    throw ArgumentError('entity $id not in snapshot');
  }
```

Confirm `import 'dart:typed_data';`, the `state/byte_writer.dart` import (for `ByteReader`), and `math/det_rng.dart` import are present in `simulation.dart`.

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/snapshot_test.dart`
Expected: PASS (4 tests, incl. the golden-untouched check `0xa00d6337`).

Run: `dart test packages/sim` — confirm ALL prior sim tests still pass and `dart analyze` is clean.

- [ ] **Step 5: Commit**

```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/snapshot_test.dart
git commit -m "feat(sim): snapshotBytes/restoreFromSnapshot/peekEntityPos (netcode restore path)"
```

---

## Task 4: `protocol` messages + `ProtocolCodec`

**Files:** Create `packages/protocol/lib/src/messages.dart`, `packages/protocol/lib/src/codec.dart`; modify `packages/protocol/lib/protocol.dart`; Test `packages/protocol/test/codec_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/protocol/test/codec_test.dart`:

```dart
import 'dart:typed_data';
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  T roundTrip<T extends Msg>(T msg) =>
      ProtocolCodec.decode(ProtocolCodec.encode(msg)) as T;

  test('MatchStartMsg round-trips', () {
    final m = roundTrip(const MatchStartMsg(
        yourSlot: 1, seed: 1337, tickRateHz: 30, snapshotRateHz: 20, startTick: 0));
    expect(m.yourSlot, 1);
    expect(m.seed, 1337);
    expect(m.tickRateHz, 30);
    expect(m.snapshotRateHz, 20);
    expect(m.startTick, 0);
  });

  test('InputMsg round-trips', () {
    final m = roundTrip(const InputMsg(
        slot: 0, seq: 7, clientTick: 42, aimX: 655360, aimY: -131072, type: 1));
    expect(m.slot, 0);
    expect(m.seq, 7);
    expect(m.clientTick, 42);
    expect(m.aimX, 655360);
    expect(m.aimY, -131072);
    expect(m.type, 1);
  });

  test('SnapshotMsg round-trips incl. raw stateBytes', () {
    final state = Uint8List.fromList(List.generate(40, (i) => i));
    final m = roundTrip(SnapshotMsg(serverTick: 99, ackedSeq: const [3, 5], stateBytes: state));
    expect(m.serverTick, 99);
    expect(m.ackedSeq, [3, 5]);
    expect(m.stateBytes, state);
  });

  test('MatchEndMsg round-trips reason', () {
    final m = roundTrip(const MatchEndMsg(reason: EndReason.opponentLeft));
    expect(m.reason, EndReason.opponentLeft);
  });

  test('decode throws on a text frame', () {
    expect(() => ProtocolCodec.decode('not bytes'), throwsArgumentError);
  });

  test('InputMsg golden bytes are stable', () {
    final bytes = ProtocolCodec.encode(const InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 65536, aimY: 0, type: 1));
    // tag(1)=0x02, then i32 LE: slot,seq,clientTick,aimX,aimY,type
    expect(bytes, [
      0x02,
      0,0,0,0,        // slot 0
      1,0,0,0,        // seq 1
      0,0,0,0,        // clientTick 0
      0,0,1,0,        // aimX 65536
      0,0,0,0,        // aimY 0
      1,0,0,0,        // type 1
    ]);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `dart test packages/protocol/test/codec_test.dart`
Expected: FAIL — `protocol` symbols undefined.

- [ ] **Step 3: Implement**

`packages/protocol/lib/src/messages.dart`:

```dart
import 'dart:typed_data';

enum EndReason { opponentLeft, roomFull, serverShutdown }

/// Wire messages. Integer-only fields (Q16.16 raws for aim). Sealed so the
/// codec switch is exhaustive.
sealed class Msg {
  const Msg();
}

class MatchStartMsg extends Msg {
  final int yourSlot, seed, tickRateHz, snapshotRateHz, startTick;
  const MatchStartMsg({
    required this.yourSlot,
    required this.seed,
    required this.tickRateHz,
    required this.snapshotRateHz,
    required this.startTick,
  });
}

class InputMsg extends Msg {
  final int slot, seq, clientTick, aimX, aimY, type;
  const InputMsg({
    required this.slot,
    required this.seq,
    required this.clientTick,
    required this.aimX,
    required this.aimY,
    required this.type,
  });
}

class SnapshotMsg extends Msg {
  final int serverTick;
  final List<int> ackedSeq; // length 2: [slot0, slot1]
  final Uint8List stateBytes; // Simulation.snapshotBytes()
  const SnapshotMsg({
    required this.serverTick,
    required this.ackedSeq,
    required this.stateBytes,
  });
}

class MatchEndMsg extends Msg {
  final EndReason reason;
  const MatchEndMsg({required this.reason});
}
```

`packages/protocol/lib/src/codec.dart`:

```dart
import 'dart:typed_data';
import 'package:sim/sim.dart'; // ByteWriter, ByteReader

import 'messages.dart';

/// Single binary codec shared by server, client, and FakeTransport.
/// 1-byte type tag + ByteWriter/ByteReader. Binary frames only.
class ProtocolCodec {
  static const int _tagMatchStart = 1;
  static const int _tagInput = 2;
  static const int _tagSnapshot = 3;
  static const int _tagMatchEnd = 4;

  static Uint8List encode(Msg msg) {
    final w = ByteWriter();
    switch (msg) {
      case MatchStartMsg m:
        w.i32(_tagMatchStartByte());
        w.i32(m.yourSlot);
        w.i32(m.seed);
        w.i32(m.tickRateHz);
        w.i32(m.snapshotRateHz);
        w.i32(m.startTick);
      case InputMsg m:
        w.bytes([_tagInput]);
        w.i32(m.slot);
        w.i32(m.seq);
        w.i32(m.clientTick);
        w.i32(m.aimX);
        w.i32(m.aimY);
        w.i32(m.type);
      case SnapshotMsg m:
        w.bytes([_tagSnapshot]);
        w.i32(m.serverTick);
        w.i32(m.ackedSeq[0]);
        w.i32(m.ackedSeq[1]);
        w.i32(m.stateBytes.length);
        w.bytes(m.stateBytes);
      case MatchEndMsg m:
        w.bytes([_tagMatchEnd]);
        w.i32(m.reason.index);
    }
    return w.toBytes();
  }

  // NOTE: tag is written as a single byte; see fix in Step 3b.
  static int _tagMatchStartByte() => _tagMatchStart;

  static Msg decode(Object frame) {
    if (frame is! List<int>) {
      throw ArgumentError('protocol frames must be binary, got ${frame.runtimeType}');
    }
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
    final tag = bytes[0];
    final r = ByteReader(Uint8List.sublistView(bytes, 1));
    switch (tag) {
      case _tagMatchStart:
        return MatchStartMsg(
            yourSlot: r.i32(), seed: r.i32(), tickRateHz: r.i32(),
            snapshotRateHz: r.i32(), startTick: r.i32());
      case _tagInput:
        return InputMsg(
            slot: r.i32(), seq: r.i32(), clientTick: r.i32(),
            aimX: r.i32(), aimY: r.i32(), type: r.i32());
      case _tagSnapshot:
        final st = r.i32();
        final a0 = r.i32();
        final a1 = r.i32();
        final len = r.i32();
        return SnapshotMsg(serverTick: st, ackedSeq: [a0, a1], stateBytes: r.bytes(len));
      case _tagMatchEnd:
        return MatchEndMsg(reason: EndReason.values[r.i32()]);
      default:
        throw ArgumentError('unknown protocol tag $tag');
    }
  }
}
```

- [ ] **Step 3b: Fix the tag write to be a single byte**

The `MatchStartMsg` branch above writes the tag via `w.i32(...)` (4 bytes) while others use `w.bytes([tag])` (1 byte) — inconsistent. Make ALL branches write the tag as one byte. Replace the `MatchStartMsg` tag line with `w.bytes([_tagMatchStart]);` and delete `_tagMatchStartByte()`. (The golden-bytes test pins the 1-byte tag, so this must be consistent.) Re-read the encode method and ensure every branch's first statement is `w.bytes([_tag...]);`.

`packages/protocol/lib/protocol.dart`:

```dart
/// Wire protocol for Guild netcode.
library;

export 'src/messages.dart';
export 'src/codec.dart';
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/protocol` and `dart analyze`
Expected: PASS (6 tests); analyze clean.

- [ ] **Step 5: Commit**

```bash
git add packages/protocol/lib packages/protocol/test/codec_test.dart
git commit -m "feat(protocol): wire messages + binary ProtocolCodec"
```

---

## Task 5: `netcode` package scaffold + purity gate + render types

**Files:** Create `packages/netcode/pubspec.yaml`, `lib/netcode.dart`, `lib/src/match_view.dart`, `lib/src/snapshot_cadence.dart`, `test/banned_imports_test.dart`; modify root `pubspec.yaml`

- [ ] **Step 1: Add the package to the workspace + write the purity test**

Modify root `pubspec.yaml`: add `packages/netcode` to `workspace:` and add `netcode: {path: packages/netcode}` and `protocol: {path: packages/protocol}` under `dependencies:` (so root-owned tooling/tests resolve them).

`packages/netcode/pubspec.yaml`:

```yaml
name: netcode
description: Pure-Dart client-side prediction/reconciliation/interpolation (headless).
publish_to: none
version: 0.0.1
environment:
  sdk: ^3.6.0
resolution: workspace
dependencies:
  sim:
    path: ../sim
  protocol:
    path: ../protocol
dev_dependencies:
  test: ^1.25.0
```

`packages/netcode/test/banned_imports_test.dart` — copy `packages/sim/test/banned_imports_test.dart` verbatim (including `@TestOn('vm')` and the `_findPackageRoot` helper), so `packages/netcode/lib` is held to the same purity (no flutter/flame/dart:io/dart:ui, no Random/DateTime).

- [ ] **Step 2: Run to verify it fails**

Run: `dart pub get` then `dart test packages/netcode/test/banned_imports_test.dart`
Expected: FAIL initially only if lib is missing; create the lib files in Step 3, then it passes (empty lib is trivially pure).

- [ ] **Step 3: Implement render types + cadence + barrel**

`packages/netcode/lib/src/snapshot_cadence.dart`:

```dart
/// THE shared 20 Hz snapshot predicate — used by both the server (Plan 2b) and
/// the FakeTransport test harness so the harness exercises production cadence.
/// 30 Hz ticks, emit on (tick % 3) < 2 => 20 snapshots / 30 ticks.
bool shouldSnapshot(int tick) => (tick % 3) < 2;
```

`packages/netcode/lib/src/match_view.dart`:

```dart
/// Render-boundary value types. Doubles ONLY (never fed back into the sim).
class RenderEntity {
  final double x, y;
  const RenderEntity(this.x, this.y);
}

class MatchView {
  final RenderEntity local;
  final RenderEntity opponent;
  final RenderEntity wanderer;
  final int predictedTick;
  final int lastServerTick;
  final int pendingInputCount;
  final double lastCorrectionDist; // world units corrected on the last reconcile
  const MatchView({
    required this.local,
    required this.opponent,
    required this.wanderer,
    required this.predictedTick,
    required this.lastServerTick,
    required this.pendingInputCount,
    required this.lastCorrectionDist,
  });
}
```

`packages/netcode/lib/netcode.dart`:

```dart
/// Pure-Dart netcode: prediction, reconciliation, interpolation.
library;

export 'src/match_view.dart';
export 'src/snapshot_cadence.dart';
export 'src/interpolation_buffer.dart';
export 'src/match_controller.dart';
```

(The two exports for files created in Tasks 6–7 will dangle until then; that's fine — add them now so the barrel is complete, and ensure Task 6/7 create those files before running `dart test packages/netcode`.)

- [ ] **Step 4: Run to verify purity passes**

Run: `dart test packages/netcode/test/banned_imports_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/netcode/pubspec.yaml packages/netcode/lib/src/snapshot_cadence.dart packages/netcode/lib/src/match_view.dart packages/netcode/lib/netcode.dart packages/netcode/test/banned_imports_test.dart pubspec.yaml
git commit -m "feat(netcode): scaffold pure-Dart package + purity gate + render types"
```

---

## Task 6: `InterpolationBuffer`

**Files:** Create `packages/netcode/lib/src/interpolation_buffer.dart`; Test `packages/netcode/test/interpolation_buffer_test.dart`

Holds recent opponent positions keyed by `serverTick`, deduped, sampled ~100 ms in the past. Output is doubles (render-only). Snapshot logical time = `serverTick * _dtMs` with `_dtMs = 33`.

- [ ] **Step 1: Write the failing test**

`packages/netcode/test/interpolation_buffer_test.dart`:

```dart
import 'package:netcode/netcode.dart';
import 'package:test/test.dart';

void main() {
  test('lerps on the segment between two bracketing snapshots', () {
    final b = InterpolationBuffer()
      ..add(0, 0, 0)      // serverTick 0 -> time 0ms, pos (0,0)
      ..add(3, 99, 0);    // serverTick 3 -> time 99ms, pos (99,0)
    // sample at 49.5ms -> halfway
    final p = b.sample(49);
    expect(p.x, closeTo(49.0, 1.0));
    expect(p.y, 0.0);
  });

  test('holds at newest when target is past the last snapshot (no extrapolation)', () {
    final b = InterpolationBuffer()..add(0, 0, 0)..add(3, 30, 0);
    final p = b.sample(10_000); // far future
    expect(p.x, 30.0);
  });

  test('holds at oldest when target precedes the first snapshot', () {
    final b = InterpolationBuffer()..add(3, 30, 0)..add(6, 60, 0);
    final p = b.sample(0);
    expect(p.x, 30.0);
  });

  test('dedupes by serverTick (duplicate add is a no-op)', () {
    final b = InterpolationBuffer()..add(3, 30, 0)..add(3, 999, 0);
    expect(b.length, 1);
  });

  test('ignores out-of-order older serverTick', () {
    final b = InterpolationBuffer()..add(6, 60, 0)..add(3, 30, 0);
    expect(b.length, 1); // the stale tick 3 after 6 is dropped
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `dart test packages/netcode/test/interpolation_buffer_test.dart`
Expected: FAIL — `InterpolationBuffer` undefined.

- [ ] **Step 3: Implement**

`packages/netcode/lib/src/interpolation_buffer.dart`:

```dart
import 'match_view.dart';

class _Sample {
  final int tick;
  final int timeMs;
  final double x, y;
  const _Sample(this.tick, this.timeMs, this.x, this.y);
}

/// Opponent interpolation buffer. Logical time = serverTick * dtMs. Render-only
/// doubles; never extrapolates (holds at the newest sample under loss).
class InterpolationBuffer {
  static const int dtMs = 33; // ~1/30s, integer; matches the shared tick clock
  final List<_Sample> _samples = []; // ascending tick, capped
  static const int _cap = 64;
  int _newestTick = -1;

  void add(int serverTick, double x, double y) {
    if (serverTick <= _newestTick) return; // dedupe + drop stale
    _newestTick = serverTick;
    _samples.add(_Sample(serverTick, serverTick * dtMs, x, y));
    if (_samples.length > _cap) _samples.removeAt(0);
  }

  int get length => _samples.length;

  /// Sample the opponent position at logical time [targetTimeMs].
  RenderEntity sample(int targetTimeMs) {
    if (_samples.isEmpty) return const RenderEntity(0, 0);
    if (targetTimeMs <= _samples.first.timeMs) {
      final s = _samples.first;
      return RenderEntity(s.x, s.y);
    }
    if (targetTimeMs >= _samples.last.timeMs) {
      final s = _samples.last; // HOLD — never extrapolate
      return RenderEntity(s.x, s.y);
    }
    for (var i = 0; i < _samples.length - 1; i++) {
      final a = _samples[i], b = _samples[i + 1];
      if (targetTimeMs >= a.timeMs && targetTimeMs <= b.timeMs) {
        final span = (b.timeMs - a.timeMs);
        final alpha = span == 0 ? 0.0 : (targetTimeMs - a.timeMs) / span;
        return RenderEntity(a.x + (b.x - a.x) * alpha, a.y + (b.y - a.y) * alpha);
      }
    }
    final s = _samples.last;
    return RenderEntity(s.x, s.y);
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/netcode/test/interpolation_buffer_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/netcode/lib/src/interpolation_buffer.dart packages/netcode/test/interpolation_buffer_test.dart
git commit -m "feat(netcode): opponent InterpolationBuffer (hold, no extrapolation)"
```

---

## Task 7: `MatchController` (predict / reconcile)

**Files:** Create `packages/netcode/lib/src/match_controller.dart`; Test `packages/netcode/test/match_controller_test.dart`

Implements the Tick Contract. `_nextTick` starts at 0; stepping does `step(_nextTick); _nextTick++`. `_pending` is an ordered list of `(clientTick, Intent)`; the "held" local intent at tick `t` is the latest pending whose `clientTick <= t`.

- [ ] **Step 1: Write the failing test**

`packages/netcode/test/match_controller_test.dart`:

```dart
import 'package:netcode/netcode.dart';
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';
import 'package:test/test.dart';

MatchController _ctrl({int slot = 0}) => MatchController(
    seed: 1337, localSlot: slot, startTick: 0);

void main() {
  test('predicts local hero immediately (moves within a few ticks of input)', () {
    final c = _ctrl();
    final startX = c.debugLocalPos().x.raw;
    c.applyLocalInput(655360, 0); // move right
    for (var i = 0; i < 10; i++) {
      c.advanceClientTick();
    }
    expect(c.debugLocalPos().x.raw, greaterThan(startX));
  });

  test('tick contract: first step is tick 0, _nextTick advances', () {
    final c = _ctrl();
    expect(c.predictedTick, 0); // nothing stepped yet
    c.advanceClientTick();
    expect(c.predictedTick, 1); // completed tick 0, next is 1
  });

  test('applyLocalInput returns an InputMsg stamped with the local slot+seq', () {
    final c = _ctrl(slot: 1);
    final msg = c.applyLocalInput(0, 262144);
    expect(msg.slot, 1);
    expect(msg.seq, 1);
    expect(msg.type, IntentType.move.index);
    expect(msg.aimY, 262144);
  });

  test('reconcile to a fresh snapshot with no pending leaves no correction', () {
    // Build an authoritative sim that advanced identically with no input.
    final server = Simulation.create(const SimConfig(seed: 1337));
    final c = _ctrl();
    for (var t = 0; t < 5; t++) {
      server.step(t, const []);
      c.advanceClientTick();
    }
    final snap = SnapshotMsg(
        serverTick: 4, ackedSeq: const [0, 0], stateBytes: server.snapshotBytes());
    c.onServerSnapshot(snap);
    expect(c.lastCorrectionDist, 0.0); // exact at steady state, no pending
    expect(c.debugHash(), server.canonicalStateHash());
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `dart test packages/netcode/test/match_controller_test.dart`
Expected: FAIL — `MatchController` undefined.

- [ ] **Step 3: Implement**

`packages/netcode/lib/src/match_controller.dart`:

```dart
import 'dart:math' as math; // sqrt is allowed HERE (render-only correction dist, not sim state)
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

import 'interpolation_buffer.dart';
import 'match_view.dart';

class _Pending {
  final int clientTick;
  final Intent intent;
  const _Pending(this.clientTick, this.intent);
}

/// Owns the predicted sim + prediction/reconciliation/interpolation. Pure: the
/// HOST drives advanceClientTick() (per 33ms) and update(renderMs) (per frame).
class MatchController {
  final int localSlot;
  final Simulation _predicted;
  final InterpolationBuffer _interp = InterpolationBuffer();

  int _nextTick; // next tick to step; completed up to _nextTick-1
  int _localSeq = 0;
  final List<_Pending> _pending = []; // ordered by (clientTick, seq)
  int _lastReconciledServerTick = -1;
  double _lastCorrectionDist = 0.0;

  MatchController({required int seed, required this.localSlot, required int startTick})
      : _predicted = Simulation.create(SimConfig(seed: seed)),
        _nextTick = startTick;

  int get predictedTick => _nextTick;
  int get lastServerTick => _lastReconciledServerTick;
  int get pendingCount => _pending.length;
  double get lastCorrectionDist => _lastCorrectionDist;

  // --- test seams ---
  int debugHash() => _predicted.canonicalStateHash();
  FVec2 debugLocalPos() => _predicted.entity(localSlot).pos;

  /// Record + apply a local move. Returns the InputMsg the host must send.
  InputMsg applyLocalInput(int aimX, int aimY) {
    final seq = ++_localSeq;
    final intent = Intent(
        playerSlot: localSlot, type: IntentType.move,
        aimX: aimX, aimY: aimY, seq: seq, clientTick: _nextTick);
    _pending.add(_Pending(_nextTick, intent));
    return InputMsg(
        slot: localSlot, seq: seq, clientTick: _nextTick,
        aimX: aimX, aimY: aimY, type: IntentType.move.index);
  }

  /// The held local intent in effect at tick [t] = latest pending with clientTick <= t.
  Intent? _heldAt(int t) {
    Intent? held;
    for (final p in _pending) {
      if (p.clientTick <= t) held = p.intent; else break;
    }
    return held;
  }

  /// Advance the predicted sim one tick (host calls at 30Hz).
  void advanceClientTick() {
    final held = _heldAt(_nextTick);
    _predicted.step(_nextTick, held == null ? const [] : [held]);
    _nextTick++;
  }

  /// Reconcile to an authoritative snapshot.
  void onServerSnapshot(SnapshotMsg snap) {
    // Interpolation always sees fresh ticks (dedupe handled inside).
    final opp = Simulation.peekEntityPos(snap.stateBytes, 1 - localSlot);
    _interp.add(snap.serverTick, opp.x.toDouble(), opp.y.toDouble());

    if (snap.serverTick <= _lastReconciledServerTick) return; // stale/dup guard

    // Pre-reconcile local pos (for correction distance).
    final before = _predicted.entity(localSlot).pos;

    // Drop acked pending intents.
    final acked = snap.ackedSeq[localSlot];
    _pending.removeWhere((p) => p.intent.seq <= acked);

    // Restore to authoritative state, then re-step to "now".
    _predicted.restoreFromSnapshot(snap.stateBytes);
    for (var t = snap.serverTick + 1; t < _nextTick; t++) {
      final held = _heldAt(t);
      _predicted.step(t, held == null ? const [] : [held]);
    }

    final after = _predicted.entity(localSlot).pos;
    final dx = (after.x - before.x).toDouble();
    final dy = (after.y - before.y).toDouble();
    _lastCorrectionDist = math.sqrt(dx * dx + dy * dy);
    _lastReconciledServerTick = snap.serverTick;
  }

  /// Render view (host calls per frame). Opponent interpolated ~100ms behind.
  MatchView update(int renderTimeMs) {
    final local = _predicted.entity(localSlot).pos;
    final wanderer = _predicted.entity(2).pos;
    final opp = _interp.sample(renderTimeMs - 100);
    return MatchView(
      local: RenderEntity(local.x.toDouble(), local.y.toDouble()),
      opponent: opp,
      wanderer: RenderEntity(wanderer.x.toDouble(), wanderer.y.toDouble()),
      predictedTick: _nextTick,
      lastServerTick: _lastReconciledServerTick,
      pendingInputCount: _pending.length,
      lastCorrectionDist: _lastCorrectionDist,
    );
  }
}
```

> Note: `dart:math.sqrt` is used here ONLY to report a render-diagnostic correction distance; it never touches sim state, so it does not violate sim determinism. The `netcode` purity test bans `dart:io`/flutter/flame but permits `dart:math` (unlike `sim`). If the copied purity test also bans `dart:math`, relax it for `netcode` to allow `dart:math` while still banning `Random(` — or compute correction distance with `Fixed` and `.lengthSq()` instead and drop the `dart:math` import. Prefer the latter (use `(after - before).lengthSq().toDouble()` and compare squared bounds) to keep the ban strict; adjust the tests' bound to be squared accordingly.

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/netcode/test/match_controller_test.dart` and `dart analyze`
Expected: PASS (4 tests); analyze clean. (If the purity test fails on `dart:math`, apply the squared-distance approach noted above.)

- [ ] **Step 5: Commit**

```bash
git add packages/netcode/lib/src/match_controller.dart packages/netcode/test/match_controller_test.dart
git commit -m "feat(netcode): MatchController predict + reconcile (tick contract)"
```

---

## Task 8: `FakeTransport` + the 9 integration cases (the proof)

**Files:** Create `packages/netcode/lib/test_support/fake_transport.dart`; Test `packages/netcode/test/netcode_integration_test.dart`

`FakeTransport` owns a server `Simulation`, a virtual integer-ms clock, one-way latency (default 75 ms ⇒ 150 RTT), DetRng-seeded loss, and in-flight queues tagged `deliverAtMs`. It steps the server on the canonical 30 Hz tick, broadcasts via `shouldSnapshot`, and pumps the controller. It exposes reorder/dup hooks.

- [ ] **Step 1: Write `FakeTransport`**

`packages/netcode/lib/test_support/fake_transport.dart`:

```dart
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

import '../src/match_controller.dart';
import '../src/snapshot_cadence.dart';

class _InFlight<T> {
  final int deliverAtMs;
  final T payload;
  _InFlight(this.deliverAtMs, this.payload);
}

/// Headless server<->client link with a virtual integer-ms clock, injectable
/// one-way latency and deterministic loss. Drives a real server Simulation
/// against a real MatchController. dtMs=33 matches InterpolationBuffer.dtMs.
class FakeTransport {
  static const int dtMs = 33;
  final int seed;
  final int oneWayLatencyMs;
  final double lossRate; // 0..1, applied to BOTH directions
  final MatchController client;
  final Simulation server;
  final int localSlot;

  final DetRng _loss;
  int _nowMs = 0;
  int _serverNextTick = 0;
  int _accMs = 0;
  final List<_InFlight<InputMsg>> _toServer = [];
  final List<_InFlight<SnapshotMsg>> _toClient = [];
  final List<Intent> _serverHeld = [null, null].cast(); // held intent per slot
  final List<int> _ackedSeq = [0, 0];

  FakeTransport({
    required this.seed,
    required this.client,
    required this.localSlot,
    this.oneWayLatencyMs = 75,
    this.lossRate = 0.0,
  })  : server = Simulation.create(SimConfig(seed: seed)),
        _loss = DetRng.fromInt(seed ^ 0x5EED);

  bool _drop() => lossRate > 0 && client != null
      ? (_loss.nextU32() / 0x100000000) < lossRate
      : false;

  /// Client sends an input now (subject to latency + loss).
  void clientSend(InputMsg msg) {
    if (_drop()) return;
    _toServer.add(_InFlight(_nowMs + oneWayLatencyMs, msg));
  }

  /// Advance the whole world by one 33ms client frame: deliver due packets,
  /// step the server on tick boundaries, broadcast snapshots, pump the client.
  void tickWorld() {
    _nowMs += dtMs;
    _accMs += dtMs;

    // Deliver due client->server inputs into the server's held-intent slots.
    _toServer.removeWhere((f) {
      if (f.deliverAtMs <= _nowMs) {
        final m = f.payload;
        if (m.seq > _ackedSeq[m.slot]) {
          _serverHeld[m.slot] = Intent(
              playerSlot: m.slot, type: IntentType.values[m.type],
              aimX: m.aimX, aimY: m.aimY, seq: m.seq, clientTick: m.clientTick);
          _ackedSeq[m.slot] = m.seq;
        }
        return true;
      }
      return false;
    });

    // Step the server forward by whole ticks accumulated.
    while (_accMs >= dtMs) {
      _accMs -= dtMs;
      final intents = <Intent>[
        for (final h in _serverHeld) if (h != null) h,
      ];
      final tick = _serverNextTick;
      server.step(tick, intents);
      if (shouldSnapshot(tick) && !_drop()) {
        _toClient.add(_InFlight(
          _nowMs + oneWayLatencyMs,
          SnapshotMsg(
              serverTick: tick,
              ackedSeq: [_ackedSeq[0], _ackedSeq[1]],
              stateBytes: server.snapshotBytes()),
        ));
      }
      _serverNextTick++;
    }

    // Deliver due server->client snapshots.
    _toClient.removeWhere((f) {
      if (f.deliverAtMs <= _nowMs) {
        client.onServerSnapshot(f.payload);
        return true;
      }
      return false;
    });

    // Advance the client's predicted sim one tick.
    client.advanceClientTick();
  }

  int get nowMs => _nowMs;
  int get serverTick => _serverNextTick - 1;
  int serverHash() => server.canonicalStateHash();
}
```

> The implementer must fix the `_serverHeld` init (Dart can't put `null` in a non-nullable list); use `final List<Intent?> _serverHeld = [null, null];` and the `_drop()` `client != null` guard is spurious (client is non-null) — simplify to `lossRate > 0 && (_loss.nextU32() / 0x100000000) < lossRate`. Make these two fixes when the analyzer flags them.

- [ ] **Step 2: Write the 9 integration cases**

`packages/netcode/test/netcode_integration_test.dart` — implement these assertions (the harness above drives them):

1. **Zero-latency, zero-loss baseline:** `oneWayLatencyMs: 0, lossRate: 0`. After applying a move and `tickWorld()` ×40, `client.debugHash() == transport.serverHash()` (allowing for the 1-tick client-lead — assert they match at the tick the client has a snapshot for; simplest: assert `client.lastCorrectionDist == 0` on every reconcile).
2. **150 ms bounded + steady-state-exact:** `oneWayLatencyMs: 75`. Apply a move; run ×120. Assert `client.lastCorrectionDist < 0.5` on every reconcile AND that once the hero reaches its target, a later reconcile yields `lastCorrectionDist == 0.0` exactly. Assert it never grows.
3. **30% loss bounded:** `lossRate: 0.30`. Run ×200. Assert `lastCorrectionDist < 0.5` always, never throws, and `client.pendingCount` stays bounded (≤ a small constant, e.g. < 20).
4. **Dropped input self-heals:** drop the first input (don't call `clientSend` for it), then send a later identical held move; assert the hero still reaches the target and no permanent desync (final client hash == an independently replayed server-input-log hash).
5. **Out-of-order snapshots ignored:** manually deliver a `serverTick=20` snapshot after `22`; assert the controller ignores the stale 20 (`lastServerTick` stays 22) and final state equals an in-order control run.
6. **Duplicate snapshot idempotent:** deliver the same snapshot twice; assert second `onServerSnapshot` is a no-op (hash unchanged, `pendingCount` unchanged) and the interpolation buffer didn't double-insert.
7. **Opponent interpolation on-segment:** drive both heroes moving; sample `update(renderTimeMs)` and assert the opponent render pos lies between the two bracketing authoritative snapshots (~100 ms behind) and never overshoots when a snapshot is late.
8. **Determinism golden:** run the exact same `(seed, latency, lossRate)` scenario twice; assert identical `client.debugHash()` at the final tick across runs.
9. **Reconcile == fresh replay:** build an independent `Simulation` from the same seed, feed it the exact merged server input log; assert its `canonicalStateHash()` equals the client's predicted hash after the matching reconcile.

- [ ] **Step 3: Run, iterate to green**

Run: `dart test packages/netcode`
Expected: all pass. **If case 2's steady-state correction is not exactly 0**, the tick contract is off by one — re-check that the client steps tick `t` for the same `t` the server stepped (both start at 0) and that reconcile re-steps `serverTick+1 .. _nextTick-1`. This is the single most important assertion in Plan 2a; do not weaken it to make it pass — fix the contract.

- [ ] **Step 4: Cross-runtime + analyze**

Run: `dart test packages/netcode -p node` and `dart test packages/netcode -p node -c dart2wasm` and `dart analyze`
Expected: all green (banned_imports skipped on node/wasm via `@TestOn('vm')`).

- [ ] **Step 5: Commit**

```bash
git add packages/netcode/lib/test_support/fake_transport.dart packages/netcode/test/netcode_integration_test.dart
git commit -m "test(netcode): FakeTransport + 9 latency/loss cases (smooth-under-150ms proof)"
```

---

## Task 9: CI — gate protocol + netcode

**Files:** Modify `.github/workflows/sim-determinism.yml`

- [ ] **Step 1: Add the new packages to CI**

In `.github/workflows/sim-determinism.yml`, in `purity-gate` after the existing `dart test` (working-directory packages/sim) step, add (each as its own `- run:` at the job's root working dir):

```yaml
      - run: dart test packages/protocol
      - run: dart test packages/netcode
```

And in `replay-golden` (which has Node) after the existing sim cross-runtime runs, add:

```yaml
      - run: dart test packages/netcode -p node
      - run: dart test packages/netcode -p node -c dart2wasm
```

- [ ] **Step 2: Validate locally**

Run: `dart analyze --fatal-infos --fatal-warnings` (clean), then `dart test packages/sim && dart test packages/protocol && dart test packages/netcode`, then `dart test packages/netcode -p node -c dart2wasm`, then `bash tooling/compare_replays.sh` (still `caf9858f`).
Expected: all green; replay golden unchanged.

- [ ] **Step 3: Commit + push**

```bash
git add .github/workflows/sim-determinism.yml
git commit -m "ci: gate protocol + netcode packages (incl. cross-runtime)"
```

---

## Self-Review

**Spec coverage (spec §8.3 client prediction/reconciliation, §8.4 net model, §11 gate 2 "movement-only predict/reconcile/interpolate proven clean with 150ms + loss"):** prediction (Task 7), reconciliation w/ restore+re-step (Tasks 3, 7), opponent interpolation (Task 6), proven smooth under 150 ms + 30% loss headlessly (Task 8, cases 2/3/7). ✓ Determinism golden untouched (Task 3 asserts `0xa00d6337`; `canonicalBytes` not modified). ✓ Deferred to Plan 2b (correctly out of scope): real WebSocket server, Flutter/Flame client, RealTickDriver, room lifecycle, dev-lag transport. ✓

**Placeholder scan:** Two spots intentionally instruct the implementer to fix analyzer-flagged issues inline (Task 4 Step 3b single-byte tag; Task 8 `_serverHeld` nullable list + `_drop` simplification + `dart:math` ban decision). These are *named, specific* fixes with the exact correction given — not vague TODOs.

**Type consistency:** `ByteReader.{u32,i32,fixed,bytes}` and `ByteWriter.bytes` (Task 1) are consumed by `snapshotBytes`/`restoreFromSnapshot`/`peekEntityPos` (Task 3), `ProtocolCodec` (Task 4), and `FakeTransport` (Task 8) with identical signatures. `MatchController.{applyLocalInput→InputMsg, advanceClientTick, onServerSnapshot(SnapshotMsg), update(int)→MatchView, debugHash, debugLocalPos, lastCorrectionDist, pendingCount, predictedTick}` are used identically across Tasks 7–8. `shouldSnapshot(tick)` (Task 5) is the single cadence source used by `FakeTransport` (Task 8) and (Plan 2b) the server. `MatchStartMsg/InputMsg/SnapshotMsg/MatchEndMsg/EndReason` (Task 4) are used by controller + transport consistently. ✓
