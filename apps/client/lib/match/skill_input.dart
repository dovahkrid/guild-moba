/// The action GuildGame should take in response to a skill-input event.
enum SkillAction {
  none, // do nothing
  castAtSelf, // cast immediately at the hero's own position
  enterAim, // begin aiming (wait for a left-click); show no reticle this pass
  castAtPoint, // cast at the just-clicked world point
  cancel, // abort a pending aim
}

/// Pure state machine for the E-cast / left-click-aim control scheme (spec
/// 2026-06-09 §3). Holds no rendering or network concerns — GuildGame maps its
/// [SkillAction] results onto MatchBinding.submitAbility. Unit-tested in
/// isolation (no Flame harness needed).
class SkillInputController {
  bool _aimPending = false;
  bool get aimPending => _aimPending;

  /// The skill key (E) was pressed. [downed] gates all casting (Plan 6);
  /// [placesAtSelf] is `heroPlacesAtSelf(localHeroId)`.
  SkillAction onSkillKey({required bool downed, required bool placesAtSelf}) {
    if (downed) {
      final wasPending = _aimPending;
      _aimPending = false;
      return wasPending ? SkillAction.cancel : SkillAction.none;
    }
    if (_aimPending) {
      _aimPending = false; // E again cancels a pending aim
      return SkillAction.cancel;
    }
    if (placesAtSelf) return SkillAction.castAtSelf; // immediate; stays idle
    _aimPending = true;
    return SkillAction.enterAim;
  }

  /// A left-click happened. Only meaningful while aiming.
  SkillAction onLeftClick() {
    if (!_aimPending) return SkillAction.none; // bare left-click does nothing
    _aimPending = false;
    return SkillAction.castAtPoint;
  }

  /// A right-click happened. Returns true if it was consumed as an aim-cancel
  /// (the caller must then NOT issue a move); false if there was no pending aim
  /// (the caller handles it as a normal move/attack).
  bool onRightClickConsumedAsCancel() {
    if (!_aimPending) return false;
    _aimPending = false;
    return true;
  }

  /// Force-clear a pending aim (e.g. the local hero became downed mid-aim).
  /// Returns true if an aim was actually cancelled.
  bool clearAim() {
    if (!_aimPending) return false;
    _aimPending = false;
    return true;
  }
}
