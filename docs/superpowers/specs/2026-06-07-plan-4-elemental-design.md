# Guild — Plan 4: Elemental (Vaporize Vertical Slice) Design Spec

> **Status:** Locked design from the 2026-06-07 brainstorm. This is the slice where the core loop becomes *fun*: the first neutral, two-sided elemental reaction (**Vaporize**), sourced from the two heroes' own overlapping fields. It builds directly on Plan 3's `_applyDamage` chokepoint, the declared `ReactionTriggered` event, and neutral team 2. Parent design: `docs/superpowers/specs/2026-06-06-elemental-moba-design.md` (§3 reactions, §4 sourcing, §5 kits, §11 Milestone-0 gate 4). Predecessor plan: `docs/superpowers/plans/2026-06-07-plan-3-combat.md`.

This spec is the input to `superpowers:writing-plans`. It fixes **what** the slice is and **why**; the plan fixes the task-by-task **how**.

---

## 1. Goal

Prove Milestone-0's second risky pillar — *one neutral, two-sided elemental reaction, sourced from the two heroes' own overlapping fields* — on top of the proven deterministic combat sim. Concretely: a hero coats a unit in their element (autos + a placed field), a **different** element detonates **Vaporize** on whoever carries the status (enemy, creep, **or self**), and we can **measure** that this happens often enough and fast enough (TT2E) to make lane combat interesting — all while staying byte-identical across native / dart2js / dart2wasm.

If two mono-element heroes' own fields can reliably produce satisfying reactions, the core-depth thesis holds and the remaining 6 reactions + 8 heroes are additive data. If not, we learn it cheaply here (only Vaporize + 2 kits built).

---

## 2. Locked Scope (from the brainstorm)

### 2.1 Decisions ruled this session

| Axis | Decision |
|---|---|
| **Reactions** | **Vaporize only** (Pyro ⊕ Hydro). The two-hero pairing can produce no other. |
| **Elemental status** | **≤1 per unit, serialized on `Entity`** (`statusElement` + `statusTimer`). Not a transient map — a status that vanishes on reconcile would let the client fail to reproduce a Vaporize (violates parent §8.3). |
| **Fields** | **Stationary serialized struct-list** on `Simulation`: `[{ownerId, center, element, timer}]`. Placed at cast position; membership by `lengthSq`. No new `EntityKind`. |
| **Hero kits** | **Autos apply LIGHT element + one left-click field ability each.** Ults, Ember Hook, Maelstrom, all displacement → deferred. |
| **Vaporize multiplier** | **Single ×1.3 field-cap** constant. The ×1.3-field / ×2.0-hero provenance split is deferred. |
| **TT2E telemetry** | **Harness / log-only** measurement, computed from `ReactionTriggered` timings. Not in canonical bytes. |
| **Cinderfang's field** | **Ember Field** — a stationary Pyro zone placed at his own cast position (melee igniting the ground around himself). Explicit slice stand-in for his eventual Ember Hook / Pyre Unchained kit. |
| **Vaporize damage source** | **Fields tick a small DoT AND autos apply element**; either can trigger an amplified Vaporize. Reaction ICD caps overlap farm. |
| **Elemental scope** | **Heroes + creeps** carry status and can react. Towers, cores, and the wanderer are exempt. **Field DoT does real damage to heroes but ZERO to creeps** (fields coat creeps but never farm them — parent §6 "not a free CS engine"); only hero **autos** last-hit creeps for gold, so Plan-3's economy is untouched. |

### 2.2 IN (this slice)

- `enum Element { pyro, hydro }`, `enum Reaction { vaporize }` — append-only, index serialized.
- Per-unit elemental **status** (element + countdown timer), applied to heroes **and** creeps, serialized.
- A **reaction internal-cooldown** (ICD, per unit) so an overlap can't machine-gun reactions (keeps reactions-per-minute measurable).
- **Vaporize** wrapped around `_applyDamage`: consume the differing status, amplify the triggering hit ×1.3, emit `ReactionTriggered`.
- **Two-sided rule**: the reaction lands on whoever *carries* the status — attacker, victim, creep, or self.
- **Stationary neutral fields** (Cinderfang **Ember Field** / Marisol **Tidepool**): coat any hero/creep inside each tick (2-sided), tick a small DoT to heroes (zero to creeps).
- A **left-click `IntentType.ability`** that places the hero's field at an aim point, with an ability cooldown.
- **Autos apply LIGHT element** to their target (the path that lets you land a reaction on the enemy: coat them, then their own field / your other element detonates it).
- **Serialization**: new per-entity fields + the field block → bump `kSchemaVersion`/`kSnapshotVersion` 2→3, re-pin all four goldens.
- **Client**: element tint on statused units, translucent field zones, "VAPORIZE ×1.3" pop text from the locally re-stepped `ReactionTriggered`, left-click ability input.
- **TT2E + reactions-per-minute** measured in a test harness / debug overlay.
- A new `elemental.json` replay fixture that *exercises* a Vaporize, pinned cross-runtime in CI.

### 2.3 OUT (deferred — leave only the noted inert hooks)

- All other reactions (Melt, Overload, Electro-Charged, Frozen, Superconduct, Swirl) and the reaction matrix table.
- LIGHT vs **STRONG** ×1.5 potency; the ×1.3-field / ×2.0-hero **provenance split** (store neither `strength` nor provenance this slice).
- Reaction **cascades**, Swirl spread, per-reaction-type ICD maps (single per-unit ICD suffices for one reaction).
- **Ultimates** and the deferred ability mechanics: Ember Hook (skillshot yank), Pyre Unchained, Maelstrom (channel), all knockback/pull/displacement, Tidepool's **25% slow** (slows pull in the shared-slow-bucket §3.5 — out).
- **Persistent detached field trails** outliving the owner (a hero's field clears on respawn).
- Elemental **creeps / element-steal / Anemo displacement** (the post-slice second-element sources), the **revenge boss** (`BossSpawned` stays declared-only), **XP / levels** (`LevelUp` stays declared-only), item shop, bounties.
- Elemental interactions on **towers / cores** and any element on the **wanderer**.
- Putting any `SimEvent` (incl. `ReactionTriggered`) **on the wire** — the client re-steps the deterministic sim and emits events locally, exactly as Plan 3 established.

---

## 3. Inherited Hooks (verified against source at `fefce07`)

| Hook | Location | How Plan 4 uses it |
|---|---|---|
| `_applyDamage(source, target, amount, events) -> bool` | `packages/sim/lib/src/simulation.dart:343` | Stays the pure damage chokepoint (clamp + `DamageDealt` + `_lastDamager` + lethal bool). A new `_applyHit` wrapper computes element + reaction, then calls it. **Signature unchanged.** |
| `ReactionTriggered{unitId, reaction}` | `packages/sim/lib/src/events.dart:49` | Widened to carry `multiplierRaw` + `sourceId`; emitted from `_applyHit`. Cosmetic, off-wire. |
| `step()` 5-phase pipeline | `simulation.dart:87` | Reaction logic slots **inside** the combat phase (4), before the phase-5 wanderer RNG draw. Phase order is load-bearing — not reordered. |
| `Fixed *` (limb-split), `FVec2.lengthSq()` | `math/fixed.dart:37`, `math/fvec2.dart:15` | Multiplier (`base × ×1.3`) and field-radius membership (`lengthSq ≤ rSq`). No new math; **no `sqrt` / `dart:math`**. |
| `canonicalBytes` / `snapshotBytes` / `restoreFromSnapshot` / `peekEntityPos` | `simulation.dart:355 / 391 / 425 / 490` | Per-entity status/ability fields land after `attackTargetId` (4 sites in lockstep). The field block is appended **after** the entity loop, so `peekEntityPos` (which returns within/after the entity loop) needs only the 4 per-entity skips, not the block. |
| `EntityKind` / `IntentType` append-only | `model/entity.dart`, `model/intent.dart:1` | `IntentType.ability` appended (index 3). No new `EntityKind` (fields are not entities). |
| Combat-free determinism anchor | `simulation_test.dart`, `snapshot_test.dart` (pin `0xa14ee38d`) | Move-only intents → no casts/autos → empty field block + none statuses, so it is **automatically reaction-free** and stays valid. The layout change still moves the hash → re-pin once. |
| Render path | `netcode/.../match_view.dart`, `match_controller.dart`; `apps/client/.../entity_view.dart`, `guild_game.dart` | Add `statusElement` to `RenderEntity` (tint), a `fields` list to `MatchView` (zones), and surface local-step `ReactionTriggered` (pop text). |

---

## 4. Data Model

### 4.1 Enums (append-only; index is serialized)

```
enum Element { pyro, hydro }        // Electro/Cryo/Anemo append later
enum Reaction { vaporize }          // other reactions append later
```

### 4.2 Per-entity status state (new `Entity` fields, serialized uniformly)

Four new countdown/int fields, defaulting to "none/ready", serialized for **every** entity (uniform, matching how `gold`/`attackCooldown` already serialize on entities that don't use them):

| Field | Type | Meaning |
|---|---|---|
| `statusElement` | `int` | `-1` = no status; else `Element.index`. |
| `statusTimer` | `int` | Ticks of status remaining; at `0`, `statusElement` resets to `-1`. |
| `reactionIcd` | `int` | Ticks until this unit may react again (`0` = ready). ~0.5 s = 15 t. |
| `abilityCooldown` | `int` | Ticks until the hero's field ability is ready (`0` = ready). |

Only **heroes and creeps** ever receive a status; structures/wanderer keep the defaults. Application is gated by kind, not by which entities carry the fields.

### 4.3 Fields (serialized struct-list on `Simulation`, appended after the entity loop)

```
class ElementalField {            // NOT an Entity
  int ownerId;                    // the hero who cast it (for DamageDealt.sourceId)
  FVec2 center;                   // cast position; STATIONARY
  int element;                    // Element.index
  int timer;                      // ticks remaining; removed at 0
}
List<ElementalField> _fields;     // tiny: ≤1 active per hero (CD-gated)
```

Byte layout (both `canonicalBytes` and `snapshotBytes`, after the entity loop): `fieldCount (i32)` then per field `ownerId (i32), center.x (fixed), center.y (fixed), element (i32), timer (i32)`. Deterministic order: append on cast (cast order is the canonical intent order); expiry removal preserves order.

### 4.4 Widened event (cosmetic, off-wire)

```
class ReactionTriggered extends SimEvent {
  int unitId;        // who carried the consumed status (the reaction lands here)
  int reaction;      // Reaction.index
  int multiplierRaw; // Q16.16 raw of the applied multiplier (e.g. ×1.3) — for pop text
  int sourceId;      // who landed the triggering hit
}
```

---

## 5. The Reaction Engine

### 5.1 Element-application chokepoint (`_applyHit`)

A single function unifies element application, the reaction check, and damage. Autos and field-ticks call it; towers keep calling `_applyDamage` directly (non-elemental).

```
_applyHit(source, target, baseDamage, element, events):
  if target is not hero/creep:                      # structures/wanderer
      _applyDamage(source, target, baseDamage, events); return
  if target.statusElement != -1
     and target.statusElement != element            # DIFFERENT element present
     and target.reactionIcd == 0:                    # not on ICD
      # ---- Vaporize ----
      damage = baseDamage * kVaporizeMult            # ×1.3, Fixed
      target.statusElement = -1                      # consume the status
      target.statusTimer   = 0
      target.reactionIcd   = kReactionIcdTicks
      events.add(ReactionTriggered(unitId: target.id, reaction: vaporize,
                                   multiplierRaw: kVaporizeMult.raw, sourceId: source.id))
      _applyDamage(source, target, damage, events)
  else:
      # ---- coat (set or refresh) ----
      target.statusElement = element
      target.statusTimer   = kStatusDurationTicks    # refresh on same-element too
      _applyDamage(source, target, baseDamage, events)
```

Notes:
- **Two-sided** falls out for free: the reaction consumes/lands on `target`, whoever that is (enemy hero, the caster standing in their own field, or a creep).
- **Same-element** application refreshes the timer and deals base damage; never stacks (no STRONG this slice).
- **ICD-suppressed application coats.** A *different* element that arrives while `reactionIcd > 0` falls to the `else` branch: it overwrites the status (set to the new element, fresh timer) and deals base damage but does **not** react. Net effect: an overlap yields exactly one Vaporize per ICD window. This edge is pinned by a test (either-overwrite-or-react is a determinism-relevant fork — the choice is overwrite).
- **Vaporize amplifies the triggering hit.** A field-tick on a creep has `baseDamage = 0` (§2.1) → `0 × 1.3 = 0`, so field overlaps coat creeps and pop "VAPORIZE" VFX but never farm them; a hero **auto** triggering Vaporize on a creep deals real `auto × 1.3` and may legitimately last-hit (auto last-hit → gold, unchanged).
- `baseDamage` for a pure-coat field tick on a **hero** is the small field DoT (`kFieldDotDamage`); on a **creep** it is `Fixed.zero`.

### 5.2 Magnitude budget

`kVaporizeMult = Fixed.fromNum(1.3)`. Worst-case triggering damage is a hero auto (`kHeroAttackDamage`, currently 8) or a tower (non-elemental, never routed here). `8 × 1.3 = 10.4 < 32768`; asserted in the elemental-constants test. No multiplier may push `maxRoutedDamage × mult` past the `Fixed` budget.

### 5.3 Fields each tick

For each `ElementalField` (in list order), for each **hero/creep** whose `(unit.pos - field.center).lengthSq() <= kFieldRadiusSq` (iterated by `entityIdsSorted`): `_applyHit(owner, unit, dot, field.element, events)` where `dot = kFieldDotDamage` for heroes, `Fixed.zero` for creeps. The field is 2-sided — its owner is not exempt.

### 5.4 Placing a field (ability cast)

A left-click `IntentType.ability` (carrying `aimX/aimY` as **Q16.16 world coordinates** like `move` — *not* an entity id as `attack` does) from a hero with `abilityCooldown == 0`:
- **Marisol (Tidepool):** place the Hydro field at the **aim point** (ranged).
- **Cinderfang (Ember Field):** place the Pyro field at **his own position** (melee; aim ignored or clamped to a short leash).
- Set `abilityCooldown = kAbilityCooldownTicks`; push the field with `timer = kFieldDurationTicks`.

(Which hero is which is data: a per-hero element + a placement mode. The two heroes are the only ability-casters this slice.)

### 5.5 Respawn / despawn cleanup

On hero respawn, clear `statusElement/statusTimer/reactionIcd` (mirroring how `respawnTimer`/`attackCooldown` reset; gold deliberately persists, status does not) and **remove that hero's field** from `_fields`. Creep despawn removes the creep (status goes with it). `_removeEntity` already clears `_lastDamager`; no field is owned by a creep.

---

## 6. Per-Tick Order (determinism)

Reaction work slots inside the existing combat phase (4), preserving the load-bearing phase order and the phase-5 RNG gate. Within phase 4, the order obeys parent §3.1 (*fields → autos → ascending entityId*):

1. Respawn timers (existing).
2. **Decrement** `attackCooldown`, `abilityCooldown`, `statusTimer`, `reactionIcd` (all toward 0).
3. **Place fields** from `ability` intents (deterministic intent order).
4. **Field ticks** — coat (and DoT heroes) for every unit in every field, `entityIdsSorted`.
5. **Hero autos** (existing loop, now routed through `_applyHit` with the hero's element).
6. **Tower attacks** (existing, non-elemental → `_applyDamage`).
7. **Sweep expired statuses** — any `statusTimer == 0` → `statusElement = -1`. (A status expiring *this* tick already reacted in steps 4–5 while still present, then is swept — pinned by a test, per the brief's one-tick-slip warning.)
8. **Sweep expired fields** — `timer == 0` removed.
9. Death sweeps (structures / heroes / creeps), existing.

Phase 5 (wanderer RNG) is unchanged and still fires every tick. **No new RNG draw anywhere** — reactions are fully deterministic from state + tick.

---

## 7. Hero Kits (slice)

Both kits are pure data (element + placement mode + tunables). Autos are the existing Plan-3 locked-target autos, now applying the hero's element.

| Hero | Element | Auto (existing + element) | Field ability (left-click) |
|---|---|---|---|
| **Cinderfang** (melee) | Pyro | Locked-target melee swing → `_applyHit(..., pyro)` | **Ember Field**: stationary Pyro zone at **his own** position; coats + small DoT (heroes), 2-sided. |
| **Marisol** (ranged) | Hydro | Locked-target ranged hit → `_applyHit(..., hydro)` | **Tidepool**: stationary Hydro zone at the **aim point**; coats + small DoT (heroes), 2-sided. Spec's 25% slow deferred. |

**The core reaction loop the slice proves:**
- *Land it on the enemy:* coat Marisol with Pyro (Cinderfang's Ember Field / Pyro auto), then her own Tidepool's Hydro detonates **Vaporize on her** — or Cinderfang's Pyro auto detonates her self-applied Hydro.
- *Backfire (2-sided):* Cinderfang lingers in his own Ember Field (Pyro) while Marisol's Hydro lands → **Vaporize on Cinderfang**.
- *Overlap:* Ember Field ∩ Tidepool — any hero/creep inside gets both elements; whoever's there eats it.

All tunables (radius, durations, DoT, multiplier, ICD, cooldowns) are **playtest placeholders** (parent §13 defers exact numbers); the constants live in a new `packages/sim/lib/src/data/elements.dart` and obey the `Fixed` budget.

---

## 8. Telemetry (TT2E + reactions/min)

Harness/log-only, never in canonical bytes:
- A test harness replays a scripted lane fight and, from the stream of `ReactionTriggered` (+ a hero's first reaction after spawn), computes **TT2E** (ticks from "able to seek a 2nd element" to a landed reaction) and **reactions-per-minute**.
- A debug overlay in the client (computed from the local predicted step's events) shows a running reactions/min counter.
- Acceptance check (parent §4.1 hard gate, validated by hand at slice end, not auto-enforced): in a typical trade a hero can get a reaction-valid second element onto a target within ≤ 1.5 s in > 80 % of trades. If the slice misses this badly, the core loop needs rework — the cheap learning Milestone-0 exists to surface.

Promote TT2E to a serialized `MatchView` field only if a later design needs players to see it.

---

## 9. Determinism & Re-Pin (the single biggest mechanical cost)

- New per-entity status/ability fields + the field block change `canonicalBytes` → **bump `kSchemaVersion` and `kSnapshotVersion` 2→3**.
- Edit the **four** byte sites in lockstep: `canonicalBytes` (write), `snapshotBytes` (write), `restoreFromSnapshot` (read), `peekEntityPos` (per-entity skips only; the trailing field block is past where peek returns). Field block: written in both writers, read in restore.
- **Re-pin all four goldens in one commit** via the Plan-3 Re-Pin Procedure (`tooling/compare_replays.sh`, then capture): the `0xa14ee38d` literal in **both** `simulation_test.dart` and `snapshot_test.dart`, plus `smoke.golden` and `combat.golden`.
- The combat-free anchor stays **reaction-free** automatically (move-only → empty fields, none statuses) — so it remains the determinism anchor; later reaction-behavior tasks don't disturb it.
- Add a new **`tooling/replay_fixtures/elemental.json`** that scripts both heroes casting fields + autos to land a Vaporize, byte-identical across native/dart2js/dart2wasm, pinned as `elemental.golden` and wired into `.github/workflows/sim-determinism.yml`.

### Determinism landmines (and the rule that defuses each)

- **Multiplier overflow** → multipliers are `Fixed` consts; assert `maxRoutedDamage × mult < 32768` in the constants test.
- **`lengthSq` only** → field membership compares against precomputed `kFieldRadiusSq`; never `length()`/`sqrt`/`dart:math` (banned-imports gate enforces).
- **No new RNG** → reactions read only state + tick; the sole RNG draw stays the phase-5 wanderer.
- **Status-expiry vs reaction timing** → decrement (step 2) → react while present (4–5) → sweep expired (7); pin with a test.
- **Iteration order** → all status/field/reaction loops iterate `entityIdsSorted` (or stable field-list order), never a `Set`/hash map.
- **Serialization lockstep** → the four sites + both versions + four goldens move together in one commit.
- **Append-only** → `Element`/`Reaction`/`IntentType` indices never reorder; no new `EntityKind`.
- **Respawn cleanup** → status/field cleared explicitly on respawn (gold persists, status must not).

---

## 10. Client / VFX

- `RenderEntity` gains `statusElement` (int, `-1` default); `EntityView._color()` adds one branch tinting a statused unit toward its element colour (Pyro orange, Hydro teal). Discrete field — never interpolated.
- `MatchView` gains a `fields` list (`{center, element, radius}`); `GuildGame` draws translucent element-coloured circles.
- `MatchController.update()` collects `ReactionTriggered` from the **local predicted** `step()` and surfaces recent reactions; `GuildGame` spawns a floating "VAPORIZE ×1.3" label at the unit. Off-wire; 1–2 frames of self-correction on the rare mispredict is acceptable (parent §8.3).
- Input: left-click → `MatchBinding.submitAbility(aimX, aimY)` → `IntentType.ability`. Right-click stays move+attack (Plan-3 controls contract honored).

---

## 11. Planned Task Shape (for `writing-plans`)

Indicative decomposition; each task is independently shippable/green and obeys the determinism contract. Golden-touching tasks are flagged.

1. `Element`/`Reaction` enums + per-entity status/ability fields + widened `ReactionTriggered` + `data/elements.dart` constants (golden-neutral: not serialized yet).
2. `IntentType.ability` + field model (`ElementalField`, `_fields`) + field placement & expiry (no reactions yet).
3. **Serialize** status/ability fields + field block; bump versions; **re-pin goldens** (#1). *(determinism)*
4. `_applyHit` element-application chokepoint: field ticks coat heroes+creeps, autos coat, status set/refresh, expiry sweep (no reaction yet).
5. **Vaporize**: consume differing status, ×1.3 amplify, reaction ICD, emit `ReactionTriggered`; two-sided + creep-DoT-zero rules; pin the expiry-vs-react one-tick test.
6. TT2E + reactions/min harness instrumentation.
7. **`elemental.json`** fixture + golden + CI wiring. *(determinism)*
8. Protocol/netcode: surface `fields` + `statusElement` + reaction events to `MatchView`/`RenderEntity`.
9. Client: field zones, element tint, VAPORIZE pop text, left-click ability input.
10. Whole-branch review + `finishing-a-development-branch`.

---

## 12. Risks

1. **Re-pin churn** — the serialized status/field layout moves the goldens; mitigated by the Plan-3 Re-Pin Procedure and the reaction-free anchor (one re-pin, isolated to its task).
2. **Reactions too rare or too spammy** — TT2E + reactions/min instrumentation and the per-unit ICD are the tuning levers; numbers are playtest placeholders by design.
3. **Field-CS-farming** — defused by field DoT = 0 on creeps (only autos last-hit); keeps Plan-3 economy intact.
4. **Determinism drift from reaction math** — `Fixed`-only multiply, `lengthSq` membership, no new RNG, ascending-id iteration; the `elemental.json` cross-runtime golden is the hard gate.
5. **Two-sided confusion in UX** — element tint + clear "VAPORIZE" pop text on the unit that ate it make the 2-sided outcome legible (the slice's legibility test).
