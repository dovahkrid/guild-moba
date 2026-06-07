import 'dart:typed_data';

import 'data/combat.dart';
import 'events.dart';
import 'math/det_rng.dart';
import 'math/fixed.dart';
import 'math/fvec2.dart';
import 'model/entity.dart';
import 'model/intent.dart';
import 'model/sim_config.dart';
import 'state/byte_writer.dart';

/// Version of the canonicalBytes() determinism format (the replay-golden hash).
const int kSchemaVersion = 2;

/// Version of the snapshotBytes() netcode format (superset incl. Entity.target).
/// Independent from kSchemaVersion so the determinism golden never moves when
/// the wire format evolves.
const int kSnapshotVersion = 2;

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

  /// -1 = undecided; otherwise the teamId whose enemy core was destroyed (the
  /// winner). Set in step() (Task 10); serialized so prediction/reconcile agree.
  int _winnerTeam = -1;
  int get winnerTeam => _winnerTeam;

  DetRng _rng;
  final List<Entity> _entities;
  final Map<int, Entity> _byId;

  Simulation._(this._rng, this._entities)
      : _byId = {for (final e in _entities) e.id: e};

  factory Simulation.create(SimConfig config) {
    final entities = <Entity>[
      Entity(id: 0, kind: EntityKind.hero, teamId: 0,
          pos: FVec2(kHero0SpawnX, Fixed.zero), hp: kHeroMaxHp, maxHp: kHeroMaxHp),
      Entity(id: 1, kind: EntityKind.hero, teamId: 1,
          pos: FVec2(kHero1SpawnX, Fixed.zero), hp: kHeroMaxHp, maxHp: kHeroMaxHp),
      Entity(id: kWandererEntityId, kind: EntityKind.wanderer, teamId: 2,
          pos: FVec2.zero, hp: Fixed.fromInt(50), maxHp: Fixed.fromInt(50)),
      // Cores (back of each side; vulnerable only after both same-team towers fall).
      Entity(id: kCore0Id, kind: EntityKind.core, teamId: 0,
          pos: FVec2(-kCoreX, Fixed.zero), hp: kCoreMaxHp, maxHp: kCoreMaxHp),
      Entity(id: kCore1Id, kind: EntityKind.core, teamId: 1,
          pos: FVec2(kCoreX, Fixed.zero), hp: kCoreMaxHp, maxHp: kCoreMaxHp),
      // Outer towers (throat, nearer center).
      Entity(id: kOuterTower0Id, kind: EntityKind.tower, teamId: 0,
          pos: FVec2(-kOuterTowerX, Fixed.zero), hp: kOuterTowerMaxHp, maxHp: kOuterTowerMaxHp),
      Entity(id: kOuterTower1Id, kind: EntityKind.tower, teamId: 1,
          pos: FVec2(kOuterTowerX, Fixed.zero), hp: kOuterTowerMaxHp, maxHp: kOuterTowerMaxHp),
      // Inner towers (base mouth).
      Entity(id: kInnerTower0Id, kind: EntityKind.tower, teamId: 0,
          pos: FVec2(-kInnerTowerX, Fixed.zero), hp: kInnerTowerMaxHp, maxHp: kInnerTowerMaxHp),
      Entity(id: kInnerTower1Id, kind: EntityKind.tower, teamId: 1,
          pos: FVec2(kInnerTowerX, Fixed.zero), hp: kInnerTowerMaxHp, maxHp: kInnerTowerMaxHp),
    ];
    return Simulation._(DetRng.fromInt(config.seed), entities);
  }

  List<int> get entityIdsSorted => _entities.map((e) => e.id).toList()..sort();
  Entity entity(int id) => _byId[id]!;

  /// Advance one fixed tick through five ordered phases (intents -> pursue ->
  /// movement -> combat -> wander). Returns cosmetic-only events that never
  /// mutate state. The phase order is load-bearing for determinism: do not
  /// reorder, skip, or hoist phases (especially the wander RNG draw in phase 5).
  List<SimEvent> step(int currentTick, List<Intent> intents) {
    tick = currentTick;
    final events = <SimEvent>[];

    // 1. Apply intents (canonical order; downed heroes ignore input).
    //    move   -> set the move target AND clear the attack lock.
    //    attack -> set the attack lock to the target entity id (carried in aimX).
    final ordered = [...intents]..sort((a, b) =>
        a.playerSlot != b.playerSlot ? a.playerSlot - b.playerSlot : a.seq - b.seq);
    for (final it in ordered) {
      if (it.playerSlot < 0 || it.playerSlot >= 2) continue;
      final hero = _byId[it.playerSlot]!;
      if (hero.respawnTimer != 0) continue; // downed: ignore input
      if (it.type == IntentType.move) {
        hero.target = FVec2(Fixed.raw(it.aimX), Fixed.raw(it.aimY));
        hero.attackTargetId = -1;
      } else if (it.type == IntentType.attack) {
        hero.attackTargetId = it.aimX; // aimX carries the target entity id
      }
    }

    // 2. Resolve pursue: a hero locked onto a valid enemy seeks its position;
    //    an invalid lock is dropped and the hero holds.
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      if (e.attackTargetId == -1) continue;
      final tgt = _byId[e.attackTargetId];
      if (tgt == null || !_isAttackable(e, tgt)) {
        e.attackTargetId = -1;
        e.target = e.pos; // hold position
      } else {
        e.target = tgt.pos; // pursue the locked target
      }
    }

    // 3. Hero movement (alive heroes seek their resolved target).
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      e.pos = FVec2(
        _stepToward(e.pos.x, e.target.x, _kHeroStep),
        _stepToward(e.pos.y, e.target.y, _kHeroStep),
      );
    }

    // 4. Combat: cooldowns + instantaneous damage (heroes hit only their lock).
    _stepCombat(events);

    // 5. The wanderer drifts LAST — puts the RNG through the determinism gate
    //    every tick regardless of whether combat fired. Do NOT move or skip it.
    final w = _byId[kWandererEntityId]!;
    final dx = _rng.nextInt(3) - 1; // -1, 0, +1
    final dy = _rng.nextInt(3) - 1;
    w.pos = FVec2(
      w.pos.x + Fixed.fromInt(dx) * _kWanderStep,
      w.pos.y + Fixed.fromInt(dy) * _kWanderStep,
    );

    return events;
  }

  Fixed _stepToward(Fixed cur, Fixed target, Fixed step) {
    final diff = target - cur;
    if (diff > step) return cur + step;
    if (-diff > step) return cur - step;
    return target;
  }

  void _stepCombat(List<SimEvent> events) {
    // Tick cooldowns down for every combatant first.
    for (final e in _entities) {
      if (e.attackCooldown > 0) e.attackCooldown -= 1;
    }
    // Heroes attack ONLY their locked target, in ascending-id order. Pursue
    // (step 2) has already closed distance; here we just fire when in range.
    for (final id in entityIdsSorted) {
      final e = _byId[id]!;
      if (e.kind != EntityKind.hero || e.respawnTimer != 0 || e.hp.raw <= 0) continue;
      if (e.attackCooldown > 0 || e.attackTargetId == -1) continue;
      final tgt = _byId[e.attackTargetId];
      if (tgt == null || !_isAttackable(e, tgt)) continue;
      if ((tgt.pos - e.pos).lengthSq() > kHeroAttackRangeSq) continue; // not yet in range
      _applyDamage(e, tgt, kHeroAttackDamage, events);
      e.attackCooldown = kHeroAttackCooldownTicks;
    }
  }

  /// Is `c` a valid attack target for attacker `a`?
  bool _isAttackable(Entity a, Entity c) {
    if (identical(a, c) || c.hp.raw <= 0) return false;
    switch (c.kind) {
      case EntityKind.hero:
        return c.teamId != a.teamId && c.respawnTimer == 0;
      case EntityKind.creep:
        return true; // neutral fodder — last-hittable by either hero
      case EntityKind.tower:
      case EntityKind.core:
        return false; // structures become attackable in Task 6 (vulnerability gate)
      case EntityKind.wanderer:
        return false; // pure RNG probe — never a combat target
    }
  }

  /// The single damage chokepoint. Plan 4 wraps this to add elemental flavor +
  /// reaction multipliers. Clamps hp to [0, maxHp]; returns true if lethal.
  bool _applyDamage(Entity source, Entity target, Fixed amount, List<SimEvent> events) {
    if (target.hp.raw <= 0) return false;
    var hp = target.hp - amount;
    if (hp.raw < 0) hp = Fixed.zero;
    target.hp = hp;
    events.add(DamageDealt(
        sourceId: source.id, targetId: target.id, amountRaw: amount.raw));
    return hp.raw <= 0;
  }

  /// Canonical, integer-only, ordered byte encoding of the full state.
  Uint8List canonicalBytes() {
    final w = ByteWriter();
    w.i32(kSchemaVersion);
    w.i32(tick);
    w.u32(_rng.stateLo); // RNG limbs are unsigned 32-bit; use u32 (see ByteWriter)
    w.u32(_rng.stateHi);
    w.i32(_winnerTeam);

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
      w.fixed(e.maxHp);
      w.i32(e.attackCooldown);
      w.i32(e.gold);
      w.i32(e.respawnTimer);
      w.i32(e.attackTargetId);
      // NOTE: target is intentionally NOT in the canonical format (snapshot-only).
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
    w.i32(_winnerTeam);
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
      w.fixed(e.maxHp);
      w.i32(e.attackCooldown);
      w.i32(e.gold);
      w.i32(e.respawnTimer);
      w.i32(e.attackTargetId);
      w.fixed(e.target.x);
      w.fixed(e.target.y);
    }
    return w.toBytes();
  }

  /// Overwrite this sim's entire state from snapshotBytes(). Reuses the existing
  /// Entity instances (ids are stable from create()). FVec2 is immutable, so we
  /// reassign the mutable fields: pos/vel/target plus
  /// hp/maxHp and the int combat fields (attackCooldown/gold/respawnTimer/attackTargetId).
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
    _winnerTeam = r.i32();
    final count = r.i32();
    for (var i = 0; i < count; i++) {
      final id = r.i32();
      r.i32(); // kind.index (stable; advance cursor)
      r.i32(); // teamId (stable)
      final e = _byId[id]!;
      e.pos = FVec2(r.fixed(), r.fixed());
      e.vel = FVec2(r.fixed(), r.fixed());
      e.hp = r.fixed();
      e.maxHp = r.fixed();
      e.attackCooldown = r.i32();
      e.gold = r.i32();
      e.respawnTimer = r.i32();
      e.attackTargetId = r.i32();
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
    r.i32(); // winnerTeam
    final count = r.i32();
    for (var i = 0; i < count; i++) {
      final eid = r.i32();
      r.i32(); // kind
      r.i32(); // team
      final pos = FVec2(r.fixed(), r.fixed());
      r.fixed(); r.fixed(); // vel
      r.fixed(); // hp
      r.fixed(); // maxHp
      r.i32(); // attackCooldown
      r.i32(); // gold
      r.i32(); // respawnTimer
      r.i32(); // attackTargetId
      r.fixed(); r.fixed(); // target
      if (eid == id) return pos;
    }
    throw ArgumentError('entity $id not in snapshot');
  }
}
