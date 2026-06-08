import 'package:sim/sim.dart';
import 'package:test/test.dart';

// Plan 5 (elemental v2) reaction rules:
//   - a bare status deals NO damage;
//   - fields coat 2-sided with NO DoT (the owner is not exempt, takes no self-damage);
//   - a field-overlap reaction deals FLAT kReactionFlatDamage to an ENEMY of the
//     field owner, but 0 to the owner/own-team (status consumed + ICD stamped +
//     event emitted with multiplierRaw 0 either way);
//   - the cast burst is a one-time ENEMY-ONLY AoE (owner/own-team take 0); it
//     coats + can attack-amplify (×kVaporizeMult);
//   - autos attack-amplify (×kVaporizeMult); both reaction paths share reactionIcd;
//   - cast burst + field reactions hit creeps.
void main() {
  // --- Field placement / lifecycle (unchanged mechanics) ---

  test('Marisol (hero 1) casts Tidepool at the aim point with Hydro', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    expect(sim.fields, isEmpty);
    // aim at world (3,0) => Q16.16 raws (3*65536 = 196608). No enemy in range → no burst effect.
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
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
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 655360, aimY: 655360, seq: 1)]);
    final f = sim.fields.single;
    expect(f.ownerId, 0);
    expect(f.element, Element.pyro.index);
    expect(f.center.x.toDouble(), -5.0); // self-placed, NOT the (10,10) aim
  });

  test('a field cannot be recast while the ability is on cooldown', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 0, seq: 1)]);
    expect(sim.fields, hasLength(1));
    sim.step(1, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 131072, aimY: 0, seq: 2)]);
    expect(sim.fields, hasLength(1)); // on cooldown → not recast
    expect(sim.fields.single.center.x.toDouble(), 0.0); // original field, not the blocked recast
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

  test('a placed field survives a snapshot round-trip', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    sim.entity(0).pos = FVec2(Fixed.fromInt(-40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const [Intent(playerSlot: 1, type: IntentType.ability, aimX: 196608, aimY: 458752, seq: 1)]);
    expect(sim.fields, hasLength(1));
    final dst = Simulation.create(const SimConfig(seed: 1))
      ..restoreFromSnapshot(sim.snapshotBytes());
    expect(dst.fields, hasLength(1));
    final f = dst.fields.single;
    expect(f.ownerId, 1);
    expect(f.element, Element.hydro.index);
    expect(f.center.x.toDouble(), 3.0);
    expect(f.center.y.toDouble(), 7.0);
    expect(f.timer, sim.fields.single.timer);
    expect(dst.canonicalStateHash(), sim.canonicalStateHash());
  });

  // --- Coating (2-sided, no DoT) ---

  test('a field coats a hero standing inside it (no damage)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1);
    h.pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // tower-safe off-lane
    h.target = h.pos;
    final hpBefore = h.hp.raw;
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.pyro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(h.statusElement, Element.pyro.index);
    expect(h.statusTimer, greaterThan(0));
    expect(h.hp.raw, hpBefore); // coat is damage-free
  });

  test('a field coats its OWNER 2-sided with NO DoT (the self-suicide bug is gone)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final owner = sim.entity(0); // Cinderfang stands in his own Ember Field
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    owner.pos = spot;
    owner.target = spot;
    final ownerHpBefore = owner.hp.raw;
    sim.fields.add(ElementalField(
        ownerId: 0, center: spot, element: Element.pyro.index, timer: 100));
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(0, const []);
    expect(owner.statusElement, Element.pyro.index); // coated (2-sided: owner not exempt)
    expect(owner.hp.raw, ownerHpBefore); // NO self-damage
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

  test('same-element re-application refreshes the timer (no stacking, no damage)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.hydro.index;
    h.statusTimer = 3;
    final hpBefore = h.hp.raw;
    sim.fields.add(ElementalField(
        ownerId: 1, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []);
    expect(h.statusElement, Element.hydro.index);
    expect(h.statusTimer, kStatusDurationTicks); // refreshed to full
    expect(h.hp.raw, hpBefore); // still no damage
  });

  // --- Bare status / expiry ---

  test('a bare elemental status deals no damage by itself', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 30;
    final hpBefore = h.hp.raw;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.step(0, const []); // no field, no auto — just a status
    expect(h.hp.raw, hpBefore); // status alone never damages
    expect(h.statusElement, Element.pyro.index); // still coated
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
    expect(h.statusTimer, 0);
  });

  // --- Field-overlap flat reaction (enemy-only damage; owner-safe) ---

  test('field-overlap reaction: FLAT damage to an enemy of the owner, status consumed + event', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // victim (team 1)
    h.target = h.pos;
    h.statusElement = Element.pyro.index; // pre-coated opposite element
    h.statusTimer = 30;
    final hpBefore = h.hp.raw;
    // A Hydro field owned by hero 0 (enemy of hero 1) centered on the victim.
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero); // owner far (no auto)
    sim.entity(0).target = sim.entity(0).pos;
    final events = sim.step(0, const []);
    expect(h.hp.raw, hpBefore - kReactionFlatDamage.raw); // FLAT, not amplified
    expect(h.statusElement, -1); // consumed
    expect(h.reactionIcd, kReactionIcdTicks); // ICD stamped
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.unitId, 1);
    expect(rt.reaction, Reaction.vaporize.index);
    expect(rt.multiplierRaw, 0); // flat marker (client renders "VAPORIZE", no ×)
    expect(rt.sourceId, 0); // the field owner
  });

  test('field-overlap reaction: ZERO damage to the OWNER, but status still consumed + ICD + event', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final cinder = sim.entity(0); // owner == victim (same team)
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    cinder.pos = spot;
    cinder.target = spot;
    cinder.statusElement = Element.hydro.index; // opposite to his own Pyro field
    cinder.statusTimer = 30;
    final hpBefore = cinder.hp.raw;
    sim.fields.add(ElementalField(
        ownerId: 0, center: spot, element: Element.pyro.index, timer: 100)); // his OWN field
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    final events = sim.step(0, const []);
    expect(cinder.hp.raw, hpBefore); // ZERO self-damage (THE headline fix)
    expect(cinder.statusElement, -1); // status still consumed
    expect(cinder.reactionIcd, kReactionIcdTicks); // ICD still stamped
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.unitId, 0);
    expect(rt.multiplierRaw, 0); // flat
  });

  test('a status expiring this tick still field-reacts this tick, then is swept', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h = sim.entity(1)..pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // enemy of owner 0
    h.target = h.pos;
    h.statusElement = Element.pyro.index;
    h.statusTimer = 1; // decrements to 0 BEFORE the field tick this tick
    sim.fields.add(ElementalField(
        ownerId: 0, center: h.pos, element: Element.hydro.index, timer: 100));
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    final events = sim.step(0, const []);
    expect(events.whereType<ReactionTriggered>().single.unitId, 1); // reacted before the sweep
    expect(h.statusElement, -1); // then consumed/swept
  });

  test('the reaction ICD blocks a second field reaction until it expires', () {
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

  test('field-overlap reaction damages a neutral creep (enemy of the owner)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final spot = FVec2(Fixed.fromInt(-8), Fixed.zero); // tower-safe (own-team tower won't target a creep)
    final creep = sim.entity(kCreepIdBase)..pos = spot;
    creep.statusElement = Element.pyro.index; // pre-coated opposite
    creep.statusTimer = 30;
    final creepHpBefore = creep.hp.raw;
    sim.entity(0).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(0).target = sim.entity(0).pos;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.fromInt(2));
    sim.entity(1).target = sim.entity(1).pos;
    sim.fields.add(ElementalField(
        ownerId: 1, center: spot, element: Element.hydro.index, timer: 100)); // owner hero 1
    final events = sim.step(kFirstWaveTick + 1, const []);
    expect(creep.hp.raw, creepHpBefore - kReactionFlatDamage.raw); // creep (team 2) is an enemy
    expect(creep.statusElement, -1);
    expect(events.whereType<ReactionTriggered>().single.unitId, kCreepIdBase);
  });

  // --- Auto-attack coat + attack-amplify (retained from Plan 4) ---

  test('a hero auto coats its locked enemy with the hero element', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final a = sim.entity(0); // Cinderfang → Pyro
    final b = sim.entity(1);
    a.pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    b.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    a.target = a.pos;
    b.target = b.pos;
    final bHpBefore = b.hp.raw;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(b.statusElement, Element.pyro.index);
    expect(b.hp.raw, bHpBefore - kHeroAttackDamage.raw); // coat + plain auto damage
  });

  test('auto-attack amplifies (×kVaporizeMult) on a differently-coated enemy', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final a = sim.entity(0); // Pyro auto
    final b = sim.entity(1);
    a.pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    b.pos = FVec2(Fixed.fromInt(1), Fixed.fromInt(7));
    a.target = a.pos;
    b.target = b.pos;
    b.statusElement = Element.hydro.index; // pre-coated opposite
    b.statusTimer = 30;
    final bHpBefore = b.hp;
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(b.hp.raw, (bHpBefore - (kHeroAttackDamage * kVaporizeMult)).raw); // amplified (no field to re-coat)
    expect(b.statusElement, -1); // consumed
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.multiplierRaw, kVaporizeMult.raw); // amplify marker
    expect(rt.sourceId, 0);
    expect(rt.unitId, 1);
  });

  // --- Cast burst (enemy-only; owner-safe; amplifies; hits creeps) ---

  test('cast burst: enemy-only AoE damages an enemy hero in radius; OWNER takes 0', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final caster = sim.entity(0); // Cinderfang self-places at his feet (0,7)
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    caster.pos = spot;
    caster.target = spot;
    final enemy = sim.entity(1)..pos = FVec2(Fixed.fromNum(1), Fixed.fromInt(7)); // dist 1 < radius 2.5
    enemy.target = enemy.pos;
    final enemyHpBefore = enemy.hp.raw;
    final casterHpBefore = caster.hp.raw;
    sim.step(0, const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1)]);
    expect(enemy.hp.raw, enemyHpBefore - kCastBurstDamage.raw); // enemy took the (un-amplified) burst
    expect(enemy.statusElement, Element.pyro.index); // coated by the burst
    expect(caster.hp.raw, casterHpBefore); // OWNER took ZERO (self-safe)
  });

  test('cast burst hits neutral creeps in radius (cooldown-gated AoE farm)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    for (var t = 0; t <= kFirstWaveTick; t++) {
      sim.step(t, const []);
    }
    final caster = sim.entity(0);
    final spot = FVec2(Fixed.fromInt(-8), Fixed.zero); // own side, creep tower-safe
    caster.pos = spot;
    caster.target = spot;
    final creep = sim.entity(kCreepIdBase)..pos = spot;
    final creepHpBefore = creep.hp.raw;
    sim.entity(1).pos = FVec2(Fixed.fromInt(40), Fixed.zero);
    sim.entity(1).target = sim.entity(1).pos;
    sim.step(kFirstWaveTick + 1,
        const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 0, seq: 1)]);
    expect(creep.hp.raw, creepHpBefore - kCastBurstDamage.raw); // creep (team 2) is an enemy → hit
    expect(creep.statusElement, Element.pyro.index); // and coated
  });

  test('cast burst amplifies (×kVaporizeMult) when the enemy was pre-coated with a different element', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final caster = sim.entity(0); // Pyro burst
    final spot = FVec2(Fixed.zero, Fixed.fromInt(7));
    caster.pos = spot;
    caster.target = spot;
    final enemy = sim.entity(1)..pos = FVec2(Fixed.fromNum(1), Fixed.fromInt(7));
    enemy.target = enemy.pos;
    enemy.statusElement = Element.hydro.index; // pre-coated opposite
    enemy.statusTimer = 30;
    final enemyHpBefore = enemy.hp;
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1)]);
    // The burst amplifies (×mult); the same-tick field then re-coats the (now -1) enemy with Pyro.
    expect(enemy.hp.raw, (enemyHpBefore - (kCastBurstDamage * kVaporizeMult)).raw);
    final rt = events.whereType<ReactionTriggered>().single;
    expect(rt.multiplierRaw, kVaporizeMult.raw); // amplify, not flat
    expect(rt.sourceId, 0);
    expect(rt.unitId, 1);
  });

  // --- Shared ICD across both reaction paths ---

  test('shared reactionIcd: a field reaction + an auto in one window yield ONE reaction', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h0 = sim.entity(0); // Pyro field owner + Pyro auto
    final h1 = sim.entity(1); // victim, pre-coated Hydro (opposite)
    h0.pos = FVec2(Fixed.zero, Fixed.fromInt(7));
    h1.pos = FVec2(Fixed.fromNum(1), Fixed.fromInt(7)); // in field + auto range
    h0.target = h0.pos;
    h1.target = h1.pos;
    h1.statusElement = Element.hydro.index;
    h1.statusTimer = 30;
    sim.fields.add(ElementalField(
        ownerId: 0, center: h0.pos, element: Element.pyro.index, timer: 100));
    final events = sim.step(0, const [Intent(playerSlot: 0, type: IntentType.attack, aimX: 1, seq: 1)]);
    expect(events.whereType<ReactionTriggered>(), hasLength(1)); // field reacts; the auto is ICD-blocked
  });

  test('a hero downed by a same-tick cast burst does not cast back (no corpse cast)', () {
    final sim = Simulation.create(const SimConfig(seed: 1));
    final h0 = sim.entity(0)..pos = FVec2(Fixed.zero, Fixed.fromInt(7)); // Pyro, casts first (lower seq)
    h0.target = h0.pos;
    final h1 = sim.entity(1)..pos = FVec2(Fixed.fromNum(1), Fixed.fromInt(7)); // in h0's burst radius
    h1.target = h1.pos;
    h1.hp = Fixed.fromNum(5); // < kCastBurstDamage (16) → downed by h0's burst this tick
    sim.step(0, const [
      Intent(playerSlot: 0, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 1),
      Intent(playerSlot: 1, type: IntentType.ability, aimX: 0, aimY: 458752, seq: 2),
    ]);
    expect(h1.hp.raw, lessThanOrEqualTo(0)); // h0's burst downed h1 in phase 1
    expect(sim.fields.where((f) => f.ownerId == 1), isEmpty); // the corpse did NOT place a field / cast back
    expect(sim.fields.where((f) => f.ownerId == 0), hasLength(1)); // h0's own cast still happened
  });
}
