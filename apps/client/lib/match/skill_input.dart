/// Which skill slot an aim is armed for: E = ability, Q = ult.
enum SkillSlot { ability, ult }

/// The action GuildGame should take in response to a skill-input event.
enum SkillAction {
  none, // do nothing
  castAtSelf, // cast immediately at the hero's own position
  enterAim, // begin aiming (wait for a left-click)
  castAtPoint, // cast at the just-clicked world point
  cancel, // abort a pending aim
}

/// Pure state machine for the E/Q-cast + left-click-aim control scheme (spec
/// 2026-06-09 §3 + Plan 7 part 1). One aim may be armed at a time, for the
/// ability (E) or the ult (Q). Holds no rendering/network concerns — GuildGame
/// maps [SkillAction] + [armedSlot] onto submitAbility / submitUltimate.
class SkillInputController {
  SkillSlot? _armed;
  bool get aimPending => _armed != null;

  /// Which slot is currently armed (null = idle). Read BEFORE [onLeftClick] to
  /// route a castAtPoint to the right submit call.
  SkillSlot? get armedSlot => _armed;

  /// A skill key was pressed for [slot]. [downed] gates all casting (Plan 6);
  /// [placesAtSelf] is `heroPlacesAtSelf(localHeroId)`.
  SkillAction onSkillKey({
    required bool downed,
    required bool placesAtSelf,
    SkillSlot slot = SkillSlot.ability,
  }) {
    if (downed) {
      final was = _armed != null;
      _armed = null;
      return was ? SkillAction.cancel : SkillAction.none;
    }
    if (_armed != null) {
      _armed = null; // any skill key while aiming cancels the pending aim
      return SkillAction.cancel;
    }
    if (placesAtSelf) return SkillAction.castAtSelf; // immediate; stays idle
    _armed = slot;
    return SkillAction.enterAim;
  }

  /// A left-click happened. Only meaningful while aiming.
  SkillAction onLeftClick() {
    if (_armed == null) return SkillAction.none; // bare left-click does nothing
    _armed = null;
    return SkillAction.castAtPoint;
  }

  /// A right-click happened. Returns true if it was consumed as an aim-cancel
  /// (the caller must then NOT issue a move); false if there was no pending aim.
  bool onRightClickConsumedAsCancel() {
    if (_armed == null) return false;
    _armed = null;
    return true;
  }

  /// Force-clear a pending aim (e.g. the local hero became downed mid-aim).
  /// Returns true if an aim was actually cancelled.
  bool clearAim() {
    if (_armed == null) return false;
    _armed = null;
    return true;
  }
}
