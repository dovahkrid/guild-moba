import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/render/coord.dart';
import 'package:guild_client/render/dashed_circle.dart';
import 'package:sim/sim.dart';

void main() {
  test('tower range ring radius is kTowerAttackRange converted to pixels', () {
    expect(towerRangeRingRadiusPx(), kTowerAttackRange.toDouble() * kPixelsPerUnit);
    // After Task A (range 4): 4 * 28 = 112 px.
    expect(towerRangeRingRadiusPx(), 112.0);
  });

  test('DashedCircle exposes the radius it was given', () {
    final c = DashedCircle(radius: 112.0, color: const Color(0x5564B5F6));
    expect(c.radius, 112.0);
    expect(c.dashCount, greaterThan(0));
  });
}
