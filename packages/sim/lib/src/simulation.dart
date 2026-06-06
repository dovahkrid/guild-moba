import 'dart:typed_data';

import 'math/det_rng.dart';
import 'math/fixed.dart';
import 'math/fvec2.dart';
import 'model/entity.dart';
import 'model/intent.dart';
import 'model/sim_config.dart';
import 'state/byte_writer.dart';

/// Version of the canonicalBytes() determinism format (the replay-golden hash).
const int kSchemaVersion = 1;

/// Version of the snapshotBytes() netcode format (superset incl. Entity.target).
/// Independent from kSchemaVersion so the determinism golden never moves when
/// the wire format evolves.
const int kSnapshotVersion = 1;

/// Stable entity id for the wanderer NPC (created in [Simulation.create]).
const int kWandererEntityId = 2;

/// Per-tick max movement step (Q16.16). Authoring constant.
final Fixed _kHeroStep = Fixed.fromNum(0.15);
final Fixed _kWanderStep = Fixed.fromNum(0.05);

/// The authoritative, deterministic simulation. Runs identically on server and
/// client. Plan 1 only moves entities; it exists to prove cross-runtime
/// determinism end-to-end.
class Simulation {
  int tick = 0;
  DetRng _rng;
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
        id: kWandererEntityId,
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
    final w = _byId[kWandererEntityId]!;
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
    w.u32(_rng.stateLo); // RNG limbs are unsigned 32-bit; use u32 (see ByteWriter)
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
    }
    return w.toBytes();
  }

  int canonicalStateHash() => (FnvHasher()..addBytes(canonicalBytes())).hash;

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
    // A real throw (not assert) — asserts are stripped in release, and a
    // version-mismatched snapshot from a newer server must fail loud, not
    // silently corrupt state.
    if (version != kSnapshotVersion) {
      throw ArgumentError(
          'unsupported snapshot version $version (expected $kSnapshotVersion)');
    }
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
}
