import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';

import 'interpolation_buffer.dart';
import 'match_view.dart';

class _Pending {
  final int clientTick;
  final Intent intent;
  const _Pending(this.clientTick, this.intent);
}

/// Owns the predicted sim + prediction/reconciliation/interpolation. Pure: the
/// HOST drives advanceClientTick() (per 33ms) and update(renderMs) (per frame).
/// Uses Fixed.sqrt (not dart:math) so the correction-dist metric stays pure.
class MatchController {
  final int localSlot;
  final Simulation _predicted;
  final InterpolationBuffer _interp = InterpolationBuffer();

  int _nextTick; // next tick to step; completed up to _nextTick-1
  int _localSeq = 0;
  final List<_Pending> _pending = []; // ordered by clientTick
  int _lastReconciledServerTick = -1;
  double _lastCorrectionDist = 0.0;
  final List<RenderReaction> _recentReactions = []; // collected each advanceClientTick

  MatchController({required int seed, required this.localSlot, required int startTick})
      : _predicted = Simulation.create(SimConfig(seed: seed)),
        _nextTick = startTick;

  int get predictedTick => _nextTick;
  int get lastServerTick => _lastReconciledServerTick;
  int get pendingCount => _pending.length;
  double get lastCorrectionDist => _lastCorrectionDist;

  // --- test seams ---
  int debugHash() => _predicted.canonicalStateHash();
  FVec2 debugLocalPos() => _predicted.entity(localSlot).pos;

  /// Record + apply a local move. Returns the InputMsg the host must send.
  /// Returns null (and records nothing) while the local hero is downed (Plan 6).
  InputMsg? applyLocalInput(int aimX, int aimY) {
    if (_predicted.entity(localSlot).isDowned) return null; // Plan 6: dead -> ignore input
    final seq = ++_localSeq;
    final intent = Intent(
        playerSlot: localSlot,
        type: IntentType.move,
        aimX: aimX,
        aimY: aimY,
        seq: seq,
        clientTick: _nextTick);
    _pending.add(_Pending(_nextTick, intent));
    return InputMsg(
        slot: localSlot,
        seq: seq,
        clientTick: _nextTick,
        aimX: aimX,
        aimY: aimY,
        type: IntentType.move.index);
  }

  /// Record + apply a local ATTACK lock onto [targetId]; returns the InputMsg to
  /// send. Returns null (and records nothing) while the local hero is downed (Plan 6).
  InputMsg? applyAttackInput(int targetId) {
    if (_predicted.entity(localSlot).isDowned) return null; // Plan 6: dead -> ignore input
    final seq = ++_localSeq;
    final intent = Intent(
        playerSlot: localSlot,
        type: IntentType.attack,
        aimX: targetId,
        seq: seq,
        clientTick: _nextTick);
    _pending.add(_Pending(_nextTick, intent));
    return InputMsg(
        slot: localSlot,
        seq: seq,
        clientTick: _nextTick,
        aimX: targetId,
        aimY: 0,
        type: IntentType.attack.index);
  }

  /// Record + apply a local ABILITY cast at world point (aimX,aimY) (Q16.16 raw);
  /// returns the InputMsg to send. Returns null (and records nothing) while the local hero is downed (Plan 6).
  InputMsg? applyAbilityInput(int aimX, int aimY) {
    if (_predicted.entity(localSlot).isDowned) return null; // Plan 6: dead -> ignore input
    final seq = ++_localSeq;
    final intent = Intent(
        playerSlot: localSlot,
        type: IntentType.ability,
        aimX: aimX,
        aimY: aimY,
        seq: seq,
        clientTick: _nextTick);
    _pending.add(_Pending(_nextTick, intent));
    return InputMsg(
        slot: localSlot,
        seq: seq,
        clientTick: _nextTick,
        aimX: aimX,
        aimY: aimY,
        type: IntentType.ability.index);
  }

  /// The local intents to apply at client tick [t]: the held move/attack (latest
  /// pending with clientTick <= t, last-writer-wins) PLUS any one-shot ability
  /// whose clientTick == t. Abilities are edge-triggered (fire once on their
  /// issuing tick); move/attack persist. Used in BOTH forward prediction and
  /// reconcile re-steps so prediction matches the server (which one-shots the
  /// ability too). _pending is ordered by clientTick → the break is safe.
  List<Intent> _intentsAt(int t) {
    Intent? held;
    final out = <Intent>[];
    for (final p in _pending) {
      if (p.clientTick > t) break;
      if (p.intent.type == IntentType.ability) {
        if (p.clientTick == t) out.add(p.intent); // one-shot: only on its issuing tick
      } else {
        held = p.intent; // latest move/attack persists
      }
    }
    if (held != null) out.add(held); // order not load-bearing: the sim re-sorts intents by (playerSlot, seq)
    return out;
  }

  /// Advance the predicted sim one tick (host calls at 30Hz). Collects reactions
  /// fired this tick (forward prediction only — reconcile re-steps do NOT collect,
  /// so a predicted reaction surfaces exactly once).
  void advanceClientTick() {
    final events = _predicted.step(_nextTick, _intentsAt(_nextTick));
    final presentIds = _predicted.entityIdsSorted.toSet(); // snapshot once (entityIdsSorted re-sorts per call)
    for (final e in events) {
      if (e is! ReactionTriggered) continue;
      if (!presentIds.contains(e.unitId)) continue; // reacting unit gone (shouldn't happen) — skip cosmetic pop-text
      final pos = _predicted.entity(e.unitId).pos;
      _recentReactions.add(RenderReaction(
        x: pos.x.toDouble(),
        y: pos.y.toDouble(),
        reaction: e.reaction,
        multiplierRaw: e.multiplierRaw,
      ));
    }
    _nextTick++;
  }

  /// Drain reactions collected since the last call (host spawns pop-text once per
  /// frame). Separate from update() because view/update() is read multiple times
  /// per frame; a side-effecting drain there would drop pop-texts.
  List<RenderReaction> drainReactions() {
    if (_recentReactions.isEmpty) return const [];
    final out = List<RenderReaction>.of(_recentReactions);
    _recentReactions.clear();
    return out;
  }

  /// Reconcile to an authoritative snapshot.
  void onServerSnapshot(SnapshotMsg snap) {
    // Interpolation always sees fresh ticks (dedupe handled inside). The
    // opponent hero is never removed (only downed), so this is normally present;
    // the nullable peek just requires a guard to compile (caller holds the last).
    final opp = Simulation.peekEntityPos(snap.stateBytes, 1 - localSlot);
    if (opp != null) {
      _interp.add(snap.serverTick, opp.x.toDouble(), opp.y.toDouble());
    }

    if (snap.serverTick <= _lastReconciledServerTick) return; // stale/dup guard

    // Pre-reconcile local pos (for correction distance).
    final before = _predicted.entity(localSlot).pos;

    // Drop acked pending intents.
    final acked = snap.ackedSeq[localSlot];
    _pending.removeWhere((p) => p.intent.seq <= acked);

    // Restore to authoritative state, then re-step to "now".
    // Note: acked-and-pruned intents are correctly reproduced here because the
    // authoritative target is carried in snapshotBytes()/restoreFromSnapshot();
    // if a future entity gains intent-derived state NOT stored in the snapshot,
    // this re-step loop would need that state too.
    _predicted.restoreFromSnapshot(snap.stateBytes);
    for (var t = snap.serverTick + 1; t < _nextTick; t++) {
      _predicted.step(t, _intentsAt(t));
    }

    // Compute correction distance using Fixed.sqrt (pure, no dart:math).
    final after = _predicted.entity(localSlot).pos;
    _lastCorrectionDist = (after - before).length().toDouble();
    _lastReconciledServerTick = snap.serverTick;
  }

  /// Render view (host calls per frame). Opponent hero interpolated ~100ms
  /// behind; everything else from the predicted sim.
  MatchView update(int renderTimeMs) {
    final oppId = 1 - localSlot;
    final hasInterp = _interp.length > 0;
    final opp = hasInterp ? _interp.sample(renderTimeMs - 100) : null;
    final entities = <RenderEntity>[];
    for (final id in _predicted.entityIdsSorted) {
      final e = _predicted.entity(id);
      var x = e.pos.x.toDouble();
      var y = e.pos.y.toDouble();
      if (id == oppId && opp != null) {
        x = opp.x; // opponent hero interpolated ~100ms behind
        y = opp.y;
      }
      entities.add(RenderEntity(
        id: id,
        kind: e.kind.index,
        teamId: e.teamId,
        x: x,
        y: y,
        hp: e.hp.toDouble(),
        maxHp: e.maxHp.toDouble(),
        statusElement: e.statusElement,
      ));
    }
    final fields = <RenderField>[
      for (final f in _predicted.fields)
        RenderField(
          ownerId: f.ownerId,
          x: f.center.x.toDouble(),
          y: f.center.y.toDouble(),
          element: f.element,
          radius: kFieldRadius.toDouble(),
        ),
    ];
    return MatchView(
      entities: entities,
      localSlot: localSlot,
      localGold: _predicted.entity(localSlot).gold,
      predictedTick: _nextTick,
      lastServerTick: _lastReconciledServerTick,
      pendingInputCount: _pending.length,
      lastCorrectionDist: _lastCorrectionDist,
      fields: fields,
    );
  }
}
