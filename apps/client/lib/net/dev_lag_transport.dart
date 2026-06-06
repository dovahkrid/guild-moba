import 'dart:async';
import 'dart:math' as math; // OK here: transport is NOT the sim.
import 'transport.dart';

/// Injects one-way latency + loss in BOTH directions. Knobs mirror Plan 2a's
/// FakeTransport so a hand-found feel bug reproduces in a headless unit test.
class DevLagTransport implements Transport {
  DevLagTransport(
    this._inner, {
    this.latencyMs = 0,
    this.jitterMs = 0,
    this.lossPct = 0,
  }) {
    _sub = _inner.inbound.listen((frame) {
      if (_drop()) return;
      Timer(Duration(milliseconds: _delay()), () {
        if (!_out.isClosed) _out.add(frame);
      });
    });
  }

  final Transport _inner;
  int latencyMs, jitterMs, lossPct; // mutable: bound to dev-panel sliders
  final _rng = math.Random(0xC0FFEE);
  final _out = StreamController<List<int>>.broadcast();
  late final StreamSubscription<List<int>> _sub;

  int _delay() =>
      latencyMs + (jitterMs == 0 ? 0 : _rng.nextInt(jitterMs + 1));
  bool _drop() => lossPct > 0 && _rng.nextInt(100) < lossPct;

  @override
  Stream<List<int>> get inbound => _out.stream;

  @override
  void send(List<int> frame) {
    if (_drop()) return;
    Timer(Duration(milliseconds: _delay()), () => _inner.send(frame));
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    await _out.close();
    await _inner.close();
  }
}
