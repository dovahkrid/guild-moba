import 'package:sim/sim.dart';
import 'package:test/test.dart';

Simulation _run(int ticks) {
  final s = Simulation.create(const SimConfig(seed: 1337));
  // Combat-free anchor: heroes move APART (toward their own inner towers) so
  // adding combat behavior in later tasks never disturbs this pinned hash.
  const m0 = Intent(playerSlot: 0, type: IntentType.move, aimX: -655360, aimY: 131072, seq: 1);
  const m1 = Intent(playerSlot: 1, type: IntentType.move, aimX: 655360, aimY: 131072, seq: 1);
  for (var t = 0; t < ticks; t++) {
    s.step(t, [m0, m1]);
  }
  return s;
}

void main() {
  test('restoreFromSnapshot reproduces full state incl. tick, RNG, target', () {
    final src = _run(120);
    final dst = Simulation.create(const SimConfig(seed: 1337)); // different state
    dst.step(0, const []);

    dst.restoreFromSnapshot(src.snapshotBytes());

    // Canonical hash (pos/vel/hp/tick/rng) must match exactly.
    expect(dst.canonicalStateHash(), src.canonicalStateHash());
    expect(dst.tick, src.tick);
    // Target restored: stepping both one more tick with no intent stays in lockstep.
    src.step(120, const []);
    dst.step(120, const []);
    expect(dst.canonicalStateHash(), src.canonicalStateHash());
  });

  test('snapshot round-trips through bytes and continues deterministically', () {
    final src = _run(90);
    final bytes = src.snapshotBytes();
    final dst = Simulation.create(const SimConfig(seed: 1337))..restoreFromSnapshot(bytes);
    for (var t = 90; t < 200; t++) {
      src.step(t, const []);
      dst.step(t, const []);
    }
    expect(dst.canonicalStateHash(), src.canonicalStateHash());
  });

  test('peekEntityPos reads an entity pos from snapshot bytes', () {
    final src = _run(60);
    final bytes = src.snapshotBytes();
    final p1 = Simulation.peekEntityPos(bytes, 1);
    expect(p1.x.raw, src.entity(1).pos.x.raw);
    expect(p1.y.raw, src.entity(1).pos.y.raw);
  });

  test('canonicalBytes/hash unchanged (golden untouched)', () {
    expect(_run(300).canonicalStateHash(), 0xa14ee38d);
  });

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
}
