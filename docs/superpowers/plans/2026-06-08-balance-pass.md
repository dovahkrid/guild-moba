# Balance Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retune the placeholder combat + elemental tunables (lane safety, creep last-hit, duel TTK, elemental impact) and re-pin the two affected replay goldens cross-runtime, with `smoke.golden` + the `0x0fbfb7ac` anchor provably unchanged.

**Architecture:** Pure constant-value edits in `packages/sim/lib/src/data/{combat,elements}.dart` — no mechanics, no byte layout, no new constants. The lane fix is **range-only** (behavior, not a serialized position) so it can't disturb the move-only goldens/anchor. Each task changes one golden's worth of constants, proves *exactly* that golden moved (the others byte-identical), and re-pins it from the native replay harness (cross-runtime-identical by construction for a constant-only change; CI re-verifies native/js/wasm parity).

**Tech Stack:** Dart 3.11.5 pure-Dart `sim`; `tooling/replay_harness.dart` + `tooling/compare_replays.sh` (native + dart2js/node + dart2wasm/node); `dart test`.

**Spec:** `docs/superpowers/specs/2026-06-08-balance-pass-design.md`. **Branch:** `feat/balance-pass` off `main` (`2565b9e`).

**Determinism invariant (every task):** `Fixed`(Q16.16)+`int` only, all values `< 32768`; **no** `dart:math`/`Random`/`DateTime` in `packages/sim/lib`; **no new RNG draw**; no enum/field/byte-layout/version change (3/3). `kOuterTowerX`/`kInnerTowerX`/`kCoreX` and every other entity position are **untouched** (so `smoke.golden` `7e4aa28f` + anchor `0x0fbfb7ac` cannot move). The two sanctioned moves are `combat.golden` (`910ddcfc`→new) and `elemental.golden` (`8d7fbe1b`→new).

**Important for the implementer:** the repo is already on `feat/balance-pass` — **do NOT run `git checkout`/`git switch`**. All sim unit-test assertions are **symbolic** (e.g. `hpBefore - kReactionFlatDamage.raw`), so they stay green on the new values; only stale **comments/names** change.

---

## File Structure

**Modified (source — values only):**
- `packages/sim/lib/src/data/combat.dart` — `kTowerAttackRange` (20), `kTowerAttackRangeSq` (21), `kCreepMaxHp` (29), `kHeroAttackDamage` (13); header comment.
- `packages/sim/lib/src/data/elements.dart` — `kCastBurstDamage` (24), `kReactionFlatDamage` (27); header comment.

**Modified (test comments/names only — assertions unchanged):**
- `packages/sim/test/combat_test.dart` — stale `"60-hp"`/`"8 hits"`/`"range 6"` comments.
- `packages/sim/test/reaction_test.dart` — stale `"< kCastBurstDamage (10)"` comment.

**Re-pinned (generated):**
- `tooling/replay_fixtures/combat.golden`, `tooling/replay_fixtures/elemental.golden`.

**Untouched (asserted unchanged):** `smoke.golden`, all `apps/`, all `packages/netcode`, `packages/protocol`, the sim mechanics code.

---

## Task 1: Combat retune (Groups 1–3) + re-pin `combat.golden`

**Files:**
- Modify: `packages/sim/lib/src/data/combat.dart`
- Modify: `packages/sim/test/combat_test.dart` (comments/names only)
- Re-pin: `tooling/replay_fixtures/combat.golden`

- [ ] **Step 1: Edit the four combat constants**

In `packages/sim/lib/src/data/combat.dart` make exactly these value changes (keep everything else, including `kOuterTowerX`):

`kHeroAttackDamage` (line ~13):
```dart
final Fixed kHeroAttackDamage = Fixed.fromNum(10); // damage per auto-attack hit (playtest-tuned 2026-06-08, was 8)
```
`kTowerAttackRange` + `kTowerAttackRangeSq` (lines ~20–21) — change BOTH in lockstep (the squared value is the actual targeting gate; `combat_test.dart` asserts `RangeSq == Range²`):
```dart
final Fixed kTowerAttackRange = Fixed.fromNum(5); // world-units (playtest-tuned 2026-06-08, was 6 — range-only lane fix: towers NOT moved)
final Fixed kTowerAttackRangeSq = Fixed.fromNum(5 * 5); // compare vs lengthSq, no sqrt
```
`kCreepMaxHp` (line ~29):
```dart
final Fixed kCreepMaxHp = Fixed.fromInt(40); // hit-points per neutral creep (playtest-tuned 2026-06-08, was 60 → ~4 autos)
```
Also update the file header comment (lines ~3–5) to note the tunables were playtest-tuned on 2026-06-08 (keep the `// spec §…` breadcrumbs). Do NOT change `kOuterTowerX`, `kInnerTowerX`, `kCoreX`, hero/tower hp, cooldowns, gold, wave cadence, or any other constant.

- [ ] **Step 2: Refresh the stale `combat_test.dart` comments/names (assertions unchanged)**

In `packages/sim/test/combat_test.dart`:
- Line ~43 comment: `// (towers at x=±4/±10, range 6) — keeps this hero-vs-hero test combat-free.` → change `range 6` to `range 5`.
- Line ~185 comment: `// (towers at x=±4/±10, range 6) — isolates the downed-hero behavior.` → `range 5`.
- The test at line ~256: rename `'a hero last-hits a full 60-hp creep via real attack cadence (no shortcut)'` → `'a hero last-hits a full 40-hp creep via real attack cadence (no shortcut)'`.
- Its comment (line ~261–263): `// (x=-8 is >6 from every enemy tower at +4/+10/+14, and own towers never` → change `>6` to `>5`.
- Its comment (line ~278): `// 60hp / 8dmg = 8 hits, credited once` → `// 40hp / 10dmg = 4 hits, credited once`.

(These are comments/a test name only — the assertions all use constants symbolically and stay green.)

- [ ] **Step 3: Run the sim suite + analyze — expect ALL green (no logic broke)**

Run: `cd packages/sim && dart analyze && dart test`
Expected: analyze clean; **all sim tests pass** (the constant-driven assertions absorb the new values; e.g. `combat_test` "last-hits a 40-hp creep" still kills it in 4 autos within its 200-tick window; `RangeSq == Range²` holds at 25 == 5²; reaction/budget tests pass).

- [ ] **Step 4: Attribution gate — confirm ONLY `combat.golden` moved (native hashes)**

The native harness is authoritative locally (a constant-only change cannot diverge native vs js/wasm — identical integer math). Compute each fixture's native hash:

Run (from repo root):
```bash
for f in smoke combat elemental; do
  B64=$(base64 -w0 tooling/replay_fixtures/$f.json 2>/dev/null || base64 tooling/replay_fixtures/$f.json | tr -d '\n')
  H=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
  echo "$f -> $H (committed golden: $(tr -d '\r\n' < tooling/replay_fixtures/$f.golden))"
done
```
Expected: `smoke -> 7e4aa28f` (UNCHANGED, matches golden), `elemental -> 8d7fbe1b` (UNCHANGED, matches golden), `combat -> <NEWHASH>` (CHANGED vs `910ddcfc` — the sanctioned move). **If smoke or elemental changed, STOP** — a constant leaked beyond combat; investigate before re-pinning.

Also confirm the in-test anchor is intact:
Run: `cd packages/sim && dart test test/simulation_test.dart`
Expected: PASS, including `pinned 300-tick canonical state hash` == `0x0fbfb7ac` (unchanged — the anchor is move-only with no creeps/combat and unmoved towers).

- [ ] **Step 5: Re-pin `combat.golden` (write the new native hash with an LF newline)**

Run (from repo root — substitute the `<NEWHASH>` observed in Step 4, or recompute inline):
```bash
B64=$(base64 -w0 tooling/replay_fixtures/combat.json 2>/dev/null || base64 tooling/replay_fixtures/combat.json | tr -d '\n')
NEW=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
printf '%s\n' "$NEW" > tooling/replay_fixtures/combat.golden
echo "re-pinned combat.golden -> $NEW"
git --no-pager diff -- tooling/replay_fixtures/combat.golden
```
Expected: the diff shows only the single hash line changing (`910ddcfc` → `<NEWHASH>`). The `printf '%s\n'` writes a clean LF so `compare_replays.sh`'s `$(cat)` matches locally.

- [ ] **Step 6: (If the cross-runtime toolchain is present) prove native/js/wasm parity + golden match**

Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json`
Expected: `PASS: byte-identical across native/js/wasm: <NEWHASH>` then `PASS: matches golden`. Also re-run smoke + elemental: `bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json` and `…/elemental.json` → both `PASS: matches golden` (unchanged).
**If `node` / `dart compile wasm` are unavailable locally**, skip this step — the change is constant-only so native parity implies cross-runtime parity, and the CI gate `.github/workflows/sim-determinism.yml` runs the full cross-runtime compare on push. Note in the commit that cross-runtime parity is CI-verified.

- [ ] **Step 7: Commit**

Run: `git diff --quiet 2565b9e -- apps packages/netcode packages/protocol packages/sim/lib/src/simulation.dart` (Expected: exit 0 — no client/netcode/mechanics change; only data + tests + golden moved.)
```bash
git add packages/sim/lib/src/data/combat.dart packages/sim/test/combat_test.dart tooling/replay_fixtures/combat.golden
git commit -m "balance(sim): combat retune (tower range 6->5, creep hp 60->40, hero dmg 8->10) + re-pin combat.golden"
```

---

## Task 2: Elemental retune (Group 4) + re-pin `elemental.golden`

**Files:**
- Modify: `packages/sim/lib/src/data/elements.dart`
- Modify: `packages/sim/test/reaction_test.dart` (comment only)
- Re-pin: `tooling/replay_fixtures/elemental.golden`

- [ ] **Step 1: Edit the two elemental constants**

In `packages/sim/lib/src/data/elements.dart`:

`kCastBurstDamage` (line ~24):
```dart
final Fixed kCastBurstDamage = Fixed.fromNum(16); // one-time enemy-only AoE on cast (playtest-tuned 2026-06-08, was 10; ×kVaporizeMult=20.8 stays in budget)
```
`kReactionFlatDamage` (line ~27):
```dart
final Fixed kReactionFlatDamage = Fixed.fromNum(12); // flat field-overlap reaction (playtest-tuned 2026-06-08, was 8)
```
Update the file header comment (lines ~1–6) to note these were playtest-tuned 2026-06-08 (keep the spec breadcrumbs). Do NOT change `kVaporizeMult`, `kStatusDurationTicks`, `kReactionIcdTicks`, `kFieldRadius`/`Sq`, `kFieldDurationTicks`, `kAbilityCooldownTicks`, or the roster helpers.

- [ ] **Step 2: Refresh the stale `reaction_test.dart` comment**

In `packages/sim/test/reaction_test.dart` line ~421:
```dart
    h1.hp = Fixed.fromNum(5); // < kCastBurstDamage (16) → downed by h0's burst this tick
```
(Only the `(10)` → `(16)` in the comment. `h1.hp = 5` is still `< 16`, so the `lessThanOrEqualTo(0)` assertion stays green.)

- [ ] **Step 3: Run the sim suite + analyze — expect ALL green**

Run: `cd packages/sim && dart analyze && dart test`
Expected: analyze clean; all sim tests pass (every elemental/reaction assertion is symbolic — `enemyHpBefore - kCastBurstDamage.raw`, `(… - (kCastBurstDamage * kVaporizeMult)).raw`, `… - kReactionFlatDamage.raw`; `elements_data_test` budget check passes at `16×1.3=20.8`; `telemetry_test`/`elemental_fixture_test` assert reaction *existence/timing*, not amount, so they pass).

- [ ] **Step 4: Attribution gate — confirm ONLY `elemental.golden` moved**

Run (from repo root):
```bash
for f in smoke combat elemental; do
  B64=$(base64 -w0 tooling/replay_fixtures/$f.json 2>/dev/null || base64 tooling/replay_fixtures/$f.json | tr -d '\n')
  H=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
  echo "$f -> $H"
done
```
Expected: `smoke -> 7e4aa28f` (UNCHANGED), `combat -> <NEWHASH from Task 1>` (UNCHANGED vs Task 1's re-pin — Group 4 doesn't touch `combat.json`, which issues no ability casts), `elemental -> <NEW2>` (CHANGED vs `8d7fbe1b` — the sanctioned move). **If smoke or combat changed, STOP** and investigate.
Anchor check: `cd packages/sim && dart test test/simulation_test.dart` → `0x0fbfb7ac` still passes.

- [ ] **Step 5: Re-pin `elemental.golden`**

```bash
B64=$(base64 -w0 tooling/replay_fixtures/elemental.json 2>/dev/null || base64 tooling/replay_fixtures/elemental.json | tr -d '\n')
NEW2=$(dart run -DFIXTURE_JSON=$B64 tooling/replay_harness.dart | grep '^REPLAY_HASH ' | awk '{print $2}')
printf '%s\n' "$NEW2" > tooling/replay_fixtures/elemental.golden
echo "re-pinned elemental.golden -> $NEW2"
git --no-pager diff -- tooling/replay_fixtures/elemental.golden
```
Expected: only the hash line changes (`8d7fbe1b` → `<NEW2>`).

- [ ] **Step 6: (If toolchain present) cross-runtime parity + golden match**

Run: `bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json` → `PASS: byte-identical…` + `PASS: matches golden`. Re-run smoke + combat compares → both `PASS: matches golden`. (If `node`/`dart2wasm` unavailable, skip — CI verifies; note it in the commit.)

- [ ] **Step 7: Commit**

```bash
git add packages/sim/lib/src/data/elements.dart packages/sim/test/reaction_test.dart tooling/replay_fixtures/elemental.golden
git commit -m "balance(sim): elemental retune (cast-burst 10->16, flat-reaction 8->12) + re-pin elemental.golden"
```

---

## Task 3: Full mirror-CI sweep

Confirms the whole branch is green + the goldens are correctly pinned + nothing leaked, mirroring `.github/workflows/sim-determinism.yml`.

- [ ] **Step 1: Determinism + scope guard**

Run (from repo root):
```bash
git diff --quiet 2565b9e -- apps packages/netcode packages/protocol && echo "SCOPE OK: only packages/sim + tooling changed"
git --no-pager diff --name-only 2565b9e..HEAD
```
Expected: scope guard exits 0 (no `apps`/`netcode`/`protocol` change); the changed-file list is only `packages/sim/lib/src/data/{combat,elements}.dart`, `packages/sim/test/{combat,reaction}_test.dart`, `tooling/replay_fixtures/{combat,elemental}.golden`, and the spec/plan docs.

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
Expected: analyze clean; banned-imports clean; every suite green (client untouched → still green).

- [ ] **Step 3: Cross-runtime golden gate (authoritative — run if toolchain present)**

```bash
bash tooling/compare_replays.sh tooling/replay_fixtures/smoke.json      # PASS matches golden (7e4aa28f)
bash tooling/compare_replays.sh tooling/replay_fixtures/combat.json     # PASS byte-identical native/js/wasm + matches NEW golden
bash tooling/compare_replays.sh tooling/replay_fixtures/elemental.json  # PASS byte-identical + matches NEW golden
```
Expected: all three `PASS: matches golden` with byte-identical native/js/wasm. (If `node`/`dart compile wasm` are unavailable locally, this is the gate CI runs on push — proceed and rely on CI; the changes are constant-only so cross-runtime parity is guaranteed by construction.)

- [ ] **Step 4: Hand off to whole-branch review + finishing**

No commit (verification only). Proceed to the whole-branch review (superpowers:requesting-code-review) over `main..HEAD`, then superpowers:finishing-a-development-branch.

---

## Notes for the implementer

- **Never edit `packages/sim/lib/src/simulation*.dart` or any mechanics/codec.** This is values-only. The `git diff --quiet 2565b9e -- apps packages/netcode packages/protocol` guard + the file-scope list catch leaks.
- **Symbolic tests are a feature, not a problem:** if a sim test FAILS after a value change, that's a real regression to investigate — do NOT "fix" it by editing the expected literal, because the tests don't use literals (they use the constants). The only test edits in this plan are comments/a test name.
- **Re-pin = native hash + LF write.** A constant-only change keeps the sim cross-runtime-deterministic by construction (same Q16.16 integer math on native/js/wasm), so the native `REPLAY_HASH` is the correct golden; `compare_replays.sh`/CI confirm parity. Write with `printf '%s\n'` so the golden file is a clean single LF-terminated hex line.
- **Attribution is the safety net:** after each task, exactly one golden may differ from its committed value and the others (incl. the `0x0fbfb7ac` anchor) must be byte-identical. A surprise change means a constant touched more than its intended fixture — stop and investigate.
