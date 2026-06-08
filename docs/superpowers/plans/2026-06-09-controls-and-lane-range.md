# Controls (E-cast aim) + Lane Range + Range Rings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop the tower attack range so a tower reaches exactly to the midline (range-only sim retune + `combat.golden` re-pin), draw an always-on dashed range ring on every tower, and add an **E**-key skill cast that aims only when the skill needs it — all on the client's existing `submitAbility` path.

**Architecture:** Three independent slices. **Part A** is a constant-only sim change (`kTowerAttackRange`/`…Sq` 5→4) verified by the existing symbolic tests and a single sanctioned golden re-pin (empirically pre-verified: only `combat.golden` moves, `3824c068`→`030f2343`). **Parts B & C are `apps/client`-only** (render + input), determinism-neutral. Part B adds a reusable `DashedCircle` component and a pure radius helper. Part C extracts the control logic into a **pure `SkillInputController`** state machine (unit-tested like `facingFor`, since `flame_test` is not a dependency), wired into `GuildGame` keyboard/click handlers.

**Tech Stack:** Dart 3.11.5 pure-Dart `sim`; Flutter + Flame `^1.30.0` client (`flutter_test` only — no Flame test harness); `tooling/replay_harness.dart` + `tooling/compare_replays.sh` (native + dart2js/node + dart2wasm/node, all present locally).

**Spec:** `docs/superpowers/specs/2026-06-09-controls-and-lane-range-design.md`. **Branch:** `feat/controls-and-lane-range` off `main` (`763138f`).

**Determinism invariant (Part A only):** `Fixed`(Q16.16)+`int`, values `< 32768`; no `dart:math`/`Random`/`DateTime` in `packages/sim/lib`; no new RNG draw; no enum/field/byte-layout/version change (3/3). Tower **positions** untouched (range-only). Parts B & C touch **only `apps/client`** — no `packages/sim` mechanics, no `packages/netcode`, no `packages/protocol`, no byte-layout/protocol change.

**Important for the implementer:** the repo is already on `feat/controls-and-lane-range` — **do NOT run `git checkout`/`git switch`**. Sim unit-test assertions are **symbolic**, so they stay green on the new range; only stale **comments** change in `combat_test.dart`. If a sim test fails, that's a real regression to investigate, NOT a literal to edit.

---

## File Structure

**Part A — modified (sim, values + comments only):**
- `packages/sim/lib/src/data/combat.dart` — `kTowerAttackRange` (line 20), `kTowerAttackRangeSq` (line 21) + their comment.
- `packages/sim/test/combat_test.dart` — three stale "range 5"/">5" comments (lines 43, 185, 262).
- Re-pin: `tooling/replay_fixtures/combat.golden` (`3824c068`→`030f2343`).

**Part B — created/modified (client render):**
- Create: `apps/client/lib/render/dashed_circle.dart` — a `CircleComponent` whose outline is dashed.
- Modify: `apps/client/lib/render/coord.dart` — add the pure `towerRangeRingRadiusPx()` helper.
- Modify: `apps/client/lib/render/entity_view.dart` — add a dashed range ring child to tower views (behind a `kShowTowerRangeRings` flag).
- Create: `apps/client/test/tower_range_ring_test.dart`.

**Part C — created/modified (client input):**
- Create: `apps/client/lib/match/skill_input.dart` — pure `SkillAction` enum + `SkillInputController` state machine.
- Modify: `apps/client/lib/render/guild_game.dart` — `KeyboardEvents` mixin, `E` handling, left-click = aim-confirm-only, right-click cancels a pending aim, downed-clear in `update`.
- Create: `apps/client/test/skill_input_test.dart`.

**Untouched (asserted unchanged):** `smoke.golden`, `elemental.golden`, the `0x0fbfb7ac` anchor, all `packages/netcode`, `packages/protocol`, `packages/sim/lib/src/simulation*.dart`, `apps/server`.

---

## Task 1: Part A — tower range 5→4 + re-pin `combat.golden`

**Files:**
- Modify: `packages/sim/lib/src/data/combat.dart`
- Modify: `packages/sim/test/combat_test.dart` (comments only)
- Re-pin: `tooling/replay_fixtures/combat.golden`

- [ ] **Step 1: Edit the two range constants in `combat.dart`**

Change lines 20–21 (both in lockstep — the squared value is the actual targeting gate; `combat_test.dart` asserts `RangeSq == Range²`):
```dart
final Fixed kTowerAttackRange = Fixed.fromNum(4); // world-units (playtest-tuned 2026-06-09, was 5 — reaches exactly to the midline; towers NOT moved)
final Fixed kTowerAttackRangeSq = Fixed.fromNum(4 * 4); // compare vs lengthSq, no sqrt
```
Do NOT change `kOuterTowerX`/`kInnerTowerX`/`kCoreX` or any other constant. (The file header already says "PLAYTEST-TUNED … revisit in a future pass"; leave it.)

- [ ] **Step 2: Refresh the stale `combat_test.dart` range comments (assertions unchanged)**

In `packages/sim/test/combat_test.dart`:
- Line 43: `// (towers at x=±4/±10, range 5) — keeps this hero-vs-hero test combat-free.` → change `range 5` to `range 4`.
- Line 185: `// (towers at x=±4/±10, range 5) — isolates the downed-hero behavior.` → `range 4`.
- Line 262: `// (x=-8 is >5 from every enemy tower at +4/+10/+14, and own towers never` → change `>5` to `>4` (still true: `|-8 − 4| = 12 > 4`).

(Comments only — the assertions reference constants symbolically and stay green. The "40-hp creep" name and "40hp / 10dmg = 4 hits" comment are creep tunables, untouched.)

- [ ] **Step 3: Run the sim suite + analyze — expect ALL GREEN**

Run: `cd packages/sim && dart analyze && dart test`
Expected: analyze clean; **all 116 sim tests pass** (`RangeSq == Range²` holds at 16 == 4²; the hero-vs-hero and last-hit tests still sit outside range 4).

- [ ] **Step 4: Attribution gate — confirm ONLY `combat.golden` moved (native hashes)**

Run (from repo root, using the Bash tool):
```bash
for f in smoke combat elemental; do
  B64=$(base64 -w0 tooling/replay_fixtures/$f.json 2>/dev/null || base64 tooling/replay_fixtures/$f.json | tr -d '\n')
  H=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
  echo "$f -> $H (committed golden: $(tr -d '\r\n' < tooling/replay_fixtures/$f.golden))"
done
```
Expected (pre-verified during planning): `smoke -> 7e4aa28f` (UNCHANGED), `elemental -> 717305eb` (UNCHANGED), `combat -> 030f2343` (CHANGED vs `3824c068` — the sanctioned move). **If smoke or elemental changed, STOP** — a constant leaked beyond combat; investigate before re-pinning.

Anchor check: `cd packages/sim && dart test test/simulation_test.dart` → must PASS including the pinned `0x0fbfb7ac` canonical-state-hash test.

- [ ] **Step 5: Re-pin `combat.golden` (native hash, LF newline)**

Run (from repo root):
```bash
B64=$(base64 -w0 tooling/replay_fixtures/combat.json 2>/dev/null || base64 tooling/replay_fixtures/combat.json | tr -d '\n')
NEW=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
printf '%s\n' "$NEW" > tooling/replay_fixtures/combat.golden
echo "re-pinned combat.golden -> $NEW"
git --no-pager diff -- tooling/replay_fixtures/combat.golden
```
Expected: the diff shows only the single hash line changing (`3824c068` → `030f2343`).

- [ ] **Step 6: Cross-runtime parity (toolchain present — RUN it)**

Run:
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
```
Expected: combat → `PASS: byte-identical across native/js/wasm: 030f2343` + `PASS: matches golden`; smoke + elemental → both `PASS: matches golden` (`7e4aa28f` / `717305eb`).

- [ ] **Step 7: Scope guard + commit**

```bash
git diff --quiet main -- packages/netcode packages/protocol packages/sim/lib/src/simulation.dart && echo "SCOPE OK"
git add packages/sim/lib/src/data/combat.dart packages/sim/test/combat_test.dart tooling/replay_fixtures/combat.golden
git commit -m "balance(sim): tower range 5->4 (reach to midline) + re-pin combat.golden"
```
`SCOPE OK` must print (exit 0 — no netcode/protocol/mechanics change). Commit ONLY those three files.

---

## Task 2: Part B — always-on dashed range rings on all towers (client)

**Files:**
- Create: `apps/client/lib/render/dashed_circle.dart`
- Modify: `apps/client/lib/render/coord.dart`
- Modify: `apps/client/lib/render/entity_view.dart`
- Test: `apps/client/test/tower_range_ring_test.dart`

- [ ] **Step 1: Write the failing test for the radius helper + the component**

Create `apps/client/test/tower_range_ring_test.dart`:
```dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/render/coord.dart';
import 'package:guild_client/render/dashed_circle.dart';
import 'package:sim/sim.dart';

void main() {
  test('tower range ring radius is kTowerAttackRange converted to pixels', () {
    expect(towerRangeRingRadiusPx(), kTowerAttackRange.toDouble() * kPixelsPerUnit);
    // After Task 1 (range 4): 4 * 28 = 112 px.
    expect(towerRangeRingRadiusPx(), 112.0);
  });

  test('DashedCircle exposes the radius it was given', () {
    final c = DashedCircle(radius: 112.0, color: const Color(0x5564B5F6));
    expect(c.radius, 112.0);
    expect(c.dashCount, greaterThan(0));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/client && flutter test test/tower_range_ring_test.dart`
Expected: FAIL — `towerRangeRingRadiusPx` and `DashedCircle` are undefined.

- [ ] **Step 3: Add the pure radius helper to `coord.dart`**

`coord.dart` already has `import 'package:sim/sim.dart';` (line 1). Append:
```dart
/// Pixel radius of a tower's attack-range ring (the sim's [kTowerAttackRange]
/// in world units, scaled to screen). Reads the constant so it tracks any
/// future range change. At range 4 this is 4 * 28 = 112 px.
double towerRangeRingRadiusPx() => kTowerAttackRange.toDouble() * kPixelsPerUnit;
```

- [ ] **Step 4: Create the `DashedCircle` component**

Create `apps/client/lib/render/dashed_circle.dart`:
```dart
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

/// A [CircleComponent] whose outline is drawn as evenly spaced dash arcs.
/// Same placement as a solid CircleComponent (anchor-centered on its parent),
/// but dashed — used as a non-interactive range/aim overlay. Purely cosmetic.
class DashedCircle extends CircleComponent {
  DashedCircle({
    required double radius,
    required Color color,
    this.dashCount = 36,
    double strokeWidth = 1.5,
  }) : super(
          radius: radius,
          anchor: Anchor.center,
          paint: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = color,
        );

  final int dashCount;

  @override
  void render(Canvas canvas) {
    // CircleComponent sizes itself to 2*radius, so its local centre is (r, r).
    final r = radius;
    final rect = Rect.fromCircle(center: Offset(r, r), radius: r);
    const tau = 2 * math.pi;
    final seg = tau / dashCount;
    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(rect, i * seg, seg * 0.5, false, paint); // dash = half each segment
    }
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd apps/client && flutter test test/tower_range_ring_test.dart`
Expected: PASS (both tests).

- [ ] **Step 6: Wire the ring into tower `EntityView`s**

In `apps/client/lib/render/entity_view.dart`:

Add imports (near the existing `import 'element_palette.dart';`):
```dart
import 'coord.dart';
import 'dashed_circle.dart';
```

Add a top-level flag above the `EntityView` class (one-line removal later, per spec "for now"):
```dart
/// Debug/tuning aid (spec 2026-06-09 §2): draw each tower's attack range as a
/// dashed ring. Flip to false to remove all range rings.
const bool kShowTowerRangeRings = true;
```

In `onLoad()`, as the **first** child added (so it renders beneath the sprite), before `_sprite = PixelSpriteComponent(...)`:
```dart
if (kShowTowerRangeRings && kind == EntityKind.tower.index) {
  await add(DashedCircle(
    radius: towerRangeRingRadiusPx(),
    color: _rangeRingColor(teamId),
  ));
}
```

Add the private colour helper as a top-level function (below `_sizeFor`, or as a static — keep it simple, top-level private):
```dart
/// Subtle, low-alpha team tint for a tower's range ring.
Color _rangeRingColor(int teamId) =>
    teamId == 0 ? const Color(0x5564B5F6) : const Color(0x55E57373);
```

- [ ] **Step 7: Analyze + full client test suite**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: analyze clean; all tests pass (the new ring test + the existing 20 — `widget_smoke_test` still mounts `GuildGame` with tower rings present).

- [ ] **Step 8: Commit**

```bash
git add apps/client/lib/render/dashed_circle.dart apps/client/lib/render/coord.dart apps/client/lib/render/entity_view.dart apps/client/test/tower_range_ring_test.dart
git commit -m "feat(client): always-on dashed tower attack-range rings"
```

---

## Task 3: Part C — E-cast skill + conditional aim (client)

**Files:**
- Create: `apps/client/lib/match/skill_input.dart`
- Modify: `apps/client/lib/render/guild_game.dart`
- Test: `apps/client/test/skill_input_test.dart`

**Behavior recap:** right-click = move/attack (unchanged). **E** triggers the skill: a self-placed hero (Cinderfang, slot 0) casts immediately; an aim-placed hero (Marisol, slot 1) enters aim mode → **left-click** places + casts. **Q** unbound. A bare left-click (no aim pending) does nothing. Downed heroes can't cast. Uses the existing `binding.submitAbility` path (which itself no-ops while downed/ended). No live aim preview in this pass (spec §3.3 sanctioned fallback — a reticle can follow once pointer-move plumbing is chosen).

- [ ] **Step 1: Write the failing tests for the pure state machine**

Create `apps/client/test/skill_input_test.dart`:
```dart
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/client && flutter test test/skill_input_test.dart`
Expected: FAIL — `SkillAction` / `SkillInputController` undefined.

- [ ] **Step 3: Create the pure `SkillInputController`**

Create `apps/client/lib/match/skill_input.dart`:
```dart
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd apps/client && flutter test test/skill_input_test.dart`
Expected: PASS (all 7).

- [ ] **Step 5: Wire the controller into `GuildGame`**

In `apps/client/lib/render/guild_game.dart`:

(a) Extend the sim import (line 9) to add `heroPlacesAtSelf`:
```dart
import 'package:sim/sim.dart' show EntityKind, heroElement, heroPlacesAtSelf;
```
(b) Add these imports (with the other imports):
```dart
import 'package:flame/input.dart' show KeyboardEvents;
import 'package:flutter/services.dart' show LogicalKeyboardKey, KeyEvent, KeyDownEvent;
import 'package:flutter/widgets.dart' show KeyEventResult;

import '../match/skill_input.dart';
```
(c) Add the `KeyboardEvents` mixin to the class declaration (line 24):
```dart
class GuildGame extends FlameGame with SecondaryTapCallbacks, TapCallbacks, KeyboardEvents {
```
(d) Add a field next to the other state (e.g. after `final Set<int> _downed = {};`):
```dart
final SkillInputController _skill = SkillInputController();
```
(e) Add the keyboard handler (anywhere among the methods, e.g. above `onSecondaryTapUp`):
```dart
/// E = cast the hero's skill. Self-placed skills (Cinderfang) fire at once;
/// aim-placed skills (Marisol) arm aim mode, then a left-click places them.
@override
KeyEventResult onKeyEvent(KeyEvent event, Set<LogicalKeyboardKey> keysPressed) {
  if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyE) {
    return KeyEventResult.ignored;
  }
  final v = binding.view;
  if (v != null) {
    final downed = _downed.contains(v.localSlot);
    final action = _skill.onSkillKey(downed: downed, placesAtSelf: heroPlacesAtSelf(v.localSlot));
    if (action == SkillAction.castAtSelf) {
      // Self-placed: the sim ignores the aim point and uses the hero's own
      // position, but we pass it for clarity.
      binding.submitAbility(worldToRaw(v.local.x), worldToRaw(v.local.y));
    }
    // enterAim / cancel / none: state already updated in the controller; no
    // reticle this pass (spec §3.3 fallback).
  }
  return KeyEventResult.handled;
}
```
(f) Replace the body of `onTapUp` (lines 185–189) so a left-click only places a *pending* aim — a bare left-click no longer casts:
```dart
/// Left-click = aim-confirm. Only casts when a skill is pending (armed by E);
/// otherwise does nothing.
@override
void onTapUp(TapUpEvent event) {
  if (_skill.onLeftClick() != SkillAction.castAtPoint) return;
  final worldPos = camera.globalToLocal(event.canvasPosition);
  binding.submitAbility(
      worldToRaw(flameToWorld(worldPos.x)), worldToRaw(flameToWorld(worldPos.y)));
}
```
(g) At the **top** of `onSecondaryTapUp` (before `final worldPos = ...`), let a right-click cancel a pending aim instead of moving:
```dart
if (_skill.onRightClickConsumedAsCancel()) return; // cancel the pending aim; no move
```
(h) In `update`, after the respawn loop (right after the `for (final re in v.entities) { if (_downed.contains(re.id) && re.hp > 0) ... }` block, ~line 87), clear a pending aim if the local hero went down mid-aim:
```dart
if (_downed.contains(v.localSlot) && _skill.aimPending) _skill.clearAim();
```

Also update the class doc-comment on `onTapUp`/`onSecondaryTapUp` if it still says "left-click is the ability aim" so it matches the new flow (the existing comment at lines 164–166 is fine; just ensure no comment claims a bare left-click casts).

- [ ] **Step 6: Analyze + full client test suite**

Run: `cd apps/client && flutter analyze && flutter test`
Expected: analyze clean (resolve any import nit `flutter analyze` flags on `KeyboardEvents`/`KeyEventResult` — they come from `package:flame/input.dart` and `package:flutter/widgets.dart` respectively); all tests pass — the 7 new `skill_input` tests, the Part B ring tests, and the existing 20 (`widget_smoke_test` still mounts `GuildGame`, now with `KeyboardEvents`).

- [ ] **Step 7: Commit**

```bash
git add apps/client/lib/match/skill_input.dart apps/client/lib/render/guild_game.dart apps/client/test/skill_input_test.dart
git commit -m "feat(client): E-cast skill with conditional left-click aim (Q reserved)"
```

---

## Task 4: Full mirror-CI sweep

Confirms the whole branch is green + the golden is correctly pinned + nothing leaked, mirroring `.github/workflows/sim-determinism.yml` plus the client gates.

- [ ] **Step 1: Scope / determinism guard**

```bash
git diff --quiet main -- packages/netcode packages/protocol packages/sim/lib/src/simulation.dart && echo "SCOPE OK: no netcode/protocol/sim-mechanics change"
git --no-pager diff --name-only main..HEAD
```
Expected: `SCOPE OK`; the changed-file list is exactly: `packages/sim/lib/src/data/combat.dart`, `packages/sim/test/combat_test.dart`, `tooling/replay_fixtures/combat.golden`, `apps/client/lib/render/{coord,entity_view,dashed_circle,guild_game}.dart`, `apps/client/lib/match/skill_input.dart`, `apps/client/test/{tower_range_ring,skill_input}_test.dart`, and the spec + this plan doc.

- [ ] **Step 2: All package suites + analyze**

```bash
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
(cd packages/sim && dart test)
(cd packages/protocol && dart test)
(cd packages/netcode && dart test)
(cd apps/server && dart test)
(cd apps/client && flutter analyze && flutter test)
```
Expected: analyze clean; banned-imports clean; every suite green (sim 116; client = 20 prior + new ring/skill tests).

- [ ] **Step 3: Cross-runtime golden gate**

```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json      # PASS matches golden (7e4aa28f)
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json     # PASS byte-identical native/js/wasm + matches NEW golden (030f2343)
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json  # PASS matches golden (717305eb)
```
Expected: all three `PASS: matches golden` with byte-identical native/js/wasm.

- [ ] **Step 4: Hand off to whole-branch review + finishing**

No commit (verification only). Proceed to the whole-branch review (superpowers:requesting-code-review over `main..HEAD`), then superpowers:finishing-a-development-branch (present options; do NOT merge/push without explicit choice).

---

## Notes for the implementer

- **Never edit `packages/sim/lib/src/simulation*.dart` or any mechanics/codec.** Part A is values-only. Parts B & C are `apps/client`-only. The `git diff --quiet main -- packages/netcode packages/protocol packages/sim/lib/src/simulation.dart` guard catches leaks.
- **Symbolic sim tests are a feature:** if a sim test FAILS after the range change, that's a real regression to investigate — do NOT "fix" it by editing an expected literal. The only sim-test edits here are the three range comments.
- **`combat.golden` re-pin** is the native harness hash written with `printf '%s\n'` (clean single LF). The expected new value is `030f2343` (pre-verified during planning; a constant-only change is cross-runtime-deterministic by construction, and `compare_replays.sh`/CI re-verify js/wasm parity).
- **`flame_test` is not a dependency** — keep client tests pure (`flutter_test` only). The cast logic lives in the pure `SkillInputController` precisely so it's unit-testable without a Flame harness; the Flame wiring is covered by `flutter analyze` + the existing `widget_smoke_test`.
- **Web focus:** `KeyboardEvents` needs the game widget focused to receive keys. If a manual `flutter run -d chrome` shows E not firing, confirm `GameWidget` has focus (autofocus / click-to-focus) in `main.dart` — but this is not required for the headless test suite to pass.
- **Self-place ignores the aim point:** the sim places Cinderfang's field at his own position regardless of the `aimX/aimY` sent, so the `castAtSelf` coordinates are cosmetic; passing the hero's position keeps the intent readable.

---

## Self-Review (against the spec)

- **Spec §1 (Part A range 5→4 + re-pin):** Task 1 (constants in lockstep, comment refreshes, attribution gate proving only `combat` moved to the pre-verified `030f2343`, cross-runtime re-pin). ✓
- **Spec §2 (Part B always-on rings, all towers, radius from constant, dashed):** Task 2 (`towerRangeRingRadiusPx` reads `kTowerAttackRange`; `DashedCircle`; tower-gated `EntityView` child; `kShowTowerRangeRings` one-line toggle). ✓
- **Spec §3 (Part C E-cast, self-place-immediate / aim-place-then-click, Q reserved, bare left-click nothing, downed-gated, existing ability path):** Task 3 (`SkillInputController` + `GuildGame` wiring). Live aim preview intentionally deferred to the spec §3.3 fallback (noted). ✓
- **Spec §5 (tests & verification):** symbolic sim tests + golden attribution (Task 1), pure unit tests for ring radius + skill state machine (Tasks 2–3), full mirror-CI + cross-runtime sweep (Task 4). ✓
- **Spec §4 (OUT of scope):** no protocol/netcode/byte-layout change, no Q binding, no second skill, no tower-position move, no other golden moved — enforced by the scope guard and the attribution gate. ✓
- **Placeholder scan:** no TBD/TODO; every code step shows complete code; the only "deferred" item (aim reticle) is an explicit, spec-sanctioned scope decision, not a placeholder. ✓
- **Type/name consistency:** `SkillAction`/`SkillInputController` method names (`onSkillKey`/`onLeftClick`/`onRightClickConsumedAsCancel`/`clearAim`/`aimPending`) match between the test, the class, and the `GuildGame` wiring; `towerRangeRingRadiusPx`/`DashedCircle`/`kShowTowerRangeRings` match between definition and use. ✓
