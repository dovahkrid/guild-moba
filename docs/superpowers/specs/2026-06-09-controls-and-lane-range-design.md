# Guild — Controls (E-cast aim) + Lane Range + Range Rings — Design Spec

**Status:** approved 2026-06-09. Branch `feat/controls-and-lane-range` off `main` (`763138f`).
**Relationship to prior work:** the **second half of the post-animation roadmap step** (the "keyboard skill-bind + aiming-mode controls" the balance spec deferred to "a separate client-only spec to follow"), **bundled** with a small follow-up lane tweak + a debug range visualization that came out of the same playtest. Predecessor: `docs/superpowers/specs/2026-06-08-balance-pass-design.md` (which set tower range 6→5). The two earlier `[[guild-moba-controls]]` notes (right-click = move/attack; left-click = aim) are realized here.

**One combined spec, three parts** (Patrick's call, 2026-06-09):
- **Part A — sim:** tower range 5→4 so a tower's reach stops *at* the midline, never past it. The only determinism-relevant change → one sanctioned `combat.golden` re-pin.
- **Part B — client:** always-on dashed range rings on every tower (a "for now" tuning aid).
- **Part C — client:** keyboard **E** triggers the hero's skill, with **aim only when the skill needs it** (left-click to place); left-click otherwise reserved for aiming.

Parts B and C are **entirely `apps/client`** (render + input) — determinism-neutral, no golden/byte-layout/version impact. Only Part A touches `packages/sim`.

---

## 0. Motivation (from the 2026-06-08/09 playtest)

1. **"Tower still shoots too far — shouldn't cross the midline."** Towers sit at `±4`; with range 5 a `-4` tower reaches `x=+1`, i.e. 1 unit past center, so it shoots a hero standing at the clash. Range 4 makes it reach **exactly** `x=0` — defends its own half up to the midline, never beyond.
2. **"Draw a dashed circle to see the range for now."** No range visualization exists. A dashed ring of the true range around each tower makes reach legible while tuning.
3. **"Red tower looks nearer the midline than blue."** **Investigated — not a positional bug.** The sim places both outer towers at exactly `±4` and the client renders them symmetrically (`coord.dart` is a linear `×28 px/unit` map with no per-team offset; the camera merely follows the local hero, `guild_game.dart:68`). A `-4` tower and a `+4` tower are equidistant from the world origin / drawn midline. The real source of the *feel* is item #1 — the **enemy tower's range crossing the midline** — which Part A fixes and Part B makes visible. If, after this, it still reads asymmetric, sprite-anchor inspection is the next step (out of scope here).
4. **Controls.** Today right-click = move/attack (kept) and a bare left-click directly casts the ability at the cursor (`guild_game.dart:185`); there is **no keyboard input at all**. The desired scheme is LoL-style: skill on a key, left-click to aim when needed.

---

## 1. Part A — Tower range 5 → 4 (sim; sanctioned `combat.golden` re-pin)

A pure constant-value, **range-only** change in `packages/sim/lib/src/data/combat.dart`. Towers are **NOT moved** (`kOuterTowerX`/`kInnerTowerX`/`kCoreX` untouched) — exactly the discipline that keeps the move-only goldens/anchor byte-identical.

| Const | Now | New | Note |
|---|---|---|---|
| `kTowerAttackRange` | `Fixed.fromNum(5)` | `Fixed.fromNum(4)` | display/reference value |
| `kTowerAttackRangeSq` | `Fixed.fromNum(5 * 5)` (=25) | `Fixed.fromNum(4 * 4)` (=16) | **the actual targeting gate** (`lengthSq` compare); must change in lockstep — `combat_test.dart` asserts `RangeSq == Range²` |

- Update the inline comment on `kTowerAttackRange` to reflect the new value/rationale ("playtest-tuned 2026-06-09, was 5 — reaches exactly to the midline; towers NOT moved"), keeping the `// spec §…` breadcrumb.
- **Comment/name refreshes (assertions are symbolic → unchanged):** in `packages/sim/test/combat_test.dart`, the two `// (towers at x=±4/±10, range 5)` comments → `range 4`; the `// (x=-8 is >5 from every enemy tower …)` comment → `>4` (still true: `|-8 − 4| = 12 > 4`). No other test edits.
- **No** new constant/enum/field, **no** byte-layout/version change (`kSchemaVersion`/`kSnapshotVersion` stay **3/3**), `Fixed`(Q16.16)+`int` only (4 and 16 are exactly representable, well within `< 32768`), no `dart:math`/`Random`/`DateTime`, no new RNG draw.

**Determinism / re-pin scope** (identical pattern to the balance pass):

| Golden / anchor | Moves? | Why |
|---|---|---|
| `smoke.golden` `7e4aa28f` | **NO** | move-only fixture; no tower fires in-window; range is behavior-only (never serialized) |
| in-test anchor `0x0fbfb7ac` | **NO** | move-only; unmoved towers |
| `elemental.golden` `717305eb` | **NO** | range untouched by elemental fixture |
| `combat.golden` `3824c068` | **YES** | `combat.json`'s center brawl now sees tower-fire timing shift (range 5→4) |

Re-pin procedure unchanged: prove the attribution (only `combat` differs; smoke/elemental/anchor byte-identical), then regenerate `combat.golden` from the **native** replay harness (`printf '%s\n'`, single LF), then prove byte-identical native/dart2js/dart2wasm via `bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json`. (`node` + `dart` confirmed present locally.)

*Expected gameplay consequence:* with both towers reaching exactly to `x=0`, the dead-center creep sits at the very edge of each tower's reach and the center clash is uncontested by tower fire — the intended "safe to farm center."

---

## 2. Part B — Always-on dashed range rings on all towers (client; determinism-neutral)

A debug/tuning visualization in `apps/client`. **No sim/protocol impact.**

- **What:** a **dashed circle** centered on each tower, radius = the tower's true attack range, drawn for **every** tower (both teams), **always visible**.
- **Radius source:** computed from the shared sim constant `kTowerAttackRange` (not a magic number), converted world→screen via `coord.dart`'s `kPixelsPerUnit` (28). At range 4 → `4 × 28 = 112 px`. Reading the constant means the ring auto-tracks any future range change.
- **Rendering:** Flame's `CircleComponent` only strokes solid, so add a **small dashed-circle renderer** — a `PositionComponent`/custom `render(Canvas)` that walks the circle as evenly spaced dash arcs (`canvas.drawArc` segments or a dashed `Path`). Subtle per-team tint (reuse the team palette) at low alpha so it reads as an overlay, not a gameplay element.
- **Where:** attached to the tower's `EntityView` (so it tracks the tower's interpolated position) gated on `kind == EntityKind.tower`, **or** a dedicated world-overlay layer that iterates tower entities. The plan picks whichever fits the existing render structure best (`entity_view.dart` / `world_backdrop.dart` patterns).
- **"For now":** even though it's always-on per Patrick, keep it behind a single named `const`/flag so it is a one-line removal/toggle later.

---

## 3. Part C — E-cast skill + conditional aim (client; determinism-neutral)

LoL-style control layer in `apps/client`, using the **existing** `IntentType.ability` path (`binding.submitAbility(rawX, rawY)` → `applyAbilityInput` → server). **No protocol/netcode/byte-layout change.**

### 3.1 Bindings
| Input | Behavior |
|---|---|
| **Right-click** | Move, or attack-lock if it lands on an enemy — **unchanged** (`guild_game.dart:168`). |
| **E** (`LogicalKeyboardKey.keyE`) | Trigger the hero's skill (see state machine). |
| **Q** | **Unbound** — reserved for a future second skill (Plan 8). |
| **Left-click** | **Aim-confirm only.** With no skill pending it does **nothing** (today's direct-cast-on-left-click is removed). |

### 3.2 State machine (per local player)
State: `idle` ↔ `aimPending`.

- **On E pressed:**
  - If the local hero is **downed** → ignore (same Plan-6 input gate as move/attack).
  - Else determine `heroPlacesAtSelf(localHeroId)` (shared sim helper in `elements.dart`; `localHeroId` = the local slot, 0 or 1):
    - **Self-placed** (Cinderfang, slot 0): cast **immediately** — `submitAbility` with the local hero's current world position. Stay `idle`.
    - **Aim-placed** (Marisol, slot 1): → **`aimPending`**; show the aim preview (§3.3).
- **On left-click:**
  - `aimPending` → `submitAbility(clickWorld)`, hide preview, → `idle`.
  - `idle` → nothing.
- **Cancel** (from `aimPending`): pressing **E again**, or **right-click**, cancels → `idle` (preview hidden). A right-click used to cancel is consumed as the cancel and does **not** also issue a move (avoids an accidental walk). *(This "right-click cancels without moving" detail is called out for the plan to confirm against the existing right-click handler.)*

### 3.3 Aim preview
While `aimPending`, show a translucent **field-radius** circle (`kFieldRadius` 2.5 → `70 px`, reusing Part B's circle drawing) tracking the mouse cursor, so the player sees where/how big the placement is. Requires the client to track pointer-move (add a Flame pointer/mouse-move handler if not already present). If live cursor tracking proves impractical, the fallback is **no live preview** (cast still works on click) — the plan resolves this; the preview is desired but not load-bearing.

### 3.4 Authority & cooldown
Server stays authoritative. The client does **not** predict/queue cooldown: pressing E while the ability is on `kAbilityCooldownTicks` cooldown simply sends an intent the server ignores. No cooldown UI in this pass.

---

## 4. Scope

**IN:**
- **A:** `combat.dart` `kTowerAttackRange` 5→4 + `kTowerAttackRangeSq` 25→16 (range-only) + comment; refresh stale `combat_test.dart` range comments; re-pin `combat.golden` cross-runtime with clean attribution.
- **B:** always-on dashed range rings on all towers in `apps/client`, radius from the sim constant; a small dashed-circle renderer.
- **C:** keyboard **E** skill trigger with self-place-immediate / aim-place-then-left-click; left-click reserved for aim (bare left-click = nothing); E-again/right-click cancel; downed-gated; optional cursor aim preview; via the existing `submitAbility` path.

**OUT:**
- Any sim mechanic / code-path / phase-order change; any new constant, entity field, enum, or `SimEvent`; any byte-layout or version bump; any change to tower **positions**, hp, cooldowns, gold, wave cadence, elemental constants, or any golden other than `combat.golden`.
- Any **protocol/netcode** change (uses the existing `IntentType.ability` message as-is).
- Binding **Q**, a **second** skill, cooldown UI, or a sim ability beyond the one that exists today.
- Sprite-anchor / camera changes for item #3 (it's symmetric; deferred unless the range fix doesn't resolve the feel).
- Any change to `smoke.golden` / `elemental.golden` / the `0x0fbfb7ac` anchor (must stay byte-identical).

---

## 5. Tests & verification (evidence-first)

- **Sim (Part A):** symbolic assertions stay green after 5→4 (e.g. `RangeSq == Range²` holds at 16 == 4²); only comments change. `cd packages/sim && dart analyze && dart test` green.
- **Golden attribution gate:** after Part A, native hashes show `smoke 7e4aa28f` + `elemental 717305eb` byte-identical AND golden-matched, `combat` byte-identical across runtimes but golden-mismatched (the sanctioned move); the `0x0fbfb7ac` anchor test passes. Re-pin `combat.golden`; `bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json` → byte-identical native/js/wasm + matches new golden.
- **Client (Parts B, C):** `cd apps/client && flutter analyze && flutter test` green. Add tests, following existing client patterns (`match_binding_test.dart` asserts input→intent; `*_view`/widget tests render components):
  - **Input state-machine:** E on a self-place hero → exactly one `ability` intent at the hero's position, stays idle; E on an aim-place hero → no intent yet, then left-click → one `ability` intent at the clicked point; bare left-click (idle) → no intent; E while downed → no intent; E-again / right-click while `aimPending` → cancels (no `ability` intent, and the cancelling right-click issues no move).
  - **Range ring:** a tower `EntityView` (or the overlay) carries a range-ring component whose radius equals `kTowerAttackRange × kPixelsPerUnit`; non-tower entities have none.
- **Full mirror-CI sweep:** `dart analyze --fatal-infos --fatal-warnings packages apps/server tooling`; `bash tooling/check_no_banned_imports.sh`; sim + protocol + netcode + server `dart test`; the three replay compares (smoke/elemental unchanged, combat = new pin, all byte-identical native/js/wasm); `flutter analyze` + `flutter test`.
- **Eyeball post-change:** rings show radius-4 circles touching the midline on both towers; a hero last-hitting at center takes no tower fire; pressing **E** as Cinderfang drops the field immediately; as Marisol, **E** then left-click places it; a stray left-click does nothing.

---

## 6. Task plan (outline — `writing-plans` expands this)

1. **Part A — tower range 5→4 + re-pin `combat.golden`** (sim; mirrors the balance-pass task: edit `combat.dart` range/rangeSq in lockstep + comment, refresh `combat_test.dart` range comments, attribution gate proving only `combat` moved, cross-runtime re-pin, commit).
2. **Part B — dashed range rings** (client; dashed-circle renderer + per-tower ring reading `kTowerAttackRange`, always-on flag, render/widget test).
3. **Part C — E-cast + conditional aim** (client; keyboard handler, idle/aimPending state machine, self-place-immediate vs aim-place-then-click, left-click reserved, cancel, downed gate, optional cursor preview, input→intent tests).

Order rationale: A is the only golden-moving task and is self-contained (do it first, attribution-clean). B introduces the circle renderer that C's aim preview reuses (B before C). Each client task ends green on `flutter analyze && flutter test`; final full mirror-CI + cross-runtime sweep after all three.

---

## 7. Open implementation details to resolve in the plan

- **Ring host:** per-tower `EntityView` child vs a single world-overlay iterating towers — pick by fit with current render code; ensure the ring tracks the tower's interpolated position and sits beneath gameplay sprites in draw order.
- **`Fixed`→pixels:** the exact conversion for the ring/preview radius from `kTowerAttackRange`/`kFieldRadius` (`Fixed`) through `coord.dart` (confirm a `Fixed.toDouble()`-style accessor or existing helper; reuse `worldToFlameX`-style scaling).
- **Keyboard plumbing:** which Flame mechanism the client adopts (`KeyboardEvents`/`HasKeyboardHandlerComponents` on `GuildGame` vs a Flutter `Focus`/`KeyboardListener` wrapper) so `E` is captured reliably alongside the existing tap callbacks; ensure focus on web.
- **Local hero identity & position for self-cast:** read `localSlot`/local `EntityView` world position; convert to raw Q16.16 via `worldToRaw` for `submitAbility`.
- **Pointer-move for the preview:** whether the client already receives mouse-move; if not, the minimal handler to add (and the documented fallback of no live preview).
- **Right-click-cancels-without-moving:** confirm against the current `onSecondaryTapUp` so a cancel click doesn't also enqueue a move intent.
- **Downed gate reuse:** the exact existing predicate the client uses to suppress move/attack while downed, applied identically to the E-cast.
