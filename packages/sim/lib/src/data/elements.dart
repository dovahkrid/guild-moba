import '../math/fixed.dart';
import '../model/element.dart';

/// Elemental tunables for the Vaporize slice. PLAYTEST PLACEHOLDERS (spec §13
/// defers exact numbers); all obey the Fixed budget (|value| < 32768).

// --- Status (Genshin LIGHT timing, spec §3.1) ---
const int kStatusDurationTicks = 45; // ~1.5s LIGHT status
const int kReactionIcdTicks = 15; // ~0.5s per-unit reaction internal cooldown

// --- Vaporize (amplify; spec §3.3 committed field-cap multiplier) ---
final Fixed kVaporizeMult = Fixed.fromNum(1.3);

// --- Neutral fields ---
final Fixed kFieldRadius = Fixed.fromNum(2.5);
final Fixed kFieldRadiusSq = Fixed.fromNum(2.5 * 2.5); // compare vs lengthSq, no sqrt
final Fixed kFieldDotDamage = Fixed.fromNum(1); // per-tick DoT to HEROES (zero to creeps)
const int kFieldDurationTicks = 120; // ~4s
const int kAbilityCooldownTicks = 240; // ~8s (> field duration → ≤1 active field/hero)

// --- Slice roster (data) ---
// hero 0 = Cinderfang (Pyro, Ember Field placed at his own position);
// hero 1 = Marisol    (Hydro, Tidepool placed at the aim point).
int heroElement(int heroId) =>
    heroId == 0 ? Element.pyro.index : Element.hydro.index;
bool heroPlacesAtSelf(int heroId) => heroId == 0;
