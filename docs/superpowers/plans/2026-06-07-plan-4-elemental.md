# Guild — Plan 4: Elemental (Vaporize Slice — Status, Neutral Fields, 2 Mono-Element Kits, TT2E) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the core loop *fun* — layer one neutral, two-sided **Vaporize** reaction (Pyro ⊕ Hydro) onto the proven combat sim, sourced from the two heroes' own overlapping stationary fields (Cinderfang **Ember Field** + Marisol **Tidepool**), with element-applying autos, a per-unit elemental status, harness-measured TT2E, and client legibility (element tint + field zones + "VAPORIZE" pop text) — all byte-identical across native/dart2js/dart2wasm.

**Architecture:** All gameplay lives in pure-Dart `packages/sim`. A new `_applyHit` wrapper around the existing `_applyDamage` chokepoint applies an `Element` to a hero/creep, and on a **different** stored element detonates Vaporize (consume the status, amplify the triggering hit ×1.3, emit the already-declared `ReactionTriggered`). Fields are a **stationary serialized struct-list** on `Simulation` (`[{ownerId, center, element, timer}]`), placed by a new left-click `IntentType.ability`; membership is `lengthSq` vs a precomputed radius². Status (`statusElement/statusTimer/reactionIcd`) + `abilityCooldown` are 4 new serialized `Entity` ints; the field block serializes after the entity loop. `SimEvent`s stay **off the wire** — the client re-steps the deterministic sim and renders reactions from its own `step()`.

**Tech Stack:** Dart 3.11.5 pub workspace; `packages/sim` (pure, Q16.16 `Fixed`, PCG32 `DetRng`, FNV-1a canonical hash); `packages/protocol` (binary codec — `InputMsg.type` already carries `IntentType.index`, so `ability` needs **no** codec change); `packages/netcode` (predict/reconcile/interpolate); `apps/client` (Flutter + Flame). Tests: `package:test`; cross-runtime golden via `tooling/replay_harness.dart` + `tooling/compare_replays.sh` on native/dart2js/dart2wasm.

**Determinism contract (every task obeys this — non-negotiable):**
- **No floating point in gameplay math.** `Fixed` (Q16.16) + `int` only. Keep every `|value| < 32768` so `|raw| < 2^31` and intermediates `< 2^53`. The Vaporize multiplier is a `Fixed` const; `maxRoutedDamage × mult < 32768` is asserted.
- **No `dart:math`** (`sin/cos/sqrt/pow/atan2/tan`), no `Random(`, no `DateTime`/`Stopwatch` in `packages/sim/lib`. Field membership uses `FVec2.lengthSq()` vs `kFieldRadiusSq` — **never** `length()`/`sqrt`. Enforced by `packages/sim/test/banned_imports_test.dart` + `tooling/check_no_banned_imports.sh`.
- **No new RNG draw.** Reactions are a pure function of state + tick. The only RNG draw stays the phase-5 wanderer (`simulation.dart:139`) — do not move, skip, or add to it.
- **Deterministic iteration order.** Status/field/reaction loops iterate `entityIdsSorted` (ascending id) or stable `_fields` list order; never a `Set`/hash map.
- **`Element` / `Reaction` / `IntentType` / `EndReason` / `EntityKind` enum values are APPEND-ONLY** — `.index` is serialized. No new `EntityKind` (fields are not entities).
- **Two byte formats, two versions.** Bump `kSchemaVersion` when `canonicalBytes()` changes; bump `kSnapshotVersion` when `snapshotBytes()` changes. The four byte sites — `canonicalBytes` (write), `snapshotBytes` (write), `restoreFromSnapshot` (read), `peekEntityPos` (per-entity skip) — move in lockstep. The field block is appended **after** the entity loop, so `peekEntityPos` needs only the per-entity status/ability skips, not the block.
- **Reconcile correctness.** Everything `step()` reads MUST round-trip: `statusElement/statusTimer/reactionIcd/abilityCooldown` + the field list are serialized (intent-derived field placement + ability cooldown reconcile exactly like `attackTargetId` does).
- **Respawn cleanup.** On hero respawn, clear status + remove that hero's field (gold persists, status must not).
- **Forward-compat:** 1v1 now, no `== 2` hardcodes; `teamId` clean (0/1 players, 2 = neutral). Build inert hooks only — no Melt/Overload/etc., no STRONG potency, no provenance split, no boss, no XP.

**Spec:** `docs/superpowers/specs/2026-06-07-plan-4-elemental-design.md`. Predecessor: `docs/superpowers/plans/2026-06-07-plan-3-combat.md`.

---

## Re-Pin Procedure (referenced by determinism tasks 3, 5, 8)

Goldens are regenerated — never hand-typed — from a verified green 3-runtime run whenever `canonicalBytes()` output changes. Current pinned values at branch start: in-test canonical hash `0xa14ee38d` (in **both** `simulation_test.dart` and `snapshot_test.dart`); `tooling/replay_fixtures/smoke.golden`; `tooling/replay_fixtures/combat.golden`.

**Procedure (run in bash — Git Bash / WSL on Windows):**
```bash
# 1. Confirm byte-identical determinism across all three runtimes FIRST.
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
# Expect: "PASS: byte-identical across native/js/wasm: <newhash>"
# A DIVERGENCE instead = a non-determinism bug (stray shift/double/Map-iteration/sqrt).
# Binary-diff canonicalBytes() per tick to find the first divergent field; fix BEFORE pinning.

# 2. Capture the new cross-runtime golden for each affected fixture, e.g. smoke:
b64=$(base64 -w0 tooling/replay_fixtures/smoke.json) \
  && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart \
     | awk '/^REPLAY_HASH /{print $2}' > tooling/replay_fixtures/smoke.golden
# Repeat for combat.json -> combat.golden / elemental.json -> elemental.golden as the task requires.

# 3. For the in-test literal, read the new hash from the failing `dart test packages/sim`
#    output ("Expected: <0x...> Actual: <0x...>") and replace the 0xNNNNNNNN literal in BOTH:
#      packages/sim/test/simulation_test.dart  (test 'pinned 300-tick canonical state hash')
#      packages/sim/test/snapshot_test.dart    (test 'canonicalBytes/hash unchanged (golden untouched)')

# 4. Verify green + enforced.
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json   # ...then "PASS: matches golden ..."
dart test packages/sim
```
Commit the regenerated `.golden` file(s) and the updated test literal(s) **together** in the task's commit. Only the task notes say *which* goldens move; do not touch goldens a task doesn't list.

---

## File Structure

**Created:**
- `packages/sim/lib/src/model/element.dart` — `enum Element { pyro, hydro }`, `enum Reaction { vaporize }` (append-only).
- `packages/sim/lib/src/model/elemental_field.dart` — `class ElementalField { int ownerId; FVec2 center; int element; int timer; }`.
- `packages/sim/lib/src/data/elements.dart` — elemental tunables (status/ICD durations, Vaporize mult, field radius²/DoT/duration, ability cooldown) + the 2-hero roster mapping.
- `packages/sim/test/element_test.dart` — enums, widened `ReactionTriggered`, `ElementalField`.
- `packages/sim/test/elements_data_test.dart` — constants budget + range² + roster.
- `packages/sim/test/reaction_test.dart` — fields, coating, Vaporize, ICD, two-sided, creep rules, expiry-vs-react.
- `packages/sim/test/telemetry_test.dart` — TT2E + reactions/min computed from `step()` events.
- `tooling/replay_fixtures/elemental.json` + `elemental.golden` — a Vaporize-exercising cross-runtime golden.
- `apps/client/lib/render/field_view.dart` — translucent element-tinted field zone.
- `apps/client/lib/render/reaction_label.dart` — floating "VAPORIZE ×1.3" pop text.
- `apps/client/lib/render/element_palette.dart` — pure `elementColor(int)` (testable).
- `apps/client/test/element_palette_test.dart` — `elementColor` mapping.

**Modified:**
- `packages/sim/lib/src/model/entity.dart` — 4 new fields (`statusElement`, `statusTimer`, `reactionIcd`, `abilityCooldown`).
- `packages/sim/lib/src/model/intent.dart` — append `IntentType.ability`.
- `packages/sim/lib/src/events.dart` — widen `ReactionTriggered` (`+multiplierRaw +sourceId`).
- `packages/sim/lib/src/simulation.dart` — `_fields` + getter; field placement in `step()`; decrements + `_stepFields` + status/field expiry in `_stepCombat`; `_applyHit`; route hero autos through it; respawn cleanup; serialize the 4 fields + field block in all four byte sites; version bumps.
- `packages/sim/lib/sim.dart` — export `element.dart`, `elemental_field.dart`, `data/elements.dart`.
- `packages/sim/test/model_test.dart` — Entity status-field defaults + `IntentType.ability` index.
- `packages/sim/test/simulation_test.dart`, `packages/sim/test/snapshot_test.dart` — re-pinned hash literal.
- `packages/netcode/lib/src/match_view.dart` — `RenderEntity.statusElement`; `RenderField`/`RenderReaction`; `MatchView.fields`/`.reactions`.
- `packages/netcode/lib/src/match_controller.dart` — `applyAbilityInput`; collect `ReactionTriggered` in `advanceClientTick`; populate `update()`.
- `packages/netcode/test/match_controller_test.dart` — ability input + view fields.
- `apps/client/lib/match/match_binding.dart` — `submitAbility`.
- `apps/client/lib/render/guild_game.dart` — left-click ability; field-zone + reaction diff; element tint feed.
- `apps/client/lib/render/entity_view.dart` — element-tint ring driven by `statusElement`.
- `.github/workflows/sim-determinism.yml` — add the `elemental.json` replay step.

---

## Scope (read before starting)

**IN:** `Element`/`Reaction` enums; per-unit serialized status (`statusElement/statusTimer/reactionIcd`); per-hero `abilityCooldown`; stationary neutral fields (struct-list, `lengthSq` membership, 2-sided); `IntentType.ability` (left-click placement, Cinderfang self-placed / Marisol aim-placed); autos apply LIGHT element; `_applyHit` Vaporize (consume + ×1.3 amplify + per-unit ICD + emit `ReactionTriggered`); field DoT real on heroes, **zero on creeps** (coat-not-farm); status/fields on **heroes + creeps**; respawn cleanup; serialization + version bump + re-pin; TT2E + reactions/min harness; `elemental.json` cross-runtime golden; client element tint + field zones + VAPORIZE pop text + left-click input.

**OUT (no code, only the noted inert hooks):** all other reactions; STRONG potency + ×1.3/×2.0 provenance split (no `strength`/provenance stored); reaction cascades / Swirl / per-reaction ICD maps; ultimates, Ember Hook, Maelstrom, all displacement, Tidepool's slow; persistent detached trails (field clears on respawn); elemental creeps / element-steal / Anemo; revenge boss (`BossSpawned` stays declared-only); XP/levels (`LevelUp` declared-only); shop; elemental interactions on towers/cores/wanderer; any `SimEvent` on the wire.

---

## Task 1: `Element`/`Reaction` enums + per-entity status/ability fields + widened `ReactionTriggered`

**Files:**
- Create: `packages/sim/lib/src/model/element.dart`
- Modify: `packages/sim/lib/src/model/entity.dart`
- Modify: `packages/sim/lib/src/events.dart`
- Modify: `packages/sim/lib/sim.dart`
- Create: `packages/sim/test/element_test.dart`
- Modify: `packages/sim/test/model_test.dart`

> **Golden-neutral:** adds fields/types but does NOT change `canonicalBytes()` (the new `Entity` fields aren't serialized until Task 3; `create()` is unchanged). All pinned-hash tests stay untouched.

- [ ] **Step 1: Write the failing tests**

Create `packages/sim/test/element_test.dart`:
```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('Element/Reaction enum indices are stable (serialized as .index)', () {
    expect(Element.pyro.index, 0);
    expect(Element.hydro.index, 1);
    expect(Reaction.vaporize.index, 0);
  });

  test('ReactionTriggered carries unit, reaction, multiplier and source', () {
    const r = ReactionTriggered(
        unitId: 1, reaction: 0, multiplierRaw: 85197, sourceId: 0);
    expect(r.unitId, 1);
    expect(r.reaction, 0);
    expect(r.multiplierRaw, 85197); // Q16.16 raw of ×1.3 (Fixed.fromNum(1.3).raw)
    expect(r.sourceId, 0);
    expect(<SimEvent>[r], hasLength(1)); // still a SimEvent
  });
}
```

Append to `packages/sim/test/model_test.dart` (inside `main()`):
```dart
  test('Entity has elemental status fields defaulting to none/ready', () {
    final e = Entity(id: 0, kind: EntityKind.hero, teamId: 0,
        pos: FVec2.zero, hp: Fixed.fromInt(100));
    expect(e.statusElement, -1); // -1 = no elemental status
    expect(e.statusTimer, 0);
    expect(e.reactionIcd, 0);
    expect(e.abilityCooldown, 0);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test packages/sim/test/element_test.dart packages/sim/test/model_test.dart`
Expected: FAIL — `element_test`: "Undefined name 'Element'" / "ReactionTriggered ... isn't defined with named parameter 'multiplierRaw'"; `model_test`: "The getter 'statusElement' isn't defined for the type 'Entity'".

- [ ] **Step 3: Write the implementation**

Create `packages/sim/lib/src/model/element.dart`:
```dart
/// Elements a hero/field/auto can apply. APPEND-ONLY: `.index` is serialized in
/// the status field. Pyro/Hydro are the slice's two; Electro/Cryo/Anemo append
/// later. (Anemo will never be a *stored* status — it only reads/consumes.)
enum Element { pyro, hydro }

/// Reactions detonated when a different element meets a stored status.
/// APPEND-ONLY: `.index` rides `ReactionTriggered.reaction`. Vaporize is the
/// slice's only reaction; Melt/Overload/etc. append later.
enum Reaction { vaporize }
```

In `packages/sim/lib/src/model/entity.dart`, add the four fields after `attackTargetId` (keep the existing `target` field + constructor body), and the constructor params. Replace the field block from `int attackTargetId;` through `target = target ?? pos;`:
```dart
  /// Locked attack target entity id (-1 = none). Set by an attack intent,
  /// cleared by a move intent or when the target dies/leaves. Heroes pursue +
  /// attack ONLY this id. Persistent, intent-derived → serialized so reconcile
  /// reproduces it.
  int attackTargetId;

  /// Elemental status (Plan 4): the single element coating this unit.
  /// -1 = none; else Element.index. Serialized (heroes/creeps only ever carry it).
  int statusElement;

  /// Ticks of elemental status remaining; at 0 the status is swept to -1.
  int statusTimer;

  /// Per-unit reaction internal-cooldown (ticks; 0 = ready). Gates Vaporize so
  /// an overlap can't machine-gun reactions.
  int reactionIcd;

  /// Ticks until this hero's field ability is ready (0 = ready).
  int abilityCooldown;

  // Heroes seek toward this point (set by a move intent / pursue resolution).
  FVec2 target;

  Entity({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.pos,
    required this.hp,
    Fixed? maxHp,
    this.attackCooldown = 0,
    this.gold = 0,
    this.respawnTimer = 0,
    this.attackTargetId = -1,
    this.statusElement = -1,
    this.statusTimer = 0,
    this.reactionIcd = 0,
    this.abilityCooldown = 0,
    FVec2? vel,
    FVec2? target,
  })  : maxHp = maxHp ?? hp,
        vel = vel ?? FVec2.zero,
        target = target ?? pos;
```

In `packages/sim/lib/src/events.dart`, replace the declared `ReactionTriggered` (the slice now emits it; widen it):
```dart
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
```

Add to `packages/sim/lib/sim.dart` (after the `entity.dart` export):
```dart
export 'src/model/element.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test packages/sim/test/element_test.dart packages/sim/test/model_test.dart`
Expected: PASS.

Then confirm goldens untouched:
Run: `dart test packages/sim`
Expected: PASS (incl. the pinned `0xa14ee38d` tests — no serialized state changed).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/model/element.dart packages/sim/lib/src/model/entity.dart \
        packages/sim/lib/src/events.dart packages/sim/lib/sim.dart \
        packages/sim/test/element_test.dart packages/sim/test/model_test.dart
git commit -m "feat(sim): Element/Reaction enums + per-unit status/ability fields + widen ReactionTriggered"
```

---

## Task 2: Elemental tunables + `ElementalField` model + `IntentType.ability`

**Files:**
- Create: `packages/sim/lib/src/data/elements.dart`
- Create: `packages/sim/lib/src/model/elemental_field.dart`
- Modify: `packages/sim/lib/src/model/intent.dart`
- Modify: `packages/sim/lib/sim.dart`
- Create: `packages/sim/test/elements_data_test.dart`
- Modify: `packages/sim/test/element_test.dart`
- Modify: `packages/sim/test/model_test.dart`

> **Golden-neutral** (pure data + types + an append-only enum value; nothing serialized or stepped yet). Values are **playtest placeholders** (spec §13 defers exact numbers).

- [ ] **Step 1: Write the failing tests**

Create `packages/sim/test/elements_data_test.dart`:
```dart
import 'package:sim/sim.dart';
import 'package:sim/src/data/elements.dart';
import 'package:test/test.dart';

void main() {
  test('elemental constants obey the Fixed magnitude budget (|value| < 32768)', () {
    for (final f in <Fixed>[kVaporizeMult, kFieldRadius, kFieldRadiusSq, kFieldDotDamage]) {
      expect(f.toDouble().abs() < 32768, isTrue, reason: '$f exceeds budget');
    }
    // The worst routed damage × multiplier must stay in budget (no overflow).
    expect((kHeroAttackDamage * kVaporizeMult).toDouble().abs() < 32768, isTrue);
  });

  test('field radius² equals radius squared (lengthSq membership, no sqrt)', () {
    expect(kFieldRadiusSq.toDouble(),
        kFieldRadius.toDouble() * kFieldRadius.toDouble());
  });

  test('durations/cooldowns are integer ticks', () {
    expect(kStatusDurationTicks, isA<int>());
    expect(kReactionIcdTicks, isA<int>());
    expect(kFieldDurationTicks, isA<int>());
    expect(kAbilityCooldownTicks, isA<int>());
    expect(kReactionIcdTicks, greaterThan(0)); // a real per-unit reaction gate
  });

  test('slice roster: hero 0 = Cinderfang (Pyro, self-placed), hero 1 = Marisol (Hydro, aim)', () {
    expect(heroElement(0), Element.pyro.index);
    expect(heroElement(1), Element.hydro.index);
    expect(heroPlacesAtSelf(0), isTrue); // Cinderfang: Ember Field at his feet
    expect(heroPlacesAtSelf(1), isFalse); // Marisol: Tidepool at the aim point
  });
}
```

Append to `packages/sim/test/element_test.dart` (inside `main()`):
```dart
  test('ElementalField holds owner, stationary center, element and timer', () {
    final f = ElementalField(
        ownerId: 0, center: FVec2(Fixed.fromInt(2), Fixed.zero),
        element: Element.pyro.index, timer: 120);
    expect(f.ownerId, 0);
    expect(f.center.x.toDouble(), 2.0);
    expect(f.element, Element.pyro.index);
    expect(f.timer, 120);
    f.timer -= 1; // timer is mutable (decremented each tick)
    expect(f.timer, 119);
  });
```

Append to `packages/sim/test/model_test.dart` (inside `main()`):
```dart
  test('IntentType appends ability without shifting existing indices', () {
    expect(IntentType.none.index, 0);
    expect(IntentType.move.index, 1);
    expect(IntentType.attack.index, 2);
    expect(IntentType.ability.index, 3); // left-click ability cast
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test packages/sim/test/elements_data_test.dart packages/sim/test/element_test.dart packages/sim/test/model_test.dart`
Expected: FAIL — "Target of URI doesn't exist: 'package:sim/src/data/elements.dart'"; "Undefined name 'ElementalField'"; "The getter 'ability' isn't defined for the enum 'IntentType'".

- [ ] **Step 3: Write the implementation**

Create `packages/sim/lib/src/model/elemental_field.dart`:
```dart
import '../math/fvec2.dart';

/// A stationary neutral elemental field (Plan 4). NOT an Entity — it lives in a
/// small serialized list on Simulation. Placed at the caster's position (cast
/// time) and coats any hero/creep within kFieldRadius each tick (2-sided: the
/// owner is not exempt). Removed when `timer` reaches 0.
class ElementalField {
  final int ownerId; // the hero who cast it (for DamageDealt.sourceId / credit)
  final FVec2 center; // cast position; STATIONARY (does not follow the owner)
  final int element; // Element.index
  int timer; // ticks remaining
  ElementalField({
    required this.ownerId,
    required this.center,
    required this.element,
    required this.timer,
  });
}
```

Create `packages/sim/lib/src/data/elements.dart` with this exact content:
```dart
import '../math/fixed.dart';
import '../model/element.dart';

/// Elemental tunables for the Vaporize slice. PLAYTEST PLACEHOLDERS (spec §13
/// defers exact numbers); all obey the Fixed budget (|value| < 32768).

// --- Status (Genshin LIGHT timing, spec §3.1) ---
const int kStatusDurationTicks = 45; // ~1.5s LIGHT status
const int kReactionIcdTicks = 15; // ~0.5s per-unit reaction internal cooldown

// --- Vaporize (amplify; spec §3.3 committed field-cap multiplier) ---
final Fixed kVaporizeMult = Fixed.fromNum(1.3);

// --- Neutral fields ---
final Fixed kFieldRadius = Fixed.fromNum(2.5);
final Fixed kFieldRadiusSq = Fixed.fromNum(2.5 * 2.5); // compare vs lengthSq, no sqrt
final Fixed kFieldDotDamage = Fixed.fromNum(1); // per-tick DoT to HEROES (zero to creeps)
const int kFieldDurationTicks = 120; // ~4s
const int kAbilityCooldownTicks = 240; // ~8s (> field duration → ≤1 active field/hero)

// --- Slice roster (data) ---
// hero 0 = Cinderfang (Pyro, Ember Field placed at his own position);
// hero 1 = Marisol    (Hydro, Tidepool placed at the aim point).
int heroElement(int heroId) =>
    heroId == 0 ? Element.pyro.index : Element.hydro.index;
bool heroPlacesAtSelf(int heroId) => heroId == 0;
```

In `packages/sim/lib/src/model/intent.dart`, append `ability` (append-only — `.index` is the wire `type`):
```dart
enum IntentType { none, move, attack, ability }
```
(An ability intent reuses `aimX`/`aimY` as the **Q16.16 world cast point** — like `move`, not an entity id — so no protocol/codec change.)

Add to `packages/sim/lib/sim.dart` (after the `element.dart` export from Task 1):
```dart
export 'src/model/elemental_field.dart';
export 'src/data/elements.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test packages/sim/test/elements_data_test.dart packages/sim/test/element_test.dart packages/sim/test/model_test.dart`
Expected: PASS.

Run: `dart test packages/sim`
Expected: PASS (goldens still `0xa14ee38d` — nothing serialized/stepped changed).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/data/elements.dart packages/sim/lib/src/model/elemental_field.dart \
        packages/sim/lib/src/model/intent.dart packages/sim/lib/sim.dart \
        packages/sim/test/elements_data_test.dart packages/sim/test/element_test.dart \
        packages/sim/test/model_test.dart
git commit -m "feat(sim): elemental tunables + ElementalField model + IntentType.ability"
```

---

## Task 3: Serialize status/ability fields + the field block; bump versions; re-pin goldens (#1)

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/snapshot_test.dart`
- Modify: `packages/sim/test/simulation_test.dart`
- Modify: `tooling/replay_fixtures/smoke.golden`, `tooling/replay_fixtures/combat.golden`

> **Determinism-critical.** Adds the four per-entity fields (after `attackTargetId`) + an (empty for now) field block (after the entity loop) to `canonicalBytes`/`snapshotBytes`, the matching reads in `restoreFromSnapshot`, the per-entity skips in `peekEntityPos`, and bumps both versions 2→3. The combat-free anchor stays **behaviorally identical** (move-only → no status, empty `_fields`) but the **layout** changes, so all three current goldens move (smoke + combat + the in-test literal). Field placement/stepping arrives in Tasks 4–5; here `_fields` is always empty.

- [ ] **Step 1: Write/adjust the failing tests**

Append to `packages/sim/test/snapshot_test.dart` (inside `main()`):
```dart
  test('snapshot round-trips elemental status/ability fields', () {
    final src = Simulation.create(const SimConfig(seed: 1337));
    src.entity(0).statusElement = Element.hydro.index;
    src.entity(0).statusTimer = 20;
    src.entity(0).reactionIcd = 7;
    src.entity(0).abilityCooldown = 33;
    final dst = Simulation.create(const SimConfig(seed: 1337))
      ..restoreFromSnapshot(src.snapshotBytes());
    expect(dst.entity(0).statusElement, Element.hydro.index);
    expect(dst.entity(0).statusTimer, 20);
    expect(dst.entity(0).reactionIcd, 7);
    expect(dst.entity(0).abilityCooldown, 33);
    expect(dst.canonicalStateHash(), src.canonicalStateHash());
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim`
Expected: FAIL — the new round-trip test fails (`statusElement` not restored → `dst.entity(0).statusElement == -1`), AND the two pinned-hash tests fail with `Expected: <0xa14ee38d> Actual: <0x...>` (layout changed). Do **not** edit the literals yet.

- [ ] **Step 3: Add `_fields` + extend the encodings + bump versions**

In `packages/sim/lib/src/simulation.dart`:

(a) Bump both versions:
```dart
const int kSchemaVersion = 3;
```
```dart
const int kSnapshotVersion = 3;
```

(b) Add the field list + getter. After the line `final Map<int, int> _lastDamager = {};` insert:
```dart

  /// Stationary neutral elemental fields (Plan 4). Tiny (≤1 active per hero,
  /// cooldown-gated). Serialized after the entity loop. Iterated in list order
  /// (deterministic: append on cast, removal preserves order).
  final List<ElementalField> _fields = [];
  List<ElementalField> get fields => _fields;
```

(c) Add the import at the top (with the other `model/` imports):
```dart
import 'model/elemental_field.dart';
```

(d) In `canonicalBytes()`, insert the four fields after `w.i32(e.attackTargetId);` (replace the existing `w.i32(e.attackTargetId);` line + its trailing comment line):
```dart
      w.i32(e.attackTargetId);
      w.i32(e.statusElement);
      w.i32(e.statusTimer);
      w.i32(e.reactionIcd);
      w.i32(e.abilityCooldown);
      // NOTE: target is intentionally NOT in the canonical format (snapshot-only).
```
Then append the field block just before `return w.toBytes();` (the LAST line of `canonicalBytes`, right after the `for (final id in ids)` loop closes):
```dart
    w.i32(_fields.length);
    for (final f in _fields) {
      w.i32(f.ownerId);
      w.fixed(f.center.x);
      w.fixed(f.center.y);
      w.i32(f.element);
      w.i32(f.timer);
    }
    return w.toBytes();
```

(e) In `snapshotBytes()`, insert the same four fields after `w.i32(e.attackTargetId);` and **before** `w.fixed(e.target.x);`:
```dart
      w.i32(e.attackTargetId);
      w.i32(e.statusElement);
      w.i32(e.statusTimer);
      w.i32(e.reactionIcd);
      w.i32(e.abilityCooldown);
      w.fixed(e.target.x);
      w.fixed(e.target.y);
```
Then append the identical field block just before this method's `return w.toBytes();`:
```dart
    w.i32(_fields.length);
    for (final f in _fields) {
      w.i32(f.ownerId);
      w.fixed(f.center.x);
      w.fixed(f.center.y);
      w.i32(f.element);
      w.i32(f.timer);
    }
    return w.toBytes();
```

(f) In `restoreFromSnapshot()`, read the four fields after `final attackTargetId = r.i32();` and before `final target = ...`:
```dart
      final attackTargetId = r.i32();
      final statusElement = r.i32();
      final statusTimer = r.i32();
      final reactionIcd = r.i32();
      final abilityCooldown = r.i32();
      final target = FVec2(r.fixed(), r.fixed());
```
Apply them in the unconditional write block, after `e.attackTargetId = attackTargetId;` and before `e.target = target;`:
```dart
      e.attackTargetId = attackTargetId;
      e.statusElement = statusElement;
      e.statusTimer = statusTimer;
      e.reactionIcd = reactionIcd;
      e.abilityCooldown = abilityCooldown;
      e.target = target;
```
Then read the field block. Replace the tail of the method (the `_entities.removeWhere(... !seen ...)` / `_byId.removeWhere(...)` / `_lastDamager.clear();` block) by inserting the field read just before `_lastDamager.clear();`:
```dart
    // Drop entities absent from the snapshot (despawned on the authority).
    _entities.removeWhere((e) => !seen.contains(e.id));
    _byId.removeWhere((id, e) => !seen.contains(id));
    final fieldCount = r.i32();
    _fields.clear();
    for (var i = 0; i < fieldCount; i++) {
      final ownerId = r.i32();
      final cx = r.fixed();
      final cy = r.fixed();
      final element = r.i32();
      final timer = r.i32();
      _fields.add(ElementalField(
          ownerId: ownerId, center: FVec2(cx, cy), element: element, timer: timer));
    }
    _lastDamager.clear();
```

(g) In `peekEntityPos()`, add the four per-entity skips after `r.i32(); // attackTargetId` and before the `target` skip (the field block is after the entity loop, where peek already returns/ends — no block skip needed):
```dart
      r.i32(); // attackTargetId
      r.i32(); // statusElement
      r.i32(); // statusTimer
      r.i32(); // reactionIcd
      r.i32(); // abilityCooldown
      r.fixed(); r.fixed(); // target
```

(No change to `create()` — the new Entity fields default to -1/0/0/0.)

- [ ] **Step 4: Re-pin the goldens (Re-Pin Procedure)**

Run the Re-Pin Procedure for **both** `smoke.json` and `combat.json` (capture `smoke.golden` and `combat.golden`), then update the `0xa14ee38d` literal in **both** `simulation_test.dart` (`'pinned 300-tick canonical state hash'`) and `snapshot_test.dart` (`'canonicalBytes/hash unchanged (golden untouched)'`) from the failing test output.

- [ ] **Step 5: Verify all green**

Run: `dart test packages/sim`
Expected: PASS (incl. re-pinned hashes + the new round-trip test).
Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json` then `... combat.json`
Expected: each prints `PASS: byte-identical ...` then `PASS: matches golden ...`.
Run: `dart test packages/netcode && dart test packages/protocol && dart test apps/server`
Expected: PASS (they round-trip snapshots within one process at the same version).

- [ ] **Step 6: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/snapshot_test.dart \
        packages/sim/test/simulation_test.dart \
        tooling/replay_fixtures/smoke.golden tooling/replay_fixtures/combat.golden
git commit -m "feat(sim)!: serialize elemental status + field block; bump versions; re-pin goldens (#1 layout)"
```

---

## Task 4: Field placement (`IntentType.ability`) + timers + expiry + respawn cleanup

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Create: `packages/sim/test/reaction_test.dart`

> **Golden-neutral for existing fixtures:** fields are placed only by `ability` intents, which neither `smoke.json` nor `combat.json` use → `_fields` stays empty there (count 0, already serialized in Task 3). The new per-unit timer decrements act only on values that are 0 in those fixtures → no byte change. The smoke/combat goldens and the in-test literal are **untouched**. No `_applyHit` / coating yet (Task 5).

- [ ] **Step 1: Write the failing tests**

Create `packages/sim/test/reaction_test.dart`:
```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('Marisol (hero 1) casts Tidepool at the aim point with Hydro', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    expect(sim.fields, isEmpty);
    // aim at world (3,0) => Q16.16 raws (3*65536 = 196608).
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 196608, aimY: 0, seq: 1)]);
    expect(sim.fields, hasLength(1));
    final f = sim.fields.single;
    expect(f.ownerId, 1);
    expect(f.element, Element.hydro.index);
    expect(f.center.x.toDouble(), 3.0); // ranged: placed AT the aim point
    expect(sim.entity(1).abilityCooldown, greaterThan(0));
  });

  test('Cinderfang (hero 0) casts Ember Field at his OWN position (aim ignored)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = FVec2(Fixed.fromInt(-5), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 655360, aimY: 655360, seq: 1)]);
    final f = sim.fields.single;
    expect(f.ownerId, 0);
    expect(f.element, Element.pyro.index);
    expect(f.center.x.toDouble(), -5.0); // self-placed, NOT the (10,10) aim
  });

  test('a field cannot be recast while the ability is on cooldown', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 0, seq: 1)]);
    expect(sim.fields, hasLength(1));
    sim.step(1, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 131072, aimY: 0, seq: 2)]);
    expect(sim.fields, hasLength(1)); // on cooldown → not recast
  });

  test('a field expires after its duration', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 0, seq: 1)]);
    expect(sim.fields, hasLength(1));
    for (var t = 1; t <= kFieldDurationTicks; t++) {
      sim.step(t, const []);
    }
    expect(sim.fields, isEmpty);
  });

  test('respawning clears a hero status and removes their field', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // off-lane, tower-safe
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 10000; // would outlast respawn — only the clear empties it
    sim.fields.add(ElementalField(
        ownerId: 1, center: FVec2.zero, element: Element.hydro.index, timer: 10000));
    h.hp = Fixed.zero; // downable this tick
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []); // death sweep → downed
    expect(h.respawnTimer, kHeroRespawnTicks);
    for (var t = 1; t <= kHeroRespawnTicks; t++) {
      sim.step(t, const []);
    }
    expect(h.respawnTimer, 0); // respawned
    expect(h.statusElement, -1); // cleared on respawn
    expect(sim.fields.where((f) => f.ownerId == 1), isEmpty); // field removed on respawn
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/reaction_test.dart`
Expected: FAIL — casting an ability does nothing (`sim.fields` stays empty), so the placement assertions fail.

- [ ] **Step 3: Implement field placement + lifecycle**

In `packages/sim/lib/src/simulation.dart`, in `step()`'s phase-1 intent loop, add an `ability` branch. Replace the existing `} else if (it.type == IntentType.attack) {` block's closing so it reads:
```dart
      } else if (it.type == IntentType.attack) {
        hero.attackTargetId = it.aimX; // aimX carries the target entity id
      } else if (it.type == IntentType.ability) {
        if (hero.abilityCooldown != 0) continue; // on cooldown → ignore the cast
        _fields.removeWhere((f) => f.ownerId == hero.id); // ≤1 active field per hero
        final center = heroPlacesAtSelf(hero.id)
            ? hero.pos // Cinderfang: Ember Field at his feet (melee)
            : FVec2(Fixed.raw(it.aimX), Fixed.raw(it.aimY)); // Marisol: Tidepool at aim
        _fields.add(ElementalField(
            ownerId: hero.id,
            center: center,
            element: heroElement(hero.id),
            timer: kFieldDurationTicks));
        hero.abilityCooldown = kAbilityCooldownTicks;
      }
```

In `_stepCombat`, extend the respawn block to clear status + remove the field. Replace the inner respawn body:
```dart
      e.respawnTimer -= 1;
      if (e.respawnTimer == 0) {
        e.hp = e.maxHp;
        e.pos = FVec2(_heroSpawnX(e), Fixed.zero);
        e.target = e.pos;
        e.attackCooldown = 0;
        // Plan 4: a fresh respawn carries no elemental status; drop the field too.
        e.statusElement = -1;
        e.statusTimer = 0;
        e.reactionIcd = 0;
        _fields.removeWhere((f) => f.ownerId == e.id);
      }
```

Replace the cooldown-decrement loop:
```dart
    // Tick cooldowns down for every combatant first.
    for (final e in _entities) {
      if (e.attackCooldown > 0) e.attackCooldown -= 1;
    }
```
with the expanded per-unit + field timers and the field-expiry sweep (the marked line is where Task 5 inserts field ticks):
```dart
    // Tick every per-unit timer down first (statusTimer is swept to -1 AFTER
    // reactions in Task 5; reactionIcd guards the next reaction).
    for (final e in _entities) {
      if (e.attackCooldown > 0) e.attackCooldown -= 1;
      if (e.abilityCooldown > 0) e.abilityCooldown -= 1;
      if (e.reactionIcd > 0) e.reactionIcd -= 1;
      if (e.statusTimer > 0) e.statusTimer -= 1;
    }
    for (final f in _fields) {
      if (f.timer > 0) f.timer -= 1;
    }
    // (Task 5 inserts `_stepFields(events);` HERE — field ticks coat units in range.)
    _fields.removeWhere((f) => f.timer <= 0); // expired fields gone (after their final tick)
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/reaction_test.dart`
Expected: PASS (5 tests).

Run: `dart test packages/sim`
Expected: PASS — goldens unchanged (no fixture casts an ability; the new decrements act only on zeros there).
Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json` then `... combat.json`
Expected: each `PASS: byte-identical ...` then `PASS: matches golden ...` (unchanged).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/reaction_test.dart
git commit -m "feat(sim): left-click ability places a stationary field; field timers/expiry + respawn cleanup"
```

---

## Task 5: `_applyHit` element-application + field ticks + autos coat + status expiry (re-pin combat #2)

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/reaction_test.dart`
- Modify: `tooling/replay_fixtures/combat.golden`

> **Re-pins `combat.golden` ONLY.** `combat.json`'s heroes attack-lock each other → their autos now coat the target with an element → `canonicalBytes` changes. `smoke.json` (move-only) and the in-test anchor `0xa14ee38d` (move-only, no autos, empty fields) are **unchanged**. No reaction yet — `_applyHit` only coats (set/refresh); the differing-element branch arrives in Task 6.

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/reaction_test.dart` (inside `main()`):
```dart
  test('a field coats a hero standing inside it', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // tower-safe off-lane
    h.target = h.pos;
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.pyro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(h.statusElement, Element.pyro.index);
    expect(h.statusTimer, greaterThan(0));
  });

  test('a field does not coat a unit outside its radius', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.pos = FVec2(Fixed.fromInt(20), Fixed.fromInt(7));
    h.target = h.pos;
    sim.fields.add(ElementalField(
        ownerId: 0, center: FVec2(Fixed.zero, Fixed.fromInt(7)),
        element: Element.pyro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(h.statusElement, -1); // 20 units from the field center
  });

  test('field DoT damages a hero but is ZERO on a creep (coat-not-farm)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final center = FVec2(Fixed.fromInt(-8), Fixed.zero); // own-side, tower-safe
    final h = sim.entity(0)..pos = center..target = center;
    final creep = sim.entity(kCreepIdBase)..pos = center;
    final creepHpBefore = creep.hp.raw;
    final heroHpBefore = h.hp.raw;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.fields.add(ElementalField(
        ownerId: 1, center: center, element: Element.hydro.index, timer: 100));
    sim.step(kFirstWaveTick + 1, const []);
    expect(creep.statusElement, Element.hydro.index); // coated
    expect(creep.hp.raw, creepHpBefore); // but ZERO DoT
    expect(h.statusElement, Element.hydro.index); // coated
    expect(h.hp.raw, lessThan(heroHpBefore)); // real DoT to the hero
  });

  test('a hero auto coats its locked target with the hero element', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final a = sim.entity(0); // Cinderfang → Pyro
    final b = sim.entity(1);
    a.pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    b.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    a.target = a.pos;
    b.target = b.pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(b.statusElement, Element.pyro.index);
  });

  test('same-element re-application refreshes the timer (no stacking)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.hydro.index;
    h.statusTimer = 3;
    sim.fields.add(ElementalField(
        ownerId: 1, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(h.statusElement, Element.hydro.index);
    expect(h.statusTimer, kStatusDurationTicks); // refreshed to full
  });

  test('a status expires to none after its duration', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 3;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    for (var t = 0; t < 3; t++) {
      sim.step(t, const []);
    }
    expect(h.statusElement, -1); // swept after statusTimer hit 0
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/reaction_test.dart`
Expected: FAIL — fields don't coat (no `_stepFields`), autos don't coat (still `_applyDamage`).

- [ ] **Step 3: Implement `_applyHit` (coat-only) + `_stepFields` + route autos**

In `packages/sim/lib/src/simulation.dart`, add the two methods right after `_applyDamage` (anywhere among the private combat helpers is fine):
```dart
  /// Element-application chokepoint (Plan 4). Autos + field ticks route through
  /// here; towers (non-elemental) call _applyDamage directly. Only heroes/creeps
  /// carry status. A 0-damage coat (a creep field tick) skips _applyDamage so it
  /// neither last-hits nor spams DamageDealt. The Vaporize reaction is added next.
  void _applyHit(
      Entity source, Entity target, Fixed baseDamage, int element, List<SimEvent> events) {
    if (target.kind != EntityKind.hero && target.kind != EntityKind.creep) {
      if (baseDamage.raw > 0) _applyDamage(source, target, baseDamage, events);
      return;
    }
    target.statusElement = element; // coat (set/refresh)
    target.statusTimer = kStatusDurationTicks;
    if (baseDamage.raw > 0) _applyDamage(source, target, baseDamage, events);
  }

  /// Field ticks: every active field coats each hero/creep within its radius
  /// (2-sided — the owner is not exempt). DoT is real on heroes, ZERO on creeps
  /// (coat-not-farm). Iterates entityIdsSorted for determinism.
  void _stepFields(List<SimEvent> events) {
    for (final f in _fields) {
      for (final id in entityIdsSorted) {
        final u = _byId[id]!;
        if (u.kind != EntityKind.hero && u.kind != EntityKind.creep) continue;
        if (u.hp.raw <= 0) continue;
        if (u.kind == EntityKind.hero && u.respawnTimer != 0) continue; // downed
        if ((u.pos - f.center).lengthSq() > kFieldRadiusSq) continue;
        final dot = u.kind == EntityKind.creep ? Fixed.zero : kFieldDotDamage;
        _applyHit(_byId[f.ownerId]!, u, dot, f.element, events);
      }
    }
  }
```

Insert the field-tick call. Replace the Task-4 marker line + the field-expiry sweep:
```dart
    // (Task 5 inserts `_stepFields(events);` HERE — field ticks coat units in range.)
    _fields.removeWhere((f) => f.timer <= 0); // expired fields gone (after their final tick)
```
with:
```dart
    _stepFields(events); // field ticks coat units in range (may react — next task)
    _fields.removeWhere((f) => f.timer <= 0); // expired fields gone (after their final tick)
```

Route hero autos through `_applyHit`. In the hero auto loop, replace:
```dart
      _applyDamage(e, tgt, kHeroAttackDamage, events);
```
with:
```dart
      _applyHit(e, tgt, kHeroAttackDamage, heroElement(e.id), events);
```

Add the status-expiry sweep just before the death sweeps. Insert before `_sweepDeadStructures(events);`:
```dart
    // Sweep expired statuses (a status expiring this tick already reacted above).
    for (final e in _entities) {
      if (e.statusTimer == 0 && e.statusElement != -1) e.statusElement = -1;
    }
```

- [ ] **Step 4: Run + re-pin combat.golden**

Run: `dart test packages/sim/test/reaction_test.dart`
Expected: PASS (the 6 new coating tests + the Task-4 placement tests).

Run: `dart test packages/sim`
Expected: the **combat.golden enforcement** test is unaffected (it's a tooling script, not a unit test), but the pinned in-test literal `0xa14ee38d` must still PASS (anchor is move-only). The unit suite is green.

Re-pin **only** `combat.golden` via the Re-Pin Procedure:
```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
# It prints "PASS: byte-identical ... <newhash>" then "FAIL: hash changed vs golden" — expected.
b64=$(base64 -w0 tooling/replay_fixtures/combat.json) \
  && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart \
     | awk '/^REPLAY_HASH /{print $2}' > tooling/replay_fixtures/combat.golden
```
Then verify:
Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json`
Expected: `PASS: byte-identical ...` then `PASS: matches golden ...`.
Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json`
Expected: `PASS: matches golden ...` (smoke is **unchanged** — do NOT re-pin it).
Run: `dart test packages/sim && dart test packages/netcode && dart test apps/server`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/reaction_test.dart \
        tooling/replay_fixtures/combat.golden
git commit -m "feat(sim): element-application chokepoint + field ticks + autos coat; re-pin combat (#2 coating)"
```

---

## Task 6: Vaporize reaction (consume + ×1.3 amplify + per-unit ICD + emit `ReactionTriggered`)

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/reaction_test.dart`

> **Golden-neutral for existing fixtures.** Replaces `_applyHit`'s coat body with the reaction-aware version. `combat.json` never produces a unit carrying element X that then receives Y≠X (each hero only ever coats with its own element), so `_applyHit` always takes the coat branch there → identical bytes to Task 5. `smoke.json`/anchor are move-only. **No re-pin.** The reaction is first exercised by `elemental.json` in Task 8. `reactionIcd` already decrements (added in Task 4), so only `_applyHit` changes here.

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/reaction_test.dart` (inside `main()`):
```dart
  test('a different element detonates Vaporize: amplified dmg, status consumed, event', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.pyro.index; // pre-Pyro
    h.statusTimer = 30;
    final hpBefore = h.hp;
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    final events = sim.step(0, const []);
    expect(h.hp.raw, (hpBefore - (kFieldDotDamage * kVaporizeMult)).raw); // 1.0 × 1.3
    expect(h.statusElement, -1); // consumed (no residual)
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.unitId, 1);
    expect(rt.reaction, Reaction.vaporize.index);
    expect(rt.multiplierRaw, kVaporizeMult.raw);
    expect(rt.sourceId, 0); // the field owner landed the triggering Hydro
    expect(h.reactionIcd, kReactionIcdTicks); // ICD stamped
  });

  test('the reaction ICD blocks a second Vaporize until it expires', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    // Overlap: a Pyro field AND a Hydro field on the hero (Pyro listed first).
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.pyro.index, timer: 10000));
    sim.fields.add(ElementalField(
        ownerId: 1, center: h.pos, element: Element.hydro.index, timer: 10000));
    var reactions = 0;
    for (var t = 0; t < kReactionIcdTicks; t++) {
      reactions += sim.step(t, const []).whereType<ReactionTriggered>().length;
    }
    expect(reactions, 1); // exactly one per ICD window, not one per tick
  });

  test('a status expiring this tick still reacts this tick, then is swept', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 1; // decrements to 0 BEFORE the field tick this tick
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    final events = sim.step(0, const []);
    expect(events.whereType<ReactionTriggered>(), isNotEmpty); // still reacted
    expect(h.statusElement, -1); // then consumed/swept
  });

  test('Vaporize on a creep: amplified via an auto, ZERO via a field tick', () {
    // (a) auto-triggered Vaporize on a creep deals real amplified damage.
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final creep = sim.entity(kCreepIdBase)..pos = FVec2(Fixed.fromInt(-8), Fixed.zero);
    creep.statusElement = Element.hydro.index;
    creep.statusTimer = 30;
    final hpBefore = creep.hp;
    final hero = sim.entity(0)..pos = creep.pos; // Cinderfang Pyro, adjacent
    hero.target = hero.pos;
    hero.attackTargetId = kCreepIdBase;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(kFirstWaveTick + 1, const []);
    expect(creep.hp.raw, (hpBefore - (kHeroAttackDamage * kVaporizeMult)).raw); // 8 × 1.3
    expect(creep.statusElement, -1);

    // (b) field-triggered Vaporize on a creep deals ZERO (coat-not-farm).
    final sim2 = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim2.step(t, const []);
    }
    final c2 = sim2.entity(kCreepIdBase)..pos = FVec2(Fixed.fromInt(-8), Fixed.zero);
    c2.statusElement = Element.pyro.index;
    c2.statusTimer = 30;
    final c2HpBefore = c2.hp.raw;
    sim2.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim2.entity(0).target = sim2.entity(0).pos;
    sim2.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.fromInt(2));
    sim2.entity(1).target = sim2.entity(1).pos;
    sim2.fields.add(ElementalField(
        ownerId: 1, center: c2.pos, element: Element.hydro.index, timer: 100));
    final events = sim2.step(kFirstWaveTick + 1, const []);
    expect(events.whereType<ReactionTriggered>(), isNotEmpty); // reaction fired
    expect(c2.hp.raw, c2HpBefore); // ZERO damage
    expect(c2.statusElement, -1); // status still consumed
  });

  test('two-sided: a hero in their own field overlap eats the Vaporize', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final cinder = sim.entity(0); // Pyro
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    cinder.pos = spot;
    cinder.target = spot;
    cinder.statusElement = Element.hydro.index; // Hydro-statused (e.g. from Marisol)
    cinder.statusTimer = 30;
    sim.fields.add(ElementalField(
        ownerId: 0, center: spot, element: Element.pyro.index, timer: 100)); // his own Pyro
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    final hpBefore = cinder.hp.raw;
    final events = sim.step(0, const []);
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.unitId, 0); // landed on Cinderfang himself
    expect(rt.sourceId, 0); // his own field
    expect(cinder.hp.raw, lessThan(hpBefore)); // self-damage
    expect(cinder.statusElement, -1);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/reaction_test.dart`
Expected: FAIL — `_applyHit` only coats, so a different element overwrites instead of reacting; no `ReactionTriggered`, no amplified damage.

- [ ] **Step 3: Implement the reaction branch**

In `packages/sim/lib/src/simulation.dart`, replace the **body** of `_applyHit` (the coat-only version from Task 5) with the reaction-aware version:
```dart
  void _applyHit(
      Entity source, Entity target, Fixed baseDamage, int element, List<SimEvent> events) {
    if (target.kind != EntityKind.hero && target.kind != EntityKind.creep) {
      if (baseDamage.raw > 0) _applyDamage(source, target, baseDamage, events);
      return;
    }
    Fixed dmg;
    if (target.statusElement != -1 &&
        target.statusElement != element &&
        target.reactionIcd == 0) {
      // Vaporize: amplify the TRIGGERING hit, consume the status, stamp the ICD.
      dmg = baseDamage * kVaporizeMult;
      target.statusElement = -1;
      target.statusTimer = 0;
      target.reactionIcd = kReactionIcdTicks;
      events.add(ReactionTriggered(
          unitId: target.id,
          reaction: Reaction.vaporize.index,
          multiplierRaw: kVaporizeMult.raw,
          sourceId: source.id));
    } else {
      // Coat (set/refresh). A different element suppressed by ICD overwrites here.
      target.statusElement = element;
      target.statusTimer = kStatusDurationTicks;
      dmg = baseDamage;
    }
    if (dmg.raw > 0) _applyDamage(source, target, dmg, events);
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/reaction_test.dart`
Expected: PASS (all reaction tests).

Run: `dart test packages/sim`
Expected: PASS — pinned `0xa14ee38d` unchanged.
Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json` then `... combat.json`
Expected: both `PASS: matches golden ...` (combat.json never reacts → unchanged; no re-pin).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/reaction_test.dart
git commit -m "feat(sim): Vaporize reaction (consume + x1.3 amplify + per-unit ICD + ReactionTriggered)"
```

---

## Task 7: TT2E + reactions/min telemetry harness

**Files:**
- Create: `packages/sim/test/telemetry_test.dart`

> **Golden-neutral** (reads `step()` events only; no sim change). Harness/log-only telemetry per spec §8 — TT2E (ticks to a hero's first landed reaction) and reactions-per-minute, computed from the `ReactionTriggered` stream of a scripted overlap. It is a *measurement*, not game state, so it stays out of canonical bytes. (The client-side debug overlay lands in Task 10.)

- [ ] **Step 1: Write the failing test**

Create `packages/sim/test/telemetry_test.dart`:
```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

/// A landed reaction with the tick it fired on (harness/log-only telemetry).
class _Sample {
  final int tick;
  final int unitId;
  const _Sample(this.tick, this.unitId);
}

void main() {
  test('TT2E + reactions/min are measurable from a scripted overlap', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Park both heroes on one tower-safe spot so their fields overlap there.
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    for (final id in [0, 1]) {
      sim.entity(id).pos = spot;
      sim.entity(id).target = spot;
    }
    // Cinderfang (0) drops Ember Field at t0; Marisol (1) drops Tidepool at t10
    // (aim y = 7*65536 = 458752) — the overlap (and first reaction) forms at t10.
    final casts = <int, List<Intent>>{
      0: const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1)],
      10: const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1)],
    };
    const totalTicks = 300; // 10s
    final samples = <_Sample>[];
    for (var t = 0; t < totalTicks; t++) {
      for (final e in sim.step(t, casts[t] ?? const <Intent>[])) {
        if (e is ReactionTriggered) samples.add(_Sample(t, e.unitId));
      }
    }
    expect(samples, isNotEmpty, reason: 'a Pyro+Hydro overlap must produce Vaporize');
    final tt2e = samples.first.tick; // ticks to the first landed reaction
    expect(tt2e, lessThanOrEqualTo(45), reason: 'second element within ~1.5s (spec §4.1 gate)');
    final perMin = samples.length * 1800 / totalTicks; // 30Hz → 1800 ticks/min
    expect(perMin, greaterThan(0));
    // Human-readable TT2E log (spec §8).
    // ignore: avoid_print
    print('TT2E=${tt2e}t  reactions=${samples.length}  reactions/min=${perMin.toStringAsFixed(1)}');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `dart test packages/sim/test/telemetry_test.dart`
Expected: PASS already if Tasks 4–6 are correct — but first run BEFORE writing the file (it doesn't exist) to confirm the TDD gate: `dart test packages/sim/test/telemetry_test.dart` → FAIL "Could not find ... telemetry_test.dart" / no tests. (If you wrote the file first, instead temporarily break the overlap, e.g. aim the Tidepool far away, to watch `samples` be empty and the `isNotEmpty` assertion FAIL, then restore.)

- [ ] **Step 3: (no implementation needed)**

The harness is a pure consumer of `step()` events — Tasks 4–6 already produce the reactions. This task is the **measurement**, not new sim behavior.

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/telemetry_test.dart`
Expected: PASS — prints e.g. `TT2E=10t  reactions=38  reactions/min=228.0`.
Run: `dart test packages/sim`
Expected: PASS (goldens untouched — no sim change).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/test/telemetry_test.dart
git commit -m "test(sim): TT2E + reactions/min telemetry harness from the ReactionTriggered stream"
```

---

## Task 8: `elemental.json` replay fixture + golden + CI wiring (cross-runtime determinism of the reaction path)

**Files:**
- Create: `tooling/replay_fixtures/elemental.json`
- Create: `tooling/replay_fixtures/elemental.golden`
- Create: `packages/sim/test/elemental_fixture_test.dart`
- Modify: `.github/workflows/sim-determinism.yml`

> **Determinism.** A fixture that drives both heroes from their spawns to a shared tower-safe spot `(0,7)`, then overlaps Ember Field (Pyro) + Tidepool (Hydro) → a **Vaporize fires at tick 60**, exercising `_applyHit`/`_stepFields`/the multiplier across native/dart2js/dart2wasm. The accompanying test guards that the fixture keeps exercising the reaction path. No existing golden moves.

- [ ] **Step 1: Create the fixture + the guard test**

Create `tooling/replay_fixtures/elemental.json` (type 1 = move, type 3 = ability; aimY 458752 = world 7.0; both converge tower-safe at (0,7), cast overlapping fields at t60):
```json
{
  "seed": 1337,
  "ticks": 120,
  "inputLog": {
    "0": [{"playerSlot":0,"type":1,"aimX":0,"aimY":458752,"seq":1,"clientTick":0},
          {"playerSlot":1,"type":1,"aimX":0,"aimY":458752,"seq":1,"clientTick":0}],
    "60":[{"playerSlot":0,"type":3,"aimX":0,"aimY":458752,"seq":2,"clientTick":60},
          {"playerSlot":1,"type":3,"aimX":0,"aimY":458752,"seq":2,"clientTick":60}]
  }
}
```

Create `packages/sim/test/elemental_fixture_test.dart` (replays the same intents inline and asserts the reaction path is exercised — keeps the golden meaningful):
```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('the elemental fixture scenario produces a Vaporize (golden covers reactions)', () {
    final sim = Simulation.create(const SimConfig(seed: 1337));
    const moveToSpot = [
      Intent(playerSlot: 0, type: IntentType.move, aimX: 0, aimY: 458752, seq: 1),
      Intent(playerSlot: 1, type: IntentType.move, aimX: 0, aimY: 458752, seq: 1),
    ];
    const cast = [
      Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 2),
      Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 2),
    ];
    var reactions = 0;
    for (var t = 0; t < 120; t++) {
      final intents = t == 0 ? moveToSpot : (t == 60 ? cast : const <Intent>[]);
      reactions += sim.step(t, intents).whereType<ReactionTriggered>().length;
    }
    expect(reactions, greaterThan(0)); // the overlap detonated Vaporize cross-runtime
  });
}
```

- [ ] **Step 2: Run the guard test (and prove determinism before pinning)**

Run: `dart test packages/sim/test/elemental_fixture_test.dart`
Expected: PASS (`reactions > 0`).

Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json`
Expected: `PASS: byte-identical across native/js/wasm: <hash>` (no golden yet → no golden-compare line). If it prints a DIVERGENCE, STOP and binary-diff `canonicalBytes()` per tick to find the non-deterministic field before pinning.

- [ ] **Step 3: Capture the golden**

```bash
b64=$(base64 -w0 tooling/replay_fixtures/elemental.json) \
  && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart \
     | awk '/^REPLAY_HASH /{print $2}' > tooling/replay_fixtures/elemental.golden
```

- [ ] **Step 4: Wire it into CI**

In `.github/workflows/sim-determinism.yml`, in the `replay-golden` job, add a line after the `combat.json` step:
```yaml
      - run: bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
      - run: bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
```

- [ ] **Step 5: Verify all green**

Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json`
Expected: `PASS: byte-identical ...` then `PASS: matches golden ...`.
Run: `dart test packages/sim`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add tooling/replay_fixtures/elemental.json tooling/replay_fixtures/elemental.golden \
        packages/sim/test/elemental_fixture_test.dart .github/workflows/sim-determinism.yml
git commit -m "ci(sim): elemental Vaporize replay golden across native/js/wasm"
```

---

## Task 9: Netcode surface — `RenderEntity.statusElement`, field zones, reaction drain, ability input

**Files:**
- Modify: `packages/netcode/lib/src/match_view.dart`
- Modify: `packages/netcode/lib/src/match_controller.dart`
- Modify: `packages/netcode/test/match_controller_test.dart`

> No protocol/codec change: `InputMsg.type` already serializes `IntentType.index`, so `ability` (index 3) rides the wire as-is. Render additions are non-breaking (new fields default `-1`/`const []`). Reactions are **drained separately** (not inside `update()`) because `view`/`update()` is called multiple times per frame (GuildGame + HudOverlay) — a side-effecting drain there would lose pop-texts.

- [ ] **Step 1: Write the failing tests**

Append to `packages/netcode/test/match_controller_test.dart` (inside `main()`; ensure the file imports `package:netcode/netcode.dart` and `package:sim/sim.dart`):
```dart
  test('applyAbilityInput emits an ability InputMsg carrying the aim point', () {
    final c = MatchController(seed: 1, localSlot: 1, startTick: 0);
    final msg = c.applyAbilityInput(196608, 458752);
    expect(msg.type, IntentType.ability.index);
    expect(msg.slot, 1);
    expect(msg.aimX, 196608);
    expect(msg.aimY, 458752);
  });

  test('a cast field appears in the render view; statusElement is exposed', () {
    final c = MatchController(seed: 1, localSlot: 1, startTick: 0);
    c.applyAbilityInput(0, 458752); // Marisol drops Tidepool at world (0,7)
    c.advanceClientTick();
    final v = c.update(0);
    expect(v.fields, isNotEmpty);
    expect(v.fields.first.ownerId, 1);
    expect(v.fields.first.element, Element.hydro.index);
    expect(v.local.statusElement, isA<int>()); // plumbed (−1 until coated)
  });

  test('drainReactions returns + clears (empty when nothing reacted)', () {
    final c = MatchController(seed: 1, localSlot: 0, startTick: 0);
    c.advanceClientTick();
    expect(c.drainReactions(), isEmpty);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/netcode/test/match_controller_test.dart`
Expected: FAIL — `applyAbilityInput`/`drainReactions` undefined; `MatchView` has no `fields`; `RenderEntity` has no `statusElement`.

- [ ] **Step 3: Implement the render-boundary additions**

Replace `packages/netcode/lib/src/match_view.dart` entirely:
```dart
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

  /// The opponent hero's render entity (interpolated). Always present.
  RenderEntity get opponent => entities.firstWhere((e) => e.id == 1 - localSlot);
}
```

In `packages/netcode/lib/src/match_controller.dart`:

(a) Add the reaction buffer next to the other fields (after `double _lastCorrectionDist = 0.0;`):
```dart
  final List<RenderReaction> _recentReactions = []; // collected each advanceClientTick
```

(b) Add `applyAbilityInput` after `applyAttackInput`:
```dart
  /// Record + apply a local ABILITY cast at world point (aimX,aimY) (Q16.16 raw);
  /// returns the InputMsg to send. Mirrors applyLocalInput with IntentType.ability.
  InputMsg applyAbilityInput(int aimX, int aimY) {
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
```

(c) Replace `advanceClientTick` to collect reactions, and add `drainReactions`:
```dart
  /// Advance the predicted sim one tick (host calls at 30Hz). Collects reactions
  /// fired this tick (forward prediction only — reconcile re-steps do NOT collect,
  /// so a predicted reaction surfaces exactly once).
  void advanceClientTick() {
    final held = _heldAt(_nextTick);
    final events = _predicted.step(_nextTick, held == null ? const [] : [held]);
    for (final e in events) {
      if (e is! ReactionTriggered) continue;
      final present = _predicted.entityIdsSorted.contains(e.unitId);
      final pos = present ? _predicted.entity(e.unitId).pos : null;
      _recentReactions.add(RenderReaction(
        x: pos?.x.toDouble() ?? 0,
        y: pos?.y.toDouble() ?? 0,
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
```

(d) In `update()`, pass `statusElement` on each entity and build the field list. Replace the `entities.add(RenderEntity(...))` call to include `statusElement: e.statusElement,`:
```dart
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
```
Then, just before `return MatchView(`, build the fields, and add `fields: fields,` to the constructor call:
```dart
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/netcode`
Expected: PASS (new tests + all existing — the render additions are non-breaking defaults).
Run: `dart test packages/protocol && dart test apps/server`
Expected: PASS (no protocol change).

- [ ] **Step 5: Commit**
```bash
git add packages/netcode/lib/src/match_view.dart packages/netcode/lib/src/match_controller.dart \
        packages/netcode/test/match_controller_test.dart
git commit -m "feat(netcode): surface element status + field zones + reactions; ability input passthrough"
```

---

## Task 10: Client render + input — element tint, field zones, VAPORIZE pop-text, left-click ability

**Files:**
- Create: `apps/client/lib/render/element_palette.dart`
- Create: `apps/client/lib/render/field_view.dart`
- Create: `apps/client/lib/render/reaction_label.dart`
- Create: `apps/client/test/element_palette_test.dart`
- Modify: `apps/client/lib/match/match_binding.dart`
- Modify: `apps/client/lib/render/entity_view.dart`
- Modify: `apps/client/lib/render/guild_game.dart`

> Client package is `guild_client`. Flame game rendering is verified by `flutter analyze` + compile; the one pure unit is `elementColor`. Uses `withValues`/`.a` (not the deprecated `withOpacity`/`.alpha`). Right-click stays move+attack (Plan-3 contract); **left-click = ability aim**.

- [ ] **Step 1: Write the failing test + the pure palette**

Create `apps/client/lib/render/element_palette.dart`:
```dart
import 'dart:ui';

import 'package:sim/sim.dart' show Element;

/// Element → display colour (spec §9 palette). Returns null for no status (-1)
/// or an element without a slice colour yet.
Color? elementColor(int element) {
  if (element == Element.pyro.index) return const Color(0xFFFF7043); // pyro orange
  if (element == Element.hydro.index) return const Color(0xFF26C6DA); // hydro teal
  return null;
}

/// Translucent fill for a field zone of [element].
Color fieldColor(int element) =>
    (elementColor(element) ?? const Color(0xFF9E9E9E)).withValues(alpha: 0.22);
```

Create `apps/client/test/element_palette_test.dart`:
```dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sim/sim.dart' show Element;
import 'package:guild_client/render/element_palette.dart';

void main() {
  test('elementColor maps Pyro/Hydro and returns null for none', () {
    expect(elementColor(Element.pyro.index), isA<Color>());
    expect(elementColor(Element.hydro.index), isA<Color>());
    expect(elementColor(-1), isNull);
  });

  test('fieldColor is translucent', () {
    expect(fieldColor(Element.pyro.index).a, closeTo(0.22, 0.01));
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd apps/client && flutter test test/element_palette_test.dart`
Expected: FAIL — "Target of URI doesn't exist: '.../element_palette.dart'" until Step 1's lib file exists; once it does, the test PASSES (this is a pure mapping). If you created the lib file in Step 1, this test passes immediately — that's fine; it gates the remaining render wiring below.

- [ ] **Step 3: Build the field zone + pop-text components**

Create `apps/client/lib/render/field_view.dart`:
```dart
import 'dart:ui';

import 'package:flame/components.dart';

import 'coord.dart';
import 'element_palette.dart';

/// A translucent element-tinted field zone (Plan 4). Purely cosmetic; position
/// is set each frame by GuildGame (the field is stationary in the sim).
class FieldView extends PositionComponent {
  FieldView({required this.element, required double radius})
      : _r = radius * kPixelsPerUnit,
        super(anchor: Anchor.center);

  final int element; // Element.index
  final double _r;

  @override
  Future<void> onLoad() async {
    await add(CircleComponent(
      radius: _r,
      anchor: Anchor.center,
      paint: Paint()..color = fieldColor(element),
    ));
    await add(CircleComponent(
      radius: _r,
      anchor: Anchor.center,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = elementColor(element) ?? const Color(0xFF9E9E9E),
    ));
  }
}
```

Create `apps/client/lib/render/reaction_label.dart`:
```dart
import 'dart:ui';

import 'package:flame/components.dart';

/// A transient floating reaction pop-text (Plan 4). Rises, then self-removes.
class ReactionLabel extends TextComponent {
  ReactionLabel({required super.text, required Vector2 position})
      : super(
          position: position,
          anchor: Anchor.center,
          textRenderer: TextPaint(
            style: const TextStyle(
              color: Color(0xFFFFE082),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        );

  double _age = 0;
  static const double _life = 0.8;

  @override
  void update(double dt) {
    super.update(dt);
    _age += dt;
    position.y -= 24 * dt; // rise
    if (_age >= _life) removeFromParent();
  }
}
```

- [ ] **Step 4: Wire the binding + entity tint + game**

In `apps/client/lib/match/match_binding.dart`, add after `submitAttack`:
```dart
  /// Local input: left-click a world point (Q16.16 raw) -> ability cast. Predict + send.
  void submitAbility(int aimXRaw, int aimYRaw) {
    if (_ended) return; // no input after the match ends
    final c = _controller;
    if (c == null) return;
    _transport.send(ProtocolCodec.encode(c.applyAbilityInput(aimXRaw, aimYRaw)));
  }

  /// Reactions that fired since the last frame (host spawns pop-text once/frame).
  List<RenderReaction> drainReactions() => _controller?.drainReactions() ?? const [];
```

In `apps/client/lib/render/entity_view.dart`, add the element-tint ring. Add the import:
```dart
import 'element_palette.dart';
```
Add the field + ring member (near `double hpRatio = 1.0;`):
```dart
  /// Elemental status (Element.index, -1 = none); set from MatchView each frame.
  int statusElement = -1;
  CircleComponent? _statusRing;
```
In `onLoad`, after the `isLocal` ring block (before the health-bar block), add:
```dart
    // Elemental-status ring (Plan 4): colour set each frame from statusElement.
    _statusRing = CircleComponent(
      radius: size.x / 2 + 4,
      anchor: Anchor.center,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x00000000), // transparent until coated
    );
    await add(_statusRing!);
```
In `update`, after the health-bar line, add:
```dart
    final ring = _statusRing;
    if (ring != null) {
      ring.paint.color = elementColor(statusElement) ?? const Color(0x00000000);
    }
```

In `apps/client/lib/render/guild_game.dart`:

(a) Widen the netcode import and add the new component imports:
```dart
import 'package:netcode/netcode.dart' show MatchView, RenderEntity, RenderField, RenderReaction;
```
```dart
import 'field_view.dart';
import 'reaction_label.dart';
```

(b) Add `TapCallbacks` to the mixins and a field-view map:
```dart
class GuildGame extends FlameGame with SecondaryTapCallbacks, TapCallbacks {
```
```dart
  final Map<int, FieldView> _fieldViews = {}; // keyed by field ownerId
```

(c) In `update`, after the entity diff (after the `gone`/despawn block), feed `statusElement`, diff field zones, and spawn reaction labels. Insert before the closing brace of `update`:
```dart
    // Feed elemental status to each entity view (discrete; never interpolated).
    for (final re in v.entities) {
      _views[re.id]?.statusElement = re.statusElement;
    }
    // Diff field zones (keyed by ownerId).
    final seenFields = <int>{};
    for (final rf in v.fields) {
      seenFields.add(rf.ownerId);
      var fv = _fieldViews[rf.ownerId];
      if (fv == null || fv.element != rf.element) {
        fv?.removeFromParent();
        fv = FieldView(element: rf.element, radius: rf.radius);
        _fieldViews[rf.ownerId] = fv;
        world.add(fv);
      }
      fv.position.setValues(worldToFlameX(rf.x), worldToFlameY(rf.y));
    }
    for (final id in _fieldViews.keys.where((id) => !seenFields.contains(id)).toList()) {
      _fieldViews.remove(id)?.removeFromParent();
    }
    // Spawn a pop-text per reaction that fired this frame.
    for (final r in binding.drainReactions()) {
      final mult = r.multiplierRaw / 65536.0;
      world.add(ReactionLabel(
        text: 'VAPORIZE x${mult.toStringAsFixed(1)}',
        position: Vector2(worldToFlameX(r.x), worldToFlameY(r.y)),
      ));
    }
```

(d) Add the left-click handler (right-click stays as-is):
```dart
  /// Left-click = ability aim: cast the hero's field at the clicked world point.
  @override
  void onTapUp(TapUpEvent event) {
    final worldPos = camera.globalToLocal(event.canvasPosition);
    binding.submitAbility(
        worldToRaw(flameToWorld(worldPos.x)), worldToRaw(flameToWorld(worldPos.y)));
  }
```

- [ ] **Step 5: Run analyze + tests**

Run: `cd apps/client && flutter pub get && flutter analyze && flutter test`
Expected: analyze clean (no deprecation/warnings); `element_palette_test` PASSES; existing client tests PASS.

- [ ] **Step 6: Commit**
```bash
git add apps/client/lib/render/element_palette.dart apps/client/lib/render/field_view.dart \
        apps/client/lib/render/reaction_label.dart apps/client/test/element_palette_test.dart \
        apps/client/lib/match/match_binding.dart apps/client/lib/render/entity_view.dart \
        apps/client/lib/render/guild_game.dart
git commit -m "feat(client): element tint + field zones + VAPORIZE pop-text + left-click ability cast"
```

---

## Task 11: Whole-branch verification + finishing

**Files:** none (verification + integration).

> Final green-everything gate, whole-branch review, then branch completion. No new code unless the review surfaces a fix (each fix follows TDD + the re-pin rules if it touches `canonicalBytes`).

- [ ] **Step 1: Full determinism + test sweep**

Run each and confirm PASS:
```bash
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
dart test packages/sim
dart test packages/protocol
dart test packages/netcode
dart test apps/server
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json
( cd apps/client && flutter analyze && flutter test )
```
Expected: every command exits 0; each `compare_replays.sh` prints `PASS: byte-identical ...` then `PASS: matches golden ...`.

- [ ] **Step 2: Cross-runtime sim tests (mirror CI)**

```bash
dart test packages/sim -p node
dart test packages/sim -p node -c dart2wasm
dart test packages/netcode -p node
dart test packages/netcode -p node -c dart2wasm
```
Expected: PASS on both node (dart2js) and dart2wasm — proves the reaction/field math is bit-identical off-native.

- [ ] **Step 3: Whole-branch review**

Use **superpowers:requesting-code-review** for the whole branch (`main..plan-4-elemental`). Focus the reviewer on: the determinism contract (no `dart:math`, `lengthSq`-only membership, no new RNG, ascending-id iteration), the four byte-site lockstep + version bumps, the two-sided/creep-DoT-zero rules, and the off-wire reaction surfacing. Address findings via **superpowers:receiving-code-review** (verify before implementing); any fix touching `canonicalBytes` re-pins per the Re-Pin Procedure.

- [ ] **Step 4: Finish the branch**

Use **superpowers:finishing-a-development-branch** to present merge/PR/cleanup options. Do not merge to `main` without the user's choice.

---

## Plan Self-Review (author check — completed)

- **Spec coverage:** §2 decisions → Tasks 1–10 (status T1/T3; fields T2/T4; Vaporize T6; autos-coat T5; ×1.3 cap T6/T2; heroes+creeps + creep-DoT-zero T5/T6; TT2E T7; Ember Field/Tidepool roster T2/T4; off-wire VFX T9/T10; re-pin T3/T5; elemental golden T8). §6 tick order → T4/T5/T6. §9 determinism/re-pin → T3/T5/T8/T11. §10 client → T10. All spec sections map to a task.
- **Placeholder scan:** no TBD/TODO/"handle edge cases"; every code step shows complete code; re-pin steps cite the procedure + exact literal locations (new hash values are *read from output*, never guessed — correct for a plan).
- **Type consistency (checked across tasks):** `statusElement`/`statusTimer`/`reactionIcd`/`abilityCooldown` (Entity, T1) used identically in serialization (T3) and logic (T4–T6); `ElementalField{ownerId,center,element,timer}` (T2) matches `_fields` serialization (T3) and `_stepFields` (T5) and `RenderField` (T9); `_applyHit(source,target,baseDamage,element,events)` signature identical in T5 (coat) and T6 (reaction) and its call sites (autos T5, fields T5); `ReactionTriggered{unitId,reaction,multiplierRaw,sourceId}` (T1) matches emission (T6) and `RenderReaction`/drain (T9) and pop-text (T10); `heroElement`/`heroPlacesAtSelf`/`kVaporizeMult`/`kFieldRadiusSq`/`kFieldDotDamage`/`kStatusDurationTicks`/`kReactionIcdTicks`/`kFieldDurationTicks`/`kAbilityCooldownTicks` (T2) used consistently downstream; `IntentType.ability` (T2) used in placement (T4), netcode (T9), client (T10); `RenderField`/`RenderReaction` (T9) consumed in T10.
- **Golden bookkeeping:** T3 re-pins smoke+combat+2 literals (layout); T5 re-pins combat **only** (autos coat); T8 adds elemental.golden (new); T6/T4/T7 golden-neutral — explicitly justified in each task. The combat-free in-test anchor (`0xa14ee38d`) moves **only** at T3.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-07-plan-4-elemental.md`. Per the requested workflow, this will be executed **subagent-driven** (superpowers:subagent-driven-development): a fresh implementer per task, then a two-stage review (spec-compliance, then code-quality) with fix loops, then a final whole-branch review, then finishing-a-development-branch.
