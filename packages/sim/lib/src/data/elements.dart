import '../math/fixed.dart';
import '../model/element.dart';

/// Elemental tunables for the Vaporize slice. PLAYTEST PLACEHOLDERS (spec §13
/// defers exact numbers); all obey the Fixed budget (|value| < 32768).

// --- Status (Genshin LIGHT timing, spec §3.1) ---
const int kStatusDurationTicks = 45; // ~1.5s LIGHT status
const int kReactionIcdTicks = 15; // ~0.5s per-unit reaction internal cooldown

// --- Vaporize (amplify; spec §3.3 committed field-cap multiplier) ---
final Fixed kVaporizeMult = Fixed.fromNum(1.3);

// --- Neutral fields (coat-only; no DoT in v2) ---
final Fixed kFieldRadius = Fixed.fromNum(2.5);
final Fixed kFieldRadiusSq = Fixed.fromNum(2.5 * 2.5); // compare vs lengthSq, no sqrt
const int kFieldDurationTicks = 120; // ~4s
const int kAbilityCooldownTicks = 240; // ~8s (> field duration → ≤1 active field/hero)

// --- Plan 5 damage model (v2) ---
// A one-time, enemy-only AoE dealt on cast, centered on the field. May be
// amplified by an attack-amplify reaction → kCastBurstDamage × kVaporizeMult must
// stay in the Fixed budget.
final Fixed kCastBurstDamage = Fixed.fromNum(10);
// Flat damage from a field-overlap reaction (no triggering hit to amplify);
// dealt only to an ENEMY of the field owner (owner/own-team take 0).
final Fixed kReactionFlatDamage = Fixed.fromNum(8);

// --- Slice roster (data) ---
// hero 0 = Cinderfang (Pyro, Ember Field placed at his own position);
// hero 1 = Marisol    (Hydro, Tidepool placed at the aim point).
/// Element each hero applies. Slice roster is 1v1: heroId must be 0 or 1.
int heroElement(int heroId) {
  assert(heroId == 0 || heroId == 1, 'roster is 1v1: heroId must be 0 or 1');
  return heroId == 0 ? Element.pyro.index : Element.hydro.index;
}

/// Whether this hero self-places its field (Cinderfang) vs aim-places (Marisol).
/// Slice roster is 1v1: heroId must be 0 or 1.
bool heroPlacesAtSelf(int heroId) {
  assert(heroId == 0 || heroId == 1, 'roster is 1v1: heroId must be 0 or 1');
  return heroId == 0;
}
