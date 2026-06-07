import 'package:sim/sim.dart';
import 'package:test/test.dart';

/// A landed reaction with the tick it fired on (harness/log-only telemetry).
/// `unitId` is captured for a future per-hero reaction breakdown; this test only
/// asserts on `tick` (TT2E).
class _Sample {
  final int tick;
  final int unitId;
  const _Sample(this.tick, this.unitId);
}

void main() {
  test('TT2E + reactions/min are measurable from a scripted overlap', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Park both heroes on one tower-safe spot so their fields overlap there.
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    for (final id in [0, 1]) {
      sim.entity(id).pos = spot;
      sim.entity(id).target = spot;
    }
    // Cinderfang (0) drops Ember Field at t0; Marisol (1) drops Tidepool at t10
    // (aim y = 7*65536 = 458752) — the overlap (and first reaction) forms at t10.
    final casts = <int, List<Intent>>{
      0: const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1)],
      10: const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1)],
    };
    const totalTicks = 300; // 10s
    final samples = <_Sample>[];
    for (var t = 0; t < totalTicks; t++) {
      for (final e in sim.step(t, casts[t] ?? const <Intent>[])) {
        if (e is ReactionTriggered) samples.add(_Sample(t, e.unitId));
      }
    }
    expect(samples, isNotEmpty, reason: 'a Pyro+Hydro overlap must produce Vaporize');
    final tt2e = samples.first.tick; // ticks to the first landed reaction
    expect(tt2e, lessThanOrEqualTo(45),
        reason: 'second element within ~1.5s (TT2E hard gate: parent §4.1, surfaced via plan-4 §8)');
    final perMin = samples.length * 1800 / totalTicks; // 30Hz → 1800 ticks/min
    expect(perMin, greaterThan(0));
    // Human-readable TT2E log (spec §8).
    // ignore: avoid_print
    print('TT2E=${tt2e}t  reactions=${samples.length}  reactions/min=${perMin.toStringAsFixed(1)}');
  });
}
