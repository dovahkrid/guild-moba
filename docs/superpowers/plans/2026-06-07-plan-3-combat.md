# Guild — Plan 3: Combat (Auto-Attacks, Towers, Neutral Creeps, Last-Hit Gold, Destroy-Core Win) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer deterministic combat onto the proven movement netcode — hero auto-attacks, towers with ordered (outer→inner→core) vulnerability, neutral creep waves, last-hit gold, and a destroy-enemy-core win condition — extending the sim's canonical/snapshot encodings and re-pinning the determinism goldens, while leaving clean inert hooks for Plan 4 (elemental).

**Architecture:** All combat logic lives in the pure-Dart `packages/sim` (the single source of truth both server and client step). Damage is **instantaneous** (hitscan) through one `_applyDamage` chokepoint — no projectile entities. **Heroes use a LoL-style locked target:** a right-click `attack` intent locks the hero onto an enemy (`attackTargetId` — persistent, intent-derived, **serialized** so it reconciles), which the hero pursues and attacks until the target dies or a `move` intent clears the lock; an unlocked hero never attacks. **Towers auto-acquire** the nearest enemy hero in range (deterministic, ascending-id tiebreak); creeps are passive. Towers and a core per team are static entities; neutral creeps spawn in waves with **tick-derived ids** and despawn on death, handled by an **id-keyed snapshot reconcile**. `step()` now returns `List<SimEvent>` (cosmetic-only, per spec §8.1) but Plan 3 does **not** put events on the wire — the client renders combat purely from durable snapshot state (hp, gold, entity set) plus an authoritative `MatchEndMsg` carrying the winner.

**Tech Stack:** Dart 3.11.5 pub workspace; `packages/sim` (pure, Q16.16 fixed-point, PCG32 `DetRng`, FNV-1a canonical hash); `packages/protocol` (binary codec); `packages/netcode` (predict/reconcile/interpolate); `apps/server` (`shelf` WS); `apps/client` (Flutter + Flame ^1.30). Tests: `package:test`; cross-runtime golden via `tooling/replay_harness.dart` + `tooling/compare_replays.sh` on native/dart2js/dart2wasm.

**Determinism contract (every task obeys this — non-negotiable):**
- **No floating point in gameplay math.** `Fixed` (Q16.16) and `int` only. `Fixed.fromNum` is authoring-only (config/tests). Keep every `|value| < 32768` so `|raw| < 2^31` and all intermediates `< 2^53` (dart2js mantissa). Gold is a running total → **plain `int`, never `Fixed`**.
- **No `dart:math`** (`sin/cos/sqrt/pow/atan2/tan`), no `Random(`, no `DateTime`/`Stopwatch` anywhere in `packages/sim/lib`. Enforced by `packages/sim/test/banned_imports_test.dart` + `tooling/check_no_banned_imports.sh`. Range checks use `FVec2.lengthSq()` vs a precomputed radius² — **never `sqrt`**.
- **No `<<`/`>>`/`>>>` on values that may be negative or exceed 32 bits.** Time is the integer `tick` only; cooldowns/timers/wave cadence are integer tick counts (seconds × 30).
- **Deterministic iteration order.** Iterate `_entities` (insertion order) or `entityIdsSorted` (ascending id); **never** iterate `_byId` / a `Set` for state-affecting logic. Intents keep the existing canonical sort (playerSlot then seq).
- **No `hashCode`-dependent branching** (`Fixed`/`FVec2` hashCode are value-based but documented never-to-branch-on); **no reflection**. The match seed enters only via `SimConfig` / `MatchStart` (spec §8.1/§12).
- **`EntityKind` / `IntentType` / `EndReason` enum values are APPEND-ONLY** — `.index` is serialized; never insert mid-enum or reorder.
- **Two byte formats, two versions.** Bump `kSchemaVersion` when `canonicalBytes()` layout changes; bump `kSnapshotVersion` when `snapshotBytes()` changes. The three snapshot byte-sites — `snapshotBytes` (write), `restoreFromSnapshot` (read), `peekEntityPos` (skip) — MUST be edited in lockstep.
- **Reconcile correctness.** Every piece of state `step()` reads MUST round-trip through `snapshotBytes()` (the client restores then re-steps). Acquisition targets are recomputed each tick from positions (already serialized) so they need no storage; `attackCooldown`, `gold`, `respawnTimer`, and `winnerTeam` persist → they ARE serialized.
- **`SimEvent`s are cosmetic only** — they never mutate state, so they fire identically on server (authoritative) and client (predicted).
- **Forward-compat:** 1v1 now, no `== 2` hardcodes; `teamId` clean (0/1 players, 2 = neutral). Build inert hooks for Plan 4; implement **no** elemental content, **no** revenge boss.

---

## Re-Pin Procedure (referenced by determinism-affecting tasks 3, 4, and 12)

Two sim goldens are pinned and MUST be regenerated — never hand-typed — from a verified green 3-runtime run whenever `canonicalBytes()` output changes:
1. The cross-runtime replay golden `tooling/replay_fixtures/smoke.golden` (currently `caf9858f`).
2. The in-test pinned hash literal `0xa00d6337`, which appears in **both** `packages/sim/test/simulation_test.dart` and `packages/sim/test/snapshot_test.dart`.

**Procedure (run in bash — Git Bash / WSL on Windows):**
```bash
# 1. Confirm byte-identical determinism across all three runtimes FIRST.
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
# Expect: "PASS: byte-identical across native/js/wasm: <newhash>"
# If it prints a DIVERGENCE instead, STOP — there is a non-determinism bug.
# Binary-diff canonicalBytes() per tick to find the first divergent field
# (almost always a stray shift/double/Map-iteration) and fix it before pinning.

# 2. Capture the new cross-runtime golden.
b64=$(base64 -w0 tooling/replay_fixtures/smoke.json) \
  && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart \
     | awk '/^REPLAY_HASH /{print $2}' > tooling/replay_fixtures/smoke.golden

# 3. Read the new in-test canonical hash from the failing unit test output
#    (`dart test packages/sim` prints "Expected: <0x...> Actual: <0x...>").
#    Update the 0xNNNNNNNN literal in BOTH:
#      packages/sim/test/simulation_test.dart  (test 'pinned 300-tick canonical state hash')
#      packages/sim/test/snapshot_test.dart    (test 'canonicalBytes/hash unchanged (golden untouched)')

# 4. Verify everything is green and the golden is enforced.
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json   # ...then "PASS: matches golden ..."
dart test packages/sim
```
Commit the regenerated `smoke.golden` and both updated test literals **together** in the task's commit.

---

## File Structure

**Created in this plan:**
- `packages/sim/lib/src/events.dart` — `sealed SimEvent` + subtypes (DamageDealt, CreepKilled, TowerDestroyed, CoreDestroyed emitted; ReactionTriggered/BossSpawned/LevelUp declared for Plan 4+).
- `packages/sim/lib/src/data/combat.dart` — all combat tunables + lane geometry + reserved entity ids (named constants; playtest placeholders).
- `packages/sim/test/combat_test.dart` — target acquisition, auto-attack/damage, tower gating, respawn, creep waves, last-hit gold, win condition.
- `packages/sim/test/events_test.dart` — SimEvent construction + that `step()` returns events on damage/kill.
- `tooling/replay_fixtures/combat.json` + `tooling/replay_fixtures/combat.golden` — combat replay fixture exercising attack-lock + hero damage + tower fire + death/respawn + a creep-wave spawn, pinned cross-runtime.

**Modified in this plan:**
- `packages/sim/lib/src/model/entity.dart` — append `EntityKind {tower, creep, core}`; add `maxHp`, `attackCooldown`, `gold`, `respawnTimer` fields.
- `packages/sim/lib/src/simulation.dart` — combat systems in `step()` (now returns `List<SimEvent>`); structures+core in `create()`; `winnerTeam` getter; extended `canonicalBytes`/`snapshotBytes`/`restoreFromSnapshot` (id-keyed)/`peekEntityPos` (nullable); version bumps.
- `packages/sim/lib/sim.dart` — export `events.dart` and `data/combat.dart`.
- `packages/sim/test/simulation_test.dart`, `packages/sim/test/snapshot_test.dart` — entity-set + re-pinned hash + combat-free scenario aims.
- `packages/protocol/lib/src/messages.dart`, `codec.dart` — `EndReason.coreDestroyed`; `MatchEndMsg.winnerSlot`.
- `packages/protocol/test/codec_test.dart` — round-trip tests for the new `MatchEndMsg(reason, winnerSlot)`.
- `packages/netcode/lib/src/match_view.dart` — `RenderEntity` (id/kind/team/hp/maxHp) + `MatchView` entity list + localGold.
- `packages/netcode/lib/src/match_controller.dart` — `update()` builds the entity list (opponent hero interpolated); ignore `step()` return; null-safe peek.
- `packages/netcode/test/match_controller_test.dart`, `netcode_integration_test.dart` — migrate view reads to the entity list.
- `apps/server/lib/src/loop/match.dart` — win detection in `_tick()` → final snapshot + `MatchEndMsg(coreDestroyed, winnerSlot)` → `onEnded`.
- `apps/server/test/match_test.dart` — win-end test.
- `apps/client/lib/render/guild_game.dart` — keyed entity diff (add/remove); follow local hero from the list.
- `apps/client/lib/render/entity_view.dart` — shape/color by (kind, teamId); health-bar child.
- `apps/client/lib/match/match_binding.dart` — expose `winnerSlot` from `MatchEndMsg`.
- `apps/client/lib/ui/hud_overlay.dart` — gold counter; `apps/client/lib/main.dart` — register `result` overlay; new `apps/client/lib/ui/result_overlay.dart`.
- `.github/workflows/sim-determinism.yml` — add a combat-fixture replay step.

---

## Scope (read before starting)

**IN (Milestone-0 build-order gate 3 + combat plumbing under gate 4):** hero auto-attacks; 2 towers + core per team with ordered (outer→inner→core) vulnerability gating; neutral creep waves (passive last-hit fodder); last-hit gold; hero death + fixed-timer respawn; destroy-enemy-core win; the `SimEvent` channel (emitted, not wired to the protocol); client rendering of all entity kinds + health bars + gold + win/lose overlay.

**OUT (deferred — leave only the noted inert hooks):** elemental auras / reactions / fields / Vaporize (Plan 4); the revenge boss (emit `TowerDestroyed{killerId}` + declare `BossSpawned` only); item shop; XP / leveling / ability ranks; hero abilities & ultimates (hero combat = auto-attack only); bounties / comeback / streak gold (last-hit only); the "reduced tower damage without creeps" + "escalating same-target damage" balance modifiers (§6 — documented balance hook, deferred to playtest §13); room-code lobby; reconnect. **Do not** implement any of these.

---

## Task 1: Combat model — extend `EntityKind`, `IntentType`, `Entity`; add `SimEvent` types

**Files:**
- Modify: `packages/sim/lib/src/model/entity.dart`
- Modify: `packages/sim/lib/src/model/intent.dart`
- Create: `packages/sim/lib/src/events.dart`
- Modify: `packages/sim/lib/sim.dart`
- Create: `packages/sim/test/events_test.dart`
- Modify: `packages/sim/test/model_test.dart`

> **Control model (LoL-style, locked target):** right-click an enemy → the hero **locks** onto it (`attackTargetId`) and pursues + auto-attacks it until the target dies/leaves or you right-click the ground (a **move** intent clears the lock). Heroes do **not** passively auto-acquire — they attack **only** their locked target. (Towers still auto-acquire; creeps are passive.) This needs an `IntentType.attack` carrying the target entity id, and a **persistent, serialized** `Entity.attackTargetId` (intent-derived state read by `step()` → it MUST round-trip through the snapshot, exactly as the `match_controller` reconcile comment warns).

> This task is **golden-neutral**: it adds fields and types but does NOT change `canonicalBytes()` output (the new fields are not serialized until Task 3, and `create()` is unchanged). All existing pinned-hash tests must still pass untouched.

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/model_test.dart` (inside `main()`):
```dart
  test('Entity has combat fields defaulting sanely', () {
    final e = Entity(
      id: 5,
      kind: EntityKind.tower,
      teamId: 0,
      pos: FVec2.zero,
      hp: Fixed.fromInt(600),
      maxHp: Fixed.fromInt(600),
    );
    expect(e.kind, EntityKind.tower);
    expect(e.maxHp.toDouble(), 600.0);
    expect(e.attackCooldown, 0);
    expect(e.gold, 0);
    expect(e.respawnTimer, 0);
    expect(e.attackTargetId, -1); // -1 = no locked target
  });

  test('EntityKind appends combat kinds without shifting existing indices', () {
    // Wire format serializes kind.index — existing indices MUST be preserved.
    expect(EntityKind.hero.index, 0);
    expect(EntityKind.wanderer.index, 1);
    expect(EntityKind.tower.index, 2);
    expect(EntityKind.creep.index, 3);
    expect(EntityKind.core.index, 4);
  });

  test('IntentType appends attack without shifting existing indices', () {
    // InputMsg.type is the wire int = IntentType.index — append only.
    expect(IntentType.none.index, 0);
    expect(IntentType.move.index, 1);
    expect(IntentType.attack.index, 2);
  });
```

Create `packages/sim/test/events_test.dart`:
```dart
import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('combat SimEvents carry their payloads', () {
    const d = DamageDealt(sourceId: 0, targetId: 1, amountRaw: 8 * 65536);
    const k = CreepKilled(creepId: 1000, killerId: 0, gold: 18);
    const t = TowerDestroyed(towerId: 12, teamId: 0, killerId: 1);
    const c = CoreDestroyed(teamId: 0, winnerTeam: 1);
    expect(d.targetId, 1);
    expect(k.gold, 18);
    expect(t.killerId, 1);
    expect(c.winnerTeam, 1);
    expect(<SimEvent>[d, k, t, c], hasLength(4));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test packages/sim/test/model_test.dart packages/sim/test/events_test.dart`
Expected: FAIL — `model_test.dart`: "The named parameter 'maxHp' isn't defined" / "EntityKind.tower ... isn't defined"; `events_test.dart`: "Target of URI doesn't exist: 'package:sim/sim.dart'" resolves but "DamageDealt isn't a function/class".

- [ ] **Step 3: Write the implementation**

Replace `packages/sim/lib/src/model/entity.dart` entirely:
```dart
import '../math/fixed.dart';
import '../math/fvec2.dart';

/// Append-only: kind.index is serialized in canonicalBytes() AND snapshotBytes().
/// hero=0, wanderer=1 are from Plan 1; tower/creep/core are appended for combat.
enum EntityKind { hero, wanderer, tower, creep, core }

/// A simulated unit. Plan 3 adds combat state.
class Entity {
  final int id;
  final EntityKind kind;
  final int teamId; // 0/1 = players; 2 = neutral (wanderer, creeps).

  FVec2 pos;
  FVec2 vel;
  Fixed hp;

  /// Full health (for the health-bar ratio + clamping). Constant per entity.
  Fixed maxHp;

  /// Ticks remaining until this unit may attack again (0 = ready).
  int attackCooldown;

  /// Accumulated last-hit gold (heroes only; running total → int, not Fixed).
  int gold;

  /// Ticks until a downed hero respawns (0 = alive). >0 means downed:
  /// untargetable, cannot attack, ignores move intents.
  int respawnTimer;

  /// Locked attack target entity id (-1 = none). Set by an attack intent,
  /// cleared by a move intent or when the target dies/leaves. Heroes pursue +
  /// attack ONLY this id. Persistent, intent-derived → serialized so reconcile
  /// reproduces it.
  int attackTargetId;

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
    FVec2? vel,
    FVec2? target,
  })  : maxHp = maxHp ?? hp,
        vel = vel ?? FVec2.zero,
        target = target ?? pos;
}
```

In `packages/sim/lib/src/model/intent.dart`, append `attack` to `IntentType` (append-only — `.index` is the wire `type`):
```dart
enum IntentType { none, move, attack }
```
(The rest of `intent.dart` is unchanged. An attack intent reuses `aimX` to carry the **target entity id** — no protocol/codec change.)

Create `packages/sim/lib/src/events.dart`:
```dart
/// Cosmetic-only events emitted by Simulation.step(). They NEVER mutate state,
/// so the predicted client and authoritative server emit identical events for
/// the same (tick, intents, prior state). Plan 3 emits the combat subset only;
/// the rest are declared for Plan 4+ (reactions) and a later revenge-boss plan.
sealed class SimEvent {
  const SimEvent();
}

class DamageDealt extends SimEvent {
  final int sourceId;
  final int targetId;
  final int amountRaw; // Q16.16 raw of the damage applied
  const DamageDealt({
    required this.sourceId,
    required this.targetId,
    required this.amountRaw,
  });
}

class CreepKilled extends SimEvent {
  final int creepId;
  final int killerId;
  final int gold;
  const CreepKilled({
    required this.creepId,
    required this.killerId,
    required this.gold,
  });
}

class TowerDestroyed extends SimEvent {
  final int towerId;
  final int teamId; // owner of the fallen tower
  final int killerId; // the "debtor" — revenge-boss target hook for a later plan
  const TowerDestroyed({
    required this.towerId,
    required this.teamId,
    required this.killerId,
  });
}

class CoreDestroyed extends SimEvent {
  final int teamId; // owner of the destroyed core
  final int winnerTeam;
  const CoreDestroyed({required this.teamId, required this.winnerTeam});
}

// --- Declared for Plan 4+ (NOT emitted in Plan 3). ---
class ReactionTriggered extends SimEvent {
  final int unitId;
  final int reaction; // enum index, defined in Plan 4
  const ReactionTriggered({required this.unitId, required this.reaction});
}

class BossSpawned extends SimEvent {
  final int bossId;
  final int teamId;
  const BossSpawned({required this.bossId, required this.teamId});
}

class LevelUp extends SimEvent {
  final int heroId;
  final int level;
  const LevelUp({required this.heroId, required this.level});
}
```

Add to `packages/sim/lib/sim.dart` (after the existing exports):
```dart
export 'src/events.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test packages/sim/test/model_test.dart packages/sim/test/events_test.dart`
Expected: PASS (model_test: existing tests + 3 new; events_test: 1).

Then confirm the goldens are still untouched:
Run: `dart test packages/sim`
Expected: PASS (all, including the pinned `0xa00d6337` tests — this task changed no serialized state; `IntentType`/`Entity.attackTargetId` are not yet read by `step()` or serialized).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/model/entity.dart packages/sim/lib/src/model/intent.dart \
        packages/sim/lib/src/events.dart packages/sim/lib/sim.dart \
        packages/sim/test/model_test.dart packages/sim/test/events_test.dart
git commit -m "feat(sim): combat entity fields + attack intent + cosmetic SimEvent types"
```

---

## Task 2: Combat tunables + lane geometry constants

**Files:**
- Create: `packages/sim/lib/src/data/combat.dart`
- Modify: `packages/sim/lib/sim.dart`
- Create: `packages/sim/test/combat_test.dart`

> Golden-neutral (pure data, nothing serialized yet). Values are **playtest placeholders** (spec §13 defers exact numbers); slice values keep matches tractable and entity counts modest. Spec's eventual targets are noted in comments.

- [ ] **Step 1: Write the failing test**

Create `packages/sim/test/combat_test.dart`:
```dart
import 'package:sim/sim.dart';
import 'package:sim/src/data/combat.dart';
import 'package:test/test.dart';

void main() {
  test('combat constants obey the Fixed magnitude budget (|value| < 32768)', () {
    // Every Fixed tunable and the largest possible lengthSq must stay in range.
    final maxima = <Fixed>[
      kHeroMaxHp, kOuterTowerMaxHp, kInnerTowerMaxHp, kCoreMaxHp, kCreepMaxHp,
      kHeroAttackDamage, kTowerAttackDamage, kHeroAttackRangeSq, kTowerAttackRangeSq,
    ];
    for (final f in maxima) {
      expect(f.toDouble().abs() < 32768, isTrue, reason: '$f exceeds budget');
    }
    // Worst-case separation²: the two cores (±kCoreX).
    final sep = kCoreX + kCoreX; // 28 units
    expect((sep * sep).toDouble().abs() < 32768, isTrue);
  });

  test('attack-range² equals range squared (no sqrt needed)', () {
    expect(kHeroAttackRangeSq.toDouble(), kHeroAttackRange.toDouble() * kHeroAttackRange.toDouble());
    expect(kTowerAttackRangeSq.toDouble(), kTowerAttackRange.toDouble() * kTowerAttackRange.toDouble());
  });

  test('wave cadence is expressed in integer ticks', () {
    expect(kFirstWaveTick, 450); // 0:15 at 30Hz
    expect(kWaveIntervalTicks, 900); // 30s
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: FAIL — "Target of URI doesn't exist: 'package:sim/src/data/combat.dart'".

- [ ] **Step 3: Write the implementation**

Create `packages/sim/lib/src/data/combat.dart`:
```dart
import '../math/fixed.dart';

/// Combat tunables for the Milestone-0 slice. PLAYTEST PLACEHOLDERS (spec §13
/// defers exact numbers); slice values keep a match tractable and obey the
/// Fixed contract (|value| < 32768). Spec's eventual targets noted inline.

const int kTicksPerSecond = 30; // server tick rate; seconds × 30 = ticks.

// --- Hero auto-attack ---
final Fixed kHeroMaxHp = Fixed.fromInt(100);
final Fixed kHeroAttackRange = Fixed.fromNum(3);
final Fixed kHeroAttackRangeSq = Fixed.fromNum(3 * 3); // compare vs lengthSq, no sqrt
final Fixed kHeroAttackDamage = Fixed.fromNum(8);
const int kHeroAttackCooldownTicks = 18; // ~0.6s
const int kHeroRespawnTicks = 150; // 5s

// --- Towers (spec §6 targets: outer 1800/120/1.0/~6, inner 2400/150/1.1/~6) ---
final Fixed kOuterTowerMaxHp = Fixed.fromInt(600);
final Fixed kInnerTowerMaxHp = Fixed.fromInt(800);
final Fixed kTowerAttackRange = Fixed.fromNum(6);
final Fixed kTowerAttackRangeSq = Fixed.fromNum(6 * 6);
final Fixed kTowerAttackDamage = Fixed.fromNum(20);
const int kTowerAttackCooldownTicks = 30; // 1.0/s

// --- Core ---
final Fixed kCoreMaxHp = Fixed.fromInt(400);

// --- Neutral creeps (slice = passive last-hit fodder; spec §6: 5/wave) ---
final Fixed kCreepMaxHp = Fixed.fromInt(60);
const int kCreepsPerWave = 3;
const int kFirstWaveTick = 450; // 0:15
const int kWaveIntervalTicks = 900; // 30s

// --- Gold (last-hit; spec §6 values) ---
const int kCreepGold = 18; // melee-equivalent neutral creep
const int kOuterTowerGold = 200;
const int kInnerTowerGold = 300;

// --- Lane geometry: single horizontal lane, mirror-symmetric on x, y = 0.
// Team 0 occupies negative x; team 1 positive x. Magnitudes are per-side
// offsets (negate for team 0). ---
final Fixed kHero0SpawnX = Fixed.fromInt(-8);
final Fixed kHero1SpawnX = Fixed.fromInt(8);
final Fixed kOuterTowerX = Fixed.fromInt(4); // team0 at -4, team1 at +4 (throat)
final Fixed kInnerTowerX = Fixed.fromInt(10); // base mouth
final Fixed kCoreX = Fixed.fromInt(14); // back
final Fixed kCreepSpawnSpacing = Fixed.fromNum(1.5); // creeps spread on x at center

// --- Reserved stable entity ids (heroes 0/1, wanderer 2 from Plan 1) ---
const int kCore0Id = 10;
const int kCore1Id = 11;
const int kOuterTower0Id = 12;
const int kInnerTower0Id = 13;
const int kOuterTower1Id = 14;
const int kInnerTower1Id = 15;
/// Wave creeps get ids kCreepIdBase + waveIndex*kCreepsPerWave + indexInWave,
/// a pure function of spawn tick — no stored counter, never reused/collides.
const int kCreepIdBase = 1000;
```

Add to `packages/sim/lib/sim.dart` (after the other exports):
```dart
export 'src/data/combat.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/data/combat.dart packages/sim/lib/sim.dart packages/sim/test/combat_test.dart
git commit -m "feat(sim): combat tunables + lane geometry constants"
```

---

## Task 3: Serialize combat fields + `winnerTeam`; retune the determinism anchor combat-free; re-pin goldens (#1)

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/simulation_test.dart`, `packages/sim/test/snapshot_test.dart`
- Modify: `tooling/replay_fixtures/smoke.json`, `tooling/replay_fixtures/smoke.golden`

> **Determinism-critical.** This changes `canonicalBytes()`/`snapshotBytes()` layout (new per-entity fields + a `winnerTeam` header) and bumps both versions. The entity set is still the original 3 (structures arrive in Task 4). We also retune the pinned movement scenario so the heroes move **apart** — this keeps the determinism anchor **combat-free**, so the later combat-behavior tasks (5–10) don't disturb it. After the layout + scenario change, re-pin via the Re-Pin Procedure.

- [ ] **Step 1: Write/adjust the failing tests (new fields round-trip; retune scenario)**

In `packages/sim/test/snapshot_test.dart`, add a round-trip test for the new fields (append inside `main()`):
```dart
  test('snapshot round-trips combat fields (gold, cooldown, respawn, maxHp, winnerTeam)', () {
    final src = Simulation.create(const SimConfig(seed: 1337));
    // Mutate combat fields directly to prove they serialize (no combat logic yet).
    src.entity(0).gold = 42;
    src.entity(0).attackCooldown = 7;
    src.entity(0).attackTargetId = 1; // hero 0 locked onto hero 1
    src.entity(1).respawnTimer = 13;
    final dst = Simulation.create(const SimConfig(seed: 1337))
      ..restoreFromSnapshot(src.snapshotBytes());
    expect(dst.entity(0).gold, 42);
    expect(dst.entity(0).attackCooldown, 7);
    expect(dst.entity(0).attackTargetId, 1);
    expect(dst.entity(1).respawnTimer, 13);
    expect(dst.entity(0).maxHp.raw, src.entity(0).maxHp.raw);
    expect(dst.entity(2).maxHp.raw, src.entity(2).maxHp.raw); // wanderer maxHp=50 round-trips
    expect(dst.canonicalStateHash(), src.canonicalStateHash());
  });
```

Retune the **combat-free** scenario. In `packages/sim/test/simulation_test.dart`, in BOTH the `'identical seed + inputs produce identical state hash (determinism)'` test and the `'pinned 300-tick canonical state hash'` test, swap the two heroes' aimX so they move **apart** (away from center). Change:
```dart
    const m0 = Intent(playerSlot: 0, type: IntentType.move, aimX: 655360, aimY: 131072, seq: 1);
    const m1 = Intent(playerSlot: 1, type: IntentType.move, aimX: -655360, aimY: 131072, seq: 1);
```
to:
```dart
    // Combat-free anchor: heroes move APART (toward their own inner towers) so
    // adding combat behavior in later tasks never disturbs this pinned hash.
    const m0 = Intent(playerSlot: 0, type: IntentType.move, aimX: -655360, aimY: 131072, seq: 1);
    const m1 = Intent(playerSlot: 1, type: IntentType.move, aimX: 655360, aimY: 131072, seq: 1);
```
Make the **identical** swap in `packages/sim/test/snapshot_test.dart`'s top-level `_run()` helper (`m0`/`m1`). (Leave the `'a move intent pulls the hero toward its aim'` test in simulation_test.dart unchanged — it is not a pinned test and stays combat-free.)

Update `tooling/replay_fixtures/smoke.json` so its scenario is also combat-free — replace the whole `inputLog` so the tick-0 heroes diverge and the tick-120 nudge keeps hero 0 on its own (left) side, far from any enemy structure:
```json
  "inputLog": {
    "0":  [{"playerSlot":0,"type":1,"aimX":-655360,"aimY":131072,"seq":1,"clientTick":0},
           {"playerSlot":1,"type":1,"aimX":655360,"aimY":131072,"seq":1,"clientTick":0}],
    "120":[{"playerSlot":0,"type":1,"aimX":-786432,"aimY":-262144,"seq":2,"clientTick":120}]
  }
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim`
Expected: FAIL — the new round-trip test fails ("gold isn't serialized" → assertion mismatch or `dst.entity(0).gold == 0`), AND the two pinned-hash tests fail with `Expected: <0xa00d6337> Actual: <0x...>` (scenario + layout changed). This is expected; do not edit the literals yet.

- [ ] **Step 3: Extend the encodings + add `winnerTeam`**

In `packages/sim/lib/src/simulation.dart`:

(a) Bump both versions:
```dart
const int kSchemaVersion = 2;
const int kSnapshotVersion = 2;
```

(b) Import the combat constants at the top (needed in Task 4; add now):
```dart
import 'data/combat.dart';
```

(c) Add the winner field + getter to the `Simulation` class (near `int tick = 0;`):
```dart
  /// -1 = undecided; otherwise the teamId whose enemy core was destroyed (the
  /// winner). Set in step() (Task 10); serialized so prediction/reconcile agree.
  int _winnerTeam = -1;
  int get winnerTeam => _winnerTeam;
```

(d) Replace `canonicalBytes()`'s body with (header `winnerTeam` after the rng limbs; four new per-entity fields after `hp`):
```dart
  Uint8List canonicalBytes() {
    final w = ByteWriter();
    w.i32(kSchemaVersion);
    w.i32(tick);
    w.u32(_rng.stateLo);
    w.u32(_rng.stateHi);
    w.i32(_winnerTeam);
    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      w.fixed(e.pos.x);
      w.fixed(e.pos.y);
      w.fixed(e.vel.x);
      w.fixed(e.vel.y);
      w.fixed(e.hp);
      w.fixed(e.maxHp);
      w.i32(e.attackCooldown);
      w.i32(e.gold);
      w.i32(e.respawnTimer);
      w.i32(e.attackTargetId);
    }
    return w.toBytes();
  }
```

(e) Replace `snapshotBytes()`'s body identically, but with `target.x`/`target.y` appended last per entity:
```dart
  Uint8List snapshotBytes() {
    final w = ByteWriter();
    w.i32(kSnapshotVersion);
    w.i32(tick);
    w.u32(_rng.stateLo);
    w.u32(_rng.stateHi);
    w.i32(_winnerTeam);
    final ids = entityIdsSorted;
    w.i32(ids.length);
    for (final id in ids) {
      final e = _byId[id]!;
      w.i32(id);
      w.i32(e.kind.index);
      w.i32(e.teamId);
      w.fixed(e.pos.x);
      w.fixed(e.pos.y);
      w.fixed(e.vel.x);
      w.fixed(e.vel.y);
      w.fixed(e.hp);
      w.fixed(e.maxHp);
      w.i32(e.attackCooldown);
      w.i32(e.gold);
      w.i32(e.respawnTimer);
      w.i32(e.attackTargetId);
      w.fixed(e.target.x);
      w.fixed(e.target.y);
    }
    return w.toBytes();
  }
```

(f) Update `restoreFromSnapshot()` to read `winnerTeam` + the new fields (still id-reuse; id-keyed create/remove arrives in Task 8). Replace its body:
```dart
  void restoreFromSnapshot(Uint8List bytes) {
    final r = ByteReader(bytes);
    final version = r.i32();
    if (version != kSnapshotVersion) {
      throw ArgumentError(
          'unsupported snapshot version $version (expected $kSnapshotVersion)');
    }
    tick = r.i32();
    final lo = r.u32();
    final hi = r.u32();
    _rng = DetRng.fromState(lo, hi);
    _winnerTeam = r.i32();
    final count = r.i32();
    for (var i = 0; i < count; i++) {
      final id = r.i32();
      r.i32(); // kind.index (stable; advance cursor)
      r.i32(); // teamId (stable)
      final e = _byId[id]!;
      e.pos = FVec2(r.fixed(), r.fixed());
      e.vel = FVec2(r.fixed(), r.fixed());
      e.hp = r.fixed();
      e.maxHp = r.fixed();
      e.attackCooldown = r.i32();
      e.gold = r.i32();
      e.respawnTimer = r.i32();
      e.attackTargetId = r.i32();
      e.target = FVec2(r.fixed(), r.fixed());
    }
  }
```

(g) Update `peekEntityPos()`'s skips to match the new per-entity layout (still throws on absent; nullable in Task 8). Replace its loop body to add the four field skips and the header `winnerTeam` skip:
```dart
  static FVec2 peekEntityPos(Uint8List bytes, int id) {
    final r = ByteReader(bytes);
    r.i32(); // version
    r.i32(); // tick
    r.u32(); // rng lo
    r.u32(); // rng hi
    r.i32(); // winnerTeam
    final count = r.i32();
    for (var i = 0; i < count; i++) {
      final eid = r.i32();
      r.i32(); // kind
      r.i32(); // team
      final pos = FVec2(r.fixed(), r.fixed());
      r.fixed(); r.fixed(); // vel
      r.fixed(); // hp
      r.fixed(); // maxHp
      r.i32(); // attackCooldown
      r.i32(); // gold
      r.i32(); // respawnTimer
      r.i32(); // attackTargetId
      r.fixed(); r.fixed(); // target
      if (eid == id) return pos;
    }
    throw ArgumentError('entity $id not in snapshot');
  }
```

(No change to `create()` this task — `Entity.maxHp` defaults to `hp`, so the existing 3 entities get maxHp 100/100/50 automatically.)

- [ ] **Step 4: Re-pin the goldens (per the Re-Pin Procedure near the top of this plan)**

Run the Re-Pin Procedure: `bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json` → confirm `PASS: byte-identical across native/js/wasm: <newhash>`; capture it into `smoke.golden`; read the new canonical hash from the failing `dart test packages/sim` output and update the `0xa00d6337` literal in **both** `simulation_test.dart` (`'pinned 300-tick canonical state hash'`) and `snapshot_test.dart` (`'canonicalBytes/hash unchanged (golden untouched)'`).

- [ ] **Step 5: Verify all green**

Run: `dart test packages/sim`
Expected: PASS (incl. the re-pinned hash tests + the new round-trip test).
Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json`
Expected: `PASS: byte-identical ...` then `PASS: matches golden ...`.

- [ ] **Step 6: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/simulation_test.dart \
        packages/sim/test/snapshot_test.dart tooling/replay_fixtures/smoke.json \
        tooling/replay_fixtures/smoke.golden
git commit -m "feat(sim)!: serialize combat fields + winnerTeam; re-pin goldens (combat-free anchor)"
```

---

## Task 4: Spawn cores + towers in `create()`; re-pin goldens (#2)

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/simulation_test.dart`
- Modify: `tooling/replay_fixtures/smoke.golden`

> Adds 6 static structure entities (2 cores + 4 towers). The entity set grows from 3 → 9 (count + new `kind.index` values change `canonicalBytes()` output), so re-pin again. The combat-free scenario stays combat-free (no combat logic yet; heroes move to their own inner towers; towers/cores are inert).

- [ ] **Step 1: Update the entity-set test**

In `packages/sim/test/simulation_test.dart`, replace the first test:
```dart
  test('starts with heroes, wanderer, cores and towers in id order', () {
    final sim = Simulation.create(const SimConfig(seed: 1337));
    expect(sim.entityIdsSorted, [0, 1, 2, 10, 11, 12, 13, 14, 15]);
    expect(sim.entity(10).kind, EntityKind.core);
    expect(sim.entity(12).kind, EntityKind.tower);
    expect(sim.entity(10).teamId, 0);
    expect(sim.entity(11).teamId, 1);
  });
```
(`EntityKind` is exported via `package:sim/sim.dart`; ensure the test imports it — add `import 'package:sim/sim.dart';` if the file only imports deep paths, or reference `EntityKind` through the existing imports.)

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/simulation_test.dart`
Expected: FAIL — `entityIdsSorted` is `[0, 1, 2]` (cores/towers not created yet) and the pinned-hash test fails again (entity set will change once implemented).

- [ ] **Step 3: Add structures to `create()`**

In `packages/sim/lib/src/simulation.dart`, replace the `entities` list literal inside `Simulation.create` with (uses the `data/combat.dart` constants imported in Task 3; `-kCoreX` etc. use `Fixed`'s unary minus):
```dart
    final entities = <Entity>[
      Entity(id: 0, kind: EntityKind.hero, teamId: 0,
          pos: FVec2(kHero0SpawnX, Fixed.zero), hp: kHeroMaxHp, maxHp: kHeroMaxHp),
      Entity(id: 1, kind: EntityKind.hero, teamId: 1,
          pos: FVec2(kHero1SpawnX, Fixed.zero), hp: kHeroMaxHp, maxHp: kHeroMaxHp),
      Entity(id: kWandererEntityId, kind: EntityKind.wanderer, teamId: 2,
          pos: FVec2.zero, hp: Fixed.fromInt(50), maxHp: Fixed.fromInt(50)),
      // Cores (back of each side; vulnerable only after both same-team towers fall).
      Entity(id: kCore0Id, kind: EntityKind.core, teamId: 0,
          pos: FVec2(-kCoreX, Fixed.zero), hp: kCoreMaxHp, maxHp: kCoreMaxHp),
      Entity(id: kCore1Id, kind: EntityKind.core, teamId: 1,
          pos: FVec2(kCoreX, Fixed.zero), hp: kCoreMaxHp, maxHp: kCoreMaxHp),
      // Outer towers (throat, nearer center).
      Entity(id: kOuterTower0Id, kind: EntityKind.tower, teamId: 0,
          pos: FVec2(-kOuterTowerX, Fixed.zero), hp: kOuterTowerMaxHp, maxHp: kOuterTowerMaxHp),
      Entity(id: kOuterTower1Id, kind: EntityKind.tower, teamId: 1,
          pos: FVec2(kOuterTowerX, Fixed.zero), hp: kOuterTowerMaxHp, maxHp: kOuterTowerMaxHp),
      // Inner towers (base mouth).
      Entity(id: kInnerTower0Id, kind: EntityKind.tower, teamId: 0,
          pos: FVec2(-kInnerTowerX, Fixed.zero), hp: kInnerTowerMaxHp, maxHp: kInnerTowerMaxHp),
      Entity(id: kInnerTower1Id, kind: EntityKind.tower, teamId: 1,
          pos: FVec2(kInnerTowerX, Fixed.zero), hp: kInnerTowerMaxHp, maxHp: kInnerTowerMaxHp),
    ];
```

- [ ] **Step 4: Re-pin the goldens (Re-Pin Procedure)**

Re-pin `smoke.golden` and the `0x...` literal in both test files exactly as in Task 3 Step 4 (the hash moved because the entity set grew).

- [ ] **Step 5: Verify all green**

Run: `dart test packages/sim`
Expected: PASS (entity-set test + re-pinned hashes).
Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json`
Expected: `PASS: byte-identical ...` then `PASS: matches golden ...`.

- [ ] **Step 6: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/simulation_test.dart \
        packages/sim/test/snapshot_test.dart tooling/replay_fixtures/smoke.golden
git commit -m "feat(sim): spawn 2 towers + core per team; re-pin goldens"
```

---

## Task 5: Hero locked-target combat (attack intent + pursue) + the `_applyDamage` chokepoint; `step()` returns `List<SimEvent>`

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/combat_test.dart`

> **Locked-target (LoL) model:** an `attack` intent locks the hero onto a target id (`attackTargetId`); each tick the hero **pursues** the locked target's position and **attacks only it** when in range. A `move` intent clears the lock. Heroes do **not** auto-acquire — an unlocked hero never attacks. The lock drops automatically when the target dies/becomes invalid.
> Golden-neutral: the combat-free anchor uses **move intents only**, so heroes are never locked → never attack there; the pinned hashes are unaffected (towers also never fire — heroes stay out of enemy range). `step()` now returns `List<SimEvent>`; all existing callers use it as a statement, so nothing else needs editing — confirm by running the full suite in Step 4.

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/combat_test.dart`:
```dart
  test('step() returns a List<SimEvent>', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final events = sim.step(0, const []);
    expect(events, isA<List<SimEvent>>());
  });

  test('unlocked adjacent heroes do NOT attack; locking deals damage + sets the lock', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(1).pos = FVec2(Fixed.fromInt(1), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const []); // neither locked -> no attack (manual-only)
    expect(sim.entity(1).hp.raw, kHeroMaxHp.raw);
    // Hero 0 right-clicks hero 1 -> attack intent (aimX = target entity id).
    final events = sim.step(1, const [
      Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1),
    ]);
    expect(sim.entity(0).attackTargetId, 1);
    expect(sim.entity(1).hp.toDouble(), lessThan(kHeroMaxHp.toDouble()));
    expect(events.whereType<DamageDealt>(), isNotEmpty);
  });

  test('a locked hero pursues an out-of-range target into range and hits it', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(6), Fixed.zero); // outside 3-range
    sim.entity(1).target = sim.entity(1).pos;
    const lock = Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1);
    for (var t = 0; t < 40; t++) {
      sim.step(t, const [lock]); // (incidental enemy-tower fire on hero 0 is harmless here)
    }
    expect(sim.entity(0).pos.x.toDouble(), greaterThan(0.0)); // pursued toward +x
    expect(sim.entity(1).hp.toDouble(), lessThan(kHeroMaxHp.toDouble())); // and hit it
  });

  test('a move intent clears the attack lock', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(1).pos = FVec2(Fixed.fromInt(1), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(sim.entity(0).attackTargetId, 1);
    sim.step(1, const [Intent(playerSlot: 0, type: IntentType.move, aimX: -655360, aimY: 0, seq: 2)]);
    expect(sim.entity(0).attackTargetId, -1); // move cleared the lock
  });

  test('attack respects the cooldown (one hit per cooldown window)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(1).pos = FVec2(Fixed.fromInt(1), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    const lock = Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1);
    sim.step(0, const [lock]); // hit (cooldown -> kHeroAttackCooldownTicks)
    final hpAfterFirst = sim.entity(1).hp.raw;
    sim.step(1, const [lock]); // on cooldown -> no new damage
    expect(sim.entity(1).hp.raw, hpAfterFirst);
  });

  test('a hero cannot lock the neutral wanderer (lock dropped, no damage)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(kWandererEntityId).pos = const FVec2(Fixed.zero, Fixed.zero); // on top of hero
    final hpBefore = sim.entity(kWandererEntityId).hp.raw;
    sim.step(0, const [
      Intent(playerSlot: 0, type: IntentType.attack, aimX: kWandererEntityId, seq: 1),
    ]);
    expect(sim.entity(kWandererEntityId).hp.raw, hpBefore); // wanderer never a target
    expect(sim.entity(0).attackTargetId, -1); // invalid lock dropped
  });
```
(`Intent`/`IntentType`/`Fixed`/`FVec2`/`DamageDealt`/`kWandererEntityId` are all exported from `package:sim/sim.dart` + `data/combat.dart`.)

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: FAIL — `step()` returns `void` ("This expression has type 'void' and can't be used") and no damage is applied.

- [ ] **Step 3: Implement combat in `step()`**

In `packages/sim/lib/src/simulation.dart`, change `step`'s signature and body. Replace the whole `step(...)` method:
```dart
  /// Advance one fixed tick. Returns cosmetic-only events (never mutate state).
  List<SimEvent> step(int currentTick, List<Intent> intents) {
    tick = currentTick;
    final events = <SimEvent>[];

    // 1. Apply intents (canonical order; downed heroes ignore input).
    //    move   -> set the move target AND clear the attack lock.
    //    attack -> set the attack lock to the target entity id (carried in aimX).
    final ordered = [...intents]..sort((a, b) =>
        a.playerSlot != b.playerSlot ? a.playerSlot - b.playerSlot : a.seq - b.seq);
    for (final it in ordered) {
      if (it.playerSlot < 0 || it.playerSlot >= 2) continue;
      final hero = _byId[it.playerSlot]!;
      if (hero.respawnTimer != 0) continue; // downed: ignore input
      if (it.type == IntentType.move) {
        hero.target = FVec2(Fixed.raw(it.aimX), Fixed.raw(it.aimY));
        hero.attackTargetId = -1;
      } else if (it.type == IntentType.attack) {
        hero.attackTargetId = it.aimX; // aimX carries the target entity id
      }
    }

    // 2. Resolve pursue: a hero locked onto a valid enemy seeks its position;
    //    an invalid lock is dropped and the hero holds.
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      if (e.attackTargetId == -1) continue;
      final tgt = _byId[e.attackTargetId];
      if (tgt == null || !_isAttackable(e, tgt)) {
        e.attackTargetId = -1;
        e.target = e.pos; // hold position
      } else {
        e.target = tgt.pos; // pursue the locked target
      }
    }

    // 3. Hero movement (alive heroes seek their resolved target).
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      e.pos = FVec2(
        _stepToward(e.pos.x, e.target.x, _kHeroStep),
        _stepToward(e.pos.y, e.target.y, _kHeroStep),
      );
    }

    // 4. Combat: cooldowns + instantaneous damage (heroes hit only their lock).
    _stepCombat(events);

    // 5. The wanderer drifts LAST — keeps the RNG through the gate every tick.
    final w = _byId[kWandererEntityId]!;
    final dx = _rng.nextInt(3) - 1; // -1, 0, +1
    final dy = _rng.nextInt(3) - 1;
    w.pos = FVec2(
      w.pos.x + Fixed.fromInt(dx) * _kWanderStep,
      w.pos.y + Fixed.fromInt(dy) * _kWanderStep,
    );

    return events;
  }
```

Add the combat helpers as private methods on `Simulation` (place them after `_stepToward`):
```dart
  void _stepCombat(List<SimEvent> events) {
    // Tick cooldowns down for every combatant first.
    for (final e in _entities) {
      if (e.attackCooldown > 0) e.attackCooldown -= 1;
    }
    // Heroes attack ONLY their locked target, in ascending-id order. Pursue
    // (step 2) has already closed distance; here we just fire when in range.
    for (final id in entityIdsSorted) {
      final e = _byId[id]!;
      if (e.kind != EntityKind.hero || e.respawnTimer != 0 || e.hp.raw <= 0) continue;
      if (e.attackCooldown > 0 || e.attackTargetId == -1) continue;
      final tgt = _byId[e.attackTargetId];
      if (tgt == null || !_isAttackable(e, tgt)) continue;
      if ((tgt.pos - e.pos).lengthSq() > kHeroAttackRangeSq) continue; // not yet in range
      _applyDamage(e, tgt, kHeroAttackDamage, events);
      e.attackCooldown = kHeroAttackCooldownTicks;
    }
  }

  /// Is `c` a valid attack target for attacker `a`?
  bool _isAttackable(Entity a, Entity c) {
    if (identical(a, c) || c.hp.raw <= 0) return false;
    switch (c.kind) {
      case EntityKind.hero:
        return c.teamId != a.teamId && c.respawnTimer == 0;
      case EntityKind.creep:
        return true; // neutral fodder — last-hittable by either hero
      case EntityKind.tower:
      case EntityKind.core:
        return false; // structures become attackable in Task 6 (vulnerability gate)
      case EntityKind.wanderer:
        return false; // pure RNG probe — never a combat target
    }
  }

  /// The single damage chokepoint. Plan 4 wraps this to add elemental flavor +
  /// reaction multipliers. Clamps hp to [0, maxHp]; returns true if lethal.
  bool _applyDamage(Entity source, Entity target, Fixed amount, List<SimEvent> events) {
    if (target.hp.raw <= 0) return false;
    var hp = target.hp - amount;
    if (hp.raw < 0) hp = Fixed.zero;
    target.hp = hp;
    events.add(DamageDealt(
        sourceId: source.id, targetId: target.id, amountRaw: amount.raw));
    return hp.raw <= 0;
  }
```

- [ ] **Step 4: Run tests + full suite to verify it passes**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: PASS (the 6 new locked-target combat tests + the earlier combat-constant tests).
Run: `dart test packages/sim && dart test packages/netcode && dart test packages/protocol && dart test apps/server`
Expected: PASS everywhere — the pinned goldens are unchanged (combat-free anchor uses move intents only → no locks → no attacks) and all `step()` callers ignore the new return value.

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/combat_test.dart
git commit -m "feat(sim): hero locked-target combat (attack intent + pursue) + applyDamage chokepoint + SimEvent return"
```

---

## Task 6: Tower combat + ordered (outer→inner→core) vulnerability gating + structure death

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/combat_test.dart`

> Golden-neutral (combat-free anchor: heroes never enter enemy tower range). Adds: towers auto-attack enemy heroes; heroes may now target *vulnerable* enemy structures; ordered gating (inner invulnerable until outer falls, core until both towers fall); structures despawn on death, emitting `TowerDestroyed{killerId}` (the revenge-boss hook).

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/combat_test.dart`:
```dart
  test('outer tower is vulnerable; inner is not until outer falls; core last', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    expect(sim.isStructureVulnerable(sim.entity(kOuterTower1Id)), isTrue);
    expect(sim.isStructureVulnerable(sim.entity(kInnerTower1Id)), isFalse);
    expect(sim.isStructureVulnerable(sim.entity(kCore1Id)), isFalse);
  });

  test('a hero attacks a vulnerable enemy outer tower in range', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Put hero 0 next to team1 outer tower (+4,0).
    sim.entity(0).pos = FVec2(Fixed.fromInt(3), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero); // keep opp away
    sim.entity(1).target = sim.entity(1).pos;
    // Hero 0 right-clicks (locks) the enemy outer tower.
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kOuterTower1Id, seq: 1)]);
    expect(sim.entity(kOuterTower1Id).hp.toDouble(), lessThan(kOuterTowerMaxHp.toDouble()));
  });

  test('a tower shoots an enemy hero in range', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Hero 1 stands next to team0 outer tower (-4,0); keep hero 0 far.
    sim.entity(1).pos = FVec2(Fixed.fromInt(-3), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(sim.entity(1).hp.toDouble(), lessThan(kHeroMaxHp.toDouble()));
  });

  test('destroying the outer tower despawns it, opens the inner, emits TowerDestroyed', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final tower = sim.entity(kOuterTower1Id);
    tower.hp = Fixed.fromInt(10); // one hero hit kills it
    sim.entity(0).pos = FVec2(Fixed.fromInt(3), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    // Hero 0 locks the 10-hp outer tower; one hit kills it this tick.
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kOuterTower1Id, seq: 1)]);
    expect(sim.entityIdsSorted.contains(kOuterTower1Id), isFalse); // despawned
    expect(sim.isStructureVulnerable(sim.entity(kInnerTower1Id)), isTrue);
    final td = events.whereType<TowerDestroyed>().single;
    expect(td.towerId, kOuterTower1Id);
    expect(td.killerId, 0);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: FAIL — `isStructureVulnerable` is not defined; towers deal/take no damage; the tower is not despawned.

- [ ] **Step 3: Implement tower combat, gating, and structure death**

In `packages/sim/lib/src/simulation.dart`:

(a) Make structure targeting live for heroes — in `_isAttackable` (from Task 5), change the tower/core case so a hero can lock a *vulnerable* enemy structure:
```dart
      case EntityKind.tower:
      case EntityKind.core:
        return c.teamId != a.teamId && isStructureVulnerable(c);
```

(b) Add the public vulnerability query + a tower attack pass. Add `isStructureVulnerable` (public — the server/tests read it) and extend `_stepCombat`:
```dart
  /// Ordered gating: outer towers always vulnerable; an inner tower only after
  /// its team's outer tower is gone; a core only after BOTH its towers are gone.
  bool isStructureVulnerable(Entity e) {
    if (e.kind == EntityKind.tower) {
      final isInner = e.id == kInnerTower0Id || e.id == kInnerTower1Id;
      if (!isInner) return true; // outer
      final outerId = e.teamId == 0 ? kOuterTower0Id : kOuterTower1Id;
      return !_byId.containsKey(outerId);
    }
    if (e.kind == EntityKind.core) {
      final outerId = e.teamId == 0 ? kOuterTower0Id : kOuterTower1Id;
      final innerId = e.teamId == 0 ? kInnerTower0Id : kInnerTower1Id;
      return !_byId.containsKey(outerId) && !_byId.containsKey(innerId);
    }
    return true; // heroes/creeps always damageable
  }
```
Then in `_stepCombat`, after the hero attack loop and before it returns, add a tower attack loop and a structure-death sweep:
```dart
    // Towers fire at the nearest enemy hero in range.
    for (final id in entityIdsSorted) {
      final e = _byId[id]!;
      if (e.kind != EntityKind.tower || e.attackCooldown > 0 || e.hp.raw <= 0) continue;
      final target = _acquireTowerTarget(e);
      if (target == null) continue;
      _applyDamage(e, target, kTowerAttackDamage, events);
      e.attackCooldown = kTowerAttackCooldownTicks;
    }
    // Despawn dead structures (towers/cores). Heroes (Task 7) and creeps
    // (Task 9) are handled by their own systems.
    _sweepDeadStructures(events);
```
Add the tower acquisition + death sweep helpers:
```dart
  Entity? _acquireTowerTarget(Entity tower) {
    Entity? best;
    Fixed bestSq = Fixed.zero;
    for (final id in entityIdsSorted) {
      final c = _byId[id]!;
      if (c.kind != EntityKind.hero) continue;
      if (c.teamId == tower.teamId || c.respawnTimer != 0 || c.hp.raw <= 0) continue;
      final dsq = (c.pos - tower.pos).lengthSq();
      if (dsq > kTowerAttackRangeSq) continue;
      if (best == null || dsq < bestSq) {
        best = c;
        bestSq = dsq;
      }
    }
    return best;
  }

  void _sweepDeadStructures(List<SimEvent> events) {
    final dead = <Entity>[];
    for (final e in _entities) {
      if ((e.kind == EntityKind.tower || e.kind == EntityKind.core) && e.hp.raw <= 0) {
        dead.add(e);
      }
    }
    for (final e in dead) {
      if (e.kind == EntityKind.tower) {
        events.add(TowerDestroyed(
            towerId: e.id, teamId: e.teamId, killerId: _lastDamagerOf(e.id)));
      }
      _removeEntity(e.id);
    }
  }
```
To attribute the killer ("debtor") deterministically, track the last damager per entity. Add a field + record it in `_applyDamage`:
```dart
  // Last source id to damage each entity this tick-range (for kill credit /
  // the revenge-boss "debtor"). Transient; not serialized (kill is resolved the
  // same tick the lethal hit lands, so it never needs to survive a snapshot).
  final Map<int, int> _lastDamager = {};
```
In `_applyDamage`, after computing `target.hp = hp;` add: `_lastDamager[target.id] = source.id;` and add the reader:
```dart
  int _lastDamagerOf(int id) => _lastDamager[id] ?? -1;
```
Add the removal helper (keeps `_entities`, `_byId`, and `_lastDamager` consistent):
```dart
  void _removeEntity(int id) {
    _entities.removeWhere((e) => e.id == id);
    _byId.remove(id);
    _lastDamager.remove(id);
  }
```

> Note: `_lastDamager` is intentionally **not** serialized — kill credit is resolved on the same tick the lethal hit lands (the death sweep runs immediately after the attack loops in `_stepCombat`), so it never needs to survive a snapshot. This keeps the byte layout unchanged.

(c) **Retune the netcode integration tests combat-free.** This is the task where towers start firing, so the `packages/netcode/test/netcode_integration_test.dart` scenarios — which currently drive the **local** hero (slot 0) toward center/+x into the team-1 outer tower's range (x=+4, range 6) — would now take tower fire, die, and respawn (an ~8-unit position jump) and break the `correction == 0` / `< 0.5` invariants. Retune every **local-hero** `applyLocalInput` so the local hero moves onto its OWN (left) half, staying ≥6 units left of the enemy outer tower at +4 (local-hero target x ≤ −2; it starts at −8). Concretely:
> - Replace each local `applyLocalInput(655360, ...)` (→ +10) with `applyLocalInput(-655360, ...)` (→ −10). (Cases 1, 3, 4, 8, 9.)
> - Replace local center/right aimX values used in `applyLocalInput` — `Fixed.fromInt(0).raw`, `0`, `32768` — with `Fixed.fromInt(-12).raw` (single-target cases 2, 7) or, for the two-target alternations, `aimA = Fixed.fromInt(-10).raw` / `aimB = Fixed.fromInt(-12).raw` (Cases 2b, 3). These stay distinct (so unacked inputs still accumulate) and combat-free.
> - In **Case 4**, the hero now moves LEFT: flip its final assertion `expect(clientPos.x.raw, greaterThan(Fixed.fromInt(-8).raw), reason: '...moved right...')` to `lessThan(...)` with reason `'hero should have moved left despite dropped first input'`.
> - Leave **Case 7's opponent** aim (`oppAimX = Fixed.fromInt(100).raw`) unchanged — the opponent (slot 1) moving right goes AWAY from team-0's towers, so it stays combat-free; Case 7 only asserts `view.opponent.x`.
> Update the now-stale "moves right"/"toward (0,0)"/"x=8" comments accordingly. The opponent never enters the local team's tower range, no creeps spawn before tick 450 (every case runs < 450 server ticks), and the two heroes stay ≥18 units apart — so all cases are combat-free and the existing invariants hold.

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: PASS (4 new tower/gating tests + earlier).
Run: `dart test packages/sim && dart test packages/netcode`
Expected: PASS — sim pinned goldens still green (the anchor never enters tower range); netcode correction invariants still hold (integration scenarios retuned combat-free).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/combat_test.dart \
        packages/netcode/test/netcode_integration_test.dart
git commit -m "feat(sim): tower combat + ordered structure gating + TowerDestroyed"
```

---

## Task 7: Hero death + fixed-timer respawn

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/combat_test.dart`

> Golden-neutral (no hero dies in the anchor). On lethal damage a hero is **downed** (hp 0, `respawnTimer = kHeroRespawnTicks`, parked at its spawn, untargetable, ignores intents); when the timer elapses it respawns at full hp. Keeping the hero entity present (never removed) means `peekEntityPos(opponentId)` always resolves — no netcode crash.

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/combat_test.dart`:
```dart
  test('a hero reduced to 0 hp is downed and respawns after the timer', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.hp = Fixed.fromInt(5); // next hit is lethal
    sim.entity(0).pos = const FVec2(Fixed.zero, Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    h.pos = FVec2(Fixed.fromInt(1), Fixed.zero);
    h.target = h.pos;
    sim.step(0, const []);
    expect(h.respawnTimer, kHeroRespawnTicks);
    expect(h.hp.raw, 0);
    // Hero id stays present (peekEntityPos must never miss it).
    expect(sim.entityIdsSorted.contains(1), isTrue);
    // Run out the timer; respawns at full hp at its spawn x.
    for (var t = 1; t <= kHeroRespawnTicks; t++) {
      sim.step(t, const []);
    }
    expect(sim.entity(1).respawnTimer, 0);
    expect(sim.entity(1).hp.raw, kHeroMaxHp.raw);
    expect(sim.entity(1).pos.x.raw, kHero1SpawnX.raw);
  });

  test('a downed hero is not a valid target and does not attack', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h0 = sim.entity(0);
    h0.respawnTimer = 10;
    h0.hp = Fixed.zero;
    h0.pos = const FVec2(Fixed.zero, Fixed.zero);
    final h1 = sim.entity(1);
    h1.pos = FVec2(Fixed.fromInt(1), Fixed.zero);
    h1.target = h1.pos;
    sim.step(0, const []);
    expect(h1.hp.raw, kHeroMaxHp.raw); // downed h0 dealt no damage
    expect(h0.hp.raw, 0); // untargetable: took none either (hp already 0)
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: FAIL — a 0-hp hero is not converted to a respawn; `respawnTimer` stays 0.

- [ ] **Step 3: Implement death/respawn**

In `packages/sim/lib/src/simulation.dart`, add a hero-death + respawn pass. In `_stepCombat`, after `_sweepDeadStructures(events);`, add `_sweepDeadHeroes();`. Then add a respawn-tick pass. Put the respawn tick at the very start of `_stepCombat` (so a respawning hero counts down each tick) — add before the cooldown loop:
```dart
    // Respawn timers count down; a hero whose timer hits 0 returns at full hp.
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer == 0) continue;
      e.respawnTimer -= 1;
      if (e.respawnTimer == 0) {
        e.hp = e.maxHp;
        final spawnX = e.teamId == 0 ? kHero0SpawnX : kHero1SpawnX;
        e.pos = FVec2(spawnX, Fixed.zero);
        e.target = e.pos;
        e.attackCooldown = 0;
      }
    }
```
Add the hero-death sweep helper (downs, does NOT remove):
```dart
  void _sweepDeadHeroes() {
    for (final e in _entities) {
      if (e.kind != EntityKind.hero || e.respawnTimer != 0) continue;
      if (e.hp.raw > 0) continue;
      e.respawnTimer = kHeroRespawnTicks;
      final spawnX = e.teamId == 0 ? kHero0SpawnX : kHero1SpawnX;
      e.pos = FVec2(spawnX, Fixed.zero); // park at base while downed
      e.target = e.pos;
    }
  }
```

> Ordering note for the executor: within `_stepCombat` the order is **respawn-countdown → cooldowns → hero attacks → tower attacks → structure death sweep → hero death sweep**. A hero downed this tick is parked immediately; it was already excluded from attacking (the attack loop checks `respawnTimer != 0 || hp <= 0`) and from being targeted (`_isAttackable` / `_acquireTowerTarget` check `respawnTimer` and `hp`).

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: PASS (2 new respawn tests + earlier).
Run: `dart test packages/sim`
Expected: PASS (goldens green).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/combat_test.dart
git commit -m "feat(sim): hero death + fixed-timer respawn (keeps hero ids stable)"
```

---

## Task 8: Neutral creep waves + id-keyed snapshot reconcile + nullable `peekEntityPos`

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/combat_test.dart`, `packages/sim/test/snapshot_test.dart`
- Modify: `packages/netcode/lib/src/match_controller.dart`

> Golden-neutral (first wave is at tick 450; the 300-tick anchor spawns none). Creeps are **neutral, passive** last-hit fodder (no movement, no attack) spawned in waves with **tick-derived ids** (no stored counter). This is the first system that adds/removes entities mid-match, so `restoreFromSnapshot` becomes an **id-keyed reconcile** (create entities present in the snapshot but missing locally; remove locals absent from it) and `peekEntityPos` becomes nullable (an entity may have despawned).

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/combat_test.dart`:
```dart
  test('a creep wave spawns at the first-wave tick with deterministic ids', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final creepIds = sim.entityIdsSorted.where((id) => id >= kCreepIdBase).toList();
    expect(creepIds, [for (var i = 0; i < kCreepsPerWave; i++) kCreepIdBase + i]);
    expect(sim.entity(kCreepIdBase).kind, EntityKind.creep);
    expect(sim.entity(kCreepIdBase).teamId, 2); // neutral
  });

  test('id-keyed reconcile creates and removes entities to match the snapshot', () {
    final withWave = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      withWave.step(t, const []);
    }
    final noWave = Simulation.create(const SimConfig(seed: 1))..step(0, const []);
    // (a) restoring the with-wave snapshot CREATES the creeps locally.
    noWave.restoreFromSnapshot(withWave.snapshotBytes());
    expect(noWave.entityIdsSorted, withWave.entityIdsSorted);
    expect(noWave.canonicalStateHash(), withWave.canonicalStateHash());
    // (b) restoring an early (no-creep) snapshot REMOVES them again.
    final early = Simulation.create(const SimConfig(seed: 1))..step(0, const []);
    noWave.restoreFromSnapshot(early.snapshotBytes());
    expect(noWave.entityIdsSorted.any((id) => id >= kCreepIdBase), isFalse);
  });
```

In `packages/sim/test/snapshot_test.dart`, update the `peekEntityPos` test for the nullable return + add an absent-id case:
```dart
  test('peekEntityPos reads an entity pos from snapshot bytes; null if absent', () {
    final src = _run(60);
    final bytes = src.snapshotBytes();
    final p1 = Simulation.peekEntityPos(bytes, 1)!;
    expect(p1.x.raw, src.entity(1).pos.x.raw);
    expect(p1.y.raw, src.entity(1).pos.y.raw);
    expect(Simulation.peekEntityPos(bytes, 99999), isNull); // never spawned
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/combat_test.dart packages/sim/test/snapshot_test.dart`
Expected: FAIL — no creeps spawn; `peekEntityPos(..., 99999)` throws instead of returning null.

- [ ] **Step 3: Implement waves, id-keyed reconcile, nullable peek**

In `packages/sim/lib/src/simulation.dart`:

(a) In `step()`, add a wave-spawn call right before `_stepCombat(events);`:
```dart
    // 2b. Spawn the periodic neutral creep wave (deterministic, idempotent).
    _maybeSpawnWave(currentTick);
```
Add the helper:
```dart
  void _maybeSpawnWave(int currentTick) {
    if (currentTick < kFirstWaveTick) return;
    if ((currentTick - kFirstWaveTick) % kWaveIntervalTicks != 0) return;
    final waveIndex = (currentTick - kFirstWaveTick) ~/ kWaveIntervalTicks;
    for (var i = 0; i < kCreepsPerWave; i++) {
      final id = kCreepIdBase + waveIndex * kCreepsPerWave + i;
      if (_byId.containsKey(id)) continue; // idempotent across reconcile re-steps
      final offset = kCreepSpawnSpacing * Fixed.fromInt(i - (kCreepsPerWave ~/ 2));
      final e = Entity(
        id: id,
        kind: EntityKind.creep,
        teamId: 2, // neutral
        pos: FVec2(offset, Fixed.zero),
        hp: kCreepMaxHp,
        maxHp: kCreepMaxHp,
      );
      _entities.add(e);
      _byId[id] = e;
    }
  }
```

(b) Replace `restoreFromSnapshot()` with the id-keyed reconcile:
```dart
  void restoreFromSnapshot(Uint8List bytes) {
    final r = ByteReader(bytes);
    final version = r.i32();
    if (version != kSnapshotVersion) {
      throw ArgumentError(
          'unsupported snapshot version $version (expected $kSnapshotVersion)');
    }
    tick = r.i32();
    final lo = r.u32();
    final hi = r.u32();
    _rng = DetRng.fromState(lo, hi);
    _winnerTeam = r.i32();
    final count = r.i32();
    final seen = <int>{};
    for (var i = 0; i < count; i++) {
      final id = r.i32();
      final kindIndex = r.i32();
      final teamId = r.i32();
      final pos = FVec2(r.fixed(), r.fixed());
      final vel = FVec2(r.fixed(), r.fixed());
      final hp = r.fixed();
      final maxHp = r.fixed();
      final cooldown = r.i32();
      final gold = r.i32();
      final respawn = r.i32();
      final attackTargetId = r.i32();
      final target = FVec2(r.fixed(), r.fixed());
      seen.add(id);
      var e = _byId[id];
      if (e == null) {
        // Present on the authority but not locally — spawn it (id/kind/team
        // are immutable, so set via constructor).
        e = Entity(
          id: id,
          kind: EntityKind.values[kindIndex],
          teamId: teamId,
          pos: pos,
          hp: hp,
          maxHp: maxHp,
        );
        _entities.add(e);
        _byId[id] = e;
      }
      e.pos = pos;
      e.vel = vel;
      e.hp = hp;
      e.maxHp = maxHp;
      e.attackCooldown = cooldown;
      e.gold = gold;
      e.respawnTimer = respawn;
      e.attackTargetId = attackTargetId;
      e.target = target;
    }
    // Drop entities absent from the snapshot (despawned on the authority).
    _entities.removeWhere((e) => !seen.contains(e.id));
    _byId.removeWhere((id, e) => !seen.contains(id));
    _lastDamager.clear();
  }
```

(c) Make `peekEntityPos` nullable (return `null` for an absent id instead of throwing):
```dart
  static FVec2? peekEntityPos(Uint8List bytes, int id) {
```
and replace the final `throw ArgumentError('entity $id not in snapshot');` with:
```dart
    return null; // not in snapshot (despawned / never spawned) — caller holds last
```

(d) In `packages/netcode/lib/src/match_controller.dart`, null-guard the opponent peek in `onServerSnapshot`:
```dart
    final opp = Simulation.peekEntityPos(snap.stateBytes, 1 - localSlot);
    if (opp != null) {
      _interp.add(snap.serverTick, opp.x.toDouble(), opp.y.toDouble());
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim && dart test packages/netcode`
Expected: PASS (new wave + reconcile + peek tests; pinned goldens green — anchor < tick 450; netcode steady-state correction still 0).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/combat_test.dart \
        packages/sim/test/snapshot_test.dart packages/netcode/lib/src/match_controller.dart
git commit -m "feat(sim): neutral creep waves + id-keyed snapshot reconcile + nullable peek"
```

---

## Task 9: Last-hit gold + creep death + `CreepKilled`

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/combat_test.dart`

> Golden-neutral. On a killing blow, credit the **killer hero's** `gold` by victim type (creep 18, outer tower 200, inner tower 300 — spec §6 last-hit values), emit `CreepKilled`, and despawn dead creeps. Last-hit only — no bounties/streak/comeback (deferred). Tower gold is credited in the structure-death sweep (Task 6) now that gold exists.

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/combat_test.dart`:
```dart
  test('last-hitting a creep credits the killer hero gold and despawns it', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final creep = sim.entity(kCreepIdBase);
    creep.hp = Fixed.fromInt(5); // next hero hit is lethal
    final hero = sim.entity(0);
    hero.pos = creep.pos; // in range
    hero.target = hero.pos;
    hero.attackCooldown = 0;
    final goldBefore = hero.gold;
    // Hero 0 right-clicks (locks) the creep; the lethal hit lands this tick.
    final events = sim.step(kFirstWaveTick + 1,
        const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kCreepIdBase, seq: 1)]);
    expect(hero.gold, goldBefore + kCreepGold);
    expect(sim.entityIdsSorted.contains(kCreepIdBase), isFalse); // despawned
    final ck = events.whereType<CreepKilled>().single;
    expect(ck.creepId, kCreepIdBase);
    expect(ck.killerId, 0);
    expect(ck.gold, kCreepGold);
  });

  test('destroying an enemy outer tower credits 200 gold to the killer', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(kOuterTower1Id).hp = Fixed.fromInt(5);
    final hero = sim.entity(0);
    hero.pos = FVec2(Fixed.fromInt(3), Fixed.zero); // next to team1 outer (+4)
    hero.target = hero.pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: kOuterTower1Id, seq: 1)]);
    expect(sim.entity(0).gold, kOuterTowerGold);
  });

  test('a hero last-hits a full 60-hp creep via real attack cadence (no shortcut)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    // Relocate the creep + hero 0 to a TOWER-SAFE spot on team 0's own side
    // (x=-8 is >6 from every enemy tower at +4/+10/+14, and own towers never
    // fire on own heroes), so ONLY the hero's auto-attack cadence kills it.
    final creep = sim.entity(kCreepIdBase);
    creep.pos = FVec2(Fixed.fromInt(-8), Fixed.zero);
    final hero = sim.entity(0);
    hero.pos = creep.pos;
    hero.target = hero.pos;
    hero.attackTargetId = kCreepIdBase; // lock the creep (persists across ticks)
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    var t = kFirstWaveTick + 1;
    while (sim.entityIdsSorted.contains(kCreepIdBase) && t < kFirstWaveTick + 200) {
      sim.step(t, const []);
      t++;
    }
    expect(sim.entityIdsSorted.contains(kCreepIdBase), isFalse); // died to real DPS
    expect(sim.entity(0).gold, kCreepGold); // 60hp / 8dmg = 8 hits, credited once
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: FAIL — gold stays 0; no `CreepKilled`; creep not despawned.

- [ ] **Step 3: Implement last-hit gold + creep death**

In `packages/sim/lib/src/simulation.dart`:

(a) Add a creep-death sweep. In `_stepCombat`, after `_sweepDeadHeroes();`, add `_sweepDeadCreeps(events);`. Add the helper:
```dart
  void _sweepDeadCreeps(List<SimEvent> events) {
    final dead = <Entity>[];
    for (final e in _entities) {
      if (e.kind == EntityKind.creep && e.hp.raw <= 0) dead.add(e);
    }
    for (final e in dead) {
      final killerId = _lastDamagerOf(e.id);
      _creditGold(killerId, kCreepGold);
      events.add(CreepKilled(creepId: e.id, killerId: killerId, gold: kCreepGold));
      _removeEntity(e.id);
    }
  }

  /// Credit gold to a hero by id (no-op if the killer isn't a live hero, e.g. a
  /// tower last-hit a creep). Gold is a plain int running total.
  void _creditGold(int heroId, int amount) {
    final e = _byId[heroId];
    if (e != null && e.kind == EntityKind.hero) e.gold += amount;
  }
```

(b) Credit tower gold in the structure-death sweep. In `_sweepDeadStructures` (Task 6), where a tower is destroyed, credit the killer before removal:
```dart
    for (final e in dead) {
      if (e.kind == EntityKind.tower) {
        final killerId = _lastDamagerOf(e.id);
        final isInner = e.id == kInnerTower0Id || e.id == kInnerTower1Id;
        _creditGold(killerId, isInner ? kInnerTowerGold : kOuterTowerGold);
        events.add(TowerDestroyed(towerId: e.id, teamId: e.teamId, killerId: killerId));
      }
      _removeEntity(e.id);
    }
```
(Replace the Task-6 `dead` loop body with this; the `TowerDestroyed` emission moves inside.)

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim/test/combat_test.dart`
Expected: PASS (2 new gold tests + earlier).
Run: `dart test packages/sim`
Expected: PASS (goldens green).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/combat_test.dart
git commit -m "feat(sim): last-hit gold + creep death + CreepKilled (tower gold credited)"
```

---

## Task 10: Destroy-core win condition → `MatchEndMsg(coreDestroyed, winnerSlot)` + server wiring

**Files:**
- Modify: `packages/sim/lib/src/simulation.dart`
- Modify: `packages/sim/test/combat_test.dart`
- Modify: `packages/protocol/lib/src/messages.dart`, `packages/protocol/lib/src/codec.dart`
- Modify: `packages/protocol/test/codec_test.dart`
- Modify: `apps/server/lib/src/loop/match.dart`
- Modify: `apps/server/test/match_test.dart`

> Golden-neutral on the sim side (no core dies in the anchor). When a **vulnerable** core reaches 0 hp, the sim sets `winnerTeam` (= the enemy team) and emits `CoreDestroyed`. The authoritative server reads `_sim.winnerTeam` after each `step()` and ends the match symmetrically to the disconnect path — but notifies **both** players with a winner. `EndReason.coreDestroyed` and `MatchEndMsg.winnerSlot` are append-only/additive wire changes.

- [ ] **Step 1: Write the failing tests**

Append to `packages/sim/test/combat_test.dart`:
```dart
  test('destroying a vulnerable enemy core sets winnerTeam and emits CoreDestroyed', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    // Remove team1 towers (zero hp -> swept) so the core is exposed.
    sim.entity(kOuterTower1Id).hp = Fixed.zero;
    sim.entity(kInnerTower1Id).hp = Fixed.zero;
    sim.entity(kCore1Id).hp = Fixed.fromInt(5);
    // Hero 0 stands next to team1 core (+14,0); keep opponent far.
    sim.entity(0).pos = FVec2(Fixed.fromInt(13), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    expect(sim.winnerTeam, -1);
    // Hero 0 right-clicks (locks) the core. The hp-0 towers are swept on tick 0;
    // the lock re-applies each tick and the core dies once it becomes vulnerable.
    const lockCore = Intent(playerSlot: 0, type: IntentType.attack, aimX: kCore1Id, seq: 1);
    SimEvent? core;
    for (var t = 0; t < 5 && sim.winnerTeam == -1; t++) {
      for (final e in sim.step(t, const [lockCore])) {
        if (e is CoreDestroyed) core = e;
      }
    }
    expect(sim.winnerTeam, 0); // team 0 destroyed team 1's core
    expect((core! as CoreDestroyed).teamId, 1);
    expect(sim.entityIdsSorted.contains(kCore1Id), isFalse);
  });
```

Append to `packages/protocol/test/codec_test.dart`:
```dart
  test('MatchEndMsg round-trips reason + winnerSlot', () {
    final m = roundTrip(const MatchEndMsg(reason: EndReason.coreDestroyed, winnerSlot: 1));
    expect(m.reason, EndReason.coreDestroyed);
    expect(m.winnerSlot, 1);
  });

  test('MatchEndMsg winnerSlot defaults to -1', () {
    final m = roundTrip(const MatchEndMsg(reason: EndReason.opponentLeft));
    expect(m.winnerSlot, -1);
  });
```

Append to `apps/server/test/match_test.dart`:
```dart
  test('core destroyed ends the match and notifies BOTH players with the winner', () {
    final driver = FakeTickDriver();
    final p0 = FakePlayerConn(), p1 = FakePlayerConn();
    // Inject a sim with team1's core exposed + nearly dead, hero 0 adjacent.
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(kOuterTower1Id).hp = Fixed.zero;
    sim.entity(kInnerTower1Id).hp = Fixed.zero;
    sim.entity(kCore1Id).hp = Fixed.fromInt(5);
    sim.entity(0).pos = FVec2(Fixed.fromInt(13), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    var endedCb = false;
    final match = Match(seed: 1, sim: sim, driver: driver)
      ..addPlayer(0, p0)
      ..addPlayer(1, p1)
      ..onEnded = () => endedCb = true;
    match.start();
    // Hero 0 right-clicks (locks) the enemy core; the held intent persists each
    // tick, re-establishing the lock after the (hp-0) towers are swept on tick 0.
    p0.receive(ProtocolCodec.encode(InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: kCore1Id, aimY: 0,
        type: IntentType.attack.index)));
    driver.pump(5);

    expect(match.ended, isTrue);
    expect(endedCb, isTrue);
    for (final p in [p0, p1]) {
      final end = p.sent.map(ProtocolCodec.decode).whereType<MatchEndMsg>().single;
      expect(end.reason, EndReason.coreDestroyed);
      expect(end.winnerSlot, 0);
    }
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/sim/test/combat_test.dart packages/protocol/test/codec_test.dart apps/server/test/match_test.dart`
Expected: FAIL — `winnerTeam` never leaves -1; `MatchEndMsg.winnerSlot` / `EndReason.coreDestroyed` undefined; `Match(... sim: ...)` not a parameter.

- [ ] **Step 3: Implement**

(a) Sim — set winner on core death. In `packages/sim/lib/src/simulation.dart`, replace the `_sweepDeadStructures` `dead` loop body to handle cores (extends the Task-9 version):
```dart
    for (final e in dead) {
      if (e.kind == EntityKind.tower) {
        final killerId = _lastDamagerOf(e.id);
        final isInner = e.id == kInnerTower0Id || e.id == kInnerTower1Id;
        _creditGold(killerId, isInner ? kInnerTowerGold : kOuterTowerGold);
        events.add(TowerDestroyed(towerId: e.id, teamId: e.teamId, killerId: killerId));
      } else {
        // core
        final winner = e.teamId == 0 ? 1 : 0;
        if (_winnerTeam == -1) _winnerTeam = winner;
        events.add(CoreDestroyed(teamId: e.teamId, winnerTeam: winner));
      }
      _removeEntity(e.id);
    }
```

(b) Protocol — additive enum + field. In `packages/protocol/lib/src/messages.dart`:
```dart
enum EndReason { opponentLeft, roomFull, serverShutdown, coreDestroyed }
```
and
```dart
class MatchEndMsg extends Msg {
  final EndReason reason;
  final int winnerSlot; // -1 when not applicable (e.g. opponentLeft)
  const MatchEndMsg({required this.reason, this.winnerSlot = -1});
}
```
In `packages/protocol/lib/src/codec.dart`, extend the `MatchEndMsg` encode case and the `_tagMatchEnd` decode case:
```dart
      case final MatchEndMsg m:
        w.bytes([_tagMatchEnd]);
        w.i32(m.reason.index);
        w.i32(m.winnerSlot);
```
```dart
      case _tagMatchEnd:
        return MatchEndMsg(reason: EndReason.values[r.i32()], winnerSlot: r.i32());
```

(c) Server — inject-able sim + win detection. In `apps/server/lib/src/loop/match.dart`:

Change the constructor + `_sim` field so a sim can be injected (default = create from seed):
```dart
  Match({required this.seed, required TickDriver driver, Simulation? sim})
      : _driver = driver,
        _sim = sim ?? Simulation.create(SimConfig(seed: seed));

  final int seed;
  final TickDriver _driver;
  final Simulation _sim;
```
(Delete the old `late final Simulation _sim = ...` line.)

In `_tick()`, after `_sim.step(_currentTick, intents);`, add the win check before the snapshot block (`winnerTeam` == winning slot in 1v1, where teamId 0/1 == slot 0/1 by construction; a future 2v2 plan must map team→slot here):
```dart
    if (_sim.winnerTeam != -1) {
      _endWithWin(_sim.winnerTeam); // teamId == slot in 1v1
      return;
    }
```
Add the win-end method (mirrors `_onPlayerLeft`, but notifies BOTH players + a final snapshot so they render the terminal state):
```dart
  void _endWithWin(int winnerSlot) {
    if (ended) return;
    ended = true;
    _driver.stop();
    final snap = ProtocolCodec.encode(SnapshotMsg(
      serverTick: _currentTick,
      ackedSeq: [_buffer.lastAckedSeq[0], _buffer.lastAckedSeq[1]],
      stateBytes: _sim.snapshotBytes(),
    ));
    final end = ProtocolCodec.encode(
        MatchEndMsg(reason: EndReason.coreDestroyed, winnerSlot: winnerSlot));
    for (final p in _players) {
      p?.send(snap);
      p?.send(end);
      p?.close();
    }
    for (final sub in _subs) {
      sub.cancel();
    }
    onEnded?.call();
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/sim && dart test packages/protocol && dart test apps/server`
Expected: PASS (new win tests + all existing; sim goldens still green).

- [ ] **Step 5: Commit**
```bash
git add packages/sim/lib/src/simulation.dart packages/sim/test/combat_test.dart \
        packages/protocol/lib/src/messages.dart packages/protocol/lib/src/codec.dart \
        packages/protocol/test/codec_test.dart apps/server/lib/src/loop/match.dart \
        apps/server/test/match_test.dart
git commit -m "feat: destroy-core win condition -> MatchEnd(coreDestroyed, winnerSlot) + server wiring"
```

---

## Task 11: Client render — entity list in `MatchView`, kind/team shapes, health bars, gold HUD, win/lose overlay

**Files:**
- Modify: `packages/netcode/lib/src/match_view.dart`
- Modify: `packages/netcode/lib/src/interpolation_buffer.dart`
- Modify: `packages/netcode/lib/src/match_controller.dart`
- Modify: `apps/client/lib/render/entity_view.dart`, `apps/client/lib/render/guild_game.dart`
- Modify: `apps/client/lib/match/match_binding.dart`
- Modify: `apps/client/lib/ui/hud_overlay.dart`, `apps/client/lib/main.dart`
- Create: `apps/client/lib/ui/result_overlay.dart`
- Modify: `apps/client/test/match_binding_test.dart`

> The render boundary moves from a fixed `{local, opponent, wanderer}` struct to an **id-keyed entity list** carrying kind/team/hp so the renderer can draw every kind, spawn/despawn dynamically, and show health bars. `MatchView.local`/`.opponent` are kept as getters over the list, so the netcode interpolation tests (Case 7's `view.opponent.x`) and `match_binding_test`'s `v.local.x` keep working unchanged. The opponent hero stays **interpolated ~100ms behind** (proven netcode); everything else renders from the predicted sim. Discrete fields (hp/gold) are taken straight from the snapshot — **never interpolated**.

- [ ] **Step 1: Write/extend the failing tests**

Add to `packages/netcode/test/match_controller_test.dart` (inside `main()`):
```dart
  test('update() exposes all entities with kind/team/hp and the local/opponent getters', () {
    final c = _ctrl(slot: 0);
    c.advanceClientTick();
    final v = c.update(0);
    // 9 static entities exist at start (2 heroes, wanderer, 2 cores, 4 towers).
    expect(v.entities.length, greaterThanOrEqualTo(9));
    expect(v.localSlot, 0);
    expect(v.local.id, 0);
    expect(v.opponent.id, 1);
    final core = v.entities.firstWhere((e) => e.id == 10);
    expect(core.kind, EntityKind.core.index);
    expect(core.maxHp, greaterThan(0));
    expect(v.localGold, 0);
  });
```

Extend `apps/client/test/match_binding_test.dart` with a win-surfacing test (append inside `main()`):
```dart
  test('surfaces the winner from a MatchEndMsg', () async {
    final mem = _MemTransport();
    final binding = MatchBinding(mem);
    mem.serverPush(ProtocolCodec.encode(const MatchStartMsg(
        yourSlot: 0, seed: 1337, tickRateHz: 30, snapshotRateHz: 20, startTick: 0)));
    await Future<void>.delayed(Duration.zero);
    expect(binding.isOver, isFalse);
    mem.serverPush(ProtocolCodec.encode(
        const MatchEndMsg(reason: EndReason.coreDestroyed, winnerSlot: 0)));
    await Future<void>.delayed(Duration.zero);
    expect(binding.isOver, isTrue);
    expect(binding.winnerSlot, 0);
    expect(binding.localSlot, 0);
  });
```
(`v.local.x` in the existing binding test keeps working via the new `local` getter.)

- [ ] **Step 2: Run to verify failure**

Run: `dart test packages/netcode/test/match_controller_test.dart`
Expected: FAIL — `MatchView` has no `entities`/`localSlot`/`localGold`; `RenderEntity` has no `id`.
(The client test will be run under `flutter test` in Step 4.)

- [ ] **Step 3: Implement the render boundary + renderer**

(a) `packages/netcode/lib/src/match_view.dart` — replace the whole file:
```dart
/// Render-boundary value types. Doubles/ints ONLY (never fed back into the sim).
class RenderEntity {
  final int id;
  final int kind; // EntityKind.index
  final int teamId; // 0/1 players, 2 neutral
  final double x, y;
  final double hp, maxHp;
  const RenderEntity({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.x,
    required this.y,
    required this.hp,
    required this.maxHp,
  });
}

class MatchView {
  /// All LIVE entities (local hero predicted; opponent hero interpolated;
  /// others straight from the predicted sim). Discrete fields (hp) are snapshot
  /// values — never interpolated.
  final List<RenderEntity> entities;
  final int localSlot;
  final int localGold;
  final int predictedTick;
  final int lastServerTick;
  final int pendingInputCount;
  final double lastCorrectionDist;
  const MatchView({
    required this.entities,
    required this.localSlot,
    required this.localGold,
    required this.predictedTick,
    required this.lastServerTick,
    required this.pendingInputCount,
    required this.lastCorrectionDist,
  });

  /// The local hero's render entity (predicted).
  RenderEntity get local => entities.firstWhere((e) => e.id == localSlot);

  /// The opponent hero's render entity (interpolated). Always present (heroes
  /// respawn rather than despawn).
  RenderEntity get opponent => entities.firstWhere((e) => e.id == 1 - localSlot);
}
```

(b) `packages/netcode/lib/src/interpolation_buffer.dart` — decouple from `RenderEntity` (it now carries combat fields). Remove the `import 'match_view.dart';` and change `sample`'s return type to a record; replace every `return RenderEntity(...)` with the record form:
```dart
  /// Sample the opponent position at logical time [targetTimeMs]. Returns (x, y).
  ({double x, double y}) sample(int targetTimeMs) {
    if (_samples.isEmpty) return (x: 0.0, y: 0.0);
    if (targetTimeMs <= _samples.first.timeMs) {
      final s = _samples.first;
      return (x: s.x, y: s.y);
    }
    if (targetTimeMs >= _samples.last.timeMs) {
      final s = _samples.last; // HOLD — never extrapolate
      return (x: s.x, y: s.y);
    }
    for (var i = 0; i < _samples.length - 1; i++) {
      final a = _samples[i], b = _samples[i + 1];
      if (targetTimeMs >= a.timeMs && targetTimeMs <= b.timeMs) {
        final span = (b.timeMs - a.timeMs);
        final alpha = span == 0 ? 0.0 : (targetTimeMs - a.timeMs) / span;
        return (x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha);
      }
    }
    final s = _samples.last;
    return (x: s.x, y: s.y);
  }
```

(c) `packages/netcode/lib/src/match_controller.dart` — rebuild `update()` to assemble the entity list (opponent interpolated only once samples exist), and add `applyAttackInput` (the attack-lock analog of `applyLocalInput`):
```dart
  MatchView update(int renderTimeMs) {
    final oppId = 1 - localSlot;
    final hasInterp = _interp.length > 0;
    final opp = hasInterp ? _interp.sample(renderTimeMs - 100) : null;
    final entities = <RenderEntity>[];
    for (final id in _predicted.entityIdsSorted) {
      final e = _predicted.entity(id);
      var x = e.pos.x.toDouble();
      var y = e.pos.y.toDouble();
      if (id == oppId && opp != null) {
        x = opp.x; // opponent hero interpolated ~100ms behind
        y = opp.y;
      }
      entities.add(RenderEntity(
        id: id,
        kind: e.kind.index,
        teamId: e.teamId,
        x: x,
        y: y,
        hp: e.hp.toDouble(),
        maxHp: e.maxHp.toDouble(),
      ));
    }
    return MatchView(
      entities: entities,
      localSlot: localSlot,
      localGold: _predicted.entity(localSlot).gold,
      predictedTick: _nextTick,
      lastServerTick: _lastReconciledServerTick,
      pendingInputCount: _pending.length,
      lastCorrectionDist: _lastCorrectionDist,
    );
  }

  /// Record + apply a local ATTACK lock onto [targetId]; returns the InputMsg to
  /// send. Mirrors applyLocalInput but with IntentType.attack (aimX = targetId).
  InputMsg applyAttackInput(int targetId) {
    final seq = ++_localSeq;
    final intent = Intent(
        playerSlot: localSlot,
        type: IntentType.attack,
        aimX: targetId,
        seq: seq,
        clientTick: _nextTick);
    _pending.add(_Pending(_nextTick, intent));
    return InputMsg(
        slot: localSlot,
        seq: seq,
        clientTick: _nextTick,
        aimX: targetId,
        aimY: 0,
        type: IntentType.attack.index);
  }
```

(d) `apps/client/lib/render/entity_view.dart` — replace the whole file (shape+color by kind/team; health bar; local outline):
```dart
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:sim/sim.dart' show EntityKind;

/// A Flame view of one sim entity. Branches its shape/color on (kind, teamId)
/// and renders a health bar. Purely cosmetic — never feeds back into the sim.
class EntityView extends PositionComponent {
  EntityView({required this.kind, required this.teamId, required this.isLocal})
      : super(anchor: Anchor.center, size: Vector2.all(_sizeFor(kind)));

  static const double _kLerpSpeed = 12.0;
  static const double _kBarH = 3.0;

  final int kind; // EntityKind.index
  final int teamId;
  final bool isLocal;

  /// Target in Flame coords (set from MatchView each frame).
  final Vector2 target = Vector2.zero();

  /// 0..1 health fraction (set from MatchView each frame).
  double hpRatio = 1.0;

  RectangleComponent? _hpFg;
  double _barW = 0;

  static double _sizeFor(int kind) {
    if (kind == EntityKind.core.index) return 28;
    if (kind == EntityKind.tower.index) return 22;
    if (kind == EntityKind.creep.index) return 12;
    return 20; // hero / wanderer
  }

  @override
  Future<void> onLoad() async {
    final paint = Paint()..color = _color();
    if (kind == EntityKind.tower.index || kind == EntityKind.core.index) {
      await add(RectangleComponent(size: size, anchor: Anchor.center, paint: paint));
    } else {
      await add(CircleComponent(radius: size.x / 2, anchor: Anchor.center, paint: paint));
    }
    if (isLocal) {
      await add(CircleComponent(
        radius: size.x / 2 + 2,
        anchor: Anchor.center,
        paint: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFFFFFFF),
      ));
    }
    // Health bar (skip the neutral wanderer — it has no combat role).
    if (kind != EntityKind.wanderer.index) {
      _barW = size.x;
      final top = -size.y / 2 - _kBarH - 2;
      await add(RectangleComponent(
        position: Vector2(-_barW / 2, top),
        size: Vector2(_barW, _kBarH),
        paint: Paint()..color = const Color(0x88000000),
      ));
      _hpFg = RectangleComponent(
        position: Vector2(-_barW / 2, top),
        size: Vector2(_barW, _kBarH),
        paint: Paint()..color = const Color(0xFF4CAF50),
      );
      await add(_hpFg!);
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    position.lerp(target, (_kLerpSpeed * dt).clamp(0.0, 1.0));
    final fg = _hpFg;
    if (fg != null) fg.size.x = _barW * hpRatio.clamp(0.0, 1.0);
  }

  Color _color() {
    switch (teamId) {
      case 0:
        return const Color(0xFF2196F3); // blue
      case 1:
        return const Color(0xFFF44336); // red
      default:
        return const Color(0xFF9E9E9E); // neutral grey
    }
  }
}
```

(e) `apps/client/lib/render/guild_game.dart` — replace the whole file (keyed diff; follow local; LoL right-click input; show result overlay when over):
```dart
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:netcode/netcode.dart' show MatchView, RenderEntity;
import 'package:sim/sim.dart' show EntityKind;

import '../match/match_binding.dart';
import 'coord.dart';
import 'entity_view.dart';
import 'world_backdrop.dart';

/// The Flame game. Renders MatchView's entity list as colored shapes; holds ZERO
/// gameplay truth. Spawns/despawns EntityViews via an id-keyed diff each frame.
class GuildGame extends FlameGame with TapCallbacks {
  GuildGame(this.binding);

  final MatchBinding binding;
  final Map<int, EntityView> _views = {};

  @override
  Future<void> onLoad() async {
    camera = CameraComponent.withFixedResolution(width: 960, height: 540, world: world);
    await world.add(WorldBackdrop());
  }

  @override
  void update(double dt) {
    super.update(dt);
    binding.tick((dt * 1000).round());

    if (binding.isOver && !overlays.isActive('result')) {
      overlays.add('result');
    }

    final v = binding.view;
    if (v == null) return;

    final seen = <int>{};
    for (final re in v.entities) {
      seen.add(re.id);
      var view = _views[re.id];
      if (view == null) {
        view = EntityView(kind: re.kind, teamId: re.teamId, isLocal: re.id == v.localSlot);
        _views[re.id] = view;
        world.add(view);
        if (re.id == v.localSlot) camera.follow(view);
      }
      view.target.setValues(worldToFlameX(re.x), worldToFlameY(re.y));
      view.hpRatio = re.maxHp > 0 ? re.hp / re.maxHp : 1.0;
    }
    // Despawn views whose entity is gone (dead creep / fallen tower / dead core).
    final gone = _views.keys.where((id) => !seen.contains(id)).toList();
    for (final id in gone) {
      _views.remove(id)?.removeFromParent();
    }
  }

  /// LoL right-click semantics: clicking ON an enemy locks an attack onto it;
  /// clicking the ground issues a move (which clears any lock). (The web build
  /// maps the single tap to "right-click"; left-click selection is not modeled.)
  @override
  void onTapUp(TapUpEvent event) {
    final worldPos = camera.globalToLocal(event.canvasPosition);
    final wx = flameToWorld(worldPos.x);
    final wy = flameToWorld(worldPos.y);
    final v = binding.view;
    if (v != null) {
      final targetId = _enemyAt(v, wx, wy);
      if (targetId != null) {
        binding.submitAttack(targetId);
        return;
      }
    }
    binding.submitMoveTo(worldToRaw(wx), worldToRaw(wy));
  }

  /// Nearest valid enemy entity within a small click radius (world units), else null.
  int? _enemyAt(MatchView v, double wx, double wy) {
    const clickR2 = 1.5 * 1.5;
    int? best;
    var bestD2 = clickR2;
    for (final re in v.entities) {
      if (!_isEnemyKind(re, v.localSlot)) continue;
      final dx = re.x - wx, dy = re.y - wy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = re.id;
      }
    }
    return best;
  }

  bool _isEnemyKind(RenderEntity re, int localSlot) {
    if (re.kind == EntityKind.wanderer.index) return false; // never targetable
    if (re.kind == EntityKind.creep.index) return true; // neutral fodder
    return re.teamId != localSlot; // hero/tower/core: enemy = other team (team==slot in 1v1)
  }
}
```

(f) `apps/client/lib/match/match_binding.dart` — surface the winner; add `submitAttack`; stop ticking when over. Add fields/getters + a `submitAttack` method (next to the existing `submitMoveTo`) + change `_onFrame` + `tick`:
```dart
  bool _ended = false;
  int _winnerSlot = -1;

  bool get isOver => _ended;
  int? get winnerSlot => _ended ? _winnerSlot : null;
  int? get localSlot => _controller?.localSlot;

  /// Local input: right-click an enemy entity id → attack-lock. Predict + send.
  void submitAttack(int targetId) {
    final c = _controller;
    if (c == null) return;
    _transport.send(ProtocolCodec.encode(c.applyAttackInput(targetId)));
  }
```
In `_onFrame`, replace the `MatchEndMsg` branch:
```dart
    } else if (msg is MatchEndMsg) {
      _winnerSlot = msg.winnerSlot;
      _ended = true; // keep the controller so the final frame stays rendered
    }
```
In `tick`, guard the stepping so a finished match freezes:
```dart
  void tick(int dtMs) {
    _renderTimeMs += dtMs;
    if (_ended) return;
    _accMs += dtMs;
    while (_accMs >= _tickMs) {
      _accMs -= _tickMs;
      _controller?.advanceClientTick();
    }
  }
```
(`MatchController.localSlot` is already a public final field — no change needed there.)

(g) `apps/client/lib/ui/hud_overlay.dart` — add a gold line. Inside the `Column`'s `children`, before the tick stats, add:
```dart
              Text('gold: ${v?.localGold ?? '-'}'),
```

(h) Create `apps/client/lib/ui/result_overlay.dart`:
```dart
import 'package:flutter/material.dart';

import '../match/match_binding.dart';

/// Full-screen victory/defeat banner shown when the match ends.
class ResultOverlay extends StatelessWidget {
  const ResultOverlay({super.key, required this.binding});

  final MatchBinding binding;

  @override
  Widget build(BuildContext context) {
    final winner = binding.winnerSlot;
    final me = binding.localSlot;
    final String text;
    if (winner == null || winner < 0) {
      text = 'MATCH ENDED';
    } else {
      text = winner == me ? 'VICTORY' : 'DEFEAT';
    }
    return Container(
      color: const Color(0x99000000),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 48,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
```

(i) `apps/client/lib/main.dart` — register the `result` overlay. Add the import and a map entry:
```dart
import 'ui/result_overlay.dart';
```
and in `overlayBuilderMap`:
```dart
            'result': (context, _) => ResultOverlay(binding: binding),
```
(Leave it OUT of `initialActiveOverlays`; `GuildGame.update` activates it when `binding.isOver`.)

- [ ] **Step 4: Run to verify it passes**

Run: `dart test packages/netcode`
Expected: PASS (new `update()` test + Case 7 interpolation via the `opponent` getter + all others).
Run (from `apps/client`): `flutter test`
Expected: PASS (`match_binding_test` incl. the new win test; `widget_smoke_test` mounts the keyed-diff game without throwing).
Run: `dart analyze --fatal-infos --fatal-warnings packages apps/server tooling` and (from `apps/client`) `flutter analyze`
Expected: no issues.

- [ ] **Step 5: Commit**
```bash
git add packages/netcode/lib/src/match_view.dart packages/netcode/lib/src/interpolation_buffer.dart \
        packages/netcode/lib/src/match_controller.dart packages/netcode/test/match_controller_test.dart \
        apps/client/lib/render/entity_view.dart apps/client/lib/render/guild_game.dart \
        apps/client/lib/match/match_binding.dart apps/client/lib/ui/hud_overlay.dart \
        apps/client/lib/ui/result_overlay.dart apps/client/lib/main.dart \
        apps/client/test/match_binding_test.dart
git commit -m "feat(client): render entity list (kind/team shapes + health bars), gold HUD, win/lose overlay"
```

---

## Task 12: Combat replay fixture + CI coverage + Self-Review

**Files:**
- Create: `tooling/replay_fixtures/combat.json`, `tooling/replay_fixtures/combat.golden`
- Modify: `.github/workflows/sim-determinism.yml`

> Adds a cross-runtime golden that exercises combat — hero-vs-hero damage, enemy-tower fire, hero death + respawn, and a neutral creep-wave **spawn** (which forces the id-keyed entity set through the per-tick hash). The `smoke` golden stays movement-only. This is the determinism proof for combat across native/js/wasm. (It does NOT reach a creep last-hit — the wave spawns at tick 450 and 50 ticks is too few for 8 hero hits; the last-hit-gold path is proven instead by the real-DPS unit test in Task 9.)

- [ ] **Step 1: Create the combat fixture**

Create `tooling/replay_fixtures/combat.json`. Both heroes move to center (tick 0, `type:1`=move), then at tick 70 each **attack-locks the other** (`type:2`=`IntentType.attack`, `aimX`=enemy hero id) → they pursue + trade hits, take enemy-tower fire, die and respawn (lock persists → re-pursue); the wave spawns at tick 450; 500 ticks:
```json
{
  "seed": 1337,
  "ticks": 500,
  "inputLog": {
    "0": [{"playerSlot":0,"type":1,"aimX":0,"aimY":0,"seq":1,"clientTick":0},
          {"playerSlot":1,"type":1,"aimX":0,"aimY":0,"seq":1,"clientTick":0}],
    "70":[{"playerSlot":0,"type":2,"aimX":1,"aimY":0,"seq":2,"clientTick":70},
          {"playerSlot":1,"type":2,"aimX":0,"aimY":0,"seq":2,"clientTick":70}]
  }
}
```

- [ ] **Step 2: Confirm 3-runtime determinism on the combat fixture**

Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json`
Expected: `PASS: byte-identical across native/js/wasm: <hash>`.
If it prints a divergence, STOP and binary-diff `canonicalBytes()` per tick to find the first divergent field (a stray double/shift/Map-iteration in the combat code) and fix it before pinning.

- [ ] **Step 3: Pin the combat golden**

Run:
```bash
b64=$(base64 -w0 tooling/replay_fixtures/combat.json) \
  && dart run -DFIXTURE_JSON=$b64 tooling/replay_harness.dart \
     | awk '/^REPLAY_HASH /{print $2}' > tooling/replay_fixtures/combat.golden
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
```
Expected: second run ends with `PASS: matches golden .../combat.golden`.

- [ ] **Step 4: Add the combat fixture to CI**

In `.github/workflows/sim-determinism.yml`, in the `replay-golden` job, after the existing smoke step add:
```yaml
      - run: bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
```

- [ ] **Step 5: Self-Review (run yourself; fix any gaps inline before finishing)**

Verify against the spec and this plan:

1. **Spec coverage map** — confirm each is implemented and cite the task:
   - Auto-attacks (spec §6/§11 gate 3) → Tasks 5 (hero), 6 (tower).
   - Towers + ordered outer→inner→core gating (§4.3, §6, §11) → Tasks 4 (spawn), 6 (gating + combat).
   - Neutral creeps only (§6, §10, §11) → Task 8 (passive neutral waves).
   - Last-hit gold (§6 values: creep 18 / outer 200 / inner 300) → Task 9.
   - Destroy-enemy-core win (§6, §11) → Task 10 (sim winner + server `MatchEnd`).
   - `SimEvent`s cosmetic-only (§8.1) → Tasks 1 (types), 5/6/9/10 (emitted, never mutate state).
   - Determinism rules (§8.1, §12) → goldens re-pinned (Tasks 3, 4), combat golden (Task 12), purity gate green.
   - Forward-compat hooks (§10): `_applyDamage` chokepoint (Plan-4 reaction multiplier point), `TowerDestroyed{killerId}` + `BossSpawned` stub (revenge boss), neutral team 2 (2-sided fields), declared `ReactionTriggered`/`LevelUp`.
   - Explicitly OUT and confirmed absent: elemental/auras/reactions/fields, revenge-boss entity/AI, shop, XP/leveling, hero abilities/ults, bounties/comeback, the §6 "reduced tower damage without creeps" / "escalating same-target damage" balance modifiers (documented deferral).

2. **Placeholder scan** — grep the plan and the diff for `TODO`/`TBD`/"implement later"/"add error handling"; there must be none. Combat tunables are named constants documented as playtest placeholders (intended, not placeholders-in-code).

3. **Type-consistency check** — confirm names/signatures match across tasks: `EntityKind {hero, wanderer, tower, creep, core}`; `IntentType {none, move, attack}`; `Entity` fields `maxHp/attackCooldown/gold/respawnTimer/attackTargetId`; `isStructureVulnerable` (public, same name in sim + tests); `_applyDamage(source, target, amount, events)`; `_isAttackable(a, c)` / `_acquireTowerTarget`; `winnerTeam` getter; `MatchController.applyAttackInput`; `MatchBinding.submitAttack`; `MatchEndMsg(reason, winnerSlot)`; `MatchView.entities/localSlot/localGold` + `local`/`opponent` getters; `RenderEntity(id, kind, teamId, x, y, hp, maxHp)`; reserved ids `kCore0Id`/…/`kInnerTower1Id`/`kCreepIdBase`.

4. **Determinism invariants** — confirm: no `dart:math`/`Random`/`DateTime` added to `packages/sim/lib`; all new magnitudes obey `|value| < 32768`; no `<<`/`>>` on signed/large ints; entities iterated by ascending id; both goldens + the combat golden green across native/js/wasm; `EntityKind`/`EndReason`/`IntentType` only appended.

- [ ] **Step 6: Full green sweep + commit**

Run:
```bash
dart analyze --fatal-infos --fatal-warnings packages apps/server tooling
bash tooling/check_no_banned_imports.sh
dart test packages/sim && dart test packages/protocol && dart test packages/netcode && dart test apps/server
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json
```
(from `apps/client`) `flutter analyze && flutter test`
Expected: all green.

```bash
git add tooling/replay_fixtures/combat.json tooling/replay_fixtures/combat.golden \
        .github/workflows/sim-determinism.yml
git commit -m "ci(sim): combat replay golden across native/js/wasm"
```

---

## Definition of Done

- All 12 tasks committed; `dart analyze --fatal-infos --fatal-warnings` clean; `tooling/check_no_banned_imports.sh` green.
- `dart test` green in `packages/sim`, `packages/protocol`, `packages/netcode`, `apps/server`; `flutter test` green in `apps/client`.
- Both replay goldens (`smoke`, `combat`) byte-identical across native/dart2js/dart2wasm in CI.
- The game is playable locally (`dart run apps/server/bin/server.dart 8080`, then `cd apps/client && flutter run -d chrome`, two tabs): heroes auto-attack, towers fire, a creep wave spawns and can be last-hit for gold (HUD), towers fall outer→inner exposing the core, and destroying the enemy core shows VICTORY/DEFEAT.
- No elemental content, revenge boss, shop, leveling, or hero abilities were implemented (deferred to Plan 4+), but the noted inert hooks exist.

