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
      if (hero.respawnTimer != 0) continue; // downed: ignore input
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

  void _stepCombat(List<SimEvent> events) {
    // Respawn timers count down; a hero whose timer hits 0 returns at full hp.
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer == 0) continue;
      e.respawnTimer -= 1;
      if (e.respawnTimer == 0) {
        e.hp = e.maxHp;
        e.pos = FVec2(_heroSpawnX(e), Fixed.zero);
        e.target = e.pos;
        e.attackCooldown = 0;
        // Plan 4: a fresh respawn carries no elemental status; drop the field too.
        e.statusElement = -1;
        e.statusTimer = 0;
        e.reactionIcd = 0;
        _fields.removeWhere((f) => f.ownerId == e.id);
      }
    }
    // Tick every per-unit timer down first (statusTimer is swept to -1 AFTER
    // reactions in Task 5; reactionIcd guards the next reaction). Runs for every
    // entity incl. downed heroes — their status/icd are reset on respawn regardless.
    for (final e in _entities) {
      if (e.attackCooldown > 0) e.attackCooldown -= 1;
      if (e.abilityCooldown > 0) e.abilityCooldown -= 1;
      if (e.reactionIcd > 0) e.reactionIcd -= 1;
      if (e.statusTimer > 0) e.statusTimer -= 1;
    }
    for (final f in _fields) {
      if (f.timer > 0) f.timer -= 1;
    }
    _stepFields(events); // field ticks coat units in range (may react — next task)
    _fields.removeWhere((f) => f.timer <= 0); // expired fields gone (after their final tick)
    // Heroes attack ONLY their locked target, in ascending-id order. Pursue
    // (step 2) has already closed distance; here we just fire when in range.
    for (final id in entityIdsSorted) {
      final e = _byId[id]!;
      if (e.kind != EntityKind.hero || e.respawnTimer != 0 || e.hp.raw <= 0) continue;
      if (e.attackCooldown > 0 || e.attackTargetId == -1) continue;
      final tgt = _byId[e.attackTargetId];
      if (tgt == null || !_isAttackable(e, tgt)) continue;
      if ((tgt.pos - e.pos).lengthSq() > kHeroAttackRangeSq) continue; // not yet in range
      _applyHit(e, tgt, kHeroAttackDamage, heroElement(e.id), events);
      e.attackCooldown = kHeroAttackCooldownTicks;
    }
    // Towers fire at the nearest enemy hero in range.
    for (final id in entityIdsSorted) {
      final e = _byId[id]!;
      if (e.kind != EntityKind.tower || e.attackCooldown > 0 || e.hp.raw <= 0) continue;
      final target = _acquireTowerTarget(e);
      if (target == null) continue;
      _applyDamage(e, target, kTowerAttackDamage, events);
      e.attackCooldown = kTowerAttackCooldownTicks;
    }
    // Sweep expired statuses. Once reactions land (Task 6), a status whose timer
    // hit 0 this tick will already have been consumed before this sweep runs.
    for (final e in _entities) {
      if (e.statusTimer == 0 && e.statusElement != -1) e.statusElement = -1;
    }
    // Despawn the dead, each via its own sweep: structures (towers/cores),
    // then heroes (downed, not removed), then creeps.
    _sweepDeadStructures(events);
    _sweepDeadHeroes();
    _sweepDeadCreeps(events);
  }

  void _sweepDeadHeroes() {
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      if (e.hp.raw > 0) continue;
      e.respawnTimer = kHeroRespawnTicks;
      e.pos = FVec2(_heroSpawnX(e), Fixed.zero); // park at base while downed
      e.target = e.pos;
    }
  }

  void _sweepDeadCreeps(List<SimEvent> events) {
    final dead = <Entity>[];
    for (final e in _entities) {
      if (e.kind == EntityKind.creep && e.hp.raw <= 0) dead.add(e);
    }
    for (final e in dead) {
      final killerId = _lastDamagerOf(e.id);
      _creditGold(killerId, kCreepGold);
      events.add(CreepKilled(creepId: e.id, killerId: killerId, gold: kCreepGold));
      _removeEntity(e.id);
    }
  }

  /// Credit gold to a hero by id (no-op if the killer isn't a hero, e.g. a
  /// tower last-hit a creep). A hero downed on its kill tick still earns —
  /// gold is a plain int running total that survives respawn. Intentional.
  void _creditGold(int heroId, int amount) {
    final e = _byId[heroId];
    if (e != null && e.kind == EntityKind.hero) e.gold += amount;
  }

  /// A hero's spawn x by team (team 0 negative side, team 1 positive side).
  Fixed _heroSpawnX(Entity e) => e.teamId == 0 ? kHero0SpawnX : kHero1SpawnX;

  /// Whether [id] is one of the two inner towers (vs an outer tower).
  bool _isInnerTower(int id) => id == kInnerTower0Id || id == kInnerTower1Id;

  Entity? _acquireTowerTarget(Entity tower) {
    Entity? best;
    Fixed bestSq = Fixed.zero; // sentinel; only read once best != null
    for (final id in entityIdsSorted) {
      final c = _byId[id]!;
      if (c.kind != EntityKind.hero) continue;
      if (c.teamId == tower.teamId || c.respawnTimer != 0 || c.hp.raw <= 0) continue;
      final dsq = (c.pos - tower.pos).lengthSq();
      if (dsq > kTowerAttackRangeSq) continue;
      if (best == null || dsq < bestSq) {
        best = c;
        bestSq = dsq;
      }
    }
    return best;
  }

  void _sweepDeadStructures(List<SimEvent> events) {
    final dead = <Entity>[];
    for (final e in _entities) {
      if ((e.kind == EntityKind.tower || e.kind == EntityKind.core) && e.hp.raw <= 0) {
        dead.add(e);
      }
    }
    for (final e in dead) {
      if (e.kind == EntityKind.tower) {
        final killerId = _lastDamagerOf(e.id);
        final isInner = _isInnerTower(e.id);
        _creditGold(killerId, isInner ? kInnerTowerGold : kOuterTowerGold);
        events.add(TowerDestroyed(towerId: e.id, teamId: e.teamId, killerId: killerId));
      } else {
        // core
        final winner = e.teamId == 0 ? 1 : 0;
        if (_winnerTeam == -1) _winnerTeam = winner;
        events.add(CoreDestroyed(teamId: e.teamId, winnerTeam: winner));
      }
      _removeEntity(e.id);
    }
  }

  /// Ordered gating: outer towers always vulnerable; an inner tower only after
  /// its team's outer tower is gone; a core only after BOTH its towers are gone.
  bool isStructureVulnerable(Entity e) {
    if (e.kind == EntityKind.tower) {
      if (!_isInnerTower(e.id)) return true; // outer
      final outerId = e.teamId == 0 ? kOuterTower0Id : kOuterTower1Id;
      return !_byId.containsKey(outerId);
    }
    if (e.kind == EntityKind.core) {
      final outerId = e.teamId == 0 ? kOuterTower0Id : kOuterTower1Id;
      final innerId = e.teamId == 0 ? kInnerTower0Id : kInnerTower1Id;
      return !_byId.containsKey(outerId) && !_byId.containsKey(innerId);
    }
    return true; // heroes/creeps always damageable
  }

  void _removeEntity(int id) {
    _entities.removeWhere((e) => e.id == id);
    _byId.remove(id);
    _lastDamager.remove(id);
  }

  int _lastDamagerOf(int id) => _lastDamager[id] ?? -1;

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
        return c.teamId != a.teamId && isStructureVulnerable(c);
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
    _lastDamager[target.id] = source.id;
    events.add(DamageDealt(
        sourceId: source.id, targetId: target.id, amountRaw: amount.raw));
    return hp.raw <= 0;
  }

  /// Element-application chokepoint (Plan 4). Autos + field ticks route through
  /// here; towers (non-elemental) call _applyDamage directly. Only heroes/creeps
  /// carry status. A 0-damage coat (a creep field tick) skips _applyDamage so it
  /// neither last-hits nor spams DamageDealt. A differing element on an already-
  /// coated, ICD-ready unit detonates Vaporize (amplify + consume + emit).
  void _applyHit(
      Entity source, Entity target, Fixed baseDamage, int element, List<SimEvent> events) {
    if (target.kind != EntityKind.hero && target.kind != EntityKind.creep) {
      if (baseDamage.raw > 0) _applyDamage(source, target, baseDamage, events);
      return;
    }
    Fixed dmg;
    if (target.statusElement != -1 &&
        target.statusElement != element &&
        target.reactionIcd == 0) {
      // Vaporize: amplify the TRIGGERING hit, consume the status, stamp the ICD.
      dmg = baseDamage * kVaporizeMult;
      target.statusElement = -1;
      target.statusTimer = 0;
      target.reactionIcd = kReactionIcdTicks;
      events.add(ReactionTriggered(
          unitId: target.id,
          reaction: Reaction.vaporize.index,
          multiplierRaw: kVaporizeMult.raw,
          sourceId: source.id));
    } else {
      // Coat (set/refresh). A different element suppressed by ICD overwrites here.
      target.statusElement = element;
      target.statusTimer = kStatusDurationTicks;
      dmg = baseDamage;
    }
    if (dmg.raw > 0) _applyDamage(source, target, dmg, events);
  }

  /// Field ticks: every active field coats each hero/creep within its radius
  /// (2-sided — the owner is not exempt). DoT is real on heroes, ZERO on creeps
  /// (coat-not-farm). Iterates entityIdsSorted for determinism.
  void _stepFields(List<SimEvent> events) {
    for (final f in _fields) {
      for (final id in entityIdsSorted) {
        final u = _byId[id]!;
        if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
        if (u.hp.raw <= 0) continue;
        if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
        if ((u.pos - f.center).lengthSq() > kFieldRadiusSq) continue;
        final dot = u.kind == EntityKind.creep ? Fixed.zero : kFieldDotDamage;
        // Owner is always a hero, and heroes are downed-not-removed, so
        // _byId[f.ownerId] is non-null while the field is alive: the respawn
        // block clears _fields for any returning hero, and _removeEntity (creeps/
        // structures) never touches _fields.
        _applyHit(_byId[f.ownerId]!, u, dot, f.element, events);
      }
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
