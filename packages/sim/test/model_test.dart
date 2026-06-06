import 'package:sim/src/math/fixed.dart';
import 'package:sim/src/math/fvec2.dart';
import 'package:sim/src/model/entity.dart';
import 'package:sim/src/model/intent.dart';
import 'package:sim/src/model/sim_config.dart';
import 'package:test/test.dart';

void main() {
  test('Entity holds mutable fixed-point position', () {
    final e = Entity(id: 0, kind: EntityKind.hero, teamId: 0,
        pos: FVec2(Fixed.fromInt(1), Fixed.fromInt(2)), hp: Fixed.fromInt(100));
    e.pos = FVec2(Fixed.fromInt(3), Fixed.fromInt(4));
    expect(e.pos.x.toDouble(), 3.0);
  });

  test('Intent carries slot, type and aim', () {
    const i = Intent(playerSlot: 1, type: IntentType.move, aimX: 65536, aimY: 0, seq: 7);
    expect(i.playerSlot, 1);
    expect(i.type, IntentType.move);
    expect(i.aimX, 65536);
  });

  test('SimConfig carries a seed', () {
    const c = SimConfig(seed: 1337);
    expect(c.seed, 1337);
  });
}
