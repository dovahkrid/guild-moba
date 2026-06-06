# Guild — Plan 2b: Netcode Wiring (Dart WS Server + Flutter/Flame Client) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Wire the *already-proven* pure-Dart netcode core (Plan 2a) to reality: a Dart WebSocket server running the authoritative sim, and a Flutter+Flame client (render + input only). End state: run the server, open two browser tabs, click-to-move two heroes in a real online 1v1 over `ws://localhost` — placeholder art.

**Architecture:** `apps/server` = a thin `dart:io`/`shelf` shell around a **pure** `Match`/`IntentBuffer`/`RoomManager` core, driven by an injected `TickDriver` (real = Stopwatch+Timer catch-up; test = synchronous `pump`) over an abstract `PlayerConn` (real = `WsPlayerConn`; test = `FakePlayerConn`). `apps/client` = Flutter+Flame holding ZERO gameplay truth: a `match_binding` drives the Plan-2a `MatchController` at 30 Hz over an abstract `Transport` (real = `WebSocketChannelTransport`; dev = `DevLagTransport`), and `GuildGame` renders `MatchView` as colored shapes. The smooth-under-latency *logic* is already proven headlessly (Plan 2a); this plan's automated tests cover the server core + client net glue, and the Flame render + real socket are a documented manual smoke.

**Tech Stack (verified on Dart 3.11.5 / Flutter 3.41.9):** `shelf ^1.4.2`, `shelf_web_socket ^3.0.0` (callback `(WebSocketChannel, String?)`), `web_socket_channel ^3.0.3`, `flame ^1.30.0`. Build: `flutter build web --release` (canvaskit default — **never** `--web-renderer`, removed in 3.41); dev: `flutter run -d chrome`. **Binary WS frames only** (throw on `String`).

---

## Contracts carried over from Plan 2a (do not re-derive)

- **Tick contract:** authoritative tick N == state after `step(N)`; first tick N=0 on both sides; `MatchStartMsg.startTick = 0`.
- **Real `MatchController` API (already built in `packages/netcode`):** `MatchController({seed, localSlot, startTick})`; `InputMsg applyLocalInput(int aimX, int aimY)` (returns the frame's message to send); `void advanceClientTick()` (call at 30 Hz); `void onServerSnapshot(SnapshotMsg)`; `MatchView update(int renderTimeMs)`; getters `predictedTick`, `lastServerTick`, `pendingCount`, `lastCorrectionDist`. `MatchView{RenderEntity local, opponent, wanderer; int predictedTick, lastServerTick, pendingInputCount; double lastCorrectionDist}`, `RenderEntity{double x,y}`.
- **Protocol:** `MatchStartMsg`, `InputMsg`, `SnapshotMsg{serverTick, ackedSeq[2], stateBytes}`, `MatchEndMsg`, `ProtocolCodec.encode/decode` (binary, 1-byte tag).
- **Snapshot format:** `Simulation.snapshotBytes()` / `restoreFromSnapshot()` / `peekEntityPos()`.
- **Cadence:** `shouldSnapshot(tick) => (tick % 3) < 2` (20 Hz). **Relocated to `protocol` in Task 1 below so server + client share one source.**

---

## File Structure

**`packages/protocol` (modify):** move `shouldSnapshot` here (`lib/src/cadence.dart`), export from barrel.
**`packages/netcode` (modify):** delete its local `snapshot_cadence.dart`; re-export `shouldSnapshot` from `protocol` (so existing imports keep working).

**`apps/server` (new):**
- `pubspec.yaml`, `bin/server.dart` (real wiring), `lib/server.dart` (barrel).
- `lib/src/loop/tick_driver.dart` — `TickDriver` + `RealTickDriver`.
- `lib/src/loop/intent_buffer.dart` — pure `IntentBuffer`.
- `lib/src/loop/match.dart` — pure `Match` (sim + buffer + snapshot cadence).
- `lib/src/net/player_conn.dart` — abstract `PlayerConn` + `WsPlayerConn`.
- `lib/src/net/room_manager.dart` — slot assignment, match lifecycle.
- `lib/src/net/ws_server.dart` — shelf `webSocketHandler` + `serve`.
- Tests: `test/fakes.dart` (`FakeTickDriver`, `FakePlayerConn`), `test/intent_buffer_test.dart`, `test/match_test.dart`, `test/room_manager_test.dart`, `test/banned_imports_loop_test.dart`, `test/ws_integration_test.dart`.

**`apps/client` (new, Flutter):**
- `pubspec.yaml`, `analysis_options.yaml`, `web/` (flutter create), `lib/main.dart`, `lib/app_config.dart`.
- `lib/net/transport.dart` (abstract `Transport`), `lib/net/ws_transport.dart`, `lib/net/dev_lag_transport.dart`.
- `lib/match/match_binding.dart` (drives `MatchController`).
- `lib/render/{guild_game,entity_view,coord,world_backdrop}.dart`.
- `lib/ui/{hud_overlay,dev_panel}.dart`.
- Tests: `test/dev_lag_transport_test.dart`, `test/match_binding_test.dart`, `test/widget_smoke_test.dart`.

**Root (modify):** `pubspec.yaml` (`workspace:` add `apps/server`; the Flutter `apps/client` is NOT a workspace member — Flutter apps resolve separately; see Task 7 note); `.github/workflows/` (add server CI; optionally a client analyze job).

---

## Task 1: Relocate `shouldSnapshot` to `protocol` (single cadence source)

**Files:** Create `packages/protocol/lib/src/cadence.dart`; modify `packages/protocol/lib/protocol.dart`, `packages/netcode/lib/src/snapshot_cadence.dart`, `packages/netcode/lib/netcode.dart`

- [ ] **Step 1: Failing test**

`packages/protocol/test/cadence_test.dart`:

```dart
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('shouldSnapshot emits 20 of every 30 ticks (2-of-3)', () {
    final emitted = [for (var t = 0; t < 30; t++) if (shouldSnapshot(t)) t];
    expect(emitted.length, 20);
    expect(shouldSnapshot(0), isTrue);
    expect(shouldSnapshot(1), isTrue);
    expect(shouldSnapshot(2), isFalse);
  });
}
```

- [ ] **Step 2: Run → fails** (`shouldSnapshot` not exported by protocol).

`dart test packages/protocol/test/cadence_test.dart` → FAIL.

- [ ] **Step 3: Implement**

`packages/protocol/lib/src/cadence.dart`:

```dart
/// Snapshot cadence: 30 Hz ticks, emit on (tick % 3) < 2 => 20 Hz. THE single
/// source of truth shared by the server (Match) and client (FakeTransport/tests).
bool shouldSnapshot(int tick) => (tick % 3) < 2;
```

Add to `packages/protocol/lib/protocol.dart`: `export 'src/cadence.dart';`

Replace `packages/netcode/lib/src/snapshot_cadence.dart` contents with a re-export so existing `netcode` imports still resolve:

```dart
/// Re-exported from protocol — the cadence is a shared wire concern.
export 'package:protocol/protocol.dart' show shouldSnapshot;
```

(`packages/netcode/lib/netcode.dart` already exports `src/snapshot_cadence.dart`; leave that export line as-is.)

- [ ] **Step 4: Run → passes**

`dart test packages/protocol` (incl. new cadence test) and `dart test packages/netcode` (its FakeTransport still imports `shouldSnapshot` via the re-export) → all green. `dart analyze` clean.

- [ ] **Step 5: Commit**

```bash
git add packages/protocol/lib packages/protocol/test/cadence_test.dart packages/netcode/lib/src/snapshot_cadence.dart
git commit -m "refactor(protocol): own the shared shouldSnapshot cadence; netcode re-exports"
```

---

## Task 2: `apps/server` scaffold + pure `IntentBuffer`

**Files:** Create `apps/server/pubspec.yaml`, `lib/server.dart`, `lib/src/loop/intent_buffer.dart`, `test/intent_buffer_test.dart`; modify root `pubspec.yaml`

- [ ] **Step 1: Scaffold + failing test**

Add `apps/server` to root `pubspec.yaml` `workspace:` list.

`apps/server/pubspec.yaml`:

```yaml
name: server
description: Authoritative WebSocket match server for the Guild slice.
publish_to: none
version: 0.0.1
environment:
  sdk: ^3.6.0
resolution: workspace
dependencies:
  sim:
    path: ../../packages/sim
  protocol:
    path: ../../packages/protocol
  shelf: ^1.4.2
  shelf_web_socket: ^3.0.0
  web_socket_channel: ^3.0.3
dev_dependencies:
  test: ^1.25.0
```

`apps/server/lib/server.dart`:

```dart
/// Authoritative match server.
library;

export 'src/loop/intent_buffer.dart';
export 'src/loop/match.dart';
export 'src/loop/tick_driver.dart';
export 'src/net/player_conn.dart';
export 'src/net/room_manager.dart';
```

(Exports for files created in later tasks will dangle until they exist; create them in order so `dart test` runs only after each lands.)

`apps/server/test/intent_buffer_test.dart`:

```dart
import 'package:protocol/protocol.dart';
import 'package:server/src/loop/intent_buffer.dart';
import 'package:test/test.dart';

InputMsg input(int slot, int seq, {int aimX = 0}) =>
    InputMsg(slot: slot, seq: seq, clientTick: 0, aimX: aimX, aimY: 0, type: 1);

void main() {
  test('accepts increasing seq and tracks ackedSeq', () {
    final b = IntentBuffer();
    expect(b.accept(input(0, 1)), isTrue);
    expect(b.accept(input(0, 2)), isTrue);
    expect(b.lastAckedSeq[0], 2);
    expect(b.lastAckedSeq[1], 0);
  });

  test('drops stale/duplicate seq', () {
    final b = IntentBuffer();
    b.accept(input(0, 3));
    expect(b.accept(input(0, 3)), isFalse); // dup
    expect(b.accept(input(0, 1)), isFalse); // stale
    expect(b.lastAckedSeq[0], 3);
  });

  test('rejects out-of-range slot', () {
    expect(IntentBuffer().accept(input(2, 1)), isFalse);
  });

  test('drainForTick returns latest move per slot and persists it', () {
    final b = IntentBuffer();
    b.accept(input(0, 1, aimX: 100));
    b.accept(input(1, 1, aimX: 200));
    final a = b.drainForTick();
    expect(a.length, 2);
    // No new input next tick: still returns the held targets (heroes keep seeking).
    expect(b.drainForTick().length, 2);
  });
}
```

- [ ] **Step 2: Run → fails** (`dart pub get` then `dart test apps/server/test/intent_buffer_test.dart`) → `IntentBuffer` undefined.

- [ ] **Step 3: Implement**

`apps/server/lib/src/loop/intent_buffer.dart`:

```dart
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

/// Per-slot input frontier. Dedupes by seq, tracks the ack frontier reported in
/// snapshots, and yields the held (last-writer-wins) move each tick. PURE.
class IntentBuffer {
  final List<int> lastAckedSeq = [0, 0];
  final List<Intent?> _current = [null, null];

  /// Accept an inbound input. Returns false if stale/duplicate/out-of-range.
  bool accept(InputMsg msg) {
    final slot = msg.slot;
    if (slot < 0 || slot > 1) return false;
    if (msg.seq <= lastAckedSeq[slot]) return false;
    lastAckedSeq[slot] = msg.seq;
    _current[slot] = Intent(
      playerSlot: slot,
      type: IntentType.values[msg.type],
      aimX: msg.aimX,
      aimY: msg.aimY,
      seq: msg.seq,
      clientTick: msg.clientTick,
    );
    return true;
  }

  /// The intents to apply this tick. _current is NOT cleared (a move sets a
  /// persistent target), matching sim seek semantics.
  List<Intent> drainForTick() {
    final out = <Intent>[];
    for (final i in _current) {
      if (i != null) out.add(i);
    }
    return out;
  }
}
```

- [ ] **Step 4: Run → passes** (`dart test apps/server/test/intent_buffer_test.dart`, 4 tests). `dart analyze` clean.

- [ ] **Step 5: Commit**

```bash
git add apps/server/pubspec.yaml apps/server/lib/server.dart apps/server/lib/src/loop/intent_buffer.dart apps/server/test/intent_buffer_test.dart pubspec.yaml
git commit -m "feat(server): scaffold apps/server + pure IntentBuffer"
```

---

## Task 3: `TickDriver` + pure `Match` loop

**Files:** Create `apps/server/lib/src/loop/tick_driver.dart`, `apps/server/lib/src/net/player_conn.dart` (abstract part only), `apps/server/lib/src/loop/match.dart`, `apps/server/test/fakes.dart`, `apps/server/test/match_test.dart`

- [ ] **Step 1: Failing test**

`apps/server/test/fakes.dart`:

```dart
import 'dart:async';
import 'package:server/src/loop/tick_driver.dart';
import 'package:server/src/net/player_conn.dart';

/// Synchronous, no-time tick driver for tests.
class FakeTickDriver implements TickDriver {
  void Function()? _onTick;
  @override
  void start(void Function() onTick) => _onTick = onTick;
  @override
  void stop() => _onTick = null;
  void pump(int n) {
    for (var i = 0; i < n; i++) {
      _onTick?.call();
    }
  }
}

/// Records sent frames; lets the test push inbound frames.
class FakePlayerConn implements PlayerConn {
  final _inbound = StreamController<List<int>>.broadcast();
  final _closed = Completer<void>();
  final List<List<int>> sent = [];

  @override
  Stream<List<int>> get messages => _inbound.stream;
  @override
  Future<void> get onClose => _closed.future;
  @override
  void send(List<int> frame) => sent.add(frame);
  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
  }

  void receive(List<int> frame) => _inbound.add(frame);
}
```

`apps/server/lib/src/net/player_conn.dart` (abstract only for now; `WsPlayerConn` lands in Task 5):

```dart
/// Everything the match needs from a connection — no dart:io / WS type leaks
/// into the pure loop.
abstract class PlayerConn {
  Stream<List<int>> get messages; // inbound encoded protocol frames
  Future<void> get onClose;
  void send(List<int> frame);
  void close();
}
```

`apps/server/lib/src/loop/tick_driver.dart`:

```dart
/// Drives ticks in real time on the SERVER. The sim never sees a wall-clock
/// value; this only decides WHEN / HOW MANY TIMES to call the pure tick fn.
abstract class TickDriver {
  void start(void Function() onTick);
  void stop();
}
```

(`RealTickDriver` is appended in Task 5; keep this file abstract-only so `match_test` doesn't pull `dart:async`.)

`apps/server/test/match_test.dart`:

```dart
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:sim/sim.dart';
import 'fakes.dart';

import 'package:test/test.dart';

void main() {
  test('steps deterministically and emits 20Hz snapshots with ackedSeq', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    final match = Match(seed: 1337, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..start();

    // p0 sends a move at "now".
    p0.receive(ProtocolCodec.encode(const InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 655360, aimY: 0, type: 1)));

    driver.pump(30); // 30 ticks

    // 20 snapshots per 30 ticks (2-of-3 cadence).
    final snaps0 = p0.sent.map(ProtocolCodec.decode).whereType<SnapshotMsg>().toList();
    expect(snaps0.length, 20);
    expect(snaps0.last.ackedSeq[0], 1); // p0's input was acked
    expect(snaps0.last.serverTick, greaterThan(0));

    // Authoritative state is reconstructable and hero 0 moved right.
    final s = Simulation.create(const SimConfig(seed: 1337))
      ..restoreFromSnapshot(snaps0.last.stateBytes);
    expect(s.entity(0).pos.x.toDouble(), greaterThan(-8.0));
  });

  test('match end on player disconnect notifies survivor', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    final match = Match(seed: 1, driver: driver)..addPlayer(0, p0)..addPlayer(1, p1)..start();
    driver.pump(3);
    p1.close(); // disconnect
    // Allow the onClose handler to run, then assert survivor got MatchEndMsg.
    return Future(() {
      final ended = p0.sent.map(ProtocolCodec.decode).whereType<MatchEndMsg>();
      expect(ended.isNotEmpty, isTrue);
      expect(match.ended, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run → fails** (`Match` undefined).

- [ ] **Step 3: Implement**

`apps/server/lib/src/loop/match.dart`:

```dart
import 'dart:async';

import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

import '../net/player_conn.dart';
import 'intent_buffer.dart';
import 'tick_driver.dart';

/// Pure-ish authoritative match loop. Owns one Simulation + an IntentBuffer.
/// Time enters only via the injected TickDriver; connections only via PlayerConn.
class Match {
  Match({required this.seed, required TickDriver driver}) : _driver = driver;

  final int seed;
  final TickDriver _driver;
  late final Simulation _sim = Simulation.create(SimConfig(seed: seed));
  final IntentBuffer _buffer = IntentBuffer();
  final List<PlayerConn?> _players = [null, null];
  final List<StreamSubscription<List<int>>> _subs = [];

  int _currentTick = 0;
  bool started = false;
  bool ended = false;

  int get serverTick => _currentTick;

  void addPlayer(int slot, PlayerConn conn) {
    _players[slot] = conn;
    _subs.add(conn.messages.listen((frame) {
      final msg = ProtocolCodec.decode(frame);
      if (msg is InputMsg) {
        // Server is authoritative on slot: stamp with the assigned slot.
        _buffer.accept(InputMsg(
          slot: slot, seq: msg.seq, clientTick: msg.clientTick,
          aimX: msg.aimX, aimY: msg.aimY, type: msg.type));
      }
    }));
    conn.onClose.then((_) => _onPlayerLeft(slot));
  }

  void start() {
    if (started) return;
    started = true;
    // Tell each player its slot + the seed (client constructs its MatchController).
    for (var slot = 0; slot < 2; slot++) {
      _players[slot]?.send(ProtocolCodec.encode(MatchStartMsg(
          yourSlot: slot, seed: seed, tickRateHz: 30, snapshotRateHz: 20, startTick: 0)));
    }
    _driver.start(_tick);
  }

  void _tick() {
    if (ended) return;
    final intents = _buffer.drainForTick();
    _sim.step(_currentTick, intents);
    if (shouldSnapshot(_currentTick)) {
      final snap = ProtocolCodec.encode(SnapshotMsg(
        serverTick: _currentTick,
        ackedSeq: [_buffer.lastAckedSeq[0], _buffer.lastAckedSeq[1]],
        stateBytes: _sim.snapshotBytes(),
      ));
      for (final p in _players) {
        p?.send(snap);
      }
    }
    _currentTick++;
  }

  void _onPlayerLeft(int slot) {
    if (ended) return;
    ended = true;
    _driver.stop();
    for (var s = 0; s < 2; s++) {
      if (s != slot) {
        _players[s]?.send(ProtocolCodec.encode(
            const MatchEndMsg(reason: EndReason.opponentLeft)));
      }
      _players[s]?.close();
    }
    for (final sub in _subs) {
      sub.cancel();
    }
  }
}
```

- [ ] **Step 4: Run → passes** (`dart test apps/server/test/match_test.dart`). `dart analyze` clean.

- [ ] **Step 5: Commit**

```bash
git add apps/server/lib/src/loop/tick_driver.dart apps/server/lib/src/net/player_conn.dart apps/server/lib/src/loop/match.dart apps/server/test/fakes.dart apps/server/test/match_test.dart
git commit -m "feat(server): pure Match loop + TickDriver/PlayerConn seams"
```

---

## Task 4: `RoomManager` + loop purity gate

**Files:** Create `apps/server/lib/src/net/room_manager.dart`, `apps/server/test/room_manager_test.dart`, `apps/server/test/banned_imports_loop_test.dart`

- [ ] **Step 1: Failing test**

`apps/server/test/room_manager_test.dart`:

```dart
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'fakes.dart';
import 'package:test/test.dart';

void main() {
  test('assigns slots 0 then 1 and starts the match on the 2nd join', () {
    final rm = RoomManager(seed: 7, driverFactory: () => FakeTickDriver());
    final p0 = FakePlayerConn();
    rm.connect(p0);
    expect(p0.sent, isEmpty); // not started yet
    final p1 = FakePlayerConn();
    rm.connect(p1);
    // Both received MATCH_START with their slots.
    final m0 = ProtocolCodec.decode(p0.sent.first) as MatchStartMsg;
    final m1 = ProtocolCodec.decode(p1.sent.first) as MatchStartMsg;
    expect(m0.yourSlot, 0);
    expect(m1.yourSlot, 1);
  });

  test('rejects a 3rd connection with roomFull then closes it', () {
    final rm = RoomManager(seed: 7, driverFactory: () => FakeTickDriver());
    rm.connect(FakePlayerConn());
    rm.connect(FakePlayerConn());
    final p2 = FakePlayerConn();
    rm.connect(p2);
    final end = ProtocolCodec.decode(p2.sent.single) as MatchEndMsg;
    expect(end.reason, EndReason.roomFull);
  });
}
```

`apps/server/test/banned_imports_loop_test.dart` — copy the netcode purity test but scan **only `apps/server/lib/src/loop`** (the pure core; `net/` and `bin/` legitimately use `dart:io`/`dart:async`). Bans `dart:io`, `dart:html`, flutter, flame, `DateTime`, `Stopwatch`, `Random`, `dart:math` transcendentals. (`dart:async` is allowed even in loop since `Match` uses `StreamSubscription` — adjust the ban list to NOT include `dart:async`.)

- [ ] **Step 2: Run → fails** (`RoomManager` undefined).

- [ ] **Step 3: Implement**

`apps/server/lib/src/net/room_manager.dart`:

```dart
import 'package:protocol/protocol.dart';

import '../loop/match.dart';
import '../loop/tick_driver.dart';
import 'player_conn.dart';

/// Hardcoded single 2-player room. First two connections get slots 0/1; the
/// match starts on the second. A third is politely rejected. On match end the
/// room resets so a fresh pair can connect.
class RoomManager {
  RoomManager({required this.seed, required this.driverFactory});
  final int seed;
  final TickDriver Function() driverFactory;

  Match? _match;
  int _filled = 0;

  void connect(PlayerConn conn) {
    if (_match != null && _filled >= 2) {
      conn.send(ProtocolCodec.encode(const MatchEndMsg(reason: EndReason.roomFull)));
      conn.close();
      return;
    }
    _match ??= Match(seed: seed, driver: driverFactory());
    final slot = _filled++;
    _match!.addPlayer(slot, conn);
    if (_filled == 2) _match!.start();
    // Reset the room when this match ends so the next pair can play.
    conn.onClose.then((_) {
      if (_match != null && _match!.ended) {
        _match = null;
        _filled = 0;
      }
    });
  }
}
```

- [ ] **Step 4: Run → passes** (`dart test apps/server`, all server tests; `banned_imports_loop_test` green). `dart analyze` clean.

- [ ] **Step 5: Commit**

```bash
git add apps/server/lib/src/net/room_manager.dart apps/server/test/room_manager_test.dart apps/server/test/banned_imports_loop_test.dart
git commit -m "feat(server): RoomManager (2-player room) + loop purity gate"
```

---

## Task 5: Real adapters — `RealTickDriver`, `WsPlayerConn`, `ws_server`, `bin/server.dart`

**Files:** Modify `apps/server/lib/src/loop/tick_driver.dart`, `apps/server/lib/src/net/player_conn.dart`; create `apps/server/lib/src/net/ws_server.dart`, `apps/server/bin/server.dart`, `apps/server/test/ws_integration_test.dart`

- [ ] **Step 1: Failing test (real-socket integration smoke)**

`apps/server/test/ws_integration_test.dart`:

```dart
@TestOn('vm')
library;

import 'package:protocol/protocol.dart';
import 'package:server/src/net/ws_server.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:test/test.dart';

void main() {
  test('two real WS clients receive MATCH_START with distinct slots', () async {
    final server = await GuildWsServer.start(host: 'localhost', port: 0, seed: 99);
    final uri = Uri.parse('ws://localhost:${server.port}/ws');

    final a = WebSocketChannel.connect(uri);
    final b = WebSocketChannel.connect(uri);

    final aFirst = await a.stream.first;
    final bFirst = await b.stream.first;
    final ma = ProtocolCodec.decode(aFirst as List<int>) as MatchStartMsg;
    final mb = ProtocolCodec.decode(bFirst as List<int>) as MatchStartMsg;

    expect({ma.yourSlot, mb.yourSlot}, {0, 1});

    await a.sink.close();
    await b.sink.close();
    await server.close();
  });
}
```

- [ ] **Step 2: Run → fails** (`GuildWsServer` undefined).

- [ ] **Step 3: Implement**

Append `RealTickDriver` to `apps/server/lib/src/loop/tick_driver.dart`:

```dart
import 'dart:async';

class RealTickDriver implements TickDriver {
  RealTickDriver({this.tickRateHz = 30, this.maxCatchUp = 5});
  final int tickRateHz;
  final int maxCatchUp;
  final Stopwatch _sw = Stopwatch();
  Timer? _timer;
  int _done = 0;

  int get _tickMicros => 1000000 ~/ tickRateHz;

  @override
  void start(void Function() onTick) {
    _sw.start();
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ (tickRateHz * 2)), (_) {
      final due = _sw.elapsedMicroseconds ~/ _tickMicros;
      var budget = maxCatchUp;
      while (_done < due && budget-- > 0) {
        onTick();
        _done++;
      }
      if (_done < due) _done = due; // drop missed ticks; never spiral
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    _sw.stop();
  }
}
```

Append `WsPlayerConn` to `apps/server/lib/src/net/player_conn.dart` (binary frames only — **throw on String**, per the review):

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

class WsPlayerConn implements PlayerConn {
  WsPlayerConn(this._channel) {
    _channel.sink.done.whenComplete(() {
      if (!_closed.isCompleted) _closed.complete();
    });
  }
  final WebSocketChannel _channel;
  final _closed = Completer<void>();

  @override
  Stream<List<int>> get messages => _channel.stream.map((m) {
        if (m is String) {
          throw StateError('expected binary WS frame, got String');
        }
        return (m as List<int>);
      });

  @override
  Future<void> get onClose => _closed.future;
  @override
  void send(List<int> frame) =>
      _channel.sink.add(frame is Uint8List ? frame : Uint8List.fromList(frame));
  @override
  void close() => _channel.sink.close();
}
```

`apps/server/lib/src/net/ws_server.dart`:

```dart
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../loop/tick_driver.dart';
import 'player_conn.dart';
import 'room_manager.dart';

/// Thin real-socket shell: shelf webSocketHandler -> WsPlayerConn -> RoomManager.
class GuildWsServer {
  GuildWsServer._(this._server, this.port);
  final HttpServer _server;
  final int port;

  static Future<GuildWsServer> start({
    String host = '0.0.0.0',
    int port = 8080,
    int seed = 1337,
  }) async {
    final rooms = RoomManager(seed: seed, driverFactory: () => RealTickDriver());
    final handler = webSocketHandler((WebSocketChannel channel, String? _) {
      rooms.connect(WsPlayerConn(channel));
    });
    final server = await shelf_io.serve(handler, host, port);
    return GuildWsServer._(server, server.port);
  }

  Future<void> close() => _server.close(force: true);
}
```

`apps/server/bin/server.dart`:

```dart
import 'package:server/src/net/ws_server.dart';

Future<void> main(List<String> args) async {
  final port = int.tryParse(args.isNotEmpty ? args[0] : '') ?? 8080;
  final server = await GuildWsServer.start(host: '0.0.0.0', port: port, seed: 1337);
  // ignore: avoid_print
  print('Guild server listening on ws://localhost:${server.port}/ws');
}
```

- [ ] **Step 4: Run → passes** (`dart test apps/server/test/ws_integration_test.dart`). `dart analyze` clean. Manually: `dart run apps/server/bin/server.dart 8080` prints the listening line.

- [ ] **Step 5: Commit**

```bash
git add apps/server/lib/src/loop/tick_driver.dart apps/server/lib/src/net/player_conn.dart apps/server/lib/src/net/ws_server.dart apps/server/bin/server.dart apps/server/test/ws_integration_test.dart
git commit -m "feat(server): real WS adapters + bin entrypoint + integration smoke"
```

---

## Task 6: Client net layer — `Transport`, `WebSocketChannelTransport`, `DevLagTransport`

**Files:** Create the Flutter app `apps/client` (via `flutter create`), then `lib/net/transport.dart`, `lib/net/ws_transport.dart`, `lib/net/dev_lag_transport.dart`, `test/dev_lag_transport_test.dart`

- [ ] **Step 1: Create the Flutter app + failing test**

Run: `flutter create --platforms web --project-name guild_client apps/client`
Then set `apps/client/pubspec.yaml` dependencies (NOTE: a Flutter app is generally NOT a pub-workspace member — it resolves via path deps; do NOT add `resolution: workspace` and do NOT add it to the root `workspace:` list):

```yaml
# apps/client/pubspec.yaml (key parts)
environment:
  sdk: ^3.6.0
  flutter: ">=3.27.0"
dependencies:
  flutter:
    sdk: flutter
  flame: ^1.30.0
  web_socket_channel: ^3.0.3
  sim:
    path: ../../packages/sim
  protocol:
    path: ../../packages/protocol
  netcode:
    path: ../../packages/netcode
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
```

`apps/client/test/dev_lag_transport_test.dart`:

```dart
import 'dart:async';
import 'package:guild_client/net/dev_lag_transport.dart';
import 'package:guild_client/net/transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemTransport implements Transport {
  final _in = StreamController<List<int>>.broadcast();
  final List<List<int>> sent = [];
  @override
  Stream<List<int>> get inbound => _in.stream;
  @override
  void send(List<int> f) => sent.add(f);
  @override
  Future<void> close() async => _in.close();
  void serverPush(List<int> f) => _in.add(f);
}

void main() {
  test('0% loss, 0ms latency forwards frames both ways', () async {
    final mem = _MemTransport();
    final lag = DevLagTransport(mem, latencyMs: 0, lossPct: 0);
    final got = <List<int>>[];
    lag.inbound.listen(got.add);
    lag.send([1, 2, 3]);
    mem.serverPush([9, 9]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(mem.sent, [[1, 2, 3]]);
    expect(got, [[9, 9]]);
  });

  test('100% loss drops everything', () async {
    final mem = _MemTransport();
    final lag = DevLagTransport(mem, latencyMs: 0, lossPct: 100);
    final got = <List<int>>[];
    lag.inbound.listen(got.add);
    lag.send([1]);
    mem.serverPush([2]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(mem.sent, isEmpty);
    expect(got, isEmpty);
  });
}
```

- [ ] **Step 2: Run → fails** (`flutter test test/dev_lag_transport_test.dart` from `apps/client`) → undefined.

- [ ] **Step 3: Implement**

`apps/client/lib/net/transport.dart`:

```dart
/// Network seam. Real = WebSocketChannelTransport; dev = DevLagTransport.
abstract class Transport {
  Stream<List<int>> get inbound; // frames from the server
  void send(List<int> frame);    // frames to the server
  Future<void> close();
}
```

`apps/client/lib/net/ws_transport.dart` (binary only — throw on String):

```dart
import 'package:web_socket_channel/web_socket_channel.dart';
import 'transport.dart';

class WebSocketChannelTransport implements Transport {
  WebSocketChannelTransport(Uri url) : _ch = WebSocketChannel.connect(url);
  final WebSocketChannel _ch;

  @override
  Stream<List<int>> get inbound => _ch.stream.map((m) {
        if (m is String) throw StateError('expected binary WS frame, got String');
        return m as List<int>;
      });
  @override
  void send(List<int> frame) => _ch.sink.add(frame);
  @override
  Future<void> close() => _ch.sink.close();
}
```

`apps/client/lib/net/dev_lag_transport.dart`:

```dart
import 'dart:async';
import 'dart:math' as math; // OK here: transport is NOT the sim.
import 'transport.dart';

/// Injects one-way latency + loss in BOTH directions. Knobs mirror Plan 2a's
/// FakeTransport so a hand-found feel bug reproduces in a headless unit test.
class DevLagTransport implements Transport {
  DevLagTransport(this._inner, {this.latencyMs = 0, this.jitterMs = 0, this.lossPct = 0}) {
    _sub = _inner.inbound.listen((frame) {
      if (_drop()) return;
      Timer(Duration(milliseconds: _delay()), () {
        if (!_out.isClosed) _out.add(frame);
      });
    });
  }
  final Transport _inner;
  int latencyMs, jitterMs, lossPct; // mutable: bound to dev-panel sliders
  final _rng = math.Random(0xC0FFEE);
  final _out = StreamController<List<int>>.broadcast();
  late final StreamSubscription<List<int>> _sub;

  int _delay() => latencyMs + (jitterMs == 0 ? 0 : _rng.nextInt(jitterMs + 1));
  bool _drop() => lossPct > 0 && _rng.nextInt(100) < lossPct;

  @override
  Stream<List<int>> get inbound => _out.stream;
  @override
  void send(List<int> frame) {
    if (_drop()) return;
    Timer(Duration(milliseconds: _delay()), () => _inner.send(frame));
  }
  @override
  Future<void> close() async {
    await _sub.cancel();
    await _out.close();
    await _inner.close();
  }
}
```

- [ ] **Step 4: Run → passes** (`flutter test test/dev_lag_transport_test.dart`).

- [ ] **Step 5: Commit**

```bash
git add apps/client/pubspec.yaml apps/client/lib/net/ apps/client/test/dev_lag_transport_test.dart
git commit -m "feat(client): Transport seam + WS + DevLagTransport"
```

---

## Task 7: `match_binding` — drive `MatchController` over a `Transport`

**Files:** Create `apps/client/lib/match/match_binding.dart`, `apps/client/test/match_binding_test.dart`

The binding is the testable heart of the client: first inbound `MatchStartMsg` constructs the controller; it pumps `advanceClientTick()` at 30 Hz off an accumulator fed by `tick(dtMs)`; it forwards inbound `SnapshotMsg` to `onServerSnapshot`; and it encodes the `InputMsg` returned by `applyLocalInput` onto the transport.

- [ ] **Step 1: Failing test**

`apps/client/test/match_binding_test.dart`:

```dart
import 'dart:async';
import 'package:guild_client/match/match_binding.dart';
import 'package:guild_client/net/transport.dart';
import 'package:protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemTransport implements Transport {
  final _in = StreamController<List<int>>.broadcast();
  final List<List<int>> sent = [];
  @override
  Stream<List<int>> get inbound => _in.stream;
  @override
  void send(List<int> f) => sent.add(f);
  @override
  Future<void> close() async => _in.close();
  void serverPush(List<int> f) => _in.add(f);
}

void main() {
  test('constructs controller on MatchStart, then predicts + sends input', () async {
    final mem = _MemTransport();
    final binding = MatchBinding(mem);
    mem.serverPush(ProtocolCodec.encode(const MatchStartMsg(
        yourSlot: 0, seed: 1337, tickRateHz: 30, snapshotRateHz: 20, startTick: 0)));
    await Future<void>.delayed(Duration.zero); // deliver inbound

    expect(binding.isReady, isTrue);
    binding.submitMoveTo(655360, 0); // click far right
    // An InputMsg frame was sent to the server.
    final sent = mem.sent.map(ProtocolCodec.decode).whereType<InputMsg>().toList();
    expect(sent.single.aimX, 655360);

    // Advance ~10 ticks of client time; the local hero predicts movement.
    binding.tick(330); // 10 * 33ms
    final v = binding.view!;
    expect(v.local.x, greaterThan(-8.0));
  });

  test('forwards server snapshots into reconciliation', () async {
    final mem = _MemTransport();
    final binding = MatchBinding(mem);
    mem.serverPush(ProtocolCodec.encode(const MatchStartMsg(
        yourSlot: 0, seed: 1337, tickRateHz: 30, snapshotRateHz: 20, startTick: 0)));
    await Future<void>.delayed(Duration.zero);
    binding.tick(330);
    // A no-input authoritative snapshot at tick 5.
    final srv = Simulation.create(const SimConfig(seed: 1337));
    for (var t = 0; t < 6; t++) {
      srv.step(t, const []);
    }
    mem.serverPush(ProtocolCodec.encode(SnapshotMsg(
        serverTick: 5, ackedSeq: const [0, 0], stateBytes: srv.snapshotBytes())));
    await Future<void>.delayed(Duration.zero);
    expect(binding.view!.lastServerTick, 5);
  });
}
```

(Add `import 'package:sim/sim.dart';` to the test.)

- [ ] **Step 2: Run → fails** (`MatchBinding` undefined).

- [ ] **Step 3: Implement**

`apps/client/lib/match/match_binding.dart`:

```dart
import 'dart:async';

import 'package:netcode/netcode.dart';
import 'package:protocol/protocol.dart';

import '../net/transport.dart';

/// Glue between the network Transport and the pure MatchController. Holds NO
/// gameplay truth — it only pumps bytes and the 30 Hz client tick.
class MatchBinding {
  MatchBinding(this._transport) {
    _sub = _transport.inbound.listen(_onFrame);
  }
  final Transport _transport;
  late final StreamSubscription<List<int>> _sub;

  MatchController? _controller;
  int _renderTimeMs = 0;
  int _accMs = 0;
  static const int _tickMs = 33; // ~30 Hz

  bool get isReady => _controller != null;
  MatchView? get view => _controller?.update(_renderTimeMs);

  void _onFrame(List<int> frame) {
    final msg = ProtocolCodec.decode(frame);
    if (msg is MatchStartMsg) {
      _controller = MatchController(
          seed: msg.seed, localSlot: msg.yourSlot, startTick: msg.startTick);
    } else if (msg is SnapshotMsg) {
      _controller?.onServerSnapshot(msg);
    } else if (msg is MatchEndMsg) {
      // Slice: stop pumping; UI can show "opponent left".
      _controller = null;
    }
  }

  /// Local input: a world point (Q16.16 raw). Predict immediately + send.
  void submitMoveTo(int aimXRaw, int aimYRaw) {
    final c = _controller;
    if (c == null) return;
    final input = c.applyLocalInput(aimXRaw, aimYRaw);
    _transport.send(ProtocolCodec.encode(input));
  }

  /// Advance by [dtMs] of real time: accumulate and step the predicted sim at
  /// a fixed 30 Hz; advance the render clock for interpolation.
  void tick(int dtMs) {
    _renderTimeMs += dtMs;
    _accMs += dtMs;
    while (_accMs >= _tickMs) {
      _accMs -= _tickMs;
      _controller?.advanceClientTick();
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    await _transport.close();
  }
}
```

- [ ] **Step 4: Run → passes** (`flutter test test/match_binding_test.dart`).

- [ ] **Step 5: Commit**

```bash
git add apps/client/lib/match/match_binding.dart apps/client/test/match_binding_test.dart
git commit -m "feat(client): MatchBinding drives MatchController over Transport"
```

---

## Task 8: Flame render + HUD + `main.dart` (manual smoke)

**Files:** Create `apps/client/lib/render/{coord,entity_view,world_backdrop,guild_game}.dart`, `apps/client/lib/ui/{hud_overlay,dev_panel}.dart`, `apps/client/lib/app_config.dart`, `apps/client/lib/main.dart`, `apps/client/test/widget_smoke_test.dart`

This unit is mostly **manual smoke** (Flame rendering + real sockets aren't unit-testable); only a boots-without-throwing widget test is automated.

- [ ] **Step 1: `coord` helpers**

`apps/client/lib/render/coord.dart`:

```dart
import 'package:sim/sim.dart';

/// World units are Q16.16 in the sim; render uses doubles. Pixels-per-world-unit
/// scales the lane to screen. Lane spans roughly x in [-12, 12], y in [-4, 4].
const double kPixelsPerUnit = 28.0;

double rawToWorld(int raw) => raw / kOne; // Fixed.raw -> world double
int worldToRaw(double w) => (w * kOne).round();

double worldToFlameX(double wx) => wx * kPixelsPerUnit;
double worldToFlameY(double wy) => wy * kPixelsPerUnit;
double flameToWorld(double f) => f / kPixelsPerUnit;
```

- [ ] **Step 2: `EntityView`, `WorldBackdrop`, `GuildGame`**

`apps/client/lib/render/entity_view.dart` — a `PositionComponent` that renders a colored shape (blue = local, red = opponent, grey = wanderer) and lerps `position` toward a target each frame (cosmetic 60 fps glide). `apps/client/lib/render/world_backdrop.dart` — a static lane rectangle + center line. `apps/client/lib/render/guild_game.dart` — `FlameGame` with a `World` + `CameraComponent.withFixedResolution(world: world, width: 960, height: 540)`, mixing in `TapCallbacks`; in `update(dt)` it calls `binding.tick((dt*1000).round())`, reads `binding.view`, syncs three `EntityView`s (local/opponent/wanderer) to the view positions (via `worldToFlame*`), and follows the local hero with the camera; `onTapUp` converts the tap to world coords (`camera.globalToLocal` → `flameToWorld` → `worldToRaw`) and calls `binding.submitMoveTo`.

Provide the full code for these three files following the Flame 1.30 API (`FlameGame`, `World`, `CameraComponent.withFixedResolution`, `TapCallbacks`, `add`/`removeFromParent`, `CircleComponent`/`RectangleComponent` with `Paint`). Keep all gameplay math out — only `binding.view` doubles drive positions.

- [ ] **Step 3: `app_config`, HUD/dev panel, `main.dart`**

`app_config.dart`: `ClientConfig{String wsUrl; int devLatencyMs; int devLossPct}` with a compile-time default `wsUrl = String.fromEnvironment('WS_URL', defaultValue: 'ws://localhost:8080/ws')`. `main.dart`: build the transport chain `WebSocketChannelTransport(Uri.parse(config.wsUrl))` optionally wrapped in `DevLagTransport`, construct `MatchBinding`, construct `GuildGame(binding)`, and run `GameWidget(game: game, overlayBuilderMap: {'hud': hud, 'dev': devPanel})`. HUD reads `binding.view` stats; dev panel binds two sliders to the `DevLagTransport` knobs.

- [ ] **Step 4: Widget smoke test + run**

`apps/client/test/widget_smoke_test.dart`: pump a `GameWidget` over a `MatchBinding` wired to an in-memory transport; assert it mounts without throwing.

Run: `flutter test` (smoke passes), `flutter analyze` (clean).

**Manual smoke (the actual "playable" check):**
1. Terminal A: `dart run apps/server/bin/server.dart 8080`
2. Terminal B: `cd apps/client && flutter run -d chrome` (note the served URL).
3. Open that URL in a **second** browser tab.
4. In each tab, click on the lane — your hero (blue) moves toward the click; the opponent (red) moves in the other tab; the grey wanderer drifts identically in both. Use the dev panel to add 150 ms + 10% loss and confirm your hero stays responsive (no rubber-band) and the opponent stays smooth.

- [ ] **Step 5: Commit**

```bash
git add apps/client/lib apps/client/test/widget_smoke_test.dart
git commit -m "feat(client): Flame render + HUD + dev panel + entrypoint"
```

---

## Task 9: CI + local-dev README

**Files:** Modify `.github/workflows/sim-determinism.yml` (or add a `server-client.yml`); create `apps/README.md`

- [ ] **Step 1:** Add a CI job/steps: `dart test apps/server` (VM) to the purity-gate job. Add a separate `client-analyze` job using `subosito/flutter-action@v2` (Flutter 3.41.x) running `flutter pub get` + `flutter analyze` + `flutter test` in `apps/client`. (Don't attempt headless web e2e in CI.)
- [ ] **Step 2:** `apps/README.md`: the two-terminal local run instructions from Task 8 Step 4, plus the build command `flutter build web --release` (note: **no** `--web-renderer`).
- [ ] **Step 3:** Validate locally: `dart test apps/server`, `cd apps/client && flutter analyze && flutter test`.
- [ ] **Step 4: Commit + push**

```bash
git add .github/workflows apps/README.md
git commit -m "ci+docs: server tests, client analyze, local-run README"
```

---

## Self-Review

**Spec coverage (spec §8.2 server, §8.3 client render+input, §8.6 lobby-lite, §11 the slice's online play):** authoritative WS server over a pure tick loop (Tasks 2–5); Flutter+Flame render+input-only client over the proven `MatchController` (Tasks 6–8); hardcoded 2-player room (Task 4); binary protocol over real sockets (Tasks 5–6); dev lag/loss toggle bridging to Plan 2a's headless proof (Tasks 6, 8); local two-tab run (Task 8). ✓ Deferred (correctly): room codes/lobby/reconnect, matchmaking, delta snapshots, hand-drawn art, combat/elemental — later plans. ✓

**Placeholder scan:** Task 8 intentionally specifies the Flame render files by interface + API rather than full literal code, because (a) they are manual-smoke, not TDD, and (b) exact Flame component code is best written against the live `flame ^1.30.0` API by the implementer. Every other task has complete code. The Task 8 spec names exact classes/methods (`FlameGame`, `CameraComponent.withFixedResolution`, `TapCallbacks`, `worldToRaw`, `binding.submitMoveTo`) so it is unambiguous.

**Type consistency:** `MatchController` API (`applyLocalInput→InputMsg`, `advanceClientTick`, `onServerSnapshot(SnapshotMsg)`, `update(int)→MatchView`) matches Plan 2a exactly and is used identically in `MatchBinding` (Task 7) and `GuildGame` (Task 8). `Transport{inbound,send,close}` is implemented by `WebSocketChannelTransport`/`DevLagTransport` and consumed by `MatchBinding` consistently. `PlayerConn{messages,onClose,send,close}` is implemented by `WsPlayerConn`/`FakePlayerConn` and consumed by `Match`/`RoomManager`. `shouldSnapshot` is the single `protocol` source used by `Match` (server) and Plan 2a's `FakeTransport` (via re-export). `ProtocolCodec`/`MatchStartMsg`/`InputMsg`/`SnapshotMsg`/`MatchEndMsg` are used identically across server + client. `snapshotBytes()`/`restoreFromSnapshot()` bridge server→wire→client. ✓
