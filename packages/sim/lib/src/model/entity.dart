import '../math/fixed.dart';
import '../math/fvec2.dart';

enum EntityKind { hero, wanderer }

/// A simulated unit. Plan 1 only moves entities; combat fields arrive in Plan 3.
class Entity {
  final int id;
  final EntityKind kind;
  final int teamId;

  FVec2 pos;
  FVec2 vel;
  Fixed hp;

  // Heroes seek toward this point (set by a move intent).
  FVec2 target;

  Entity({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.pos,
    required this.hp,
    FVec2? vel,
    FVec2? target,
  })  : vel = vel ?? FVec2.zero,
        target = target ?? pos;
}
