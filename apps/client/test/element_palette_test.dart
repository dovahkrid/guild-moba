import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sim/sim.dart' show Element;
import 'package:guild_client/render/element_palette.dart';

void main() {
  test('elementColor maps Pyro/Hydro and returns null for none', () {
    expect(elementColor(Element.pyro.index), isA<Color>());
    expect(elementColor(Element.hydro.index), isA<Color>());
    expect(elementColor(-1), isNull);
  });

  test('fieldColor is translucent', () {
    expect(fieldColor(Element.pyro.index).a, closeTo(0.22, 0.01));
  });
}
