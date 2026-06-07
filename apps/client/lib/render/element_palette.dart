import 'dart:ui';

import 'package:sim/sim.dart' show Element;

/// Element → display colour (spec §9 palette). Returns null for no status (-1)
/// or an element without a slice colour yet.
Color? elementColor(int element) {
  if (element == Element.pyro.index) return const Color(0xFFFF7043); // pyro orange
  if (element == Element.hydro.index) return const Color(0xFF26C6DA); // hydro teal
  return null;
}

/// Translucent fill for a field zone of [element].
Color fieldColor(int element) =>
    (elementColor(element) ?? const Color(0xFF9E9E9E)).withValues(alpha: 0.22);
