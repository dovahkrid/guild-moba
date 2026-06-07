# Guild — Plan 5: Elemental Damage Model v2 (aura-coat + reactions, no field DoT) — Design Spec

**Status:** approved 2026-06-07. Branch `plan-5-elemental-v2` off `main` (`374e3da`).
**Relationship to Plan 4:** Plan 4 (the Vaporize slice) stays merged. This plan *revises how damage is dealt* — it removes continuous field DoT and reshapes casts/reactions into a Genshin-style model. The serialized state (Entity status fields + the field struct-list) is **unchanged**; only damage *values/paths* change.

**Why:** In Plan 4 a field ticks continuous DoT to every unit inside it (2-sided), so a self-placing hero (Cinderfang's Ember Field) damages himself every tick and effectively suicides. The new model: a coating (aura) does **no** damage by itself; damage comes from the **cast hit** and from **reactions**; and **no damage ever lands on the caster's own team**.

**Predecessor docs:** `docs/superpowers/specs/2026-06-07-plan-4-elemental-design.md`, `docs/superpowers/plans/2026-06-07-plan-4-elemental.md`. Game spec: `docs/superpowers/specs/2026-06-06-elemental-moba-design.md`.

---

## 1. Core model (what changes vs Plan 4)

| Concern | Plan 4 (current) | Plan 5 (this spec) |
|---|---|---|
| Bare status (aura) | n/a (status implied by field DoT) | **No damage by itself.** Pure marker; ~1.5s, refreshes on re-apply. |
| Field tick | Coats + real DoT on heroes / 0 on creeps, **2-sided (hurts self)** | **Coats only** (2-sided, no DoT). May *detonate a reaction* (see §4). |
| Cast | Just places the field | Places the field **+ a one-time enemy-only damage burst** (§3). |
| Reaction (Vaporize) | Amplify the triggering hit ×1.3 (autos + field ticks) | **Two paths** (§4): attack-amplify ×1.3 **and** field-overlap flat damage. |
| Who takes damage | Anyone (incl. self via field DoT) | **Enemies only** — caster's own team never takes damage. |
| Creeps | Coated; field DoT zero (coat-not-farm) | **Cast burst + field reactions DO hit creeps** (cooldown-gated AoE farm). |
| Ability input | Held intent → **auto-recasts every cooldown** (bug) | **One-shot** (fires once per press) — see §7. |

**Self-safety invariant (the headline fix):** the caster and the caster's own team never take cast-burst or field-reaction damage. You can still be Vaporized by the *enemy's* field/attack if you are carrying the opposite element — that is fair risk, not auto-suicide.

---

## 2. Fields (lingering, damage-free coat zones)

- Struct **unchanged**: `ElementalField{ownerId, center, element, timer}` in the serialized `_fields` list. Placement (`IntentType.ability`), duration (`kFieldDurationTicks`), ≤1 per hero, cooldown (`kAbilityCooldownTicks`), self-placed (Cinderfang) vs aim-placed (Marisol): **all unchanged**.
- `_stepFields` each tick, per field, per hero/creep in range (`lengthSq` vs `kFieldRadiusSq`, iterate `entityIdsSorted`):
  - If the unit is coated with a **different** element than the field's AND its `reactionIcd == 0` → **field-overlap reaction** (§4.2).
  - Else → **coat**: set `statusElement = field.element`, `statusTimer = kStatusDurationTicks`. **No damage.** 2-sided (the owner is **not** exempt from coating).
- Removed: `kFieldDotDamage` and all field DoT.

---

## 3. Cast burst (enemy-only AoE hit)

- In `step()`'s `ability` branch, **after** placing the field, deal a one-time burst:
  - For every hero/creep within `kFieldRadius` of the field center whose `teamId != caster.teamId` (enemy hero + neutral creeps; owner/own-team excluded), route through the element-application chokepoint with `baseDamage = kCastBurstDamage`. This applies the caster's element **and** triggers an attack-amplify reaction (§4.1) if the target was already coated with a different element.
- Centered on the field center → Cinderfang's burst is around his feet (melee AoE), Marisol's around the aim (ranged AoE).
- This is the **only** on-cast damage. Owner/own-team take nothing → self-safe.

---

## 4. Reactions (Vaporize) — two trigger paths, one shared ICD

Both paths consume the status (`statusElement = -1`, `statusTimer = 0`), stamp the per-unit `reactionIcd = kReactionIcdTicks`, and emit `ReactionTriggered`. The per-unit `reactionIcd` gates **both** paths (≤1 reaction per unit per ICD window) so overlapping fields + autos cannot machine-gun reactions.

### 4.1 Attack-amplify (autos + cast burst)
A **different-element damaging hit** (an auto-attack, or the cast burst) on a coated unit amplifies that hit's damage by `kVaporizeMult` (×1.3). This is the Plan 4 `_applyHit` reaction, retained. Damage rides the hit, which only ever targets enemies → self-safe. Works on enemy heroes **and** creeps (deliberate last-hit). Event carries `multiplierRaw = kVaporizeMult.raw`.

### 4.2 Field-overlap (flat)
A unit coated with element X that is inside a field of element Y≠X detonates a Vaporize dealing **flat** `kReactionFlatDamage` — but only if the unit is an **enemy of the field owner** (`unit.teamId != owner.teamId`; enemy hero + creeps). For the owner / own-team the reaction **still fires** (status consumed, ICD stamped, event emitted) but deals **0** damage. (There is no "triggering hit" to amplify here, hence a flat value.) Event carries `multiplierRaw = 0` to mark it "flat" (the client renders it without a "×n", see §10).

**Overlap timing:** within one `_stepFields` tick, a unit in two opposite-element fields gets coated by the first field then detonated by the second (the per-unit ICD then blocks further detonations until it expires). Field-list order is stable → deterministic.

---

## 5. Auto-attacks

Unchanged from Plan 4: a hero's auto on its locked enemy applies the hero's element and triggers an attack-amplify reaction (§4.1) if the target was coated with a different element. Autos only target enemies → self-safe.

---

## 6. Damage-targeting rule (the self-safety invariant, precisely)

- **Cast burst (§3)** and **field-overlap flat reaction (§4.2)**: apply damage only to units with `teamId != sourceTeam` (source = caster / field owner). Heroes + creeps qualify (creeps are team 2, an enemy of both players). Own team takes 0.
- **Attack-amplify (§4.1, §5)**: damage rides an auto/cast hit that already only targets enemies — inherently self-safe.
- Net: no code path can deal damage to the caster's own team.

---

## 7. Ability input = one-shot (the auto-recast fix)

**Root cause (confirmed):** the input system treats every input as a *held* intent (correct for `move` = "keep walking there" and `attack` = "keep hitting that target") and re-applies the latest one **every tick** — on the server (`IntentBuffer.drainForTick()` never clears `_current[slot]`) and the client (`MatchController._heldAt`). An `ability` is a one-shot action, so once its cooldown lapses the still-held cast fires again → auto-recast every `kAbilityCooldownTicks`, for any hero that has cast.

**Fix:** make `ability` **edge-triggered / one-shot** while `move`/`attack` stay held, applied exactly on its issuing tick:
- **Server (`IntentBuffer`):** keep `_held[slot]` for move/attack (persistent, last-writer-wins) and a separate one-shot `_pendingAbility[slot]` that `drainForTick` emits **once then clears**.
- **Client (`MatchController`):** held state = latest move/attack; the ability fires only at its exact `clientTick` in **both** forward prediction (`advanceClientTick`) and reconcile re-steps (`onServerSnapshot`), so prediction still matches the authority. Unacked ability intents remain in `_pending` for reconcile re-application and drop on ack as usual.
- The sim sorts intents by `(playerSlot, seq)` each tick, so drain order is normalized → deterministic.

This is a **netcode-only** change (no sim/serialization change) → golden-neutral for the replay goldens.

---

## 8. Tunables (`packages/sim/lib/src/data/elements.dart`)

- **Remove:** `kFieldDotDamage`.
- **Add (playtest placeholders):** `kCastBurstDamage = Fixed.fromNum(10)`, `kReactionFlatDamage = Fixed.fromNum(8)`.
- **Keep:** `kVaporizeMult` (1.3), `kStatusDurationTicks` (45), `kReactionIcdTicks` (15), `kFieldRadius`/`kFieldRadiusSq` (2.5 / 6.25), `kFieldDurationTicks` (120), `kAbilityCooldownTicks` (240).
- **Budget:** assert `kCastBurstDamage × kVaporizeMult < 32768` (the burst can be amplified). `kReactionFlatDamage` is flat (never amplified). All `|value| < 32768`.

---

## 9. Determinism / re-pin scope

- **Byte layout UNCHANGED** (same Entity status fields + same `_fields` struct) → **no `kSchemaVersion`/`kSnapshotVersion` bump.**
- **Unchanged goldens:** `smoke.golden` (move-only), `combat.golden` (combat autos each coat the *same* element repeatedly → no reaction, and combat has no fields/casts → no DoT), and the in-test 300-tick anchor `0x0fbfb7ac`.
- **Re-pins:** `elemental.golden` **only** — the elemental fixture casts overlapping fields, so cast bursts + field-overlap reactions change its outcome. Re-pin via the cross-runtime Re-Pin Procedure (prove byte-identical native/dart2js/dart2wasm, regenerate from harness output, never hand-type).
- Determinism rules unchanged: `Fixed`(Q16.16)+int only; no `dart:math`/`Random(`/`DateTime`/`Stopwatch` in `packages/sim/lib`; `lengthSq` membership; iterate `entityIdsSorted`/stable `_fields` list; **no new RNG draw** (the phase-5 wanderer is untouched); enums append-only.

---

## 10. Netcode / client

- **`ReactionTriggered`** keeps its shape; for the flat path `multiplierRaw = 0`. The client pop-text shows `"VAPORIZE"` when `multiplierRaw == 0`, else `"VAPORIZE ×1.3"`. (Small change in `guild_game.dart`'s reaction-label spawn.)
- **One-shot ability** in `MatchController` + server `IntentBuffer` (§7) — golden-neutral; new netcode tests.
- Field rendering unchanged (zones still drawn; they are now coat-only). Element-tint status ring unchanged.

---

## 11. Scope

**IN:** status does no damage; fields coat-only (2-sided, no DoT); enemy-only cast burst; two reaction triggers (attack-amplify + field-flat) sharing the per-unit ICD; all damage enemy-only (own-team safe); cast burst + field reactions hit creeps; one-shot ability input fix (server + client); `kCastBurstDamage`/`kReactionFlatDamage` tunables (remove `kFieldDotDamage`); client pop-text flat-vs-amplify distinction; rewrite `reaction_test.dart` for the new rules; re-pin `elemental.golden`; full determinism + cross-runtime sweep.

**OUT:** no new elements/reactions; no STRONG potency / provenance split; no new serialized fields or version bump; no boss/XP/shop; no change to `smoke.golden`/`combat.golden`/the in-test anchor; no protocol/codec change; no change to field placement/duration/cooldown mechanics; declared-only hooks (`BossSpawned`/`LevelUp`) untouched.

---

## 12. Tests

- **`reaction_test.dart` rewritten** for v2: a bare status deals no damage; a field coats 2-sided with no DoT (owner included, no self-damage); a field-overlap reaction deals `kReactionFlatDamage` to an enemy of the owner but **0** to the owner/own-team (status consumed either way); the cast burst hits enemy hero + creeps in radius (owner takes 0); attack-amplify reaction via an auto **and** via the cast burst (×1.3); the shared `reactionIcd` gates both paths (one reaction per window across overlapping field + auto); creeps take cast/field-reaction damage.
- **Netcode one-shot tests** (`match_controller_test`, server tests): cast once → exactly one field + one burst over a full cooldown cycle (no auto-recast); held move/attack still persist; reconcile reproduces a single cast.
- **`elemental_fixture_test`** updated if reaction-count assertions shift; **`elemental.golden` re-pinned** cross-runtime; CI line unchanged (already wired).
- **Client:** `element_palette` unit unchanged; `flutter analyze` clean (pop-text tweak compiles).
- **Full sweep** (mirror CI): `dart analyze --fatal-infos`, banned-imports, sim/protocol/netcode/server, the 3 replay compares, flutter analyze+test, cross-runtime sim+netcode (node + dart2wasm).

---

## 13. Open implementation details to resolve in the plan

- Element-application chokepoint refactor: `_applyHit` currently takes `(source, target, baseDamage, element, events)` and coats+amplifies. v2 needs (a) a **target-team gate** for the cast-burst/field-flat paths and (b) a **flat-damage reaction** distinct from amplify. Decide whether to extend `_applyHit` (e.g. an `enemyOnly`/`flat` mode) or add a sibling helper for the field-flat path — keep it one clear chokepoint per concern.
- Where exactly the cast burst iterates (in the `ability` branch vs a helper) — keep deterministic iteration (`entityIdsSorted`).
- Confirm `combat.golden` truly does not move (combat autos are same-element coats → no reaction) by running the compare during the relevant task; if it moves, investigate before re-pinning anything.
