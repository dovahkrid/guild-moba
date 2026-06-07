# Guild — Plan 6: Respawn Stand-Still — Design Spec

**Status:** approved 2026-06-07. Branch `plan-6-respawn-standstill` off `main` (`abe1360`).
**Relationship to prior plans:** purely a behavior fix on top of Plans 1–5 (all merged). No new gameplay system; it corrects how a *downed* hero's standing order is handled across the sim + netcode so a respawned hero stands still until the player issues a new order.

**Predecessor docs:** game spec `docs/superpowers/specs/2026-06-06-elemental-moba-design.md`; netcode plans `docs/superpowers/plans/2026-06-06-plan-2a-netcode-core.md`, `2026-06-06-plan-2b-netcode-wiring.md`; combat plan `docs/superpowers/plans/2026-06-07-plan-3-combat.md`. Control scheme: LoL — right-click = move+attack, left-click = ability.

---

## 1. The bug

When a hero dies and respawns, it auto-moves back toward its last position (or resumes pursuing its last attack target) instead of **standing still at spawn until the player issues a new click**.

### Root cause (confirmed in code @ `abe1360`)

A respawned hero resumes its pre-death order via **two independent channels**:

1. **Sim — the attack lock is never cleared.** `_sweepDeadHeroes` (`packages/sim/lib/src/simulation.dart:271`) sets `respawnTimer`/`pos`/`target` on death but leaves `attackTargetId` set. After respawn the pursue phase (`simulation.dart:136`) re-targets the old enemy → the hero walks to it. The respawn block (`simulation.dart:208`) also never clears `attackTargetId`.
2. **Netcode — the held order is re-fed every tick.** The server `IntentBuffer._held[slot]` re-applies the last move/attack every tick; that moving/pursuing state is baked into snapshots, and the client inherits it via `restoreFromSnapshot`. Nothing cancels the held order on death.

> The sim *does* set `target = pos` on death and respawn, which is why a respawned hero briefly stands and then walks — the held re-feed (server) and the surviving attack lock (sim) override it on the next tick.

The pure replay harness (`tooling/replay_harness.dart`) applies each intent **once at its tick** (no held re-feed) and chains the canonical hash every tick — so the **sim** channel (surviving `attackTargetId`) is what moves `combat.golden`; the **netcode** channel is exercised by the netcode/server tests, not the goldens.

---

## 2. Decision: ignore clicks while dead (LoL-style)

A click issued during the downed/respawning window is **discarded**. The hero stands still at spawn until the player issues a **new** order *after* it is back up. The entire downed window is a clean "no order" zone. This matches League, extends the sim's existing downed-input guard (`simulation.dart:108`), and is the simplest/most robust choice for prediction + reconcile (the downed window holds no live order, so nothing has to be replayed or honored across it). Applied **symmetrically to both heroes** (the deterministic sim treats both slots identically).

---

## 3. Architecture

### 3.1 Sim (`packages/sim`)

- **`Entity.isDowned` getter** — `respawnTimer != 0 || hp.raw <= 0`. Names the predicate already inlined at `simulation.dart:108` (intent guard) and `:242` (hero-attack guard). Used by the new server + client code, and substituted at the in-scope downed checks (death/respawn/intent-guard) for readability. **Pure predicate substitution → golden-neutral** (no behavior change).
- **Clear the attack lock on death** — in `_sweepDeadHeroes`, on the death transition (`hp.raw <= 0` while `respawnTimer == 0`): set `attackTargetId = -1` in addition to the existing `respawnTimer`/`pos`/`target = pos`. Nothing re-sets `attackTargetId` during the downed window (the intent and pursue phases skip downed heroes), so clear-on-death is sufficient; the respawn block needs no `attackTargetId` change.
- **Emit `HeroDowned{heroId}`** — a cosmetic, **off-wire** `SimEvent` (see §4) emitted on the same death transition.

### 3.2 Server (`apps/server`) — two plain rules

- **"Death cancels the held order."** In `Match._tick`, after `_sim.step(...)`, scan the returned events; for each `HeroDowned(slot)` call `_buffer.clearSlot(slot)`. New `IntentBuffer.clearSlot(int slot)` nulls `_held[slot]` **and** `_pendingAbility[slot]`. This cancels the *pre-death* standing order at the death tick.
- **"Dead heroes take no orders."** In the per-connection message listener (`Match.addPlayer`), ignore an `InputMsg` for `slot` when `_sim.entity(slot).isDowned`. This blocks *during-downtime* clicks from repopulating `_held` (robust regardless of client behavior; reading sim state in the async listener is safe — Dart is single-threaded and `_tick` runs to completion).
- **Alive heroes keep the per-tick re-feed.** `clearSlot` only fires for a downed slot, so the load-bearing held re-feed for *alive* heroes is untouched (e.g. an attack lock that relocks onto the enemy core after towers fall).

### 3.3 Client (`packages/netcode`) — input gating

- `applyLocalInput` / `applyAttackInput` / `applyAbilityInput` return **`InputMsg?`**; each returns `null` (records nothing in `_pending`, sends nothing) when `_predicted.entity(localSlot).isDowned`. The gating decision is made at user-input time, **outside** the deterministic re-step loop, so it is reconcile-safe.
- **A held order is dropped from `_pending` once the local hero is downed.** Input-gating handles clicks the client *knows* are during-downtime, but a click issued in the death-latency window (client still predicts the hero alive, but the server has already downed it and drops the input *without acking it*) would otherwise sit unacked in `_pending` and re-feed after respawn. So `MatchController` prunes held (move/attack) `_pending` entries whenever `_predicted.entity(localSlot).isDowned` (in `advanceClientTick` and at the end of `onServerSnapshot`). Abilities are one-shot (fire only on their issuing `clientTick`) so they are not pruned. This is reconcile-safe: the reconcile re-step window is always far newer than a 150-tick-old death, so pruned pre-death orders are never re-stepped. (The previously-acked common-case pre-death order is already gone via ack-pruning; this prune additionally closes the unacked death-window case, robust to packet loss.)

### 3.4 Render/input (`apps/client`)

- `MatchBinding` (the three call sites at `match_binding.dart:54,63,71`) skips `_transport.send(...)` when the controller method returns `null`. No other client change (no new death FX in scope).

---

## 4. The `HeroDowned` event

```dart
class HeroDowned extends SimEvent {
  final int heroId;
  const HeroDowned({required this.heroId});
}
```

- Added to `packages/sim/lib/src/events.dart` alongside the existing declared `SimEvent`s.
- **Off the wire / cosmetic:** `SimEvent`s are never serialized and never enter `canonicalBytes()`/`snapshotBytes()`, so `HeroDowned` touches no byte layout and does not move any golden by itself. It is the load-bearing signal that makes the server's "death cancels the held order" rule explicit (one named event) instead of an every-tick downed-state poll.
- `SimEvent` is a sealed class; adding a subclass follows the existing forward-declared-event pattern. No code does an exhaustive `switch` over `SimEvent` (consumers filter by type, e.g. `e is! ReactionTriggered`), so the addition is non-breaking. The server consumes it; the client need not (it gates on `isDowned`), but the event remains available as a future death-FX hook.

---

## 5. Determinism / re-pin scope

- **Byte layout UNCHANGED.** `attackTargetId` is already a serialized Entity field (`simulation.dart:527,574,627,657`); we only change *when* it is reset. `HeroDowned` is off-wire. **No `kSchemaVersion`/`kSnapshotVersion` bump** (stays 3/3).
- **`combat.golden` re-pins (the one sanctioned move).** `combat.json` (500 ticks): both heroes move to center, lock onto each other (attack intents at tick 70), trade 8 dmg / 0.6 s, drop to 0 hp (~tick 300) and respawn (~tick 450). Today the surviving `attackTargetId` makes them re-pursue for the final ~46 ticks; clearing it on death makes them **stand at spawn** → the per-tick canonical hash chain diverges from ~tick 450 onward. This is exactly the "hero death in combat.json genuinely forces a re-pin" case.
- **Unchanged:** `smoke.golden` (7e4aa28f, move-only, no deaths), `elemental.golden` (8d7fbe1b — `elemental.json` is 120 ticks with heroes 16 units apart, no attack intents, no deaths, first creep wave at tick 450 > 120), and the in-test anchor (`0x0fbfb7ac`, move-only).
- **Re-pin procedure for `combat.golden`:** the plan first verifies the `isDowned` refactor leaves **all four** hashes unchanged (clean attribution), then makes the behavioral change and re-pins via the cross-runtime procedure — run `tooling/compare_replays.sh` to prove byte-identical native / dart2js / dart2wasm, then regenerate the `.golden` from harness output. **Never hand-type a hash.**
- Determinism rules unchanged: `Fixed`(Q16.16)+int only; no `dart:math`/`Random(`/`DateTime`/`Stopwatch` in `packages/sim/lib`; `lengthSq` membership; iterate `entityIdsSorted`/stable `_entities`; **no new RNG draw** (the phase-5 wanderer is untouched); enums append-only (no enum touched).

---

## 6. Scope

**IN:** `Entity.isDowned` getter; clear `attackTargetId` on death; emit off-wire `HeroDowned`; server `IntentBuffer.clearSlot` + `Match` consuming `HeroDowned` (cancel held order) + listener ignoring input for a downed slot (dead heroes take no orders); client input-gating (`applyLocalInput/Attack/Ability` → `InputMsg?`, gated on `isDowned`) + `MatchBinding` skip-on-null; re-pin `combat.golden` cross-runtime; full determinism + cross-runtime sweep.

**OUT:** no new serialized field / version bump; no protocol/codec change; no death FX/animation/pop-text; no change to respawn timing/location, move/attack/ability mechanics, or the alive-hero held re-feed; no client death-barrier (input-gating only); `smoke.golden`/`elemental.golden`/the in-test anchor unchanged; declared-only `SimEvent`s (`BossSpawned`/`LevelUp`/`TowerDestroyed` boss hook) untouched.

---

## 7. Tests (TDD, evidence-first)

- **Sim (`packages/sim/test`):** a hero death sets `attackTargetId = -1`; the respawn block keeps `target = pos` and the lock cleared; a hero with an attack lock that is killed and run past `kHeroRespawnTicks` **stands at its spawn** (does not re-pursue); a killed hero with a prior move target stands (does not walk back); `HeroDowned{heroId}` is emitted exactly on the death transition (and not while already downed); `Entity.isDowned` truth table (alive, `respawnTimer>0`, `hp<=0`).
- **Server (`apps/server/test`):** `IntentBuffer.clearSlot` nulls held + pendingAbility; `Match` calls `clearSlot` on a `HeroDowned` event (held order gone → hero stands after respawn); an `InputMsg` arriving while the slot `isDowned` is ignored (not applied post-respawn); an alive hero's held move/attack still re-feeds every tick (relock-after-towers-fall path intact).
- **Netcode (`packages/netcode/test`):** `applyLocalInput/Attack/Ability` return `null` and record/send nothing while the local hero is downed; a killed local hero **stands through respawn** with reconcile correction ≈ 0 (proves the no-barrier design — prediction matches the authoritative standing state); a fresh post-respawn click moves it.
- **Client (`apps/client/test`):** `MatchBinding` skips the send when the controller returns `null` (and sends normally otherwise).
- **Goldens:** verify the `isDowned` refactor is golden-neutral (all four hashes unchanged); then re-pin `combat.golden` cross-runtime; assert `smoke.golden`/`elemental.golden`/the anchor are byte-unchanged.
- **Full sweep (mirror CI):** `dart analyze --fatal-infos`, banned-imports, sim/protocol/netcode/server tests, the 3 replay compares, `flutter analyze` + test, cross-runtime sim + netcode (node + dart2wasm).

---

## 8. Open implementation details to resolve in the plan

- **`HeroDowned` emission point & idempotency:** emit only on the *transition* into downed (the tick `_sweepDeadHeroes` sets `respawnTimer`), never on subsequent downed ticks, so a reconcile re-step that re-crosses the death tick re-emits identically and the server clears at the right moment. Confirm no double-emit when both `_sweepDeadStructures`/`_sweepDeadHeroes` run.
- **`clearSlot` vs `_pendingAbility`:** clearing the one-shot ability on death is tidy but not strictly required (the sim guard ignores a downed hero's ability and one-shots clear on drain); decide whether `clearSlot` nulls both or only `_held`. Default: null both for symmetry.
- **Listener ignore vs sim guard overlap:** the listener-ignore is defensive (honest clients already gate); confirm it does not also drop the *ack/seq* bookkeeping in a way that desyncs `lastAckedSeq` (ignore = don't accept = don't advance the frontier, which is correct for a dropped input).
- **Golden attribution:** run `compare_replays.sh` after the pure `isDowned` refactor to prove the four hashes are unchanged *before* the `attackTargetId` change, so the `combat.golden` move is cleanly attributable to the behavioral fix.
