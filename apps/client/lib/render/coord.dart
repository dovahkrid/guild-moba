import 'package:sim/sim.dart';

/// World units are Q16.16 in the sim; render uses doubles. Pixels-per-world-unit
/// scales the lane to screen. Lane spans roughly x in [-12, 12], y in [-4, 4].
const double kPixelsPerUnit = 28.0;

/// Convert a Q16.16 raw integer (from the sim) to a world double.
double rawToWorld(int raw) => raw / kOne;

/// Convert a world double to a Q16.16 raw integer.
int worldToRaw(double w) => (w * kOne).round();

/// Convert a world x-coordinate to Flame screen pixels (x axis).
double worldToFlameX(double wx) => wx * kPixelsPerUnit;

/// Convert a world y-coordinate to Flame screen pixels (y axis).
double worldToFlameY(double wy) => wy * kPixelsPerUnit;

/// Convert a Flame pixel coordinate back to a world unit (single axis).
double flameToWorld(double f) => f / kPixelsPerUnit;

/// Pixel radius of a tower's attack-range ring (the sim's [kTowerAttackRange]
/// in world units, scaled to screen). Reads the constant so it tracks any
/// future range change. At range 4 this is 4 * 28 = 112 px.
double towerRangeRingRadiusPx() => kTowerAttackRange.toDouble() * kPixelsPerUnit;
