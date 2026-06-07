part of 'simulation.dart';

/// Runtime entity spawning for [Simulation] (the periodic creep wave), split out
/// of simulation.dart (cleaning phase). Same library → retains private access;
/// zero behavior change. The natural home for Plan 9's revenge-boss spawn.
/// (Initial entity setup stays in Simulation.create — a factory.)
extension SimulationSpawning on Simulation {
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
}
