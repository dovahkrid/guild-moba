import 'package:sim/sim.dart';
import 'package:sim/src/data/combat.dart'; // ignore: unnecessary_import — verifies deep path resolves alongside the re-export
import 'package:test/test.dart';

void main() {
  test('combat constants obey the Fixed magnitude budget (|value| < 32768)', () {
    // Every Fixed tunable and the largest possible lengthSq must stay in range.
    final maxima = <Fixed>[
      kHeroMaxHp, kOuterTowerMaxHp, kInnerTowerMaxHp, kCoreMaxHp, kCreepMaxHp,
      kHeroAttackDamage, kTowerAttackDamage, kHeroAttackRangeSq, kTowerAttackRangeSq,
      // geometry
      kHero0SpawnX, kHero1SpawnX, kOuterTowerX, kInnerTowerX, kCoreX,
      kCreepSpawnSpacing,
    ];
    for (final f in maxima) {
      expect(f.toDouble().abs() < 32768, isTrue, reason: '$f exceeds budget');
    }
    // Worst-case separation²: the two cores (±kCoreX).
    final sep = kCoreX + kCoreX; // 28 units
    expect((sep * sep).toDouble().abs() < 32768, isTrue);
  });

  test('attack-range² equals range squared (no sqrt needed)', () {
    expect(kHeroAttackRangeSq.toDouble(), kHeroAttackRange.toDouble() * kHeroAttackRange.toDouble());
    expect(kTowerAttackRangeSq.toDouble(), kTowerAttackRange.toDouble() * kTowerAttackRange.toDouble());
  });

  test('wave cadence is expressed in integer ticks', () {
    expect(kFirstWaveTick, 450); // 0:15 at 30Hz
    expect(kWaveIntervalTicks, 900); // 30s
  });

  test('step() returns a List<SimEvent>', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final events = sim.step(0, const []);
    expect(events, isA<List<SimEvent>>());
    expect(events, isEmpty); // a no-op tick (no locks, nothing in range) emits nothing
  });

  test('unlocked adjacent heroes do NOT attack; locking deals damage + sets the lock', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Place the pair off-lane at y=7 so neither hero sits in any tower's range
    // (towers at x=±4/±10, range 6) — keeps this hero-vs-hero test combat-free.
    sim.entity(0).pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    sim.entity(1).pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const []); // neither locked -> no attack (manual-only)
    expect(sim.entity(1).hp.raw, kHeroMaxHp.raw);
    // Hero 0 right-clicks hero 1 -> attack intent (aimX = target entity id).
    final events = sim.step(1, const [
      Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1),
    ]);
    expect(sim.entity(0).attackTargetId, 1);
    expect(sim.entity(1).hp.toDouble(), lessThan(kHeroMaxHp.toDouble()));
    expect(events.whereType<DamageDealt>(), isNotEmpty);
  });

  test('a locked hero pursues an out-of-range target into range and hits it', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(6), Fixed.zero); // outside 3-range
    sim.entity(1).target = sim.entity(1).pos;
    const lock = Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1);
    for (var t = 0; t < 40; t++) {
      sim.step(t, const [lock]); // (incidental enemy-tower fire on hero 0 is harmless here)
    }
    expect(sim.entity(0).pos.x.toDouble(), greaterThan(0.0)); // pursued toward +x
    expect(sim.entity(1).hp.toDouble(), lessThan(kHeroMaxHp.toDouble())); // and hit it
  });

  test('a move intent clears the attack lock', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(1).pos = FVec2(Fixed.fromInt(1), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(sim.entity(0).attackTargetId, 1);
    sim.step(1, const [Intent(playerSlot: 0, type: IntentType.move, aimX: -655360, aimY: 0, seq: 2)]);
    expect(sim.entity(0).attackTargetId, -1); // move cleared the lock
  });

  test('attack respects the cooldown (one hit per cooldown window)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(1).pos = FVec2(Fixed.fromInt(1), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    const lock = Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1);
    sim.step(0, const [lock]); // hit (cooldown -> kHeroAttackCooldownTicks)
    final hpAfterFirst = sim.entity(1).hp.raw;
    sim.step(1, const [lock]); // on cooldown -> no new damage
    expect(sim.entity(1).hp.raw, hpAfterFirst);
  });

  test('a hero cannot lock the neutral wanderer (lock dropped, no damage)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(kWandererEntityId).pos = const FVec2(Fixed.zero, Fixed.zero); // on top of hero
    final hpBefore = sim.entity(kWandererEntityId).hp.raw;
    sim.step(0, const [
      Intent(playerSlot: 0, type: IntentType.attack, aimX: kWandererEntityId, seq: 1),
    ]);
    expect(sim.entity(kWandererEntityId).hp.raw, hpBefore); // wanderer never a target
    expect(sim.entity(0).attackTargetId, -1); // invalid lock dropped
  });

  test('outer tower is vulnerable; inner is not until outer falls; core last', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    expect(sim.isStructureVulnerable(sim.entity(kOuterTower1Id)), isTrue);
    expect(sim.isStructureVulnerable(sim.entity(kInnerTower1Id)), isFalse);
    expect(sim.isStructureVulnerable(sim.entity(kCore1Id)), isFalse);
  });

  test('a hero attacks a vulnerable enemy outer tower in range', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Put hero 0 next to team1 outer tower (+4,0).
    sim.entity(0).pos = FVec2(Fixed.fromInt(3), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero); // keep opp away
    sim.entity(1).target = sim.entity(1).pos;
    // Hero 0 right-clicks (locks) the enemy outer tower.
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kOuterTower1Id, seq: 1)]);
    expect(sim.entity(kOuterTower1Id).hp.toDouble(), lessThan(kOuterTowerMaxHp.toDouble()));
  });

  test('a tower shoots an enemy hero in range', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Hero 1 stands next to team0 outer tower (-4,0); keep hero 0 far.
    sim.entity(1).pos = FVec2(Fixed.fromInt(-3), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(sim.entity(1).hp.toDouble(), lessThan(kHeroMaxHp.toDouble()));
  });

  test('destroying the outer tower despawns it, opens the inner, emits TowerDestroyed', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final tower = sim.entity(kOuterTower1Id);
    tower.hp = kHeroAttackDamage; // exactly one hero hit kills it this tick
    sim.entity(0).pos = FVec2(Fixed.fromInt(3), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    // Hero 0 locks the outer tower (hp set to exactly one hero hit above).
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kOuterTower1Id, seq: 1)]);
    expect(sim.entityIdsSorted.contains(kOuterTower1Id), isFalse); // despawned
    expect(sim.isStructureVulnerable(sim.entity(kInnerTower1Id)), isTrue);
    final td = events.whereType<TowerDestroyed>().single;
    expect(td.towerId, kOuterTower1Id);
    expect(td.killerId, 0);
  });

  test('a hero reduced to 0 hp is downed and respawns after the timer', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.hp = Fixed.zero; // already downed-worthy: 0 hp this tick
    h.pos = FVec2(Fixed.fromInt(1), Fixed.zero);
    h.target = h.pos;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero); // keep apart
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []); // hero-death sweep converts 0 hp -> downed
    expect(h.respawnTimer, kHeroRespawnTicks);
    expect(h.hp.raw, 0);
    // Hero id stays present (peekEntityPos must never miss it).
    expect(sim.entityIdsSorted.contains(1), isTrue);
    // Run out the timer; respawns at full hp at its spawn x.
    for (var t = 1; t <= kHeroRespawnTicks; t++) {
      sim.step(t, const []);
    }
    expect(sim.entity(1).respawnTimer, 0);
    expect(sim.entity(1).hp.raw, kHeroMaxHp.raw);
    expect(sim.entity(1).pos.x.raw, kHero1SpawnX.raw);
  });

  test('a downed hero is not a valid target and does not attack', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h0 = sim.entity(0);
    h0.respawnTimer = 10;
    h0.hp = Fixed.zero;
    h0.pos = const FVec2(Fixed.zero, Fixed.zero);
    final h1 = sim.entity(1);
    // Place h1 off-lane at y=7 so it sits outside every tower's 2D range
    // (towers at x=±4/±10, range 6) — isolates the downed-hero behavior.
    h1.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    h1.target = h1.pos;
    sim.step(0, const []);
    expect(h1.hp.raw, kHeroMaxHp.raw); // downed h0 dealt no damage
    expect(h0.hp.raw, 0); // untargetable: took none either (hp already 0)
  });

  test('a creep wave spawns at the first-wave tick with deterministic ids', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final creepIds = sim.entityIdsSorted.where((id) => id >= kCreepIdBase).toList();
    expect(creepIds, [for (var i = 0; i < kCreepsPerWave; i++) kCreepIdBase + i]);
    expect(sim.entity(kCreepIdBase).kind, EntityKind.creep);
    expect(sim.entity(kCreepIdBase).teamId, 2); // neutral
  });

  test('id-keyed reconcile creates and removes entities to match the snapshot', () {
    final withWave = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      withWave.step(t, const []);
    }
    final noWave = Simulation.create(const SimConfig(seed: 1))..step(0, const []);
    // (a) restoring the with-wave snapshot CREATES the creeps locally.
    noWave.restoreFromSnapshot(withWave.snapshotBytes());
    expect(noWave.entityIdsSorted, withWave.entityIdsSorted);
    expect(noWave.canonicalStateHash(), withWave.canonicalStateHash());
    // (b) restoring an early (no-creep) snapshot REMOVES them again.
    final early = Simulation.create(const SimConfig(seed: 1))..step(0, const []);
    noWave.restoreFromSnapshot(early.snapshotBytes());
    expect(noWave.entityIdsSorted.any((id) => id >= kCreepIdBase), isFalse);
  });

  test('last-hitting a creep credits the killer hero gold and despawns it', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final creep = sim.entity(kCreepIdBase);
    creep.hp = Fixed.fromInt(5); // next hero hit is lethal
    final hero = sim.entity(0);
    hero.pos = creep.pos; // in range
    hero.target = hero.pos;
    hero.attackCooldown = 0;
    final goldBefore = hero.gold;
    // Hero 0 right-clicks (locks) the creep; the lethal hit lands this tick.
    final events = sim.step(kFirstWaveTick + 1,
        const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kCreepIdBase, seq: 1)]);
    expect(hero.gold, goldBefore + kCreepGold);
    expect(sim.entityIdsSorted.contains(kCreepIdBase), isFalse); // despawned
    final ck = events.whereType<CreepKilled>().single;
    expect(ck.creepId, kCreepIdBase);
    expect(ck.killerId, 0);
    expect(ck.gold, kCreepGold);
  });

  test('destroying an enemy outer tower credits 200 gold to the killer', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(kOuterTower1Id).hp = Fixed.fromInt(5);
    final hero = sim.entity(0);
    hero.pos = FVec2(Fixed.fromInt(3), Fixed.zero); // next to team1 outer (+4)
    hero.target = hero.pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kOuterTower1Id, seq: 1)]);
    expect(sim.entity(0).gold, kOuterTowerGold);
  });

  test('a hero last-hits a full 60-hp creep via real attack cadence (no shortcut)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    // Relocate the creep + hero 0 to a TOWER-SAFE spot on team 0's own side
    // (x=-8 is >6 from every enemy tower at +4/+10/+14, and own towers never
    // fire on own heroes), so ONLY the hero's auto-attack cadence kills it.
    final creep = sim.entity(kCreepIdBase);
    creep.pos = FVec2(Fixed.fromInt(-8), Fixed.zero);
    final hero = sim.entity(0);
    hero.pos = creep.pos;
    hero.target = hero.pos;
    hero.attackTargetId = kCreepIdBase; // lock the creep (persists across ticks)
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    var t = kFirstWaveTick + 1;
    while (sim.entityIdsSorted.contains(kCreepIdBase) && t < kFirstWaveTick + 200) {
      sim.step(t, const []);
      t++;
    }
    expect(sim.entityIdsSorted.contains(kCreepIdBase), isFalse); // died to real DPS
    expect(sim.entity(0).gold, kCreepGold); // 60hp / 8dmg = 8 hits, credited once
  });
}
