import 'dart:typed_data';

import 'data/combat.dart';
import 'data/elements.dart';
import 'events.dart';
import 'math/det_rng.dart';
import 'math/fixed.dart';
import 'math/fvec2.dart';
import 'model/element.dart';
import 'model/elemental_field.dart';
import 'model/entity.dart';
import 'model/intent.dart';
import 'model/sim_config.dart';
import 'state/byte_writer.dart';

part 'simulation_combat.dart';

/// Version of the canonicalBytes() determinism format (the replay-golden hash).
const int kSchemaVersion = 3;

/// Version of the snapshotBytes() netcode format (superset incl. Entity.target).
/// Independent from kSchemaVersion so the determinism golden never moves when
/// the wire format evolves.
const int kSnapshotVersion = 3;

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

  // Last source id to damage each entity (for kill credit / the revenge-boss
  // "debtor"). Transient; NOT serialized — a kill is resolved the same tick the
  // lethal hit lands (the death sweep runs immediately after the attack loops in
  // _stepCombat), so it never needs to survive a snapshot. Keeps byte layout
  // unchanged.
  final Map<int, int> _lastDamager = {};

  /// Stationary neutral elemental fields (Plan 4). Tiny (≤1 active per hero,
  /// cooldown-gated). Serialized after the entity loop. Iterated in list order
  /// (deterministic: append on cast, removal preserves order).
  final List<ElementalField> _fields = [];
  List<ElementalField> get fields => _fields;

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
      if (hero.isDowned) continue; // downed (incl. dropped to 0 by a same-tick burst): ignore input
      if (it.type == IntentType.move) {
        hero.target = FVec2(Fixed.raw(it.aimX), Fixed.raw(it.aimY));
        hero.attackTargetId = -1;
      } else if (it.type == IntentType.attack) {
        hero.attackTargetId = it.aimX; // aimX carries the target entity id
      } else if (it.type == IntentType.ability) {
        if (hero.abilityCooldown != 0) continue; // on cooldown → ignore the cast
        _fields.removeWhere((f) => f.ownerId == hero.id); // ≤1 active field/hero —
        // structural insurance: today the cooldown (>field duration) already
        // guarantees the prior field expired, but this keeps the invariant even
        // if those constants change. Do not remove as "dead code".
        final center = heroPlacesAtSelf(hero.id)
            ? hero.pos // Cinderfang: Ember Field at his feet (melee)
            : FVec2(Fixed.raw(it.aimX), Fixed.raw(it.aimY)); // Marisol: Tidepool at aim
        _fields.add(ElementalField(
            ownerId: hero.id,
            center: center,
            element: heroElement(hero.id),
            timer: kFieldDurationTicks));
        hero.abilityCooldown = kAbilityCooldownTicks;
        // Plan 5: a one-time ENEMY-ONLY burst centered on the field (own-team safe).
        _castBurst(hero, center, heroElement(hero.id), events);
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

    // 3b. Spawn the periodic neutral creep wave (deterministic, idempotent).
    //     Runs after movement, before combat, so a freshly spawned wave is
    //     placed before _stepCombat can target it this tick.
    _maybeSpawnWave(currentTick);

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

  void _maybeSpawnWave(int currentTick) {
    if (currentTick < kFirstWaveTick) return;
    if ((currentTick - kFirstWaveTick) % kWaveIntervalTicks != 0) return;
    final waveIndex = (currentTick - kFirstWaveTick) ~/ kWaveIntervalTicks;
    for (var i = 0; i < kCreepsPerWave; i++) {
      final id = kCreepIdBase + waveIndex * kCreepsPerWave + i;
      if (_byId.containsKey(id)) continue; // idempotent across reconcile re-steps
      final offset = kCreepSpawnSpacing * Fixed.fromInt(i - (kCreepsPerWave ~/ 2));
      final e = Entity(
        id: id,
        kind: EntityKind.creep,
        teamId: 2, // neutral
        pos: FVec2(offset, Fixed.zero),
        hp: kCreepMaxHp,
        maxHp: kCreepMaxHp,
      );
      _entities.add(e);
      _byId[id] = e;
    }
  }

  /// Field ticks (Plan 5): every active field, in stable list order, processes
  /// each hero/creep within its radius (2-sided — the owner is not exempt). A
  /// field deals NO DoT. If the unit carries a DIFFERENT element and its ICD is
  /// ready it detonates a field-overlap Vaporize: status consumed, ICD stamped,
  /// ReactionTriggered emitted (multiplierRaw 0 = "flat"), and FLAT
  /// kReactionFlatDamage dealt — but ONLY to an enemy of the field owner
  /// (owner/own-team take 0; the self-safety invariant). Otherwise the unit is
  /// coated (set/refresh, no damage). Iterates entityIdsSorted for determinism.
  void _stepFields(List<SimEvent> events) {
    for (final f in _fields) {
      // Owner is always a hero, and heroes are downed-not-removed, so
      // _byId[f.ownerId] is non-null while the field is alive: the respawn block
      // clears _fields for any returning hero, and _removeEntity (creeps/
      // structures) never touches _fields.
      final owner = _byId[f.ownerId]!;
      for (final id in entityIdsSorted) {
        final u = _byId[id]!;
        if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
        if (u.hp.raw <= 0) continue;
        if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
        if ((u.pos - f.center).lengthSq() > kFieldRadiusSq) continue;
        if (u.statusElement != -1 &&
            u.statusElement != f.element &&
            u.reactionIcd == 0) {
          // Field-overlap Vaporize. Fires 2-sided (consume + ICD + event); damage
          // lands ONLY on an enemy of the owner (own-team takes 0).
          u.statusElement = -1;
          u.statusTimer = 0;
          u.reactionIcd = kReactionIcdTicks;
          events.add(ReactionTriggered(
              unitId: u.id,
              reaction: Reaction.vaporize.index,
              multiplierRaw: 0, // flat: no triggering hit to amplify
              sourceId: f.ownerId));
          if (u.teamId != owner.teamId) {
            _applyDamage(owner, u, kReactionFlatDamage, events);
          }
        } else {
          // Coat (set/refresh). No damage. 2-sided. A different element suppressed
          // by an active ICD also lands here (overwrites; ICD gates only detonation).
          u.statusElement = f.element;
          u.statusTimer = kStatusDurationTicks;
        }
      }
    }
  }

  /// Cast burst (Plan 5): a one-time ENEMY-ONLY AoE hit centered on a freshly
  /// placed field. Routes each enemy hero/creep in radius through _applyHit, so it
  /// applies the caster's element AND triggers an attack-amplify Vaporize
  /// (×kVaporizeMult) on an already-differently-coated enemy. Own-team is excluded
  /// → self-safe. Iterates entityIdsSorted for determinism.
  void _castBurst(Entity caster, FVec2 center, int element, List<SimEvent> events) {
    for (final id in entityIdsSorted) {
      final u = _byId[id]!;
      if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
      if (u.hp.raw <= 0) continue;
      if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
      if (u.teamId == caster.teamId) continue; // ENEMY-ONLY (own-team safe)
      if ((u.pos - center).lengthSq() > kFieldRadiusSq) continue;
      _applyHit(caster, u, kCastBurstDamage, element, events);
    }
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
      w.i32(e.statusElement);
      w.i32(e.statusTimer);
      w.i32(e.reactionIcd);
      w.i32(e.abilityCooldown);
      // NOTE: target is intentionally NOT in the canonical format (snapshot-only).
    }
    w.i32(_fields.length);
    for (final f in _fields) {
      w.i32(f.ownerId);
      w.fixed(f.center.x);
      w.fixed(f.center.y);
      w.i32(f.element);
      w.i32(f.timer);
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
      w.i32(e.statusElement);
      w.i32(e.statusTimer);
      w.i32(e.reactionIcd);
      w.i32(e.abilityCooldown);
      w.fixed(e.target.x);
      w.fixed(e.target.y);
    }
    w.i32(_fields.length);
    for (final f in _fields) {
      w.i32(f.ownerId);
      w.fixed(f.center.x);
      w.fixed(f.center.y);
      w.i32(f.element);
      w.i32(f.timer);
    }
    return w.toBytes();
  }

  /// Overwrite this sim's entire state from snapshotBytes(). Reuses the existing
  /// Entity instances (ids are stable from create()). FVec2 is immutable, so we
  /// reassign the mutable fields: pos/vel/target plus hp/maxHp and the int
  /// combat/elemental fields (attackCooldown/gold/respawnTimer/attackTargetId/
  /// statusElement/statusTimer/reactionIcd/abilityCooldown). Also rebuilds the
  /// stationary elemental field list (_fields).
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
    final seen = <int>{};
    for (var i = 0; i < count; i++) {
      final id = r.i32();
      final kindIndex = r.i32();
      final teamId = r.i32();
      final pos = FVec2(r.fixed(), r.fixed());
      final vel = FVec2(r.fixed(), r.fixed());
      final hp = r.fixed();
      final maxHp = r.fixed();
      final cooldown = r.i32();
      final gold = r.i32();
      final respawn = r.i32();
      final attackTargetId = r.i32();
      final statusElement = r.i32();
      final statusTimer = r.i32();
      final reactionIcd = r.i32();
      final abilityCooldown = r.i32();
      final target = FVec2(r.fixed(), r.fixed());
      seen.add(id);
      var e = _byId[id];
      if (e == null) {
        // Present on the authority but not locally — spawn it (id/kind/team
        // are immutable, so set via constructor; pos/hp/maxHp here are
        // overwritten by the unconditional apply block below).
        e = Entity(
          id: id,
          kind: EntityKind.values[kindIndex],
          teamId: teamId,
          pos: pos,
          hp: hp,
          maxHp: maxHp,
        );
        _entities.add(e);
        _byId[id] = e;
      }
      e.pos = pos;
      e.vel = vel;
      e.hp = hp;
      e.maxHp = maxHp;
      e.attackCooldown = cooldown;
      e.gold = gold;
      e.respawnTimer = respawn;
      e.attackTargetId = attackTargetId;
      e.statusElement = statusElement;
      e.statusTimer = statusTimer;
      e.reactionIcd = reactionIcd;
      e.abilityCooldown = abilityCooldown;
      e.target = target;
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

  /// Decode just one entity's pos from snapshotBytes() (for the interpolation
  /// buffer) without allocating a Simulation.
  static FVec2? peekEntityPos(Uint8List bytes, int id) {
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
      r.i32(); // statusElement
      r.i32(); // statusTimer
      r.i32(); // reactionIcd
      r.i32(); // abilityCooldown
      r.fixed(); r.fixed(); // target
      if (eid == id) return pos;
    }
    return null; // not in snapshot (despawned / never spawned) — caller holds last
  }
}
