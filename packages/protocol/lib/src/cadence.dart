/// Snapshot cadence: 30 Hz ticks, emit on (tick % 3) < 2 => 20 Hz. THE single
/// source of truth shared by the server (Match) and client (FakeTransport/tests).
bool shouldSnapshot(int tick) => (tick % 3) < 2;
