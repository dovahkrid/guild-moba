import '../math/fixed.dart';
import '../math/fvec2.dart';

/// Append-only: kind.index is serialized in canonicalBytes() AND snapshotBytes().
/// hero=0, wanderer=1 are from Plan 1; tower/creep/core are appended for combat.
enum EntityKind { hero, wanderer, tower, creep, core }

/// A simulated unit. Plan 3 adds combat state.
class Entity {
  final int id;
  final EntityKind kind;
  final int teamId; // 0/1 = players; 2 = neutral (wanderer, creeps).

  FVec2 pos;
  FVec2 vel;
  Fixed hp;

  /// Full health (for the health-bar ratio + clamping). Constant per entity.
  Fixed maxHp;

  /// Ticks remaining until this unit may attack again (0 = ready).
  int attackCooldown;

  /// Accumulated last-hit gold (heroes only; running total → int, not Fixed).
  int gold;

  /// Ticks until a downed hero respawns (0 = alive). >0 means downed:
  /// untargetable, cannot attack, ignores move intents.
  int respawnTimer;

  /// Locked attack target entity id (-1 = none). Set by an attack intent,
  /// cleared by a move intent or when the target dies/leaves. Heroes pursue +
  /// attack ONLY this id. Persistent, intent-derived → serialized so reconcile
  /// reproduces it.
  int attackTargetId;

  /// Elemental status (Plan 4): the single element coating this unit.
  /// -1 = none; else Element.index. Serialized (heroes/creeps only ever carry it).
  int statusElement;

  /// Ticks of elemental status remaining; at 0 the status is swept to -1.
  int statusTimer;

  /// Per-unit reaction internal-cooldown (ticks; 0 = ready). Gates Vaporize so
  /// an overlap can't machine-gun reactions.
  int reactionIcd;

  /// Ticks until this hero's field ability is ready (0 = ready).
  int abilityCooldown;

  // Heroes seek toward this point (set by a move intent / pursue resolution).
  FVec2 target;

  Entity({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.pos,
    required this.hp,
    Fixed? maxHp,
    this.attackCooldown = 0,
    this.gold = 0,
    this.respawnTimer = 0,
    this.attackTargetId = -1,
    this.statusElement = -1,
    this.statusTimer = 0,
    this.reactionIcd = 0,
    this.abilityCooldown = 0,
    FVec2? vel,
    FVec2? target,
  })  : maxHp = maxHp ?? hp,
        vel = vel ?? FVec2.zero,
        target = target ?? pos;

  /// True while a hero is dead/respawning: untargetable, ignores input, does not
  /// pursue or attack. respawnTimer>0 after the death sweep; hp<=0 on the death
  /// tick itself (or from a same-tick burst) before the sweep parks it.
  bool get isDowned => respawnTimer != 0 || hp.raw <= 0;
}
