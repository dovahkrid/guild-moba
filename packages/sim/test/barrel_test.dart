import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('public API is reachable through the barrel', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    const move = Intent(playerSlot: 0, type: IntentType.move, aimX: 65536, aimY: 0);
    sim.step(0, [move]);
    expect(sim.entityIdsSorted, [0, 1, 2, 10, 11, 12, 13, 14, 15]);
    expect(Fixed.fromInt(2).toDouble(), 2.0);
  });
}
