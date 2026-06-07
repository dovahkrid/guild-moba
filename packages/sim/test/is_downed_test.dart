import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  Entity hero({int respawnTimer = 0, int hpRaw = 100 * 65536}) => Entity(
        id: 0,
        kind: EntityKind.hero,
        teamId: 0,
        pos: FVec2.zero,
        hp: Fixed.raw(hpRaw),
        respawnTimer: respawnTimer,
      );

  test('isDowned is true while respawning or at/below 0 hp, false when alive', () {
    expect(hero().isDowned, isFalse); // alive, full hp
    expect(hero(respawnTimer: 1).isDowned, isTrue); // respawning
    expect(hero(hpRaw: 0).isDowned, isTrue); // dropped to 0 (death tick)
    expect(hero(hpRaw: -65536).isDowned, isTrue); // overkilled
  });
}
