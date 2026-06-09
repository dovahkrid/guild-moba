import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/match/skill_input.dart';

void main() {
  test('self-placed hero casts immediately, no aim', () {
    final s = SkillInputController();
    expect(s.onSkillKey(downed: false, placesAtSelf: true), SkillAction.castAtSelf);
    expect(s.aimPending, isFalse);
  });

  test('aim-placed hero: E enters aim, then left-click casts at the point', () {
    final s = SkillInputController();
    expect(s.onSkillKey(downed: false, placesAtSelf: false), SkillAction.enterAim);
    expect(s.aimPending, isTrue);
    expect(s.onLeftClick(), SkillAction.castAtPoint);
    expect(s.aimPending, isFalse);
  });

  test('bare left-click with no aim pending does nothing', () {
    final s = SkillInputController();
    expect(s.onLeftClick(), SkillAction.none);
  });

  test('downed hero cannot cast', () {
    final s = SkillInputController();
    expect(s.onSkillKey(downed: true, placesAtSelf: true), SkillAction.none);
    expect(s.onSkillKey(downed: true, placesAtSelf: false), SkillAction.none);
    expect(s.aimPending, isFalse);
  });

  test('E again cancels a pending aim', () {
    final s = SkillInputController();
    s.onSkillKey(downed: false, placesAtSelf: false); // enterAim
    expect(s.onSkillKey(downed: false, placesAtSelf: false), SkillAction.cancel);
    expect(s.aimPending, isFalse);
  });

  test('right-click is consumed as a cancel only while aiming', () {
    final s = SkillInputController();
    expect(s.onRightClickConsumedAsCancel(), isFalse); // idle: not consumed -> caller moves
    s.onSkillKey(downed: false, placesAtSelf: false); // enterAim
    expect(s.onRightClickConsumedAsCancel(), isTrue); // consumed -> caller suppresses move
    expect(s.aimPending, isFalse);
  });

  test('going downed mid-aim clears the pending aim', () {
    final s = SkillInputController();
    s.onSkillKey(downed: false, placesAtSelf: false); // enterAim
    expect(s.clearAim(), isTrue);
    expect(s.aimPending, isFalse);
    expect(s.clearAim(), isFalse); // already clear
  });

  test('left-click after a cancel returns none (state fully reset to idle)', () {
    final s = SkillInputController();
    s.onSkillKey(downed: false, placesAtSelf: false); // enterAim
    expect(s.onRightClickConsumedAsCancel(), isTrue); // cancel the pending aim
    expect(s.onLeftClick(), SkillAction.none); // idle again -> no stray cast
    expect(s.aimPending, isFalse);
  });

  test('Q (ult slot) aim-places, then a left-click casts at the point', () {
    final s = SkillInputController();
    expect(s.onSkillKey(downed: false, placesAtSelf: false, slot: SkillSlot.ult), SkillAction.enterAim);
    expect(s.armedSlot, SkillSlot.ult);
    expect(s.onLeftClick(), SkillAction.castAtPoint);
    expect(s.armedSlot, isNull);
  });

  test('Q self-place casts immediately, no aim', () {
    final s = SkillInputController();
    expect(s.onSkillKey(downed: false, placesAtSelf: true, slot: SkillSlot.ult), SkillAction.castAtSelf);
    expect(s.aimPending, isFalse);
  });

  test('pressing any skill key while aiming cancels (E armed, Q pressed)', () {
    final s = SkillInputController();
    s.onSkillKey(downed: false, placesAtSelf: false, slot: SkillSlot.ability);
    expect(s.onSkillKey(downed: false, placesAtSelf: false, slot: SkillSlot.ult), SkillAction.cancel);
    expect(s.aimPending, isFalse);
  });
}
