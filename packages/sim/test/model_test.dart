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

  test('Entity has combat fields defaulting sanely', () {
    final e = Entity(
      id: 5,
      kind: EntityKind.tower,
      teamId: 0,
      pos: FVec2.zero,
      hp: Fixed.fromInt(600),
      maxHp: Fixed.fromInt(600),
    );
    expect(e.kind, EntityKind.tower);
    expect(e.maxHp.toDouble(), 600.0);
    expect(e.attackCooldown, 0);
    expect(e.gold, 0);
    expect(e.respawnTimer, 0);
    expect(e.attackTargetId, -1); // -1 = no locked target
  });

  test('EntityKind appends combat kinds without shifting existing indices', () {
    // Wire format serializes kind.index — existing indices MUST be preserved.
    expect(EntityKind.hero.index, 0);
    expect(EntityKind.wanderer.index, 1);
    expect(EntityKind.tower.index, 2);
    expect(EntityKind.creep.index, 3);
    expect(EntityKind.core.index, 4);
  });

  test('IntentType appends attack without shifting existing indices', () {
    // InputMsg.type is the wire int = IntentType.index — append only.
    expect(IntentType.none.index, 0);
    expect(IntentType.move.index, 1);
    expect(IntentType.attack.index, 2);
  });

  test('Entity has elemental status fields defaulting to none/ready', () {
    final e = Entity(id: 0, kind: EntityKind.hero, teamId: 0,
        pos: FVec2.zero, hp: Fixed.fromInt(100));
    expect(e.statusElement, -1); // -1 = no elemental status
    expect(e.statusTimer, 0);
    expect(e.reactionIcd, 0);
    expect(e.abilityCooldown, 0);
  });

  test('IntentType appends ability without shifting existing indices', () {
    expect(IntentType.none.index, 0);
    expect(IntentType.move.index, 1);
    expect(IntentType.attack.index, 2);
    expect(IntentType.ability.index, 3); // left-click ability cast
  });
}
