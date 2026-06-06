/// THE shared 20 Hz snapshot predicate — used by both the server (Plan 2b) and
/// the FakeTransport test harness so the harness exercises production cadence.
/// 30 Hz ticks, emit on (tick % 3) < 2 => 20 snapshots / 30 ticks.
bool shouldSnapshot(int tick) => (tick % 3) < 2;
