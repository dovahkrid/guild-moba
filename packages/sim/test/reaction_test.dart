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
}
