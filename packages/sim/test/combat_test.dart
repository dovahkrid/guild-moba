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
    // Hero 0 locks the 10-hp outer tower; one hit kills it this tick.
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kOuterTower1Id, seq: 1)]);
    expect(sim.entityIdsSorted.contains(kOuterTower1Id), isFalse); // despawned
    expect(sim.isStructureVulnerable(sim.entity(kInnerTower1Id)), isTrue);
    final td = events.whereType<TowerDestroyed>().single;
    expect(td.towerId, kOuterTower1Id);
    expect(td.killerId, 0);
  });
}
