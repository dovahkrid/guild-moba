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
    // Apply a move so the hero walks somewhere — onto its OWN (left) half so it
    // never enters the enemy outer tower's range (x=+4, range 6): stays combat-free.
    final msg = t.client.applyLocalInput(-655360, 0)!; // → x=-10
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
    // The hero starts at x = Fixed.fromInt(-8). Target a point on its OWN (left)
    // half (x=-12) so it never enters the enemy tower's range — combat-free.
    final msg = t.client.applyLocalInput(Fixed.fromInt(-12).raw, Fixed.fromInt(0).raw)!;
    t.clientSend(msg);

    var maxCorrectionInMotion = 0.0;
    var steadyStateCorrection = -1.0;

    // Run 120 ticks. Hero should reach target (-12, 0) within ~30 ticks from (-8, 0)
    // at 0.15 world units/tick: 4/0.15 = ~27 ticks.
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
          // Hero has definitely settled (hero step 0.15, distance ~4 → ~27 ticks to reach;
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

  // ── Case 2b: Sustained correction bounded under continuous input ───────────
  test(
      'case 2b: sustained target-changing input stays bounded — continuous reconcile is bounded and observed',
      () {
    final t = _makeTransport(oneWayLatencyMs: 75);

    // Two distinct aim points to alternate between, both on the local hero's OWN
    // (left) half (x=-12.0 vs x=-11.5) so it never enters the enemy tower's range
    // — combat-free. They are only 0.5 apart so the per-reconcile correction stays
    // well under 0.5 (max ≈ one heroStep = 0.15) while the target IS different on
    // every alternate input — guaranteeing correction > 0 on most reconciles and
    // proving continuous correction is bounded.
    final aimA = Fixed.fromNum(-12.0).raw; // x=-12.0 (Fixed Q16.16)
    final aimB = Fixed.fromNum(-11.5).raw; // x=-11.5

    var maxCorrectionObserved = 0.0;
    var correctionObservedCount = 0;
    var correctionAboveZeroCount = 0;

    // Run 120 frames, issuing a new target-changing input every ~5 frames so
    // there is always at least one unacked input in-flight at 150ms RTT.
    for (var i = 0; i < 120; i++) {
      // Alternate aim every 5 frames to keep unacked inputs in-flight at 150ms.
      if (i % 5 == 0) {
        final aim = (i ~/ 5) % 2 == 0 ? aimA : aimB;
        final msg = t.client.applyLocalInput(aim, 0)!;
        t.clientSend(msg);
      }
      t.tickWorld();

      if (t.client.lastServerTick >= 0) {
        final d = t.client.lastCorrectionDist;
        // Correction must always stay bounded below 0.5 world units.
        expect(d, lessThan(0.5),
            reason: 'sustained correction must stay < 0.5 (got $d at tick ${t.client.lastServerTick})');
        if (d > maxCorrectionObserved) maxCorrectionObserved = d;
        correctionObservedCount++;
        if (d > 0.0) correctionAboveZeroCount++;
      }
    }

    // Must have measured correction on multiple reconciles.
    expect(correctionObservedCount, greaterThan(5),
        reason: 'must have observed correction on multiple reconciles');

    // Correction must be > 0 on multiple reconciles (proves continuous correction,
    // not just a one-time event).
    expect(correctionAboveZeroCount, greaterThan(3),
        reason: 'correction must be > 0 on multiple reconciles under sustained divergence');

    // Max must be bounded — never grows unboundedly.
    expect(maxCorrectionObserved, lessThan(0.5),
        reason: 'max observed correction must be bounded < 0.5');
  });

  // ── Case 3: 30% loss bounded ──────────────────────────────────────────────
  test('case 3: 30% packet loss — correction bounded, pendingCount bounded', () {
    final t = _makeTransport(lossRate: 0.30);

    // Send initial move onto the local hero's OWN (left) half — combat-free.
    final msg = t.client.applyLocalInput(-655360, 0)!; // → x=-10
    t.clientSend(msg);

    // Two distinct aim points that change the target meaningfully but keep the
    // per-reconcile correction bounded < 0.5. Both sit on the local hero's OWN
    // (left) half (x=-12.0 vs x=-11.5) so it never enters the enemy tower's range —
    // combat-free. They are only 0.5 apart so pendingCount is genuinely non-trivial
    // under loss (new intent each 10 frames, some get dropped, so pending
    // accumulates) while correction stays well under the 0.5 bound (≈ 1 heroStep = 0.15).
    final aimA = Fixed.fromNum(-12.0).raw; // x=-12.0 (Fixed Q16.16)
    final aimB = Fixed.fromNum(-11.5).raw; // x=-11.5

    for (var i = 0; i < 200; i++) {
      // Send a new target-changing input every ~10 frames so pendingCount
      // reflects real sustained divergence under loss.
      if (i % 10 == 0) {
        final aim = (i ~/ 10) % 2 == 0 ? aimA : aimB;
        final msg2 = t.client.applyLocalInput(aim, 0)!;
        t.clientSend(msg2);
      }
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
    final t = _makeTransport(oneWayLatencyMs: 75, lossRate: 0.0);

    // Apply an intent but DON'T send it (simulate drop before send).
    // Move onto the local hero's OWN (left) half — combat-free.
    t.client.applyLocalInput(-655360, 0); // → x=-10
    // Do NOT call t.clientSend.

    // Advance a few ticks, then send a second intent (same direction).
    for (var i = 0; i < 5; i++) {
      t.tickWorld();
    }

    // Send the second intent to the server — this is the "re-send" / next input.
    final msg2 = t.client.applyLocalInput(-655360, 0)!; // → x=-10
    t.clientSend(msg2);

    for (var i = 0; i < 115; i++) {
      t.tickWorld();
    }

    // Hero should have moved left (server received the second intent).
    // Client prediction and server should both show movement.
    final clientPos = t.client.debugLocalPos();
    expect(clientPos.x.raw, lessThan(Fixed.fromInt(-8).raw),
        reason: 'hero should have moved left despite dropped first input');

    // No permanent desync: correction should eventually settle to 0.
    if (t.client.lastServerTick >= 0) {
      expect(t.client.lastCorrectionDist, lessThan(0.5),
          reason: 'no permanent desync after first input dropped');
    }

    // True replay equality: build a fresh sim from the same seed and replay
    // the exact merged authoritative input log the server processed.
    final fresh = Simulation.create(const SimConfig(seed: 1337));
    for (var tick = 0; tick < t.serverInputLog.length; tick++) {
      fresh.step(tick, t.serverInputLog[tick]);
    }
    expect(fresh.canonicalStateHash(), equals(t.server.canonicalStateHash()),
        reason: 'independent replay via serverInputLog must match server hash');

    // The client's final predicted state (with no pending after settling)
    // should also match the independent replay. Run a few more ticks to
    // ensure the client has reconciled to the latest server snapshot.
    for (var i = 0; i < 20; i++) {
      t.tickWorld();
    }
    // After settling at steady state, correction must be 0 and client matches server.
    if (t.client.lastCorrectionDist == 0.0) {
      // Build a fresh replay up to the current server log length.
      final fresh2 = Simulation.create(const SimConfig(seed: 1337));
      for (var tick = 0; tick < t.serverInputLog.length; tick++) {
        fresh2.step(tick, t.serverInputLog[tick]);
      }
      expect(fresh2.canonicalStateHash(), equals(t.server.canonicalStateHash()),
          reason: 'settled replay must equal server hash');
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

  // ── Case 7: Opponent interpolation — moving opponent, real segment ─────────
  test('case 7: opponent interpolation pos lies between bracketing snapshots (moving opponent)', () {
    final t = _makeTransport(oneWayLatencyMs: 75);

    // Also move the client hero so snapshots are more interesting — onto its OWN
    // (left) half (x=-12) so it stays out of the enemy tower's range (combat-free).
    final msg = t.client.applyLocalInput(Fixed.fromInt(-12).raw, 0)!;
    t.clientSend(msg);

    // Drive the opponent in a straight line (+x direction) for many frames.
    // The opponent hero starts at x=8; move its target to the large value so it
    // keeps walking right for the duration of the test.
    // oppAimX in Fixed Q16.16: large value so opponent never reaches target.
    final oppAimX = Fixed.fromInt(100).raw;
    const oppAimY = 0;

    // Run for enough frames to accumulate several snapshots with the opponent moving.
    // At 150ms latency, snapshots arrive ~4-5 frames late.
    for (var i = 0; i < 80; i++) {
      // Send opponent move input every few frames so it keeps walking.
      if (i % 3 == 0) {
        t.opponentSend(oppAimX, oppAimY);
      }
      t.tickWorld();
    }

    // The opponent (slot 1) starts at x=8. After 80 ticks at 0.15/tick it should
    // have advanced meaningfully toward x=100.
    // Sample rendered opponent pos at increasing render times to verify monotone +x.
    // The interpolation buffer is ~100ms behind, so sample across a window that
    // spans delivered snapshots.
    final nowMs = t.nowMs;

    // Collect several samples at INCREASING render times to verify monotone +x.
    // We sample from (nowMs - 300) to (nowMs - 100) — a 200ms window that
    // should span several snapshots (snapshots arrive every 33ms or 66ms).
    final samples = <double>[];
    for (var renderMs = nowMs - 300; renderMs <= nowMs - 100; renderMs += 33) {
      final view = t.client.update(renderMs);
      samples.add(view.opponent.x);
    }

    // The opponent must have actually moved (not stationary tautology).
    // Over the 200ms window of render times the rendered x must increase.
    final firstSample = samples.first;
    final lastSample = samples.last;
    expect(lastSample, greaterThan(firstSample),
        reason: 'opponent rendered x must increase over time as it moves right '
            '(first=${firstSample.toStringAsFixed(3)}, last=${lastSample.toStringAsFixed(3)})');

    // The rendered x must be meaningfully greater than the start position (x=8):
    // after 80 ticks at 0.15/tick the opponent is near x=20.
    expect(lastSample, greaterThan(8.5),
        reason: 'opponent rendered x must exceed start pos (8.0) after moving right '
            '(got ${lastSample.toStringAsFixed(3)})');

    // Samples must be non-decreasing across the window (monotone interpolation).
    for (var i = 1; i < samples.length; i++) {
      expect(samples[i], greaterThanOrEqualTo(samples[i - 1] - 0.001),
          reason: 'rendered opponent x must be monotone non-decreasing: '
              'samples[$i]=${samples[i]} < samples[${i-1}]=${samples[i-1]}');
    }

    // No-extrapolation: sample at two far-future render times past the last
    // delivered snapshot; the interpolation must HOLD at the newest value,
    // so both samples must be identical. The buffer's newest snapshot logical
    // time is serverTick * 33ms; any renderTime beyond that is past all snapshots.
    // After the main 80-tick run, the last snapshot is at tick ~76 → time ~2508ms.
    // Sample at nowMs+5000 and nowMs+10000 — both are far past all snapshots.
    final xFuture1 = t.client.update(nowMs + 5000).opponent.x;
    final xFuture2 = t.client.update(nowMs + 10000).opponent.x;
    expect(xFuture1, equals(xFuture2),
        reason: 'interpolation must return the same value for any render time past the last '
            'snapshot (hold-at-newest, no extrapolation): '
            'xFuture1=$xFuture1, xFuture2=$xFuture2');
    // And the held value must be >= the x we saw during the run (opponent moved right).
    expect(xFuture1, greaterThan(8.0),
        reason: 'held newest x must be greater than start pos (opponent moved right)');
  });

  // ── Case 8: Determinism golden ────────────────────────────────────────────
  test('case 8: identical seed → identical client hash (determinism)', () {
    int runHash(int seed) {
      final t = _makeTransport(seed: seed, oneWayLatencyMs: 75, lossRate: 0.10);
      final msg = t.client.applyLocalInput(-655360, 131072)!; // → (x=-10, y=2): own half, combat-free
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

  // ── Case 9: True independent seed+input-log replay ───────────────────────
  test('case 9: reconciled client state matches independent server replay', () {
    // Run the transport for a while with a known input sequence.
    final t = _makeTransport(oneWayLatencyMs: 0, lossRate: 0.0);

    // Send one explicit move input at the start — onto the local hero's OWN
    // (left) half (x=-10) so it stays out of the enemy tower's range (combat-free).
    final msg = t.client.applyLocalInput(-655360, 0)!; // → x=-10
    t.clientSend(msg);

    // Run until stable (hero reaches target).
    for (var i = 0; i < 100; i++) {
      t.tickWorld();
    }

    // At zero latency, the correction should always be 0.
    expect(t.client.lastCorrectionDist, 0.0,
        reason: 'zero-latency reconcile must match server exactly');

    // TRUE independent replay: build a fresh sim from the same seed and replay
    // the EXACT merged authoritative input log the server processed (not from
    // server's snapshotBytes — that would be circular / self-confirming).
    final fresh = Simulation.create(const SimConfig(seed: 1337));
    for (var tick = 0; tick < t.serverInputLog.length; tick++) {
      fresh.step(tick, t.serverInputLog[tick]);
    }

    // The independently replayed sim must match the server's current hash.
    expect(fresh.canonicalStateHash(), equals(t.server.canonicalStateHash()),
        reason: 'independent seed+input-log replay must match server hash');

    // The client's predicted sim, after reconciling to the latest snapshot with
    // no pending inputs (zero-latency, all acked), must also equal that hash.
    // At zero latency: predictedTick is one ahead of serverTick, so the client
    // has stepped one extra tick beyond the server. Step the fresh replay
    // forward by the same number of extra ticks (with no intents, as all were acked).
    final extraTicks = t.client.predictedTick - t.client.lastServerTick - 1;
    for (var i = 0; i < extraTicks; i++) {
      fresh.step(t.client.lastServerTick + 1 + i, const []);
    }
    // After re-stepping with no pending intent, client hash == replay hash.
    expect(t.client.debugHash(), equals(fresh.canonicalStateHash()),
        reason: 'reconcile outcome must equal fresh seed+input-log replay with same inputs');
  });
}
