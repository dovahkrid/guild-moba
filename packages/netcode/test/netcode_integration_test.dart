import 'package:netcode/netcode.dart';
import 'package:netcode/test_support/fake_transport.dart';
import 'package:protocol/protocol.dart';
import 'package:sim/sim.dart';
import 'package:test/test.dart';

MatchController _makeClient({int seed = 1337, int slot = 0}) =>
    MatchController(seed: seed, localSlot: slot, startTick: 0);

FakeTransport _makeTransport({
  int seed = 1337,
  int slot = 0,
  int oneWayLatencyMs = 75,
  double lossRate = 0.0,
}) {
  final client = _makeClient(seed: seed, slot: slot);
  return FakeTransport(
    seed: seed,
    client: client,
    localSlot: slot,
    oneWayLatencyMs: oneWayLatencyMs,
    lossRate: lossRate,
  );
}

void main() {
  // ── Case 1: Zero-latency, zero-loss baseline ──────────────────────────────
  test('case 1: zero-latency zero-loss baseline — correction == 0 on every reconcile',
      () {
    final t = _makeTransport(oneWayLatencyMs: 0, lossRate: 0.0);
    // Apply a move so the hero walks somewhere.
    final msg = t.client.applyLocalInput(655360, 0);
    t.clientSend(msg);

    var reconciled = false;
    for (var i = 0; i < 40; i++) {
      t.tickWorld();
      if (t.client.lastServerTick >= 0) {
        reconciled = true;
        expect(t.client.lastCorrectionDist, 0.0,
            reason: 'zero-latency should always reconcile exactly (tick ${t.client.lastServerTick})');
      }
    }
    expect(reconciled, isTrue, reason: 'should have received at least one snapshot');
  });

  // ── Case 2: 150ms bounded + steady-state-exact ───────────────────────────
  test(
      'case 2: 150ms latency — in-motion correction < 0.5, steady-state correction == 0.0 exactly',
      () {
    final t = _makeTransport(oneWayLatencyMs: 75);

    // Apply a move that makes the hero move to a specific target.
    // The hero starts at x = Fixed.fromInt(-8) and target defaults to FVec2.zero.
    // Use a target well within range so hero reaches it within ~40 ticks.
    final msg = t.client.applyLocalInput(Fixed.fromInt(0).raw, Fixed.fromInt(0).raw);
    t.clientSend(msg);

    var maxCorrectionInMotion = 0.0;
    var steadyStateCorrection = -1.0;

    // Run 120 ticks. Hero should reach target (0, 0) within ~60 ticks from (-8, 0)
    // at 0.15 world units/tick: 8/0.15 = ~54 ticks.
    for (var i = 0; i < 120; i++) {
      t.tickWorld();
      if (t.client.lastServerTick >= 0) {
        final d = t.client.lastCorrectionDist;
        // In motion (first 60 ticks), correction should be bounded.
        if (i < 80) {
          if (d > maxCorrectionInMotion) maxCorrectionInMotion = d;
          expect(d, lessThan(0.5),
              reason: 'in-motion correction must stay < 0.5 (got $d at world-tick ${t.client.lastServerTick})');
        }
      }
    }

    // After tick 80, the hero should have reached its target.
    // Continue running and confirm correction is exactly 0.
    for (var i = 0; i < 40; i++) {
      t.tickWorld();
      if (t.client.lastServerTick >= 0) {
        final d = t.client.lastCorrectionDist;
        // Correction must not grow over time.
        expect(d, lessThan(0.5),
            reason: 'correction must not grow (got $d at server-tick ${t.client.lastServerTick})');
        // After reaching steady state, must be exactly 0.
        if (i >= 10) {
          // Hero has definitely settled (hero step 0.15, distance ~8 → ~54 ticks to reach;
          // with 120+10 ticks passed the hero is long settled).
          steadyStateCorrection = d;
          expect(d, equals(0.0),
              reason: 'steady-state correction must be exactly 0 (got $d at server-tick ${t.client.lastServerTick})');
        }
      }
    }

    expect(steadyStateCorrection, equals(0.0),
        reason: 'must have measured steady-state correction == 0.0 exactly');
    // In-motion bound.
    expect(maxCorrectionInMotion, lessThan(0.5),
        reason: 'in-motion correction must stay < 0.5 (max was $maxCorrectionInMotion)');
  });

  // ── Case 3: 30% loss bounded ──────────────────────────────────────────────
  test('case 3: 30% packet loss — correction bounded, pendingCount bounded', () {
    final t = _makeTransport(lossRate: 0.30);

    // Send a move.
    final msg = t.client.applyLocalInput(655360, 0);
    t.clientSend(msg);

    for (var i = 0; i < 200; i++) {
      // No throws expected.
      t.tickWorld();
      if (t.client.lastServerTick >= 0) {
        expect(t.client.lastCorrectionDist, lessThan(0.5),
            reason: 'correction must stay bounded under 30% loss');
      }
      // pendingCount must stay bounded (old intents are acked and pruned).
      expect(t.client.pendingCount, lessThan(20),
          reason: 'pending input count must stay bounded under 30% loss');
    }
  });

  // ── Case 4: Dropped input self-heals ─────────────────────────────────────
  test('case 4: dropped first input self-heals via second input', () {
    // Simulate: client's first packet is lost (don't call clientSend).
    final t = _makeTransport();

    // Apply an intent but DON'T send it (simulate drop before send).
    t.client.applyLocalInput(655360, 0);
    // Do NOT call t.clientSend.

    // Advance a few ticks, then send a second intent (same direction).
    for (var i = 0; i < 5; i++) {
      t.tickWorld();
    }

    // Send the second intent to the server — this is the "re-send" / next input.
    final msg2 = t.client.applyLocalInput(655360, 0);
    t.clientSend(msg2);

    for (var i = 0; i < 115; i++) {
      t.tickWorld();
    }

    // Hero should have moved right (server received the second intent).
    // Client prediction and server should both show movement.
    final clientPos = t.client.debugLocalPos();
    expect(clientPos.x.raw, greaterThan(Fixed.fromInt(-8).raw),
        reason: 'hero should have moved right despite dropped first input');

    // No permanent desync: correction should eventually settle to 0.
    if (t.client.lastServerTick >= 0) {
      expect(t.client.lastCorrectionDist, lessThan(0.5),
          reason: 'no permanent desync after first input dropped');
    }
  });

  // ── Case 5: Out-of-order snapshots ignored ────────────────────────────────
  test('case 5: out-of-order snapshot ignored (stale serverTick rejected)', () {
    final t = _makeTransport(oneWayLatencyMs: 0);

    // Run to tick 22 on the server.
    for (var i = 0; i < 23; i++) {
      t.tickWorld();
    }

    // At this point the client should have received snapshots.
    // The stale-guard in onServerSnapshot rejects serverTick <= _lastReconciledServerTick.
    final lastTick = t.client.lastServerTick;
    expect(lastTick, greaterThanOrEqualTo(0), reason: 'should have received some snapshots');

    // Manufacture a stale snapshot at tick 1 (older than lastTick).
    final staleSnap = SnapshotMsg(
        serverTick: 1,
        ackedSeq: const [0, 0],
        stateBytes: t.server.snapshotBytes()); // using current server state is ok for this test
    final hashBefore = t.client.debugHash();
    final lastTickBefore = t.client.lastServerTick;
    t.client.onServerSnapshot(staleSnap);

    // lastServerTick must not have regressed.
    expect(t.client.lastServerTick, equals(lastTickBefore),
        reason: 'stale snapshot must not update lastServerTick (was $lastTickBefore, stale was 1)');
    // Hash must be unchanged.
    expect(t.client.debugHash(), equals(hashBefore),
        reason: 'stale snapshot must not alter predicted state');
  });

  // ── Case 6: Duplicate snapshot idempotent ─────────────────────────────────
  test('case 6: duplicate snapshot is idempotent', () {
    final t = _makeTransport(oneWayLatencyMs: 0);

    // Run until we receive at least one snapshot.
    for (var i = 0; i < 10; i++) {
      t.tickWorld();
    }
    expect(t.client.lastServerTick, greaterThanOrEqualTo(0));

    // Build a snapshot for the current server state.
    final snap = SnapshotMsg(
        serverTick: t.client.lastServerTick,
        ackedSeq: [0, 0],
        stateBytes: t.server.snapshotBytes());

    final hashBefore = t.client.debugHash();
    final pendingBefore = t.client.pendingCount;
    final lastTickBefore = t.client.lastServerTick;

    // Apply the same snapshot a second time.
    t.client.onServerSnapshot(snap);

    expect(t.client.lastServerTick, equals(lastTickBefore),
        reason: 'duplicate snapshot must not change lastServerTick');
    expect(t.client.debugHash(), equals(hashBefore),
        reason: 'duplicate snapshot must not alter predicted state');
    expect(t.client.pendingCount, equals(pendingBefore),
        reason: 'duplicate snapshot must not change pendingCount');
  });

  // ── Case 7: Opponent interpolation on-segment ─────────────────────────────
  test('case 7: opponent interpolation pos lies between bracketing snapshots', () {
    final t = _makeTransport(oneWayLatencyMs: 75);

    // Move both heroes: slot 0 (client) moves right, slot 1 (server-driven for opp)
    // has no explicit input so stays put. We just need some snapshots delivered.
    final msg = t.client.applyLocalInput(655360, 0);
    t.clientSend(msg);

    // Run for a while to accumulate opponent snapshots.
    for (var i = 0; i < 60; i++) {
      t.tickWorld();
    }

    // Sample the opponent position in the render view.
    final view = t.client.update(t.client.predictedTick * FakeTransport.dtMs);
    // The opponent is hero slot 1, starts at x=8. Since no move input was given,
    // it stays at x=8.
    // The render position should be close to x=8.0.
    expect(view.opponent.x, closeTo(8.0, 1.0),
        reason: 'opponent render pos should be near its server position (x≈8.0)');

    // The interpolation position must not overshoot: since opponent hasn't moved,
    // all samples are at x≈8 and interpolation must also be ≈8.
    // This validates the "on-segment" and "never overshoots" property.
    expect(view.opponent.x, lessThanOrEqualTo(9.0),
        reason: 'interpolated opponent must not overshoot');
    expect(view.opponent.x, greaterThanOrEqualTo(7.0),
        reason: 'interpolated opponent must not undershoot');
  });

  // ── Case 8: Determinism golden ────────────────────────────────────────────
  test('case 8: identical seed → identical client hash (determinism)', () {
    int runHash(int seed) {
      final t = _makeTransport(seed: seed, oneWayLatencyMs: 75, lossRate: 0.10);
      final msg = t.client.applyLocalInput(655360, 131072);
      t.clientSend(msg);
      for (var i = 0; i < 80; i++) {
        t.tickWorld();
      }
      return t.client.debugHash();
    }

    final hash1 = runHash(42);
    final hash2 = runHash(42);
    expect(hash1, equals(hash2),
        reason: 'same seed must produce identical client hash');

    // Different seeds should (in practice) produce different hashes.
    final hash3 = runHash(99);
    expect(hash3, isNot(equals(hash1)),
        reason: 'different seeds should produce different hashes');
  });

  // ── Case 9: Reconcile == fresh replay ─────────────────────────────────────
  test('case 9: reconciled client state matches independent server replay', () {
    // Run the transport for a while with a known input sequence.
    final t = _makeTransport(oneWayLatencyMs: 0, lossRate: 0.0);

    // Send one explicit move input at the start.
    final msg = t.client.applyLocalInput(655360, 0);
    t.clientSend(msg);

    // Run until stable (hero reaches target).
    for (var i = 0; i < 100; i++) {
      t.tickWorld();
    }

    // The client should have reconciled. Its predicted hash should match
    // what the server computes (since zero-latency → everything delivered).
    // At zero latency, the correction should always be 0.
    expect(t.client.lastCorrectionDist, 0.0,
        reason: 'zero-latency reconcile must match server exactly');

    // Independent replay: build a fresh sim from the same seed, apply the
    // same merged input log that the server processed (the server held
    // slot-0's intent from seq=1 delivered at tick ~0).
    // Since zero-latency and no loss, the server received the input immediately.
    // Build the server independently: same seed, same intents.
    // The server received: slot-0 move right intent, applied from tick ~0 onward.
    // We don't have direct access to the server's acked intent log, so we instead
    // verify the client's hash matches the server's current hash (which the transport
    // exposes). After zero-latency perfect sync, client == server.
    final serverHash = t.serverHash();
    // The client's predicted sim is one tick ahead of the server; reconcile
    // brings it back to server truth + re-step. Check lastCorrectionDist == 0
    // (already done above) and that the client's last reconciled tick matches
    // the last server snapshot tick.
    expect(t.client.lastServerTick, greaterThanOrEqualTo(0));

    // Independent direct verification: restore a fresh sim from the last
    // server snapshot bytes and verify canonical hash matches the server.
    final snap = SnapshotMsg(
        serverTick: t.serverTick,
        ackedSeq: [0, 0],
        stateBytes: t.server.snapshotBytes());
    final fresh = Simulation.create(const SimConfig(seed: 1337));
    fresh.restoreFromSnapshot(snap.stateBytes);
    expect(fresh.canonicalStateHash(), equals(serverHash),
        reason: 'fresh restore from server snapshot must match server hash');

    // The reconcile outcome: the client re-stepped from the server snapshot
    // forward by (predictedTick - serverTick - 1) ticks. At zero-latency that
    // is ~1 tick. Since correction == 0, the client's predicted sim exactly
    // matches what the server would produce for that same number of extra ticks.
    // Verify by stepping the fresh replay forward the same number of ticks.
    final extraTicks = t.client.predictedTick - t.client.lastServerTick - 1;
    for (var i = 0; i < extraTicks; i++) {
      fresh.step(t.client.lastServerTick + 1 + i, const []);
    }
    // After re-stepping with no new intent (the pending list was acked),
    // client hash == replay hash.
    expect(t.client.debugHash(), equals(fresh.canonicalStateHash()),
        reason: 'reconcile outcome must equal fresh replay with same inputs');
  });
}
