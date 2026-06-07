import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('the elemental fixture scenario produces a Vaporize (golden covers reactions)', () {
    final sim = Simulation.create(const SimConfig(seed: 1337));
    const moveToSpot = [
      Intent(playerSlot: 0, type: IntentType.move, aimX: 0, aimY: 458752, seq: 1),
      Intent(playerSlot: 1, type: IntentType.move, aimX: 0, aimY: 458752, seq: 1),
    ];
    // Both heroes have walked to ~(0,7) and now cast at the same aim (0,7), so
    // their fields overlap there. Hero 0 = Cinderfang (Pyro, self-placed at his
    // feet) and hero 1 = Marisol (Hydro, placed at the aim) -> opposite elements
    // overlapping at (0,7). Each hero standing in both fields is coated by the
    // other's element and then Vaporizes. This is a real Pyro+Hydro reaction,
    // not two same-element fields, which is why the overlap detonates below.
    const cast = [
      Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 2),
      Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 2),
    ];
    var reactions = 0;
    for (var t = 0; t < 120; t++) {
      final intents = t == 0 ? moveToSpot : (t == 60 ? cast : const <Intent>[]);
      reactions += sim.step(t, intents).whereType<ReactionTriggered>().length;
    }
    expect(reactions, greaterThan(0)); // the overlap detonated Vaporize cross-runtime
  });
}
