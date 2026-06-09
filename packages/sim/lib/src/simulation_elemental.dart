part of 'simulation.dart';

/// Stationary neutral elemental fields for [Simulation] (Plan 4/5), split out of
/// simulation.dart (cleaning phase). Same library → retains private access; zero
/// behavior change. Plan 8 grows this with more reactions.
extension SimulationElemental on Simulation {
  /// Field ticks (Plan 5): every active field, in stable list order, processes
  /// each hero/creep within its radius (2-sided — the owner is not exempt). A
  /// field deals NO DoT. If the unit carries a DIFFERENT element and its ICD is
  /// ready it detonates a field-overlap Vaporize: status consumed, ICD stamped,
  /// ReactionTriggered emitted (multiplierRaw 0 = "flat"), and FLAT
  /// kReactionFlatDamage dealt — but ONLY to an enemy of the field owner
  /// (owner/own-team take 0; the self-safety invariant). Otherwise the unit is
  /// coated (set/refresh, no damage). Iterates entityIdsSorted for determinism.
  void _stepFields(List<SimEvent> events) {
    for (final f in _fields) {
      // Owner is always a hero, and heroes are downed-not-removed, so
      // _byId[f.ownerId] is non-null while the field is alive: the respawn block
      // clears _fields for any returning hero, and _removeEntity (creeps/
      // structures) never touches _fields.
      final owner = _byId[f.ownerId]!;
      for (final id in entityIdsSorted) {
        final u = _byId[id]!;
        if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
        if (u.hp.raw <= 0) continue;
        if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
        if ((u.pos - f.center).lengthSq() > kFieldRadiusSq) continue;
        if (u.statusElement != -1 &&
            u.statusElement != f.element &&
            u.reactionIcd == 0) {
          // Field-overlap Vaporize. Fires 2-sided (consume + ICD + event); damage
          // lands ONLY on an enemy of the owner (own-team takes 0).
          u.statusElement = -1;
          u.statusTimer = 0;
          u.reactionIcd = kReactionIcdTicks;
          events.add(ReactionTriggered(
              unitId: u.id,
              reaction: Reaction.vaporize.index,
              multiplierRaw: 0, // flat: no triggering hit to amplify
              sourceId: f.ownerId));
          if (u.teamId != owner.teamId) {
            _applyDamage(owner, u, kReactionFlatDamage, events);
          }
        } else {
          // Coat (set/refresh). No damage. 2-sided. A different element suppressed
          // by an active ICD also lands here (overwrites; ICD gates only detonation).
          u.statusElement = f.element;
          u.statusTimer = kStatusDurationTicks;
        }
      }
    }
  }

  /// Cast burst (Plan 5): a one-time ENEMY-ONLY AoE hit centered on a freshly
  /// placed field. Routes each enemy hero/creep in radius through _applyHit, so it
  /// applies the caster's element AND triggers an attack-amplify Vaporize
  /// (×kVaporizeMult) on an already-differently-coated enemy. Own-team is excluded
  /// → self-safe. Iterates entityIdsSorted for determinism.
  void _castBurst(Entity caster, FVec2 center, int element, List<SimEvent> events,
      {Fixed? radiusSq, Fixed? damage}) {
    final rSq = radiusSq ?? kFieldRadiusSq;
    final dmg = damage ?? kCastBurstDamage;
    for (final id in entityIdsSorted) {
      final u = _byId[id]!;
      if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
      if (u.hp.raw <= 0) continue;
      if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
      if (u.teamId == caster.teamId) continue; // ENEMY-ONLY (own-team safe)
      if ((u.pos - center).lengthSq() > rSq) continue;
      _applyHit(caster, u, dmg, element, events);
    }
  }
}
