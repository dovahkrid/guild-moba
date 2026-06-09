part of 'simulation.dart';

/// Combat for [Simulation], split out of simulation.dart (cleaning phase).
/// Same library (`part of`) → retains private access to Simulation's fields and
/// to the other concern extensions; zero behavior change.
extension SimulationCombat on Simulation {
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
    // Tick every per-unit timer down first so a statusTimer that hits 0 this tick
    // can still react (via _stepFields/_applyHit) before the end-of-step sweep
    // clears the element; reactionIcd guards the next reaction. Runs for every
    // entity incl. downed heroes — their status/icd are reset on respawn regardless.
    for (final e in _entities) {
      if (e.attackCooldown > 0) e.attackCooldown -= 1;
      if (e.abilityCooldown > 0) e.abilityCooldown -= 1;
      if (e.ultCooldown > 0) e.ultCooldown -= 1;
      if (e.reactionIcd > 0) e.reactionIcd -= 1;
      if (e.statusTimer > 0) e.statusTimer -= 1;
    }
    for (final f in _fields) {
      if (f.timer > 0) f.timer -= 1;
    }
    _stepFields(events); // field ticks coat units in range (and may detonate Vaporize)
    _fields.removeWhere((f) => f.timer <= 0); // expired fields gone (after their final tick)
    // Heroes attack ONLY their locked target, in ascending-id order. Pursue
    // (step 2) has already closed distance; here we just fire when in range.
    for (final id in entityIdsSorted) {
      final e = _byId[id]!;
      if (e.kind != EntityKind.hero || e.isDowned) continue;
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
    _sweepDeadHeroes(events);
    _sweepDeadCreeps(events);
  }

  void _sweepDeadHeroes(List<SimEvent> events) {
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      if (e.hp.raw > 0) continue;
      e.respawnTimer = kHeroRespawnTicks;
      e.pos = FVec2(_heroSpawnX(e), Fixed.zero); // park at base while downed
      e.target = e.pos;
      e.attackTargetId = -1; // Plan 6: drop the attack lock so a respawn stands still
      events.add(HeroDowned(heroId: e.id)); // off-wire: lets the server cancel the held order
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

  /// Element-application chokepoint for DAMAGING hits (Plan 5). Autos and the
  /// enemy-only cast burst route through here; towers (non-elemental) call
  /// _applyDamage directly; field ticks coat/react INLINE in _stepFields (they no
  /// longer route here). Only heroes/creeps carry status. A different element on an
  /// already-coated, ICD-ready unit detonates an attack-amplify Vaporize
  /// (×kVaporizeMult on the triggering hit + consume + ICD + emit). Callers only
  /// ever pass ENEMY targets, so the amplified damage is inherently self-safe.
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
      // Coat (set/refresh). If ICD is active a different element still coats here
      // (no reaction; the old status is replaced) — ICD gates only the detonation.
      target.statusElement = element;
      target.statusTimer = kStatusDurationTicks;
      dmg = baseDamage;
    }
    if (dmg.raw > 0) _applyDamage(source, target, dmg, events);
  }
}
