/// Cosmetic-only events emitted by Simulation.step(). They NEVER mutate state,
/// so the predicted client and authoritative server emit identical events for
/// the same (tick, intents, prior state). Plan 3 emits the combat subset only;
/// the rest are declared for Plan 4+ (reactions) and a later revenge-boss plan.
sealed class SimEvent {
  const SimEvent();
}

class DamageDealt extends SimEvent {
  final int sourceId;
  final int targetId;
  final int amountRaw; // Q16.16 raw of the damage applied
  const DamageDealt({
    required this.sourceId,
    required this.targetId,
    required this.amountRaw,
  });
}

class CreepKilled extends SimEvent {
  final int creepId;
  final int killerId;
  final int gold;
  const CreepKilled({
    required this.creepId,
    required this.killerId,
    required this.gold,
  });
}

class TowerDestroyed extends SimEvent {
  final int towerId;
  final int teamId; // owner of the fallen tower
  final int killerId; // the "debtor" — revenge-boss target hook for a later plan
  const TowerDestroyed({
    required this.towerId,
    required this.teamId,
    required this.killerId,
  });
}

class CoreDestroyed extends SimEvent {
  final int teamId; // owner of the destroyed core
  final int winnerTeam;
  const CoreDestroyed({required this.teamId, required this.winnerTeam});
}

// --- Declared for Plan 4+ (NOT emitted in Plan 3). ---
class ReactionTriggered extends SimEvent {
  final int unitId; // who carried the consumed status (the reaction lands here)
  final int reaction; // Reaction.index
  final int multiplierRaw; // Q16.16 raw of the applied multiplier (e.g. ×1.3)
  final int sourceId; // who landed the triggering hit
  const ReactionTriggered({
    required this.unitId,
    required this.reaction,
    required this.multiplierRaw,
    required this.sourceId,
  });
}

class BossSpawned extends SimEvent {
  final int bossId;
  final int teamId;
  const BossSpawned({required this.bossId, required this.teamId});
}

class LevelUp extends SimEvent {
  final int heroId;
  final int level;
  const LevelUp({required this.heroId, required this.level});
}
