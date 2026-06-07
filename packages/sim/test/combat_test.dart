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
}
