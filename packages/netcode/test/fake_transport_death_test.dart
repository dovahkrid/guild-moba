import 'package:netcode/netcode.dart';
import 'package:netcode/test_support/fake_transport.dart';
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';
import 'package:test/test.dart';

MatchController _client({int seed = 1, int slot = 0}) =>
    MatchController(seed: seed, localSlot: slot, startTick: 0);

void main() {
  // The enemy outer tower (team 1) sits at +kOuterTowerX; dropping the local hero
  // there at ~0 hp lets the tower kill it deterministically (only damage source:
  // first creep wave is tick 450, beyond these runs).
  test('FakeTransport mirrors the server: death cancels the held order (respawn stands still)', () {
    final t = FakeTransport(
        seed: 1, client: _client(), localSlot: 0, oneWayLatencyMs: 0, lossRate: 0.0);

    // Establish a held MOVE order toward the enemy side (+x).
    t.clientSend(InputMsg(
        slot: 0, seq: 1, clientTick: 0,
        aimX: Fixed.fromInt(20).raw, aimY: 0, type: IntentType.move.index));
    t.tickWorld(); // deliver + establish the held order

    // Force a deterministic death: drop the hero into the enemy outer tower's
    // range at ~0 hp. (Held order keeps it in range until the tower fires.)
    t.server.entity(0).pos = FVec2(kOuterTowerX, Fixed.zero);
    t.server.entity(0).hp = Fixed.raw(1);

    // Run through death + full respawn + a buffer for any re-fed order to move it.
    for (var i = 0; i < kHeroRespawnTicks + 40; i++) {
      t.tickWorld();
    }

    final hero = t.server.entity(0);
    expect(hero.respawnTimer, 0, reason: 'hero should be back up');
    // The held order was cancelled on death (clearSlot-on-HeroDowned) → the
    // respawned hero STANDS at spawn; it does not resume walking toward +x.
    expect(hero.pos.x.raw, kHero0SpawnX.raw, reason: 'server hero stands at spawn');
    expect(hero.pos.y.raw, Fixed.zero.raw);
    // End-to-end (no rubber-band): the client's predicted local hero also stands
    // at spawn — it was not yanked back onto a re-fed order after respawn.
    expect(t.client.debugLocalPos().x.raw, kHero0SpawnX.raw,
        reason: 'client predicted local hero stands at spawn (no rubber-band)');
  });

  test('FakeTransport mirrors the server: input arriving while downed is dropped', () {
    final t = FakeTransport(
        seed: 1, client: _client(), localSlot: 0, oneWayLatencyMs: 0, lossRate: 0.0);

    // Down the local hero this frame (tower kill).
    t.server.entity(0).pos = FVec2(kOuterTowerX, Fixed.zero);
    t.server.entity(0).hp = Fixed.raw(1);
    t.tickWorld();
    expect(t.server.entity(0).isDowned, isTrue, reason: 'hero is downed');

    // An order arrives while the slot is downed → the server must DROP it (no
    // held update, no ack) so it cannot resume after respawn.
    t.clientSend(InputMsg(
        slot: 0, seq: 5, clientTick: 0,
        aimX: Fixed.fromInt(20).raw, aimY: 0, type: IntentType.move.index));

    for (var i = 0; i < kHeroRespawnTicks + 40; i++) {
      t.tickWorld();
    }

    final hero = t.server.entity(0);
    expect(hero.respawnTimer, 0, reason: 'hero should be back up');
    expect(hero.pos.x.raw, kHero0SpawnX.raw,
        reason: 'a downed-window order is dropped → respawned hero stands at spawn');
  });
}
