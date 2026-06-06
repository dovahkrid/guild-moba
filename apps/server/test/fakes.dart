import 'dart:async';
import 'package:server/src/loop/tick_driver.dart';
import 'package:server/src/net/player_conn.dart';

/// Synchronous, no-time tick driver for tests.
class FakeTickDriver implements TickDriver {
  void Function()? _onTick;
  @override
  void start(void Function() onTick) => _onTick = onTick;
  @override
  void stop() => _onTick = null;
  void pump(int n) {
    for (var i = 0; i < n; i++) {
      _onTick?.call();
    }
  }
}

/// Records sent frames; lets the test push inbound frames.
class FakePlayerConn implements PlayerConn {
  final _inbound = StreamController<List<int>>.broadcast(sync: true);
  final _closed = Completer<void>();
  final List<List<int>> sent = [];

  @override
  Stream<List<int>> get messages => _inbound.stream;
  @override
  Future<void> get onClose => _closed.future;
  @override
  void send(List<int> frame) => sent.add(frame);
  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
  }

  void receive(List<int> frame) => _inbound.add(frame);
}
