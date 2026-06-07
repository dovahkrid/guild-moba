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
part 'simulation_elemental.dart';
part 'simulation_spawning.dart';
part 'simulation_serialization.dart';

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

  /// Decode just one entity's pos from snapshotBytes() (for the interpolation
  /// buffer) without allocating a Simulation. Static — cannot move to the
  /// SimulationSerialization extension (Dart extension members are never static);
  /// derives from [_entityBodyCodecs] so it stays aligned with the writers when a
  /// field is added.
  static FVec2? peekEntityPos(Uint8List bytes, int id) {
    assert(identical(_entityBodyCodecs.first, _posCodec),
        'peekEntityPos derives pos via identical(c, _posCodec); _posCodec must be the first body codec');
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
      // pos is the first entry in _entityBodyCodecs; iterate ALL codecs to
      // completion so the reader offset advances over the full per-entity record
      // (incl. snapshot-only fields) to the next entity.
      for (final c in _entityBodyCodecs) {
        final v = c.read(r);
        if (identical(c, _posCodec)) pos = v as FVec2;
      }
      if (eid == id) return pos;
    }
    return null; // not in snapshot (despawned / never spawned)
  }
}
