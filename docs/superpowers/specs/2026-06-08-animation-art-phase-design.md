# Guild — Animation / Art Phase — Design Spec

**Status:** approved 2026-06-08. Branch `feat/anim-art-phase` off `main` (`0ff72fc`).
**Relationship to prior plans:** a **client-only visual** layer on top of Plans 1–6 + the cleaning phase (all merged). It adds **no gameplay** and changes **no simulation behavior**; it replaces placeholder geometry with hand-authored pixel-art SVG sprites, adds animation + combat VFX driven off data the sim **already** produces, and polishes the environment. The simulation, its wire format, and the replay goldens are untouched.

**Predecessor docs:** game spec `docs/superpowers/specs/2026-06-06-elemental-moba-design.md`; plans `…/plans/2026-06-06-plan-1-foundation.md`, `2026-06-06-plan-2a-netcode-core.md`, `2026-06-06-plan-2b-netcode-wiring.md`, `2026-06-07-plan-3-combat.md`, `2026-06-07-plan-4-elemental.md`, `2026-06-07-plan-5-elemental-v2.md`, `2026-06-07-plan-6-respawn-standstill.md`, `2026-06-08-cleaning-phase.md`. Control scheme: LoL — right-click = move+attack, left-click = ability.

---

## 0. The headline invariant — DETERMINISM-NEUTRAL / CLIENT-ONLY

This is the art-phase analog of the cleaning phase's "golden-neutral." Every task obeys it:

- **`packages/sim/lib` is NOT TOUCHED.** No new serialized field, no event change, no constant change, no enum touch. The replay goldens **`smoke 7e4aa28f`**, **`combat 910ddcfc`**, **`elemental 8d7fbe1b`** and the in-test canonical anchor **`0x0fbfb7ac`** (`packages/sim/test/snapshot_test.dart`) **MUST NOT MOVE** — and they can't, because no task edits the sim. `kSchemaVersion`/`kSnapshotVersion` stay **3/3**.
- **The WIRE is not touched.** `packages/protocol` (the WS snapshot/message codec) is unchanged. The new render-FX types added in §4 live at the **netcode render boundary** (`MatchView`), are produced client-side from already-emitted `SimEvent`s, and **are never serialized or sent over the socket**. No protocol version change.
- **All visuals are wall-clock driven and cannot feed the sim.** The Flame render loop's `update(double dt)` is real elapsed time (`apps/client/lib/render/guild_game.dart`), decoupled from the fixed 30 Hz sim tick (`apps/client/lib/match/match_binding.dart`). Every effect, tween, particle, sprite swap, and screen-shake is cosmetic **by construction** — it reads `MatchView`/drained events and writes only to Flame components. There is no path from a visual back into `Simulation`.
- **Files touched:** `apps/client/**` (most of the work) and `packages/netcode/lib/src/match_view.dart` + `match_controller.dart` + `match_binding`-facing glue (additive render-boundary projections only). Nothing else.

**Gate, every task:** `flutter analyze` clean **and** `flutter test` green from `apps/client`; the **5 existing client tests stay green** (`dev_lag_transport_test`, `widget_smoke_test`, `element_palette_test`, `reaction_label_test`, `match_binding_test`); and the sim/netcode/server suites + the three `compare_replays.sh` fixtures remain byte-identical (a cheap sanity check that nothing leaked into the sim).

---

## 1. Art direction & the animation model (locked decisions)

**Direction:** hand-authored **pixel-art**, code-authored **in-repo** (no external/CC0 packs, no licensing), stored as **SVG**. SVG is chosen over PNG deliberately: we *generate* sprites as pixel-grid `<rect>`s, so SVG stays mathematically crisp at any camera zoom / DPI (no nearest-neighbour shimmer), produces tiny diff-able files, and recolors per team/element by attribute substitution. (Per the brainstorm: option C + SVG, user-confirmed.)

**Scope:** the **full art pass** (Tiers 1–3): entity sprites + animation (§3), combat VFX off surfaced events (§4), and environment + global polish (§5).

**The one structural call — motion model:** **identity = pixel-SVG sprite; motion = procedural transform/opacity tweens + particles; per-frame swap only where it earns its keep.**
- Each entity gets **1–2 crisp SVG sprites** (a base, plus an optional accent/destroyed variant), not a deep frame stack.
- *Motion* (idle bob, walk squash, hurt-lean, spawn pop, death collapse/dissolve) comes from Flame's `MoveEffect`/`ScaleEffect`/`OpacityEffect`/`RotateEffect`/`SequenceEffect` + `EffectController` curves (confirmed available in Flame 1.37.0, currently unused), and from `ParticleSystemComponent` bursts.
- A **2-frame swap** is reserved for accents that genuinely need it (e.g. a pyro staff-flame flicker).
- Rationale: keeps the hand-authoring workload sane, stays 100% vector/crisp, and is the right fit for "iterate visuals while the game is still basic." (Alternative considered: full frame-by-frame pixel animation — more authentic-retro but multiplies SVG authoring; rejected for this phase, can be layered later by adding frames to the same actor.)

**Facing:** **left/right horizontal flip only**, derived client-side from the sign of the per-frame movement delta (single horizontal lane → 4/8-direction sprites would be far more art for zero readability gain).

---

## 2. The sprite system (`apps/client/lib/render/`)

Today every entity is a flat `CircleComponent`/`RectangleComponent` tinted by team in `entity_view.dart`; fields are translucent circles in `field_view.dart`; coordinates map at `kPixelsPerUnit = 28.0` (`coord.dart`); colors live in `element_palette.dart`. The sprite system slots into that structure.

### 2.1 Assets
- New `apps/client/assets/sprites/*.svg`, declared under `flutter:` `assets:` in `apps/client/pubspec.yaml` (today that section is only `uses-material-design: true` — this is the first asset declaration).
- Base silhouettes (seeded from the brainstorm mockups): **hero** (humanoid mage), **creep**, **tower**, **core/nexus**, **wanderer**. Authored as pixel-grid `<rect>`s with `shape-rendering="crispEdges"`, a small fixed palette, and a small native pixel size (~12–16 px world-sized; rendered at `size * kPixelsPerUnit`).

### 2.2 Recolor — one silhouette, many variants
- Each SVG uses **sentinel palette colors** for the recolorable regions: a team-primary, team-shadow, element-accent, element-light, plus fixed neutrals (outline, skin, metal). Sentinels are **valid hex** so each file remains a viewable standalone SVG.
- At load, a `SpriteCatalog` reads the raw asset string, `String.replaceAll`s each sentinel → the concrete hex for a `(teamId, element)` pair, and builds a renderable `Svg`. Variants (blue/red × pyro/hydro, neutral) are cached by key. **Free recolor, one source file per silhouette.**
- An **all-white** recolor of each silhouette is generated the same way and cached — used as the hit-flash overlay (§4).

### 2.3 Rendering — `flame_svg` with a canvas-rect fallback
- Add `flame_svg` to `pubspec.yaml`, version-pinned compatible with Flame **1.37.0** (verified at plan time). A `SvgSpriteComponent` renders the current `Svg`, sized in world→pixels, supporting a horizontal flip (negative x-scale about center).
- **Fallback (de-risks the dependency *and* headless tests):** the `SpriteCatalog` exposes a uniform `SpriteHandle` interface; if `flame_svg` fails to load an asset (e.g. headless `flutter test`, or a web-renderer quirk), it falls back to drawing the sprite's `<rect>`s directly to the Flame `Canvas` — trivial, since the sprites *are* rects. The renderer is chosen once at catalog init; gameplay/visual code is renderer-agnostic. This keeps `widget_smoke_test` green without bundling assets into the test harness.

### 2.4 Palette module
- Extend `element_palette.dart` (keep `elementColor`/`fieldColor` — `element_palette_test` covers them) into a cohesive pixel palette: team primary/shadow (blue `0xFF2196F3` / red `0xFFF44336`), element accent/light (pyro `0xFFFF7043` / hydro `0xFF26C6DA`), neutral `0xFF9E9E9E`, UI/damage-number colors, backdrop tones. Single source of truth for both SVG recolor and code-drawn VFX.

---

## 3. Entity rendering, facing & life-cycle animation (`entity_view.dart` + `guild_game.dart`)

`guild_game.dart` already diff-syncs an `EntityView` per `RenderEntity.id` each frame (position → `target`, `hp/maxHp` → `hpRatio`, `statusElement` → ring). We keep that diff loop and rebuild the actor's visuals on top of the sprite system.

### 3.1 The entity actor
- `EntityView` (or a renamed `EntityActor`) owns an `SvgSpriteComponent` chosen by `kind` (hero/wanderer/tower/creep/core — `EntityKind.index`) and recolored by `(teamId, element)`.
- **Hero element identity:** the hero sprite's element accent is the hero's **innate** element (pyro vs hydro), derived client-side via the sim's `heroElement(...)` roster mapping (`packages/sim/lib/src/data/elements.dart`) keyed by team/slot — a pure function the client already has access to, **no render-boundary field added**. *(If `heroElement` is not cleanly client-derivable, fall back to team-only accent + the `statusElement` coat overlay below; resolved in the plan, §10.)* `statusElement` remains the *transient coat*, shown as the aura in §3.4 — distinct from identity.
- **Health bar:** keep the existing 3 px bar (`hpRatio`), restyled to the pixel palette. Wanderers keep skipping it (as today).
- **Local-hero indicator:** preserve the white outline ring for the local hero; ensure it composes with sprite flip/scale (it's a sibling, not flipped with the sprite).

### 3.2 Facing
- The actor tracks `_facing` (±1). Each `update(dt)`, compute `dx = target.x - position.x` (the actor already lerps `position` → `target` at `_kLerpSpeed = 12.0`); if `|dx|` exceeds a small deadzone, set `_facing = sign(dx)`; otherwise hold. Apply as a horizontal flip on the sprite. Works for the local hero (predicted) and the opponent (interpolated ~100 ms behind — facing simply follows the interpolated motion; the 100 ms is untouched, a separate queued concern).

### 3.3 Idle / walk
- **Idle:** a low-amplitude sinusoidal bob (small y-offset / squash) while near-stationary.
- **Walk:** a slightly stronger bob + squash-stretch gated on "is moving" (same `|dx|`/`|dy|` signal as facing). Pyro/hydro staff-flame flicker (optional 2-frame accent) plays continuously on heroes.
- All amplitude/period values centralized as tunables.

### 3.4 Status coat (Tier 3 polish)
- Today `statusElement` is a **hard color swap** on a ring. Replace with an element-tinted **aura overlay** whose opacity **tweens** in/out on `statusElement` change (track previous value; `OpacityEffect` on coat-on / coat-off). `-1` = no coat.

### 3.5 Spawn & death
- **Spawn-in:** when a new `id` enters the diff, the actor plays a pop-in (scale 0→1 + brief opacity ramp + a small spark particle). This doubles as the **respawn** cue for heroes (see note).
- **Creep death:** creeps are removed from `MatchView.entities` on death (`guild_game.dart` despawns the view). Instead of removing immediately, detach the actor from the live map, play a **collapse + fade + dissolve-particle** at its last position, then `removeFromParent()`. Synchronized with the `CreepKilled` burst (§4) at the same spot.
- **Hero death/downed:** a hero persists in the entity list while downed (parked at spawn — Plan 6). Trigger the hero **death animation on the `HeroDowned` event** (emitted by the sim since Plan 6; surfaced via the FX boundary §4), then show a subdued **downed** state (greyed/ghosted, no bob) until the hero is back up (hp restored / active again), at which point the spawn-in pop plays. *(Designed not to regress the separately-queued opponent respawn-render-delay observation; the clearer spawn cue may actually help it. That interpolation investigation stays OUT of scope.)*

---

## 4. Combat VFX & the netcode render-FX boundary (`packages/netcode` + `apps/client`)

The sim **already emits** the events VFX needs; the render boundary currently **drops all but `ReactionTriggered`**. We surface them client-side — additive, determinism-neutral.

### 4.1 The events (already emitted; `packages/sim/lib/src/events.dart`)
| Event | Payload | Position resolution |
|---|---|---|
| `DamageDealt` | `sourceId, targetId, amountRaw` (Q16.16) | `targetId`→pos (victim), `sourceId`→pos (for streaks) |
| `CreepKilled` | `creepId, killerId, gold` | `creepId`→pos **before** the death sweep removes it |
| `TowerDestroyed` | `towerId, teamId, killerId` | tower pos (static: `kOuterTowerX`/`kInnerTowerX` in `data/combat.dart`) |
| `CoreDestroyed` | `teamId, winnerTeam` | core pos (static: `kCoreX`) |
| `HeroDowned` | `heroId` | `heroId`→pos |
| `ReactionTriggered` | `unitId, reaction, multiplierRaw, sourceId` | already drained today |

`LevelUp` / `BossSpawned` are declared-but-not-emitted (Plans 8/9) — **do not rely on them**; leave the forward scaffolding untouched.

### 4.2 The boundary projection (mirrors `RenderReaction`)
- Add render-FX value types to `packages/netcode/lib/src/match_view.dart` (alongside `RenderEntity`/`RenderField`/`RenderReaction`): a `RenderFx` carrying `{ kind, x, y, …payload }` (or a small set of typed records) for `hit` (pos, amount, source-kind), `creepKill` (pos), `heroDowned` (pos), `towerFall` (pos, side), `coreDestroyed` (side, winnerTeam). Positions are resolved at collection time. These types are **render-only** — never serialized, never sent.
- `MatchController` collects them **only during forward prediction** (`advanceClientTick`), exactly like `ReactionTriggered` is collected today, into a `_recentFx` list; `drainFx()` returns + clears it once per frame. **It must NOT collect during reconcile re-steps** (`onServerSnapshot`) — that is the existing discipline that guarantees each effect surfaces exactly once with no double-pop (recon-confirmed gotcha). Resolve ids→pos against `_predicted` at collection time (for `CreepKilled`, before the entity is gone).
- `MatchBinding`/`GuildGame` call `drainFx()` per frame next to the existing `drainReactions()`.
- **Additive only** → existing `match_binding_test` and netcode/server suites stay green.

### 4.3 The consumers (`apps/client`)
- **Hit-flash:** on `hit`, pulse the victim actor's **all-white overlay** (§2.2) opacity up-then-down (a quick `OpacityEffect` sequence) + a tiny knock/scale-pop. Reliable tinting without depending on `flame_svg` color-filter support.
- **Floating damage numbers:** a `DamageNumber` component modeled on the existing `reaction_label.dart` (rise + fade + self-remove). `amountRaw.toDouble() / 65536` → integer display; **color by source kind** (hero basic / tower / reaction). Reuse the `reactionText` test pattern for formatting tests.
- **Attack / cast trigger:** when a `hit` has a **hero** source, play that hero's attack-pose tween + a **slash/projectile streak** from source→target (both positions resolvable). Tower sources get a muzzle-flash + projectile to target. (We have impact, not windup — impact-triggered reads fine; a true windup would need timing data not at the boundary, explicitly out of scope.)
- **Creep-kill burst** (`creepKill`) + **reaction burst** (`ReactionTriggered`, already has `unitId`→pos): particle pops; reaction keeps its `VAPORIZE`/`VAPORIZE x1.3` pop-text (`reaction_label.dart` unchanged in behavior).
- **Tower fall / core destruction:** see §5.

---

## 5. Environment & global polish (Tier 3)

- **Backdrop** (`world_backdrop.dart`): replace the flat 24×8-unit dark rect + divider with a **tiled pixel-art lane** (repeating ground tile via SVG pattern or a generated tile sheet), lane edges/décor, and a restyled center divider. Stays within the existing world bounds; rendered first (z-order under entities, as today).
- **Tower crumble** (`towerFall`): the tower actor swaps to a "destroyed" SVG variant + collapse tween + debris `ParticleSystemComponent` + a small screen-shake.
- **Core-destruction finale** (`coreDestroyed`): a bigger beat — flash, particle burst, stronger shake/zoom-punch — flowing into the result screen.
- **Camera juice:** screen-shake (decaying additive offset on the camera **viewfinder**) on tower-fall / core-kill / big hits, plus a subtle zoom-punch on core destruction. Magnitudes small and centralized. **Must compose with `camera.follow(localHero)`** (the camera tracks the local hero — `guild_game.dart`); verified in §10.
- **Victory / Defeat screen:** restyle the existing result overlay (one of `main.dart`'s `hud`/`dev`/`result` overlays) into a pixel-art win/lose card with a short entrance animation, triggered off the core-destruction finale + the existing match-end path (`MatchEndMsg`/`winnerTeam`, already surfaced by `match_binding`).

---

## 6. Determinism / boundary scope (restated, precise)

- **`packages/sim` untouched** → goldens `smoke 7e4aa28f` / `combat 910ddcfc` / `elemental 8d7fbe1b` + anchor `0x0fbfb7ac` cannot move; versions stay **3/3**. No enum/constant/event/field change.
- **`packages/protocol` untouched** → no wire/version change. `RenderFx` is a render-boundary projection, **never serialized**.
- **`packages/netcode` changes are additive** render-boundary projections (`MatchView` types + `MatchController` collection mirroring `ReactionTriggered`'s forward-prediction-once discipline). No change to prediction/reconcile/interpolation math; the opponent ~100 ms interpolation (`sample(renderTimeMs - 100)`) and the InterpolationBuffer are **not touched**.
- **All `apps/client` animation is wall-clock cosmetic** (§0). No new RNG-in-sim, no `dart:math` concern in the sim (client may freely use `dart:math`/`DateTime` for cosmetic timing — it never reaches the deterministic core).

---

## 7. Scope

**IN:** flame_svg + a `SpriteCatalog` (load + sentinel-recolor + cache + canvas-rect fallback) and the in-repo SVG sprite set (hero/creep/tower/core/wanderer) + palette module; sprite-based `EntityView` with L/R facing, idle/walk bob, spawn-in & death/downed animation, restyled hp bar, status-coat fade; an **additive netcode render-FX boundary** (`RenderFx` types + `MatchController` forward-once collection + `drainFx()`); combat VFX consumers (hit-flash, floating damage numbers, attack/cast trigger + projectile/slash, creep-kill & reaction bursts); environment (tiled backdrop, field breathing-pulse + particles), tower-crumble & core-destruction finale, camera shake/zoom-punch, restyled victory/defeat screen; a visual-QA pass with screenshots; new mock-style unit tests for the additive surfaces.

**OUT:** **any** `packages/sim/lib` change (no new serialized field, event, enum, or constant); any protocol/wire/version change; the `LevelUp`/`BossSpawned` forward scaffolding; the separately-queued opponent respawn-render-delay interpolation investigation and any change to the ~100 ms opponent interpolation / reconcile math; attack **windup** animation (no timing data at the boundary); audio/SFX; external/CC0 art packs; full frame-by-frame sprite animation (deferred — the actor can grow frames later); the placeholder-balance numeric pass (separate, playtest-driven).

---

## 8. Tests & visual verification (evidence-first)

**Existing suite is a hard constraint** — the 5 client tests + sim/netcode/server suites + the three replay fixtures stay green/byte-identical at every task.

**New unit tests (mock style, no real assets — mirror `reaction_label_test`/`element_palette_test`):**
- **Palette/recolor:** `SpriteCatalog` substitutes sentinels → expected hex for each `(teamId, element)`; the all-white variant; cache returns identical handles.
- **Fallback:** when SVG load is unavailable (headless), the catalog yields the canvas-rect renderer and `GuildGame` still mounts (keeps `widget_smoke_test` green; add a focused fallback test).
- **FX projection (netcode):** given a sim step that emits `DamageDealt`/`CreepKilled`/`TowerDestroyed`/`CoreDestroyed`/`HeroDowned`, `MatchController.drainFx()` returns the expected `RenderFx` with correctly **resolved positions**, **exactly once**, and **nothing during a reconcile re-step** (the double-pop guard).
- **Damage-number formatting:** `amountRaw`→display integer and source-kind→color (pure-function test, `reactionText`-style).
- **Facing:** the flip decision is a pure function of `dx` + deadzone + previous facing (idle holds, motion flips).

**Visual verification (a first-class deliverable, not optional):** launch `cd apps/client && flutter run -d chrome`, open two tabs (players 0/1, per `apps/README.md`), and walk a **scripted QA checklist**, capturing screenshots: sprites render per kind/team/element; walk + facing flip; idle bob; basic attack pose + projectile + hit-flash + damage number; left-click ability → field pulse + reaction burst/pop-text; creep last-hit → kill burst + gold; tower fall → crumble + shake; core kill → finale + victory/defeat screen; status coat fade on a vaporize coat. Tune timings/magnitudes from what we see. Use the `verify`/`run` skill or manual launch.

---

## 9. Task plan (subagent-driven; fresh implementer per task; spec-compliance then code-quality review + fix loop each)

1. **Sprite foundation** — `flame_svg` dep (version-pinned to Flame 1.37.0) + `SpriteCatalog` (load + sentinel-recolor + all-white variant + cache + **canvas-rect fallback**) + the SVG sprite set + palette module. Tests: recolor, fallback, cache. No gameplay/diff change yet (catalog unused by the live view). Gate green.
2. **Entity sprite rendering** — `EntityView` → SVG sprite by kind/team/element; facing flip; idle/walk bob; restyled hp bar; local-hero ring preserved; hero innate-element accent (or fallback). `widget_smoke_test` stays green.
3. **Netcode FX boundary** — `RenderFx` types + `MatchController` forward-once collection + `drainFx()` + `MatchBinding` passthrough. Additive; FX-projection tests; existing tests green.
4. **Spawn / death life-cycle** — spawn-in pop; creep death (detach-animate-remove) + burst; hero death on `HeroDowned` + downed state + respawn pop. (Depends on 2 + 3.)
5. **Combat VFX consumers** — hit-flash (white overlay), floating damage numbers, attack/cast trigger + projectile/slash, creep-kill & reaction bursts. (Depends on 3.)
6. **Structures finale + camera juice** — tower crumble + debris, core-destruction finale, screen-shake/zoom-punch (composes with `camera.follow`), restyled victory/defeat overlay. (Depends on 3 + 5.)
7. **Environment + status polish** — tiled pixel backdrop + décor; field breathing-pulse + particles; status-coat fade tween.
8. **Visual-QA & tuning pass** — launch, run the §8 checklist, screenshot, tune values; prep for whole-branch review.

Order rationale: 1 is the foundation everything else needs; 2 makes the game *look* different immediately; 3 unlocks all event-driven VFX (4/5/6 depend on it); 4/5/6/7 are then largely independent polish layers; 8 closes with eyes-on verification. Each task: gate green (analyze + client tests + replay sanity) before done.

---

## 10. Open implementation details to resolve in the plan

- **`flame_svg` version & web behavior:** pin the exact `flame_svg` compatible with Flame 1.37.0; confirm the load-from-asset-string + recolor path and the `Svg` render API; smoke-check on the default HTML web renderer (CanvasKit fallback via `--web-renderer=canvaskit` only if needed). The canvas-rect fallback (§2.3) is the safety net.
- **Recolor mechanism:** confirm sentinel-hex `replaceAll` (valid standalone SVGs) vs `{{token}}` templating; pick sentinel-hex unless `flame_svg`'s parser normalizes colors in a way that breaks matching.
- **Hero innate element sourcing (§3.1):** confirm `heroElement(...)`'s signature/visibility from `apps/client` (it's in the exported sim barrel) and the team/slot key; else fall back to team-only accent + `statusElement` coat. No render-boundary field either way.
- **`isDowned` / hero life-cycle at the boundary:** `respawnTimer` is **not** in `RenderEntity`; derive the death beat from the **`HeroDowned` event** (surfaced via FX) and the downed/respawn beats from `hp<=0` + re-activation, rather than a `respawnTimer` poll. Confirm the hero stays in `MatchView.entities` while downed.
- **FX drain-once under reconcile:** confirm `RenderFx` is collected only in `advanceClientTick` and never in `onServerSnapshot` re-steps (mirror `ReactionTriggered`); and that `CreepKilled` position resolves before the death sweep removes the entity within the same step.
- **Camera shake vs `camera.follow`:** decide whether shake is an additive offset on the viewfinder transform or a transient detach; verify it doesn't fight `camera.follow(localHero)` or the fixed 960×540 resolution.
- **Headless test safety:** ensure the sprite path degrades to the canvas-rect fallback under `flutter test` so `widget_smoke_test` mounts without bundling/awaiting assets; confirm no `update(dt)` self-removal lands at an unsafe lifecycle point (the `reaction_label` pattern already self-removes in `update`).
- **Asset declaration:** first-ever `flutter: assets:` entry in `apps/client/pubspec.yaml`; confirm `flutter pub get` + web build pick up `assets/sprites/`.
