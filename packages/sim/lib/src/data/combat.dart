import '../math/fixed.dart';

/// Combat tunables for the Milestone-0 slice. PLAYTEST PLACEHOLDERS (spec §13
/// defers exact numbers); slice values keep a match tractable and obey the
/// Fixed contract (|value| < 32768). Spec's eventual targets noted inline.

const int kTicksPerSecond = 30; // server tick rate; seconds × 30 = ticks.

// --- Hero auto-attack ---
final Fixed kHeroMaxHp = Fixed.fromInt(100); // hit-points at full health
final Fixed kHeroAttackRange = Fixed.fromNum(3); // world-units
final Fixed kHeroAttackRangeSq = Fixed.fromNum(3 * 3); // compare vs lengthSq, no sqrt
final Fixed kHeroAttackDamage = Fixed.fromNum(8); // damage per auto-attack hit
const int kHeroAttackCooldownTicks = 18; // ~0.6s
const int kHeroRespawnTicks = 150; // 5s

// --- Towers (spec §6 targets: outer 1800/120/1.0/~6, inner 2400/150/1.1/~6) ---
final Fixed kOuterTowerMaxHp = Fixed.fromInt(600); // hit-points (outer/front tower)
final Fixed kInnerTowerMaxHp = Fixed.fromInt(800); // hit-points (inner/base tower)
final Fixed kTowerAttackRange = Fixed.fromNum(6); // world-units
final Fixed kTowerAttackRangeSq = Fixed.fromNum(6 * 6); // compare vs lengthSq, no sqrt
final Fixed kTowerAttackDamage = Fixed.fromNum(20); // damage per tower shot
const int kTowerAttackCooldownTicks = 30; // 1.0/s

// --- Core ---
final Fixed kCoreMaxHp = Fixed.fromInt(400); // hit-points; destroying it ends the match

// --- Neutral creeps (slice = passive last-hit fodder; spec §6: 5/wave) ---
final Fixed kCreepMaxHp = Fixed.fromInt(60); // hit-points per neutral creep
const int kCreepsPerWave = 3; // creeps spawned per wave (one wave per lane side)
const int kFirstWaveTick = 450; // 0:15
const int kWaveIntervalTicks = 900; // 30s

// --- Gold (last-hit; spec §6 values) ---
const int kCreepGold = 18; // melee-equivalent neutral creep
const int kOuterTowerGold = 200;
const int kInnerTowerGold = 300;

// --- Lane geometry: single horizontal lane, mirror-symmetric on x, y = 0.
// Team 0 occupies negative x; team 1 positive x. Magnitudes are per-side
// offsets (negate for team 0). ---
final Fixed kHero0SpawnX = Fixed.fromInt(-8);
final Fixed kHero1SpawnX = Fixed.fromInt(8);
final Fixed kOuterTowerX = Fixed.fromInt(4); // team0 at -4, team1 at +4 (throat)
final Fixed kInnerTowerX = Fixed.fromInt(10); // base mouth
final Fixed kCoreX = Fixed.fromInt(14); // back
final Fixed kCreepSpawnSpacing = Fixed.fromNum(1.5); // creeps spread on x at center

// --- Reserved stable entity ids (heroes 0/1, wanderer 2 from Plan 1) ---
const int kCore0Id = 10;
const int kCore1Id = 11;
const int kOuterTower0Id = 12;
const int kInnerTower0Id = 13;
const int kOuterTower1Id = 14;
const int kInnerTower1Id = 15;
/// Wave creeps get ids kCreepIdBase + waveIndex*kCreepsPerWave + indexInWave,
/// a pure function of spawn tick — no stored counter, never reused/collides.
const int kCreepIdBase = 1000;
