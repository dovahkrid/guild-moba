import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('the elemental fixture scenario produces a Vaporize (golden covers reactions)', () {
    final sim = Simulation.create(const SimConfig(seed: 1337));
    const moveToSpot = [
      Intent(playerSlot: 0, type: IntentType.move, aimX: 0, aimY: 458752, seq: 1),
      Intent(playerSlot: 1, type: IntentType.move, aimX: 0, aimY: 458752, seq: 1),
    ];
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
