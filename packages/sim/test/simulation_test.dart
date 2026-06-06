import 'package:sim/src/model/intent.dart';
import 'package:sim/src/model/sim_config.dart';
import 'package:sim/src/simulation.dart';
import 'package:test/test.dart';

void main() {
  test('starts with two heroes and one wanderer in id order', () {
    final sim = Simulation.create(const SimConfig(seed: 1337));
    expect(sim.entityIdsSorted, [0, 1, 2]);
  });

  test('a move intent pulls the hero toward its aim over ticks', () {
    final sim = Simulation.create(const SimConfig(seed: 1337));
    final startX = sim.entity(0).pos.x.toDouble();
    // aim far to the right: (10.0, 0.0) in Q16.16 => 655360, 0.
    const move = Intent(playerSlot: 0, type: IntentType.move, aimX: 655360, aimY: 0, seq: 1);
    for (var t = 0; t < 30; t++) {
      sim.step(t, [move]);
    }
    expect(sim.entity(0).pos.x.toDouble(), greaterThan(startX));
  });

  test('identical seed + inputs produce identical state hash (determinism)', () {
    Simulation run() {
      final s = Simulation.create(const SimConfig(seed: 1337));
      const m0 = Intent(playerSlot: 0, type: IntentType.move, aimX: 655360, aimY: 131072, seq: 1);
      const m1 = Intent(playerSlot: 1, type: IntentType.move, aimX: -655360, aimY: 131072, seq: 1);
      for (var t = 0; t < 300; t++) {
        s.step(t, [m0, m1]);
      }
      return s;
    }
    expect(run().canonicalStateHash(), run().canonicalStateHash());
  });

  test('canonicalStateHash changes when state changes', () {
    final a = Simulation.create(const SimConfig(seed: 1337))..step(0, const []);
    final b = Simulation.create(const SimConfig(seed: 1337));
    expect(a.canonicalStateHash() == b.canonicalStateHash(), isFalse);
  });

  // Pinned regression: the 300-tick canonical state hash must never change
  // unless the sim physics or encoding are deliberately updated. Guards against
  // accidental cross-runtime non-determinism at the unit level (complements the
  // cross-platform golden in tooling/replay_fixtures/smoke.golden).
  test('pinned 300-tick canonical state hash', () {
    final s = Simulation.create(const SimConfig(seed: 1337));
    const m0 = Intent(playerSlot: 0, type: IntentType.move, aimX: 655360, aimY: 131072, seq: 1);
    const m1 = Intent(playerSlot: 1, type: IntentType.move, aimX: -655360, aimY: 131072, seq: 1);
    for (var t = 0; t < 300; t++) {
      s.step(t, [m0, m1]);
    }
    expect(s.canonicalStateHash(), 0xa00d6337);
  });
}
