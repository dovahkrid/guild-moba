# Project "Guild" — Design Document (Consolidated, Reviewed)

> **Status:** Reviewed consolidation of the brainstorming session (2026-06-06). All locked decisions are honored; balance, feasibility, and reaction-determinism critiques have been applied. Where a critic recommended an MVP cut, the cut is reflected here and the full vision is preserved under **§10 MVP vs Later**.

---

## 1. Overview & Pillars

**Guild** is a web multiplayer MOBA: a single-lane, top-down, click-to-move duel built in **Flutter + Flame**, with a hand-drawn **pixel-art (delivered as SVG)** aesthetic. It ships **1v1** and is architected to scale cleanly to **3v3** later.

The fantasy: every hero embodies exactly **one element**. Combat depth comes not from sprawling kits (each hero has an auto-attack + **one** ability + **one** ultimate, cooldown-only, no mana) but from **Genshin-style elemental reactions** that are a **neutral, two-sided force of nature** — they happen to *any* unit, including yourself.

### Design Pillars
1. **Mono-element clarity.** One hero = one element. Easy to read, easy to draft, deep to combine.
2. **Elements are a 2-sided force.** Elemental statuses and reactions affect every unit on the field — enemy, creep, ally, *and you*. Setting up a reaction is powerful but can backfire. Skill is making it land on *them*, not you.
3. **Low-APM, high-positioning.** Click-to-move, one ability, one ult. Mastery is *where* and *when* you fight (which element overlaps which), not clicks-per-second.
4. **Every loss is recoverable, no loss is desirable.** The signature **revenge boss** turns a destroyed tower into a counter-punch, but losing a tower is always a *net* loss.
5. **One deterministic sim, two runtimes.** A pure-Dart simulation is the single source of truth on both server (authority) and client (prediction). This is the load-bearing architectural bet.

---

## 2. Locked Design Decisions (Non-Negotiable)

- Web multiplayer MOBA, **single lane**, Flutter + Flame, pixel-art via hand-drawn SVG.
- **1v1 now**; architecture & content scale to **3v3 later**.
- **Top-down** camera.
- Scope tier = **core MOBA loop**: creep waves, last-hit gold, hero XP/leveling, a **small** item shop, towers. (Jungle/neutral objectives are later — design hooks only.)
- **Signature mechanic — revenge boss:** when *your* tower is destroyed, that fallen tower rises as *your* boss and marches at the enemy who destroyed it. Killable but **permanent until slain**. Losing a tower stays a **net loss**; the boss is consolation, never an incentive.
- **Lane:** each side has 2 towers + a core. Win = destroy enemy core. Towers fall in order (outer → inner); core vulnerable only after both towers fall.
- **Controls:** click-to-move (right-click move, click enemy = auto-attack), keys for ability + ultimate. Low APM, touch-friendly later.
- **Hero kit:** minimal — auto-attack + exactly one ability + one ultimate. **Cooldown-only, no mana.**
- **Combat depth = elemental reactions**, using a **Genshin aura model** (receive element → status for a duration → different element detonates the reaction). Reactions are **neutral and two-sided** (affect all units incl. self).
- Heroes are **mono-element**; the second element for a reaction comes from **overlapping elemental fields** (both heroes' own neutral fields), elemental creeps, and "element steal" — **not** from a fixed terrain river (cut for now).
- **Elements (launch 5):** Pyro, Hydro, Electro, Cryo, Anemo. (Dendro & Geo later.)
- **Reactions:** Vaporize, Melt, Overload, Electro-Charged, Frozen, Superconduct, Swirl.
- **Architecture:** server-authoritative; pure-Dart `sim` package runs on both server and client; WebSocket transport; Flame rendering.
- **Lobby:** private room codes (create/join) first; quick-match later. No accounts for MVP.
- **Roster:** ~10 heroes = 2 per element, each a distinct MOBA role (the two sharing an element differ — one melee, one ranged). **All 10 is the launch goal**, added progressively onto the proven core as pure data + art.
- **Build approach:** phased — ship a **vertical slice (Milestone 0)** first to prove the core is fun, then expand.

---

## 3. The Elemental Reaction System (core of the game)

### 3.1 Aura / Status Model (Genshin-style, deterministic)

- **One status per unit.** A unit holds at most one elemental status: `{ element ∈ {Pyro, Hydro, Electro, Cryo}, strength ∈ {1=LIGHT, 2=STRONG}, expiryTick }`. **Anemo is never *stored*** as a status — it only *reads & consumes* an existing status (Swirl).
- **Applying element E to a unit:**
  1. Unit has **no** status → set status E (strength, expiry). No reaction.
  2. Unit has **same** element → refresh strength (take max) and expiry (clamped to ≤ 2× base). No reaction; never stacks past STRONG.
  3. Unit has a **different** element → **trigger the reaction**, consume the status, and stamp a per-unit, per-reaction-type **internal cooldown (ICD ≈ 0.5s)** so a single overlap can't machine-gun reactions.
- **LIGHT** application (autos, field ticks): short status (~1.5s base), base reaction potency.
- **STRONG** application (ultimates, designated heavy ability hits): longer status, ×1.5 reaction potency, resists being consumed by a single stray LIGHT hit on amplifying reactions.
- **Determinism:** fixed **30 ticks/sec**, integer fixed-point math only, no RNG in reactions, **documented per-tick application order** (field ticks → creep hits → hero ability/ult → hero autos, then ascending entityId). See §7 for why this is non-negotiable.

### 3.2 Neutral & Two-Sided (the defining rule)

Statuses and reactions are a **neutral force** — they belong to no team:

- **Elemental fields** (e.g., a fire trail, a water puddle) apply their element to **any** unit standing in them — enemy, creep, ally, **and the field's own owner**. Your own fire field can light *you*.
- A **reaction detonates on whichever unit carries the status**, regardless of who caused it. If you are Pyro-statused (because you stood in your own flames) and the enemy lands Hydro on you, **you** eat the Vaporize.
- **AoE reactions** (Overload, Swirl, the burst portion of others) damage **all** nearby units indiscriminately.

**Consequences:**
- It **solves the 1v1 sourcing problem** (see §4): two mono-element heroes generate reactions through their own overlapping neutral fields — no special terrain required.
- It is **self-balancing**: hard CC like Freeze does not need heavy-handed nerfs, because a careless setup can freeze *you*. The primary balancer for oppressive reactions is the **2-sided risk** itself.
- It creates real **3v3 friendly-fire positioning depth** later.

### 3.3 The Core Balance Rebalance (applied from critiques)

The raw design made amplifying reactions strictly superior and let element sources silently favor Pyro/Cryo. Three coupled fixes are committed:

1. **Field-sourced auras feed AMPLIFY (Vaporize/Melt) at a reduced ×1.3 cap.** The big ×2.0/×3.0 multipliers require a **contestable hero- or creep-applied** status. Positioning a target onto a field is good, not a free nuke.
2. **Published DPS-equivalence rule:** *no element's best available reaction may be >15% below another's in a standard same-level trade.* `REACTION_BASE` is tuned so transformative reactions (Superconduct shred, Electro-Charged DoT+slow, Overload interrupt, Swirl spread) are each worth ~a ×2.0 amplify. **Electro and Anemo are not burst-capped grief picks.**
3. **Swirl deals amplified, element-flavored damage** (not flat), so Anemo's payoff is competitive in 1v1.

### 3.4 Reaction Matrix

| Reaction | Pair | Class | Effect (post-fix) |
|---|---|---|---|
| **Vaporize** | Pyro + Hydro | Amplify | ×2.0 (Pyro trigger) / ×1.5 (Hydro trigger), ×1.5 on STRONG. **Field-sourced capped at ×1.3.** No residual status. |
| **Melt** | Pyro + Cryo | Amplify | Same structure as Vaporize. Also breaks Freeze (frees, no shatter). Tuned equal to Vaporize so no duo dominates. |
| **Overload** | Pyro + Electro | Transformative | Flat AoE burst + small **knockback + 0.25s stun**. Knockback **capped to once per ~2.5s per target** (no chain-peel). |
| **Electro-Charged** | Hydro + Electro | Transformative DoT | 3 ticks over 1.5s + ~20% slow; single non-repeating jump. Bounded, no self-refresh. |
| **Frozen** | Hydro + Cryo | Transformative hard-CC | **2-sided** (can freeze you). Base ~0.8–1.0s; **40% shorter per refresh within 8s** (floor 0.3s → immune); **freeze-immune window ≥ duration**; broken by Melt/shatter; tenacity reduces it. |
| **Superconduct** | Cryo + Electro | Transformative | Small AoE + **~40% physical-resist shred** + ~15% slow (shared bucket). Value-matched to an amplify. |
| **Swirl** | Anemo + any | Transformative spread | **Amplified element-flavored damage** + spreads that element (LIGHT) to ≤4 nearby units (each independently ICD-gated). |

### 3.5 Anti-Degenerate Guardrails (committed, in data)

- **Shared slow bucket capped at 35%** pooling all reaction + creep slows.
- **Per-target field-reaction-damage cap per 2s window** — a hero crossing a mandatory overlap can't be free-farmed by repeated chip.
- **Element-application stacking capped** so a LIGHT auto can never reach STRONG-tier potency via items + per-level growth combined.
- **Reaction rollout order** (build/ship sequence): Vaporize → Melt → Superconduct → Overload → Electro-Charged → Swirl → **Frozen (last)**.

---

## 4. Where the Second Element Comes From (sourcing — the riskiest assumption)

### 4.1 The Load-Bearing Truth

In a 1v1, two opposing mono-element heroes are **never a mutual reaction engine** through direct hits alone — each only ever applies *their* element to the *enemy*, so they coat each **other**, never co-load two elements on one unit. **Therefore every 1v1 reaction depends on a second element source that is not "my direct hit on you."** The 2-sided field model is what supplies it:

- **Overlapping neutral fields.** A hero's element-producing ability/ult leaves a **neutral field** (fire trail, water pool, static field, frost patch) that statuses *any* unit inside — including the owner. When the two heroes' fields overlap, or a hero is statused by their own field and then struck by the opponent's element, a reaction fires. This works **in the slice with just the two heroes**.
- **Element steal** (post-slice): last-hitting an elemental creep coats your next autos in that element (~4s, LIGHT-only), letting a mono hero apply a second element themselves.
- **Elemental creeps** (post-slice): every wave carries two different live elements that status nearby units and react with each other as teaching moments.
- **Anemo on-displacement** (Gale/Cirrus): shoving/pulling a unit through a field deterministically applies that element.

> **Hard launch gate — "time-to-second-element" (TT2E):** in a typical trade, a hero must be able to get a reaction-valid second element onto their target within **≤ 1.5s, in > 80% of trades.** Any tuning that misses this blocks launch. Instrument it from the first playable build.

### 4.2 No Fixed River (for now)

The earlier "always-Hydro river" terrain hazard is **cut**. It was a crutch for a problem the 2-sided field model already solves, and it asymmetrically favored Pyro/Cryo. Optional fixed terrain hazards may return **later** as a tuning lever **only if** TT2E telemetry shows hero-fields + creeps + steal are insufficient — and if so, as a **rotating/neutral** element, not a permanent Hydro band.

### 4.3 The Lane — "The Riven Causeway"

A horizontal single lane, mirror-symmetric, widening into three arenas (Blue mouth, Mid clash ring, Red mouth) joined by two narrow throats. Per side: a **core** (also the creep spawn; vulnerable only after both towers fall), an **inner tower** at the base mouth, an **outer tower** in the throat. Towers are offset to one side so a clear path remains (last-hit stand spots; clean revenge-boss march lane). **Shop = standing in your base footprint** (no walk-to shopkeeper). Throats have vision-blocking scenery for ambush geometry. Bases walled on three sides. The map carries **no element of its own** in MVP — all elements come from units and their fields.

### 4.4 Scaling to 3v3

In 3v3 the second element is overwhelmingly **teammate-sourced** (mixed-element parties — the Genshin party fantasy). The field-density knob is keyed to the **number of distinct elements on the field**, so low-diversity comps still get reactions. Per-mode caps (reaction potency, Swirl targets, team-CC uptime) and per-mode overrides for the two zoner-heaviest kits (Gale, Marisol) are planned, not built.

---

## 5. Hero Roster (10 — full kits, post-fix)

Every kit is **auto-attack + one ability + one ultimate, cooldown-only**, all applying the hero's single element. The two heroes per element differ in role (one melee, one ranged).

### Pyro 🔥

**Cinderfang the Ashwarden** — *Melee Bruiser / Diver*
- **Auto:** short-range chain-swipe (~1.2 tiles), slow but high per-hit; LIGHT Pyro.
- **Ability — Ember Hook (10s):** line skillshot (~5 tiles); yanks the first target to him, applying **STRONG** Pyro. *This STRONG hit is his amplify-trigger instance* (its damage is the amplified number), so his slow auto cadence doesn't starve him of reactions.
- **Ultimate — Pyre Unchained (75s):** 6s burning aura — bonus move speed + damage reduction, pulses Pyro to nearby foes, lays a lingering ~2s **neutral Pyro ground trail** (which can status him too).
- **Loop:** force the enemy onto your fire (or a teammate's water), saturate with Pyro to detonate; mind your own trail.

**Solène the Emberwright** — *Ranged Burst Mage / Zone Controller*
- **Auto:** lobbed fireball (~6 tiles, travel time); LIGHT Pyro.
- **Ability — Cinder Bloom (~12s):** delayed AoE Pyro burst at a placed point. Applies Pyro **once** on detonation (no perpetual field), **near-zero creep damage** (not a free CS engine). Brief **self-speed peel** on cast.
- **Ultimate — Meteor Vigil (80s):** telegraphed long-range meteor; heavy Pyro burst + lingering scorched field. A "force them to move" zone nuke.
- **Loop:** overlap her Pyro onto a second element; herd enemies.

### Hydro 💧

**Marisol, the Tidecaller** — *Ranged Controller / Zone Mage*
- **Auto:** slow water orb (medium range, travel time); LIGHT Hydro.
- **Ability — Tidepool (9s):** stationary **neutral** puddle (6s), slows 25%, continuously re-applies Hydro to any unit in it (incl. her), and deals a **real base-damage tick** (viable solo poke). Brief self-speed peel on cast.
- **Ultimate — Maelstrom (90s):** channeled vortex dragging enemies inward + heavy Hydro, then a burst; rooted while channeling.
- **Loop:** blanket Hydro, drag a target into a fire field.

**Kassia, the Undertow** — *Melee Bruiser / Diver*
- **Auto:** quick harpoon swings; every 3rd ("Crest") splashes stronger Hydro. Reliable last-hitter.
- **Ability — Riptide Hook (11s):** skillshot dash-grab; pulls Kassia *to* the target, knocks them, applies **STRONG** Hydro (amplify-trigger instance).
- **Ultimate — Undertow (75s):** dash + outward knock-ring scattering enemies into surrounding fields; 4s self-heal-on-hit. Engage **or** escape.
- **Loop:** physically move enemies onto the second element; sticky autos keep a target wet.

### Electro ⚡

**Volt, the Coilfang Reaver** — *Melee Bruiser / Diver*
- **Auto:** crackling gauntlet (~1.5 tiles); LIGHT Electro + 1 CHARGE (cap 5).
- **Ability — Arc Lunge (9s):** dash-strike; discharges CHARGE as Electro chains to nearby units; max CHARGE adds a short stun. Spends all CHARGE.
- **Ultimate — Overcharge Core (70s):** 5s walking Electro aura (pulse every 1s), bonus speed, double CHARGE gen, damage reduction.
- **Loop:** the premier self-reactor — coat a clump in Electro, fight on a second element. (Catch him at 0 CHARGE to punish.)

**Sael, the Tempest Diviner** — *Ranged Controller / Zone Mage*
- **Auto:** thrown charged sigil (~6 tiles, travel time); LIGHT Electro. Low DPS, high utility.
- **Ability — Conductor's Field (11s):** placed **neutral** static field; slows + keeps units Electro-coated; self-peel slow.
- **Ultimate — Galvanic Verdict (75s):** telegraphed lightning line; Electro burst, ~1.25s **root**, heavy lingering Electro coat.
- **Loop:** stamp Electro onto ground and rooted targets; let a second element meet it there.

### Cryo ❄️

**Vesna, the Hoarfrost Warden** — *Ranged Controller / Zone Mage*
- **Auto:** slow icicle bolt (medium range, travel time); LIGHT Cryo. The lane's primary Cryo applicator.
- **Ability — Permafrost Field (9s):** placed **neutral** frozen patch; heavy slow (~40%) + continuous Cryo. No direct damage.
- **Ultimate — Glacial Sepulcher (70s):** Cryo AoE burst; **Freezes only if STRONG (ult-tier) Hydro is co-present**, otherwise a deep slow — so a trivial Hydro tag can't auto-root.
- **Loop:** herd enemies into Hydro for her own Freeze; hand a fat Cryo aura to allies in 3v3.

**Bjorn, the Rimebound** — *Melee Bruiser / Frontline Duelist*
- **Auto:** heavy frost gauntlet; LIGHT Cryo + stacking slow (~12%, up to ~30%).
- **Ability — Rimeguard (12s):** self-cast shield + chilling pulse aura (slow + Cryo to nearby foes). His carried Cryo source.
- **Ultimate — Avalanche Lock (65s):** short gap-close slam; heavy Cryo burst + a **slow-stick tether escapable by moving directly away after ~1s** (not a hard leash).
- **Loop:** carry Cryo into melee, pin a target on a second element.

### Anemo 🌪️

**Gale, the Tempest Warden** — *Ranged Controller / Zoner*
- **Auto:** slow wind pulse (medium-long range); LIGHT Anemo. Slowest auto in the roster.
- **Ability — Crosswind (9s):** directional shove + brief slow; when it pushes a foe **onto/through an elemental field, it deterministically applies that field's element** on the spot. Self-peels.
- **Ultimate — Eye of the Maelstrom (75s):** stationary cyclone; pulls enemies inward, applies Anemo, and **Swirl-spreads** any present element across the clump.
- **Loop:** manufacture reactions out of others' fields by displacing enemies into them.

**Cirrus, the Skyrend Dancer** — *Melee Assassin / Skirmisher*
- **Auto:** fast low-range air-dagger slashes; LIGHT Anemo. Clean last-hitter, single-target shredder.
- **Ability — Slipstream (7s):** short blink-dash through enemies applying Anemo; engage, escape, and reaction-setup in one (nudges foes onto fields).
- **Ultimate — Razorgale Cyclone (65s):** 3s mobile blade-storm; fast-ticking Anemo for rapid Swirl detonations on a diving target.
- **Loop:** bring herself *to* the second element; chain Swirls at point-blank.

---

## 6. Core Loop & Economy

**Match length target: ~10 min.**

### Creep Waves
- 5-unit waves every 30s (first at 0:15); siege creep every 4th wave (~2:00). Same shape scales to 3v3 by spawning per-lane.
- **Post-slice:** each wave carries two different elements (a caster + an opposite-element acolyte) — a central second-element source. The slice uses **neutral creeps only**.

### Gold (last-hit primary)
- Melee 18 / ranged 30 / siege 45 / elemental 40 (last-hit value).
- Elemental-creep bonus is **element-agnostic** (any last-hit), not reaction-gated — no stealth Pyro/Cryo income edge.
- Hero bounty 150g base + capped streak/comeback gold; First Blood +50g.
- Tower 200g (outer) / 300g (inner) to the killer (the killer also triggers the enemy's **revenge boss** — see §7).
- **Comeback economy (anti-snowball):** passive trickle scales **up** for the gold-behind player (**+1g/s per 500g deficit**). Target **win-rate-after-first-tower < 65%**.

### XP / Leveling
- Proximity XP (shared, unmissable: melee 12 / ranged 20 / elemental 28 / siege 30 within ~2.5 tiles); hero kill 120, tower 90. Optional slight rubber-band toward the lower-level player.
- Max level **10**. Passive stat growth **every** level; ability ranks at **3/5/7/9**; ult at **4/6/8**. **MVP:** auto-rank on level-up (no rank-choice UI for a one-ability kit).

### Towers
- Outer ≈ 1800 HP / 90 armor / 120 dmg / 1.0 shots-s / ~6 tiles. Inner ≈ 2400 / 110 / 150 / 1.1 / ~6.
- **Reduced hero damage when no enemy creeps present** → sieging requires a wave (no solo cheese). Escalating same-target damage (+20%/shot up to +60%) punishes dives. **Verified:** a fed solo hero cannot drop an inner tower without a wave.

### Item Shop (small)
- ~6–10 items, generic stat items first; element-flavored items last and capped (a defensive "Elemental Ward" reducing reaction damage; a "Reaction Catalyst" snowball item priced highest with its amplify bonus reduced; "Elemental Phial" consumable granting a few off-element autos). Application-stacking capped so a LIGHT auto can never reach STRONG potency.

### Win
- Destroy enemy **core** (vulnerable only after both towers fall, outer → inner). Single lane, no alternate path for MVP.

---

## 7. Revenge Boss (Signature Mechanic)

When **your** tower is destroyed, that tower **rises as your boss** at its location and marches down-lane at the enemy who landed the killing blow ("the debtor"). Killable, **permanent until slain**, never times out.

- **Stats:** outer-tower boss ≈ 1400 HP / 70 dmg / 1-s; inner-tower boss ≈ 1900 HP / 95 dmg (bigger disaster → bigger counter-punch). ~40 armor. Immune to its owner's units; fights only the enemy side.
- **Net-loss guarantee:**
  - **Move speed 95–100% of a hero** — it genuinely cannot be ignored; the tower-killer must stop pushing to deal with it.
  - **No/token kill-bounty (~25g)** — the winner isn't rewarded for cleaning up their own punishment.
- **Targeting:** debtor first; else nearest enemy hero; then pushes lane attacking enemy creeps/structures.
- **Invariant:** the owner still loses vision, the tower's defensive DPS, and base exposure. The boss **cannot siege a core alone** and dies to focused effort. **You never want your own tower destroyed.**
- Tuning is data-driven; instrument win-rate-after-tower-loss from day one.

---

## 8. Technical Architecture

### 8.1 `packages/sim` — pure-Dart single source of truth
Holds **all** game logic: world model, fixed-timestep `step()`, deterministic combat, the aura/reaction system, gold/XP/levels, shop, win/lose. **No** rendering, networking, or I/O. **Zero** dependency on `flutter`/`flame`/`dart:ui`/`dart:io` — enforced by a **CI grep gate**.

**Determinism rules (the #1 risk):**
- **No floating point** in gameplay math — fixed-point ints (Q16.16 or milli-units). **dart2js ints are 53-bit doubles**, so all gameplay math is constrained to stay within 2^53 (published, asserted).
- No wall-clock / `DateTime.now` / `Timer` — time advances only by tick counter.
- Seeded RNG (xorshift/PCG) in-package; seed sent in `MatchStart`.
- Deterministic iteration order (ordered lists / `SplayTreeMap` by int entity id; never iterate hash-ordered `Map`/`Set`).
- No reflection, no `hashCode`-dependent branching.

**API contract (both sides call the same):** `Simulation.create(SimConfig)`, `List<SimEvent> step(tick, intents)`, `clone()`, `encode()/decode()`. `SimEvent`s (DamageDealt, ReactionTriggered, CreepKilled, TowerDestroyed, BossSpawned, LevelUp, CoreDestroyed) are **cosmetic only** — they never mutate state, so they fire identically on both ends.

### 8.2 `apps/server` — Dart authority
`shelf` + `shelf_web_socket` over `dart:io` HttpServer; `/ws` upgrade, `/health` check. One `Simulation` per `Match`; optionally one Isolate per match. `ConnectionManager` (sockets; JSON lobby / binary in-match frames), `RoomManager` (`Map<roomCode, Room>`, collision-free 4–6 char codes), `Match` (input buffer + authoritative tick loop + snapshot scheduler). The fixed-tick loop drains per-player intents → `step()` → schedules a snapshot. Authoritative on **everything**. Late/missing input = "hold last intent," never block the tick. Intents stamped `{seq, clientTick}`, applied at `max(serverTick, intentTick)`.

### 8.3 `apps/client` — Flutter + Flame (render + input only)
`MatchController` holds the local **predicted** `Simulation`. Flame = top-down `CameraComponent` following the local hero; components are thin views over `GameState` that lerp toward sim values; HUD is Flutter overlays. SVG **pre-rasterized to atlases at load** (never per frame); CanvasKit/WASM renderer.

- **Prediction:** local hero movement + casts applied immediately.
- **Reconciliation:** on each snapshot, overwrite authoritative state at tick T, discard acked intents, replay unacked by re-stepping the deterministic sim; smooth small corrections (no teleport).
- **Interpolation:** remote/AI entities rendered ~100ms in the past between two authoritative snapshots; no remote-input prediction.
- **Reactions:** predicted locally for instant VFX, but the authoritative `ReactionTriggered` + snapshotted aura state always win → mispredictions self-correct in 1–2 snapshots. Client/server can never *permanently* disagree on what fired.

### 8.4 Net Model
Server simulates **30 Hz** (33.3ms). Snapshots **15–20 Hz** (keyframe ~1s + deltas). Client renders 60+fps. **C→S:** input intents only (small, event-driven; last-few resent for loss tolerance; idempotent). **S→C:** state (periodic full keyframe + per-entity deltas + window `SimEvent`s + `ackedSeq`). Lag compensation suited to click-to-move: input-tick scheduling + local prediction + opponent interpolation. No hitscan rewind.

### 8.5 Protocol
JSON for lobby (rare, debuggable), compact binary for in-match (intents + snapshots). `PlayerIntent` and `SimEvent` map **1:1** onto the sim's own types — a new hero ability needs no protocol change beyond a new aim payload.
- **C→S:** HELLO, CREATE_ROOM, JOIN_ROOM, PICK_HERO, READY, START_MATCH, LEAVE_ROOM, INPUT{seq,clientTick,intent}, REQUEST_KEYFRAME, PING.
- **S→C:** HELLO_OK/ERROR, ROOM_CREATED, ROOM_STATE, MATCH_START{seed,config,playerSlotMap,startTick}, SNAPSHOT{serverTick,baseTick,full,entities,events,acks}, EVENT, MATCH_END, PLAYER_DISCONNECTED/RECONNECTED, PONG.

### 8.6 Lobby Flow (private room codes, no accounts)
Name + hero on one screen → HELLO → CREATE_ROOM (unique short code, ambiguous chars excluded) or JOIN_ROOM (validate exists/capacity/lobby/name) → PICK_HERO + READY (re-broadcast ROOM_STATE on every change) → host START_MATCH (validate full + ready, pick seed, freeze roster) → MATCH_START. Reconnect grace (~30s) reclaims entityId + fresh keyframe. Rematch reverts the room to lobby. `mode`/`team`/`slot` are baked in for 3v3 forward-compat.

### 8.7 Deployment
Two artifacts: a long-lived **stateful** Dart server (in-RAM rooms + WebSockets — **not** serverless) and a static Flutter-web bundle. Server: single small VPS / Fly machine running a `dart compile exe` binary in a slim Docker image; `/health` + `/ws`; scale horizontally later (sticky by room code, or Isolate-per-match). Client: `flutter build web` (CanvasKit/WASM) → CDN (Cloudflare Pages / Netlify / Firebase). Same origin / same root domain for `wss://` to avoid CORS + mixed-content. A single-box variant (server also serves static via `shelf_static`) is fine for MVP.

### 8.8 Monorepo Layout
```
guild/                      # Dart 3 pub workspace
├─ packages/
│  ├─ sim/                  # PURE Dart — all logic; NO flutter/flame/dart:io/dart:ui
│  │  └─ lib/src/{math, model, elements, systems, data, intent, events, simulation, codec}
│  └─ protocol/             # wire types + codecs (depends on sim)
├─ apps/
│  ├─ server/               # shelf + shelf_web_socket (depends on sim+protocol); Dockerfile
│  └─ client/               # Flutter + Flame (depends on sim+protocol)
│     └─ lib/{net, match, render, ui, main}; assets/ (SVG); web/
└─ tooling/                 # CI: "no banned imports in packages/sim" + determinism golden test
```
**Dependency rule (one-way):** client → {sim, protocol}; server → {sim, protocol}; protocol → sim; sim → nothing platform-bound.

---

## 9. Art / Asset Approach

- **Aesthetic:** hand-drawn pixel-art delivered as **SVG**, top-down read; heavy silhouettes, element-coded palettes (Pyro orange, Hydro teal, Electro violet, Cryo white-blue, Anemo pale green).
- **Pipeline:** SVG decoded **once** to textures/sprite atlases at load — **never** re-rasterized per frame (that tanks web FPS). Profile a stress scene (full wave + projectiles + reaction VFX) on mid-tier hardware (CanvasKit/WASM) before committing the pipeline.
- **Decoupling:** heroes are pure data tables, so **art ships last**. The vertical slice uses flat geometric placeholders (colored shapes + a directional indicator). Build the game, then art the 2 slice heroes, then add the rest progressively.
- **Reaction VFX:** MVP renders a generic flash + text label ("VAPORIZE ×2.0") to prove **legibility** before investing in per-reaction effects (scheduled alongside hero art, last).

---

## 10. MVP (Vertical Slice) vs Later

| System | MVP / Vertical Slice | Later |
|---|---|---|
| Heroes | **2** (Cinderfang Pyro melee + Marisol Hydro ranged) | Remaining 8 as data + art (all 10 = launch goal) |
| Reactions | **1** (Vaporize), neutral & 2-sided | Melt → Superconduct → Overload → Electro-Charged → Swirl → **Frozen (last)** |
| 2nd-element source | The two heroes' **own overlapping neutral fields** | Elemental creeps + element-steal + Anemo on-displacement |
| Fixed terrain | **None** (no river) | Optional rotating hazard *only if* TT2E telemetry demands it |
| Towers/core | 2 towers + core, ordered gating | unchanged |
| Economy | Last-hit gold only | Bounties, comeback trickle, shutdown gold |
| Leveling | **Flat stats, ult from start** | Lvl 1–10, auto-rank ability/ult |
| Item shop | **None** | Generic stat items first; element items (Catalyst, Ward, Phial) last |
| Revenge boss | **None** | Full spec (data-tunable, net-loss instrumented) |
| Lobby | **Hardcoded 2-player room** | Room-code lobby + reconnect grace + rematch |
| Art | Geometric placeholders + text VFX | Hand-drawn SVG + per-reaction VFX |
| Mode | 1v1 only; `mode`/`teamId` forward-compat baked in | 3v3 (no `==2` assumptions; per-mode caps; Gale/Marisol overrides) |

---

## 11. Vertical Slice Milestone (Milestone 0)

**Goal:** the thinnest end-to-end **online** playable that proves the two novel/risky pillars **together** — cross-platform deterministic sim **and** one neutral, 2-sided elemental reaction sourced from the two heroes' own overlapping fields.

**Scope:** 2 heroes (one melee Pyro, one ranged Hydro), 1 reaction (**Vaporize**, neutral & 2-sided), **no terrain** (second element comes from Cinderfang's Pyro field/trail + Marisol's Tidepool overlapping), neutral creeps only, 2 towers + core with ordered gating, last-hit gold, no shop, flat stats + ult-from-start, no boss, hardcoded 2-player room, placeholder art, text-label reaction VFX. **Win = destroy enemy core.**

**Build-order gates (each builds on a verified base):**
1. **Sim skeleton + cross-platform replay golden test green in CI FIRST.** Record an input log; replay on dart-native **and** dart2js **and** dart2wasm; assert byte-identical `encode()`. If this can't go green in week 1, the "same sim both sides" architecture is invalid — change it immediately (e.g., server-authoritative-only + interpolation, no client prediction of sim).
2. **Movement-only predict/reconcile/interpolate loop**, proven clean with **150ms injected latency + a packet-loss simulator** (no rubber-banding on the local hero, smooth opponent) **before any combat**.
3. Layer auto-attacks, towers, last-hit/gold.
4. Layer the 2 hero kits + the single-aura system + Vaporize + the neutral fields (and the **2-sided** rule — a hero can be caught in their own/the overlap).
5. **Instrument TT2E and reactions-per-minute of lane combat** to validate the core-depth thesis. If two heroes' own fields can't reliably produce satisfying reactions, the core loop needs rework — learned cheaply (only 2 heroes built).

**Target: 4–6 weeks.** Everything else (8 more heroes as data + art, 6 more reactions, elemental creeps, element-steal, shop, leveling, revenge boss, room-code lobby, reconnect, 3v3) is additive onto this proven base.

---

## 12. Top Risks (with de-risking)

1. **Determinism drift (native vs JS/WASM).** *The #1 killer.* De-risk: fixed-point ints within 2^53, seeded RNG, ordered collections; **replay golden test as a hard CI gate before any gameplay code.**
2. **Prediction/reconciliation jank.** De-risk: prove the full loop for **movement only** with injected latency before any combat — every later bug is then a *combat* bug, not a netcode bug.
3. **Second-element sourcing too sparse → reactions rare → core depth collapses.** De-risk: TT2E is a **hard launch gate**; 2-sided neutral fields make the two heroes self-sufficient in the slice; creeps + steal + Anemo displacement added next; mirror matchups (Pyro-vs-Pyro etc.) are an explicit acceptance test.
4. **Revenge boss must stay a net loss.** De-risk: data-tunable stats, 95–100% speed, no/token bounty, instrument win-rate-after-tower-loss (< 65%).
5. **1v1→3v3 quietly breaking assumptions.** De-risk: `mode`/`teamId` from day one, no `==2` leaks, but **build no 3v3 logic in MVP**; per-mode caps and Gale/Marisol overrides planned, not built.
6. **Hosting a stateful WS process cheaply + reconnects.** De-risk: single VPS/Fly, in-RAM rooms, reconnect grace + REQUEST_KEYFRAME + ping/pong; shard only when concurrency demands.
7. **Flame + SVG web performance.** De-risk: pre-rasterize to atlases at load, CanvasKit/WASM, profile a stress scene before committing the art pipeline.
8. **Total scope ≈ 12–18 months.** De-risk: ship Milestone 0 (4–6 weeks), then expand the proven core with data.

---

## 13. Resolved Decisions & Remaining Tuning Notes

**Resolved this session:**
- Build approach → **phased**, vertical slice first.
- Launch roster → **all 10** is the goal, added progressively.
- Fixed river → **cut** (2-sided fields make it unnecessary; revisit only if TT2E fails).
- Reactions → **neutral & 2-sided** (affect all units incl. self), Genshin aura timing (status on hit → second element detonates).
- Freeze safety → handled primarily by **2-sidedness** + diminishing returns (not an ult-only hard gate).
- Solène nerf → kept **light** (single application + near-zero creep damage + ~12s CD), not one hard nerf.
- Second-element agency → **element steal** retained (free, on last-hit) as the post-slice self-source.

**Deferred tuning (playtest-time, data-driven — not blocking):**
- Exact aura durations, reaction `REACTION_BASE` values, freeze base duration, boss stats, economy curves.
- Whether to add a rotating neutral hazard later (gated on TT2E telemetry).
- Per-mode 3v3 caps and overrides.
