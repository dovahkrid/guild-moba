import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim/sim.dart' show EntityKind;
import 'package:guild_client/render/fx/damage_number.dart';

void main() {
  test('damageText rounds Q16.16 raw to a whole number', () {
    expect(damageText(524288), '8'); // 8.0 * 65536
    expect(damageText(851968), '13'); // 13.0
  });

  test('damageColor: hero source vs structure source differ', () {
    expect(damageColor(EntityKind.hero.index), isA<Color>());
    expect(damageColor(EntityKind.tower.index), isNot(damageColor(EntityKind.hero.index)));
  });
}
