import '../math/fvec2.dart';

/// A stationary neutral elemental field (Plan 4). NOT an Entity — it lives in a
/// small serialized list on Simulation. Placed at the caster's position (cast
/// time) and coats any hero/creep within kFieldRadius each tick (2-sided: the
/// owner is not exempt). Removed when `timer` reaches 0.
class ElementalField {
  final int ownerId; // the hero who cast it (for DamageDealt.sourceId / credit)
  final FVec2 center; // cast position; STATIONARY (does not follow the owner)
  final int element; // Element.index
  int timer; // ticks remaining
  ElementalField({
    required this.ownerId,
    required this.center,
    required this.element,
    required this.timer,
  });
}
