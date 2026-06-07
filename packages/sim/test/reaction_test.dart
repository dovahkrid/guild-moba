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
    expect(sim.fields.single.center.x.toDouble(), 0.0); // original field, not replaced by the cooldown-blocked recast
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
    expect(b.hp.raw, lessThan(kHeroMaxHp.raw)); // _applyHit also dealt damage (chokepoint)
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
    expect(h.statusTimer, 0); // timer floored before the sweep cleared the element
  });
}
