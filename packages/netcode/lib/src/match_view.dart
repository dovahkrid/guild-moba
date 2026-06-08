import 'package:sim/sim.dart';

/// Render-boundary value types. Doubles/ints ONLY (never fed back into the sim).
class RenderEntity {
  final int id;
  final int kind; // EntityKind.index
  final int teamId; // 0/1 players, 2 neutral
  final double x, y;
  final double hp, maxHp;
  final int statusElement; // Plan 4: Element.index of the status, -1 = none
  const RenderEntity({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.x,
    required this.y,
    required this.hp,
    required this.maxHp,
    this.statusElement = -1,
  });
}

/// A stationary elemental field zone (Plan 4) for the client to draw.
class RenderField {
  final int ownerId;
  final double x, y;
  final int element; // Element.index
  final double radius;
  const RenderField({
    required this.ownerId,
    required this.x,
    required this.y,
    required this.element,
    required this.radius,
  });
}

/// A reaction that fired this tick (Plan 4) — drives a transient pop-text.
class RenderReaction {
  final double x, y;
  final int reaction; // Reaction.index
  final int multiplierRaw; // Q16.16 raw of the multiplier (e.g. ×1.3)
  const RenderReaction({
    required this.x,
    required this.y,
    required this.reaction,
    required this.multiplierRaw,
  });
}

class MatchView {
  /// All LIVE entities (local hero predicted; opponent hero interpolated;
  /// others straight from the predicted sim). Discrete fields (hp, statusElement)
  /// are snapshot values — never interpolated.
  final List<RenderEntity> entities;
  final int localSlot;
  final int localGold;
  final int predictedTick;
  final int lastServerTick;
  final int pendingInputCount;
  final double lastCorrectionDist;
  final List<RenderField> fields; // Plan 4: active elemental field zones
  const MatchView({
    required this.entities,
    required this.localSlot,
    required this.localGold,
    required this.predictedTick,
    required this.lastServerTick,
    required this.pendingInputCount,
    required this.lastCorrectionDist,
    this.fields = const [],
  });

  /// The local hero's render entity (predicted).
  RenderEntity get local => entities.firstWhere((e) => e.id == localSlot);

  /// The opponent hero's render entity (interpolated). Always present (heroes
  /// respawn rather than despawn).
  RenderEntity get opponent => entities.firstWhere((e) => e.id == 1 - localSlot);
}

/// A pre/post-step positional snapshot of one entity (for resolving FX origins,
/// including entities removed by the same step's death sweep).
class EntitySnap {
  final double x, y;
  final int kind, teamId;
  const EntitySnap({required this.x, required this.y, required this.kind, required this.teamId});
}

/// Cosmetic combat FX surfaced at the render boundary. Built client-side from
/// already-emitted SimEvents during FORWARD prediction only (reconcile re-steps
/// do NOT collect), so each surfaces exactly once. NEVER serialized / sent.
sealed class RenderFx {
  const RenderFx();
}

class HitFx extends RenderFx {
  final int victimId, sourceId, sourceKind, amountRaw;
  final double x, y; // victim impact position (world)
  const HitFx({
    required this.victimId,
    required this.sourceId,
    required this.sourceKind,
    required this.amountRaw,
    required this.x,
    required this.y,
  });
}

class KillFx extends RenderFx {
  final double x, y;
  const KillFx({required this.x, required this.y});
}

class TowerFallFx extends RenderFx {
  final int teamId;
  final double x, y;
  const TowerFallFx({required this.teamId, required this.x, required this.y});
}

class CoreFx extends RenderFx {
  final int teamId, winnerTeam;
  final double x, y;
  const CoreFx({required this.teamId, required this.winnerTeam, required this.x, required this.y});
}

class HeroDownFx extends RenderFx {
  final int heroId;
  final double x, y;
  const HeroDownFx({required this.heroId, required this.x, required this.y});
}

/// Project the cosmetic combat [events] into [RenderFx], resolving positions
/// from [after] (falling back to [before] for entities removed this step). Pure;
/// unit-tested. ReactionTriggered is handled separately (drainReactions); the
/// declared-but-unemitted LevelUp/BossSpawned are ignored.
List<RenderFx> projectFx(
  Iterable<SimEvent> events,
  Map<int, EntitySnap> before,
  Map<int, EntitySnap> after,
) {
  EntitySnap? at(int id) => after[id] ?? before[id];
  final out = <RenderFx>[];
  for (final e in events) {
    switch (e) {
      case DamageDealt(:final sourceId, :final targetId, :final amountRaw):
        final p = at(targetId);
        if (p == null) break;
        out.add(HitFx(
          victimId: targetId,
          sourceId: sourceId,
          sourceKind: at(sourceId)?.kind ?? -1,
          amountRaw: amountRaw,
          x: p.x,
          y: p.y,
        ));
      case CreepKilled(:final creepId):
        final p = at(creepId);
        if (p != null) out.add(KillFx(x: p.x, y: p.y));
      case TowerDestroyed(:final towerId, :final teamId):
        final p = at(towerId);
        if (p != null) out.add(TowerFallFx(teamId: teamId, x: p.x, y: p.y));
      case CoreDestroyed(:final teamId, :final winnerTeam):
        final p = _coreOf(after, teamId) ?? _coreOf(before, teamId);
        out.add(CoreFx(teamId: teamId, winnerTeam: winnerTeam, x: p?.x ?? 0, y: p?.y ?? 0));
      case HeroDowned(:final heroId):
        final p = at(heroId);
        if (p != null) out.add(HeroDownFx(heroId: heroId, x: p.x, y: p.y));
      default:
        break; // ReactionTriggered / LevelUp / BossSpawned: no FX here
    }
  }
  return out;
}

EntitySnap? _coreOf(Map<int, EntitySnap> m, int teamId) {
  for (final s in m.values) {
    if (s.kind == EntityKind.core.index && s.teamId == teamId) return s;
  }
  return null;
}
