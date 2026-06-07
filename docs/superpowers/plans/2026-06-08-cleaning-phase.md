# Cleaning / Refactor Phase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure `packages/sim/lib/src/simulation.dart` (714 lines) into focused `part`/`extension` files, DRY the per-Entity serialization behind one field-descriptor list, make the netcode `FakeTransport` a faithful server mirror (death + one-shot abilities), and lightly tidy the tunables/comments — all with **zero behavior change**.

**Architecture:** Targets 1, 2, 4 are pure refactors of `packages/sim`; target 3 is test-harness work in `packages/netcode`. The split uses Dart `part of`/`extension on Simulation` (one library → private access retained, verified). The serialization DRY introduces a single library-private `_entityBodyCodecs` list that `canonicalBytes`/`snapshotBytes`/`restoreFromSnapshot`/`peekEntityPos` all derive from, emitting **byte-identical** output.

**Tech Stack:** Dart 3.11.5 (pub workspace), pure deterministic `sim` (Q16.16 `Fixed` + int, no `dart:math`/RNG/`DateTime`), cross-runtime replay gate (native/dart2js/dart2wasm via `tooling/compare_replays.sh`), `package:test`.

**Spec:** `docs/superpowers/specs/2026-06-08-cleaning-phase-design.md`.

---

## THE HEADLINE INVARIANT — read before every task

This entire phase is **GOLDEN-NEUTRAL**. After **every** task these must be **unchanged**:

- Replay goldens: `smoke 7e4aa28f`, `combat 910ddcfc`, `elemental 8d7fbe1b` (byte-identical native/dart2js/dart2wasm).
- In-test canonical anchor: `0x0fbfb7ac` (`packages/sim/test/snapshot_test.dart`, test "canonicalBytes/hash unchanged").
- `kSchemaVersion` / `kSnapshotVersion` stay **3 / 3** — **no version bump**.

Determinism rules (enforce in every task): `Fixed` (Q16.16) + `int` only; **no** `dart:math` / `Random(` / `DateTime` / `Stopwatch` in `packages/sim/lib`; **preserve the 5-phase `step()` order**; iterate `entityIdsSorted` / stable lists; **no new RNG draw**; enums are **append-only**. Do **not** remove `BossSpawned`, `LevelUp`, or the `TowerDestroyed{killerId}` hook.

If any golden, the anchor, or a version moves on tasks 1–5 or 7, the task changed behavior — **revert and fix**, do not re-pin.

---

## Standing verification commands

Run from the repo root `E:\KnowledgeBase\guild`. Bash commands use git bash; `dart` commands run in either shell.

**(A) sim suite + goldens + analyze + banned-imports** — the golden-neutral gate:

```bash
dart test packages/sim
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
```

Expected (the known-green baseline at branch start):
- `dart test packages/sim` → `All tests passed!` (116 tests; **117** after Task 6 if its test lands in a sim file — it does not, it lands in netcode, so sim stays 116).
- `dart analyze …` → `No issues found!`
- `check_no_banned_imports.sh` → `PASS: packages/sim/lib, packages/protocol/lib, and packages/netcode/lib are pure and determinism-safe.`
- `compare_replays.sh … smoke.json` → `PASS: byte-identical across native/js/wasm: 7e4aa28f` then `PASS: matches golden …smoke.golden`.
- `compare_replays.sh … combat.json` → `…: 910ddcfc` + `PASS: matches golden …combat.golden`.
- `compare_replays.sh … elemental.json` → `…: 8d7fbe1b` + `PASS: matches golden …elemental.golden`.

**(B) netcode + server suites** (for Task 6):

```bash
dart test packages/netcode
dart test apps/server
```

Expected: netcode `All tests passed!` (31 baseline → **33** after Task 6's two new tests); server `All tests passed!` (22).

---

## File structure (end state)

`packages/sim/lib/src/`:
- `simulation.dart` — the `Simulation` class (fields, `_`/`create` ctors, accessors, the 5-phase `step()`, `_stepToward`, static `peekEntityPos`) + all imports + 4 `part` directives. ~160 lines.
- `simulation_combat.dart` — `extension SimulationCombat on Simulation` (combat, sweeps, targeting, damage). ~210 lines.
- `simulation_elemental.dart` — `extension SimulationElemental on Simulation` (`_stepFields`, `_castBurst`). ~70 lines.
- `simulation_spawning.dart` — `extension SimulationSpawning on Simulation` (`_maybeSpawnWave`). ~25 lines.
- `simulation_serialization.dart` — `extension SimulationSerialization on Simulation` (canonical/snapshot/restore/hash) + the `_EntityFieldCodec` machinery + `_entityBodyCodecs`/`_posCodec`/`_writeHeader`/`_writeFields`. ~150 lines.

`packages/netcode/`:
- `lib/test_support/fake_transport.dart` — modified (faithful server mirror).
- `test/fake_transport_death_test.dart` — new (2 tests).

No test file in `packages/sim` changes — the library's public + library-private surface is identical.

---

## Task 1: Extract combat → `simulation_combat.dart`

Introduces the `part` machinery and moves all combat methods verbatim into an extension. Pure relocation → byte-identical.

**Files:**
- Create: `packages/sim/lib/src/simulation_combat.dart`
- Modify: `packages/sim/lib/src/simulation.dart`

- [ ] **Step 1: Confirm green baseline.** Run the **Standing verification commands (A)**. Expected: all green with the hashes above. (Evidence before change.)

- [ ] **Step 2: Create the combat part file.**

Create `packages/sim/lib/src/simulation_combat.dart`:

```dart
part of 'simulation.dart';

/// Combat for [Simulation], split out of simulation.dart (cleaning phase).
/// Same library (`part of`) → retains private access to Simulation's fields and
/// to the other concern extensions; zero behavior change.
extension SimulationCombat on Simulation {
  // (methods moved here verbatim in Step 3)
}
```

- [ ] **Step 3: Move the combat methods verbatim from `simulation.dart` into the extension body.**

Cut these methods **verbatim** (do not edit any logic) from the `Simulation` class body and paste them inside `extension SimulationCombat` (current line ranges @ branch start, for orientation — match by signature, not line number):

- `void _stepCombat(List<SimEvent> events)` (≈206–269)
- `void _sweepDeadHeroes(List<SimEvent> events)` (≈271–281)
- `void _sweepDeadCreeps(List<SimEvent> events)` (≈283–294)
- `void _creditGold(int heroId, int amount)` (≈296–302)
- `Fixed _heroSpawnX(Entity e)` (≈304–305)
- `bool _isInnerTower(int id)` (≈307–308)
- `Entity? _acquireTowerTarget(Entity tower)` (≈310–325)
- `void _sweepDeadStructures(List<SimEvent> events)` (≈327–348)
- `bool isStructureVulnerable(Entity e)` (≈350–364) — **public**; stays callable by importers (extensions in the exported library are auto-available).
- `void _removeEntity(int id)` (≈366–370)
- `int _lastDamagerOf(int id)` (≈372)
- `bool _isAttackable(Entity a, Entity c)` (≈374–388)
- `bool _applyDamage(Entity source, Entity target, Fixed amount, List<SimEvent> events)` (≈390–401)
- `void _applyHit(Entity source, Entity target, Fixed baseDamage, int element, List<SimEvent> events)` (≈403–438)

Leave in the class (do **not** move): `_stepFields`/`_castBurst` (Task 2), `_maybeSpawnWave` (Task 3), serialization (Task 4), `step`, `_stepToward`, `create`, accessors, fields.

- [ ] **Step 4: Add the `part` directive to `simulation.dart`.**

After the last import (`import 'state/byte_writer.dart';`) and before `const int kSchemaVersion = 3;`, add:

```dart
part 'simulation_combat.dart';
```

- [ ] **Step 5: Run the golden-neutral gate.** Run **Standing verification commands (A)**.

Expected: identical to Step 1 — `116 tests pass`, `No issues found!`, banned-imports PASS, and all three compares print the **same** hashes `7e4aa28f` / `910ddcfc` / `8d7fbe1b` with `matches golden`. The anchor test "canonicalBytes/hash unchanged" passes (`0x0fbfb7ac`). If any hash moved → a body was edited during the move; revert and re-move verbatim.

- [ ] **Step 6: Commit.**

```bash
git add packages/sim/lib/src/simulation.dart packages/sim/lib/src/simulation_combat.dart
git commit -m "refactor(sim): extract combat into simulation_combat.dart part (golden-neutral)"
```

---

## Task 2: Extract elemental → `simulation_elemental.dart`

**Files:**
- Create: `packages/sim/lib/src/simulation_elemental.dart`
- Modify: `packages/sim/lib/src/simulation.dart`

- [ ] **Step 1: Create the elemental part file.**

Create `packages/sim/lib/src/simulation_elemental.dart`:

```dart
part of 'simulation.dart';

/// Stationary neutral elemental fields for [Simulation] (Plan 4/5), split out of
/// simulation.dart (cleaning phase). Same library → retains private access; zero
/// behavior change. Plan 8 grows this with more reactions.
extension SimulationElemental on Simulation {
  // (methods moved here verbatim in Step 2)
}
```

- [ ] **Step 2: Move the elemental methods verbatim** from the `Simulation` class body into the extension:

- `void _stepFields(List<SimEvent> events)` (≈440–485)
- `void _castBurst(Entity caster, FVec2 center, int element, List<SimEvent> events)` (≈487–502)

These call `_applyDamage`/`_applyHit` (now in `SimulationCombat`); cross-part private calls resolve within the library. `step()` (main) calls `_castBurst`; `_stepCombat` (combat part) calls `_stepFields` — both resolve.

- [ ] **Step 3: Add the `part` directive** under the Task-1 one in `simulation.dart`:

```dart
part 'simulation_combat.dart';
part 'simulation_elemental.dart';
```

- [ ] **Step 4: Run the golden-neutral gate.** Run **Standing verification commands (A)**. Expected: identical to Task 1 Step 5 (hashes unchanged, all green).

- [ ] **Step 5: Commit.**

```bash
git add packages/sim/lib/src/simulation.dart packages/sim/lib/src/simulation_elemental.dart
git commit -m "refactor(sim): extract elemental fields into simulation_elemental.dart part (golden-neutral)"
```

---

## Task 3: Extract spawning → `simulation_spawning.dart`

**Files:**
- Create: `packages/sim/lib/src/simulation_spawning.dart`
- Modify: `packages/sim/lib/src/simulation.dart`

- [ ] **Step 1: Create the spawning part file.**

Create `packages/sim/lib/src/simulation_spawning.dart`:

```dart
part of 'simulation.dart';

/// Runtime entity spawning for [Simulation] (the periodic creep wave), split out
/// of simulation.dart (cleaning phase). Same library → retains private access;
/// zero behavior change. The natural home for Plan 9's revenge-boss spawn.
/// (Initial entity setup stays in Simulation.create — a factory.)
extension SimulationSpawning on Simulation {
  // (method moved here verbatim in Step 2)
}
```

- [ ] **Step 2: Move `_maybeSpawnWave` verbatim** from the `Simulation` class body into the extension:

- `void _maybeSpawnWave(int currentTick)` (≈185–204)

`step()` (main) calls `_maybeSpawnWave` — cross-part resolves.

- [ ] **Step 3: Add the `part` directive** in `simulation.dart`:

```dart
part 'simulation_combat.dart';
part 'simulation_elemental.dart';
part 'simulation_spawning.dart';
```

- [ ] **Step 4: Run the golden-neutral gate.** Run **Standing verification commands (A)**. Expected: unchanged (all green, hashes fixed).

- [ ] **Step 5: Commit.**

```bash
git add packages/sim/lib/src/simulation.dart packages/sim/lib/src/simulation_spawning.dart
git commit -m "refactor(sim): extract wave spawning into simulation_spawning.dart part (golden-neutral)"
```

---

## Task 4: Extract serialization → `simulation_serialization.dart` (move only, no DRY yet)

Move the instance serialization methods verbatim. `peekEntityPos` is **static** — it **stays in the `Simulation` class body** (statics can't be added via extension and it must remain `Simulation.peekEntityPos`). DRY happens in Task 5.

**Files:**
- Create: `packages/sim/lib/src/simulation_serialization.dart`
- Modify: `packages/sim/lib/src/simulation.dart`

- [ ] **Step 1: Create the serialization part file.**

Create `packages/sim/lib/src/simulation_serialization.dart`:

```dart
part of 'simulation.dart';

/// Binary serialization for [Simulation] (canonical determinism format +
/// netcode wire/restore format), split out of simulation.dart (cleaning phase).
/// Same library → retains private access; zero behavior change. Emitted bytes are
/// IDENTICAL to before (proven by the replay goldens + the 0x0fbfb7ac anchor).
extension SimulationSerialization on Simulation {
  // (methods moved here verbatim in Step 2)
}
```

- [ ] **Step 2: Move these methods verbatim** from the `Simulation` class body into the extension (leave `peekEntityPos` in the class):

- `Uint8List canonicalBytes()` (≈504–545)
- `int canonicalStateHash()` (≈547)
- `Uint8List snapshotBytes()` (≈549–593)
- `void restoreFromSnapshot(Uint8List bytes)` (≈595–681)

Keep `static FVec2? peekEntityPos(Uint8List bytes, int id)` (≈683–713) **in the `Simulation` class body** — unchanged.

- [ ] **Step 3: Add the `part` directive** in `simulation.dart`:

```dart
part 'simulation_combat.dart';
part 'simulation_elemental.dart';
part 'simulation_spawning.dart';
part 'simulation_serialization.dart';
```

- [ ] **Step 4: Run the golden-neutral gate.** Run **Standing verification commands (A)**. Expected: unchanged (all green; `0x0fbfb7ac`; `7e4aa28f`/`910ddcfc`/`8d7fbe1b`). `simulation.dart` is now ~160 lines.

- [ ] **Step 5: Commit.**

```bash
git add packages/sim/lib/src/simulation.dart packages/sim/lib/src/simulation_serialization.dart
git commit -m "refactor(sim): extract serialization into simulation_serialization.dart part (golden-neutral)"
```

---

## Task 5: DRY the serialization behind one field-descriptor list

Replace the four parallel per-Entity read/write sites with a single `_entityBodyCodecs` list. **Emitted bytes must stay byte-identical** — the goldens + anchor + round-trip tests are the proof. The header (`version/tick/rng/winnerTeam/count`) and the field-trailer become tiny shared helpers; the identity prefix `id/kind/teamId` stays explicit.

**Files:**
- Modify: `packages/sim/lib/src/simulation_serialization.dart`
- Modify: `packages/sim/lib/src/simulation.dart` (only `peekEntityPos`'s body)

- [ ] **Step 1: Confirm green baseline.** Run **Standing verification commands (A)**. Expected: all green, hashes fixed.

- [ ] **Step 2: Add the codec machinery to `simulation_serialization.dart`** (top-level, library-private — inside the part file, **outside** the extension):

```dart
/// One serialized per-Entity *body* field, in wire order. The SINGLE source of
/// truth for the entity body layout: canonicalBytes / snapshotBytes /
/// restoreFromSnapshot and Simulation.peekEntityPos all derive from
/// [_entityBodyCodecs], so adding a serialized field (e.g. Plan 7 XP/level) is a
/// one-row edit. The identity prefix (id, kind, teamId) is NOT here — it is read/
/// written explicitly (id is the lookup key; kind/teamId are construction-only).
class _EntityFieldCodec {
  final void Function(ByteWriter w, Entity e) write;
  final void Function(ByteReader r, Entity e) readInto;

  /// Decode this field (advancing the reader) WITHOUT an Entity — for
  /// peekEntityPos, which only inspects pos. Returns the decoded value.
  final Object Function(ByteReader r) read;

  /// True for fields present only in snapshotBytes (netcode wire + restore) and
  /// absent from canonicalBytes (the determinism hash). Currently: `target`.
  final bool snapshotOnly;

  const _EntityFieldCodec({
    required this.write,
    required this.readInto,
    required this.read,
    this.snapshotOnly = false,
  });
}

_EntityFieldCodec _i32Codec(int Function(Entity) get, void Function(Entity, int) set) =>
    _EntityFieldCodec(
      write: (w, e) => w.i32(get(e)),
      readInto: (r, e) => set(e, r.i32()),
      read: (r) => r.i32(),
    );

_EntityFieldCodec _fixedCodec(Fixed Function(Entity) get, void Function(Entity, Fixed) set) =>
    _EntityFieldCodec(
      write: (w, e) => w.fixed(get(e)),
      readInto: (r, e) => set(e, r.fixed()),
      read: (r) => r.fixed(),
    );

_EntityFieldCodec _fvecCodec(FVec2 Function(Entity) get, void Function(Entity, FVec2) set,
        {bool snapshotOnly = false}) =>
    _EntityFieldCodec(
      write: (w, e) {
        final v = get(e);
        w.fixed(v.x);
        w.fixed(v.y);
      },
      readInto: (r, e) => set(e, FVec2(r.fixed(), r.fixed())),
      read: (r) => FVec2(r.fixed(), r.fixed()),
      snapshotOnly: snapshotOnly,
    );

/// The pos codec is referenced directly by Simulation.peekEntityPos (the only
/// field it returns); it is also the first entry in [_entityBodyCodecs].
final _EntityFieldCodec _posCodec =
    _fvecCodec((e) => e.pos, (e, v) => e.pos = v);

/// The per-Entity body, in EXACT wire order. Must match the pre-DRY layout
/// byte-for-byte (pos, vel, hp, maxHp, attackCooldown, gold, respawnTimer,
/// attackTargetId, statusElement, statusTimer, reactionIcd, abilityCooldown,
/// target[snapshot-only]).
final List<_EntityFieldCodec> _entityBodyCodecs = [
  _posCodec,
  _fvecCodec((e) => e.vel, (e, v) => e.vel = v),
  _fixedCodec((e) => e.hp, (e, v) => e.hp = v),
  _fixedCodec((e) => e.maxHp, (e, v) => e.maxHp = v),
  _i32Codec((e) => e.attackCooldown, (e, v) => e.attackCooldown = v),
  _i32Codec((e) => e.gold, (e, v) => e.gold = v),
  _i32Codec((e) => e.respawnTimer, (e, v) => e.respawnTimer = v),
  _i32Codec((e) => e.attackTargetId, (e, v) => e.attackTargetId = v),
  _i32Codec((e) => e.statusElement, (e, v) => e.statusElement = v),
  _i32Codec((e) => e.statusTimer, (e, v) => e.statusTimer = v),
  _i32Codec((e) => e.reactionIcd, (e, v) => e.reactionIcd = v),
  _i32Codec((e) => e.abilityCooldown, (e, v) => e.abilityCooldown = v),
  _fvecCodec((e) => e.target, (e, v) => e.target = v, snapshotOnly: true),
];
```

- [ ] **Step 3: Replace the four serialization methods in the extension** with the codec-driven versions. Replace the bodies of `canonicalBytes`, `canonicalStateHash`, `snapshotBytes`, `restoreFromSnapshot` with exactly:

```dart
  void _writeHeader(ByteWriter w, int version) {
    w.i32(version);
    w.i32(tick);
    w.u32(_rng.stateLo); // RNG limbs are unsigned 32-bit
    w.u32(_rng.stateHi);
    w.i32(_winnerTeam);
  }

  void _writeFields(ByteWriter w) {
    w.i32(_fields.length);
    for (final f in _fields) {
      w.i32(f.ownerId);
      w.fixed(f.center.x);
      w.fixed(f.center.y);
      w.i32(f.element);
      w.i32(f.timer);
    }
  }

  /// Canonical, integer-only, ordered byte encoding of the full state. Excludes
  /// snapshot-only fields (Entity.target) so the determinism golden never moves
  /// when the wire format evolves.
  Uint8List canonicalBytes() {
    final w = ByteWriter();
    _writeHeader(w, kSchemaVersion);
    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      for (final c in _entityBodyCodecs) {
        if (c.snapshotOnly) continue;
        c.write(w, e);
      }
    }
    _writeFields(w);
    return w.toBytes();
  }

  int canonicalStateHash() => (FnvHasher()..addBytes(canonicalBytes())).hash;

  /// Netcode wire + restore format. Superset of canonicalBytes() that also
  /// carries snapshot-only fields (Entity.target) so reconciliation can resume
  /// authoritative seeking.
  Uint8List snapshotBytes() {
    final w = ByteWriter();
    _writeHeader(w, kSnapshotVersion);
    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      for (final c in _entityBodyCodecs) {
        c.write(w, e);
      }
    }
    _writeFields(w);
    return w.toBytes();
  }

  /// Overwrite this sim's entire state from snapshotBytes(). Reuses existing
  /// Entity instances (ids are stable); spawns any present on the authority but
  /// absent locally (with placeholder pos/hp/maxHp immediately overwritten by the
  /// body codecs). Drops entities absent from the snapshot. Rebuilds _fields.
  void restoreFromSnapshot(Uint8List bytes) {
    final r = ByteReader(bytes);
    final version = r.i32();
    // A real throw (not assert) — asserts are stripped in release, and a
    // version-mismatched snapshot from a newer server must fail loud.
    if (version != kSnapshotVersion) {
      throw ArgumentError(
          'unsupported snapshot version $version (expected $kSnapshotVersion)');
    }
    tick = r.i32();
    final lo = r.u32();
    final hi = r.u32();
    _rng = DetRng.fromState(lo, hi);
    _winnerTeam = r.i32();
    final count = r.i32();
    final seen = <int>{};
    for (var i = 0; i < count; i++) {
      final id = r.i32();
      final kindIndex = r.i32();
      final teamId = r.i32();
      var e = _byId[id];
      if (e == null) {
        // id/kind/team are immutable → set via constructor; pos/hp/maxHp are
        // placeholders, overwritten by the body codecs below.
        e = Entity(
          id: id,
          kind: EntityKind.values[kindIndex],
          teamId: teamId,
          pos: FVec2.zero,
          hp: Fixed.zero,
          maxHp: Fixed.zero,
        );
        _entities.add(e);
        _byId[id] = e;
      }
      for (final c in _entityBodyCodecs) {
        c.readInto(r, e);
      }
      seen.add(id);
    }
    // Drop entities absent from the snapshot (despawned on the authority).
    _entities.removeWhere((e) => !seen.contains(e.id));
    _byId.removeWhere((id, e) => !seen.contains(id));
    final fieldCount = r.i32();
    _fields.clear();
    for (var i = 0; i < fieldCount; i++) {
      final ownerId = r.i32();
      final cx = r.fixed();
      final cy = r.fixed();
      final element = r.i32();
      final timer = r.i32();
      _fields.add(ElementalField(
          ownerId: ownerId, center: FVec2(cx, cy), element: element, timer: timer));
    }
    _lastDamager.clear();
  }
```

> Note the byte-layout match: `canonicalBytes` writes id/kind/team then every **non-snapshotOnly** codec (excludes `target`) — identical to the old hand-written canonical. `snapshotBytes` writes id/kind/team then **all** codecs (includes `target` last) — identical to the old snapshot. Header and field-trailer orders are unchanged. State after `restoreFromSnapshot` is identical (placeholders are overwritten unconditionally by the codecs, exactly as the old read-then-construct path did).

- [ ] **Step 4: Rewrite `peekEntityPos`'s body** in `simulation.dart` (it stays a static method on the `Simulation` class) to derive from the same list:

```dart
  /// Decode just one entity's pos from snapshotBytes() (for the interpolation
  /// buffer) without allocating a Simulation. Derives from [_entityBodyCodecs]
  /// so it stays aligned with the writers when a field is added.
  static FVec2? peekEntityPos(Uint8List bytes, int id) {
    final r = ByteReader(bytes);
    r.i32(); // version
    r.i32(); // tick
    r.u32(); // rng lo
    r.u32(); // rng hi
    r.i32(); // winnerTeam
    final count = r.i32();
    for (var i = 0; i < count; i++) {
      final eid = r.i32(); // id
      r.i32(); // kind
      r.i32(); // team
      FVec2? pos;
      for (final c in _entityBodyCodecs) {
        final v = c.read(r);
        if (identical(c, _posCodec)) pos = v as FVec2;
      }
      if (eid == id) return pos;
    }
    return null; // not in snapshot (despawned / never spawned)
  }
```

- [ ] **Step 5: Run the golden-neutral gate.** Run **Standing verification commands (A)**.

Expected: **all green, hashes UNCHANGED** (`7e4aa28f` / `910ddcfc` / `8d7fbe1b`, anchor `0x0fbfb7ac`). `snapshot_test.dart` round-trip tests (restore reproduces state; peek reads pos / null if absent; combat + elemental field round-trips) all pass. If a hash moved, the codec order does not match the old layout — diff the codec list against the pre-DRY field order and fix.

- [ ] **Step 6: Commit.**

```bash
git add packages/sim/lib/src/simulation_serialization.dart packages/sim/lib/src/simulation.dart
git commit -m "refactor(sim): DRY entity serialization behind one field-descriptor list (byte-identical)"
```

---

## Task 6: FakeTransport faithful server mirror + death/respawn tests

Make `FakeTransport`'s fake-server model the real server: per-slot **held** (move/attack) + **one-shot ability**, **drop input for a downed slot**, **clearSlot on `HeroDowned`**. Then add two failing-first tests proving it. `netcode` must not import `apps/server`, so the semantics are replicated locally.

**Files:**
- Create: `packages/netcode/test/fake_transport_death_test.dart`
- Modify: `packages/netcode/lib/test_support/fake_transport.dart`

- [ ] **Step 1: Confirm baseline.** Run **Standing verification commands (B)**. Expected: netcode 31 pass, server 22 pass.

- [ ] **Step 2: Write the two failing tests.**

Create `packages/netcode/test/fake_transport_death_test.dart`:

```dart
import 'package:netcode/netcode.dart';
import 'package:netcode/test_support/fake_transport.dart';
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';
import 'package:test/test.dart';

MatchController _client({int seed = 1, int slot = 0}) =>
    MatchController(seed: seed, localSlot: slot, startTick: 0);

void main() {
  // The enemy outer tower (team 1) sits at +kOuterTowerX; dropping the local hero
  // there at ~0 hp lets the tower kill it deterministically (only damage source:
  // first creep wave is tick 450, beyond these runs).
  test('FakeTransport mirrors the server: death cancels the held order (respawn stands still)', () {
    final t = FakeTransport(
        seed: 1, client: _client(), localSlot: 0, oneWayLatencyMs: 0, lossRate: 0.0);

    // Establish a held MOVE order toward the enemy side (+x).
    t.clientSend(InputMsg(
        slot: 0, seq: 1, clientTick: 0,
        aimX: Fixed.fromInt(20).raw, aimY: 0, type: IntentType.move.index));
    t.tickWorld(); // deliver + establish the held order

    // Force a deterministic death: drop the hero into the enemy outer tower's
    // range at ~0 hp. (Held order keeps it in range until the tower fires.)
    t.server.entity(0).pos = FVec2(kOuterTowerX, Fixed.zero);
    t.server.entity(0).hp = Fixed.raw(1);

    // Run through death + full respawn + a buffer for any re-fed order to move it.
    for (var i = 0; i < kHeroRespawnTicks + 40; i++) {
      t.tickWorld();
    }

    final hero = t.server.entity(0);
    expect(hero.respawnTimer, 0, reason: 'hero should be back up');
    // The held order was cancelled on death (clearSlot-on-HeroDowned) → the
    // respawned hero STANDS at spawn; it does not resume walking toward +x.
    expect(hero.pos.x.raw, kHero0SpawnX.raw, reason: 'server hero stands at spawn');
    expect(hero.pos.y.raw, Fixed.zero.raw);
    // End-to-end (no rubber-band): the client's predicted local hero also stands
    // at spawn — it was not yanked back onto a re-fed order after respawn.
    expect(t.client.debugLocalPos().x.raw, kHero0SpawnX.raw,
        reason: 'client predicted local hero stands at spawn (no rubber-band)');
  });

  test('FakeTransport mirrors the server: input arriving while downed is dropped', () {
    final t = FakeTransport(
        seed: 1, client: _client(), localSlot: 0, oneWayLatencyMs: 0, lossRate: 0.0);

    // Down the local hero this frame (tower kill).
    t.server.entity(0).pos = FVec2(kOuterTowerX, Fixed.zero);
    t.server.entity(0).hp = Fixed.raw(1);
    t.tickWorld();
    expect(t.server.entity(0).isDowned, isTrue, reason: 'hero is downed');

    // An order arrives while the slot is downed → the server must DROP it (no
    // held update, no ack) so it cannot resume after respawn.
    t.clientSend(InputMsg(
        slot: 0, seq: 5, clientTick: 0,
        aimX: Fixed.fromInt(20).raw, aimY: 0, type: IntentType.move.index));

    for (var i = 0; i < kHeroRespawnTicks + 40; i++) {
      t.tickWorld();
    }

    final hero = t.server.entity(0);
    expect(hero.respawnTimer, 0, reason: 'hero should be back up');
    expect(hero.pos.x.raw, kHero0SpawnX.raw,
        reason: 'a downed-window order is dropped → respawned hero stands at spawn');
  });
}
```

- [ ] **Step 3: Run the new tests — verify they FAIL against today's FakeTransport.**

Run: `dart test packages/netcode/test/fake_transport_death_test.dart`

Expected: **both FAIL** — today's `FakeTransport` keeps re-feeding the held order across death (and accepts a downed-window order), so after respawn the hero walks toward +x: `expect(hero.pos.x.raw, kHero0SpawnX.raw)` fails (actual ≈ `Fixed.fromNum(-2.0).raw` to `-0.5`, i.e. the hero advanced from spawn `-8`). This confirms the tests exercise the gap.

- [ ] **Step 4: Update `FakeTransport` to mirror the server.**

In `packages/netcode/lib/test_support/fake_transport.dart`:

(4a) Replace the held-intent field declaration:

```dart
  // Nullable: server may have received no input for a slot yet.
  final List<Intent?> _serverHeld = [null, null];
  final List<int> _ackedSeq = [0, 0];
```

with the faithful two-channel model (mirrors `IntentBuffer`):

```dart
  // Mirror the real server IntentBuffer: per-slot HELD move/attack (persistent,
  // last-writer-wins) + per-slot ONE-SHOT ability (drained once). Nullable: a
  // slot may have received no input yet.
  final List<Intent?> _held = [null, null];
  final List<Intent?> _pendingAbility = [null, null];
  final List<int> _ackedSeq = [0, 0];
```

(4b) Replace the client→server delivery block (the `_toServer.removeWhere(...)` in `tickWorld`) with:

```dart
    // Deliver due client->server inputs. Mirrors Match.addPlayer (drop input for
    // a downed slot, NOT acked) + IntentBuffer.accept (seq-dedupe; split held
    // move/attack vs one-shot ability).
    _toServer.removeWhere((f) {
      if (f.deliverAtMs > _nowMs) return false;
      final m = f.payload;
      if (m.slot < 0 || m.slot > 1) return true; // out-of-range: drop
      if (server.entity(m.slot).isDowned) return true; // dead heroes take no orders
      if (m.seq > _ackedSeq[m.slot]) {
        _ackedSeq[m.slot] = m.seq;
        final intent = Intent(
            playerSlot: m.slot,
            type: IntentType.values[m.type],
            aimX: m.aimX,
            aimY: m.aimY,
            seq: m.seq,
            clientTick: m.clientTick);
        if (intent.type == IntentType.ability) {
          _pendingAbility[m.slot] = intent; // one-shot
        } else {
          _held[m.slot] = intent; // move/attack: persistent
        }
      }
      return true;
    });
```

(4c) Replace the server-step loop (the `while (_accMs >= dtMs) { ... }` body) with:

```dart
    while (_accMs >= dtMs) {
      _accMs -= dtMs;
      final intents = <Intent>[
        for (final h in _held)
          if (h != null) h,
      ];
      for (var slot = 0; slot < 2; slot++) {
        final a = _pendingAbility[slot];
        if (a != null) {
          intents.add(a);
          _pendingAbility[slot] = null; // one-shot: fire once, then clear
        }
      }
      final tick = _serverNextTick;
      final events = server.step(tick, intents);
      // Mirror Match._tick: death cancels the slot's held order (+ pending ability).
      for (final e in events) {
        if (e is HeroDowned) {
          _held[e.heroId] = null;
          _pendingAbility[e.heroId] = null;
        }
      }
      // Record the merged authoritative input list for independent replay.
      serverInputLog.add(List.of(intents));
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
```

> `HeroDowned.heroId` is a hero id (0/1) which equals the slot, so `_held[e.heroId]` indexes correctly — mirrors `Match._tick`'s `_buffer.clearSlot(e.heroId)`.

- [ ] **Step 5: Run the new tests — verify they PASS.**

Run: `dart test packages/netcode/test/fake_transport_death_test.dart`
Expected: **both PASS** (server + client hero stand at spawn after respawn).

- [ ] **Step 6: Run the full netcode + server gate + analyze + banned-imports.**

```bash
dart test packages/netcode
dart test apps/server
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
```

Expected: netcode `All tests passed!` (**33** now: 31 + 2 new), server `22`, `No issues found!`, banned-imports PASS. The existing 31 netcode cases are combat-free / ability-free, so the mirror changes don't perturb them.

- [ ] **Step 7: Sanity-check sim goldens untouched** (no `packages/sim` change this task, but prove it):

```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
```

Expected: `910ddcfc` + `matches golden`.

- [ ] **Step 8: Commit.**

```bash
git add packages/netcode/lib/test_support/fake_transport.dart packages/netcode/test/fake_transport_death_test.dart
git commit -m "test(netcode): FakeTransport faithfully mirrors server death (clearSlot + downed-drop + one-shot abilities)"
```

---

## Task 7: Light data/comment tidy of `combat.dart` + `elements.dart`

Lowest leverage — **keep light, NO value changes** (the Plan-5 numeric balance is deferred). Pure comment/grouping/ordering touch-ups → golden-neutral.

**Files:**
- Modify: `packages/sim/lib/src/data/combat.dart`
- Modify: `packages/sim/lib/src/data/elements.dart`

- [ ] **Step 1: Confirm green baseline.** Run **Standing verification commands (A)**. Expected: all green, hashes fixed.

- [ ] **Step 2: Apply the tidy (no value changes).** Allowed edits only:
  - Normalize section-header comment style (e.g. consistent `// --- Section ---` banners) and fix any typos.
  - Ensure each constant has a one-line purpose/unit comment where missing; keep the existing `// spec §…` target notes verbatim.
  - Group related constants together **without** changing any literal value, constant name, type, or `const`/`final` modifier, and **without** reordering in a way that changes semantics (these are independent top-level decls; ordering is cosmetic).
  - Do **not** add/remove constants, change a number, or touch the `heroElement` / `heroPlacesAtSelf` logic.

  Explicitly preserve these values unchanged: `kCastBurstDamage = Fixed.fromNum(10)`, `kReactionFlatDamage = Fixed.fromNum(8)`, `kHeroAttackDamage`, `kTowerAttackDamage`, all HP/range/cooldown/gold/geometry/id constants, `kVaporizeMult`, field radius/duration/cooldown, status/ICD durations.

- [ ] **Step 3: Run the golden-neutral gate.** Run **Standing verification commands (A)**.

Expected: **all green, hashes UNCHANGED** (`7e4aa28f` / `910ddcfc` / `8d7fbe1b`, anchor `0x0fbfb7ac`). Because no value changed, the goldens cannot move; if one moves, a value was altered — revert it.

- [ ] **Step 4: Commit.**

```bash
git add packages/sim/lib/src/data/combat.dart packages/sim/lib/src/data/elements.dart
git commit -m "docs(sim): tidy combat/elements tunable comments + grouping (no value change, golden-neutral)"
```

---

## Final: whole-branch mirror-CI sweep

After all 7 tasks (run by the orchestrator, not a single task):

```bash
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
dart test packages/sim
dart test packages/protocol
dart test packages/netcode
dart test apps/server
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
# cross-runtime suites (mirrors .github/workflows/sim-determinism.yml replay-golden job):
dart test packages/sim -p node
dart test packages/sim -p node -c dart2wasm
dart test packages/netcode -p node
dart test packages/netcode -p node -c dart2wasm
# flutter client (separate Flutter SDK; not a workspace member):
cd apps/client && flutter analyze && flutter test && cd ../..
```

**Final expected state:** sim 116 · protocol 11 · netcode 33 · server 22 · client(flutter) unchanged; analyze clean; banned-imports PASS; goldens `7e4aa28f` / `910ddcfc` / `8d7fbe1b` and anchor `0x0fbfb7ac` **all unchanged**; `kSchemaVersion`/`kSnapshotVersion` still 3/3.

---

## Self-review notes (for the implementer/reviewer)

- **Every task except Task 6 is `packages/sim`-only and must leave all four hashes fixed.** Task 6 is `packages/netcode` test-harness only (sim untouched → goldens trivially fixed; Step 7 proves it).
- **Type/name consistency:** `_EntityFieldCodec`, `_i32Codec`/`_fixedCodec`/`_fvecCodec`, `_posCodec`, `_entityBodyCodecs`, `_writeHeader`, `_writeFields` (Task 5) are referenced in `peekEntityPos` (Task 5 Step 4) and the four methods — names match. `FakeTransport` fields renamed `_serverHeld`→`_held` + new `_pendingAbility` are used consistently in 4b/4c (Task 6).
- **No placeholders:** all code blocks are complete; method move-lists give exact signatures; commands give exact expected output.
- **Spec coverage:** Target 1 → Tasks 1–4; Target 2 → Task 5; Target 3 → Task 6; Target 4 → Task 7. All four spec targets have tasks.
- **Active lints (`analysis_options.yaml`):** `package:lints/recommended` + `strict-casts`/`strict-inference`/`strict-raw-types` + `avoid_dynamic_calls` + `prefer_final_locals`. The codec code is written for these: `v as FVec2` in `peekEntityPos` is an *explicit* cast (allowed under strict-casts); codec fields are fully typed (no dynamic calls); use `final` for single-assignment locals. `dart analyze --fatal-infos --fatal-warnings` is the gate.
</content>
