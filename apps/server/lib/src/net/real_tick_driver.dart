import 'dart:async';

import '../loop/tick_driver.dart';

/// Real-time tick driver: Stopwatch + Timer catch-up, capped at [maxCatchUp]
/// to prevent spiral-of-death on hiccups. Lives in net/ (not loop/) to keep
/// the loop purity gate green (Stopwatch is banned in loop/).
class RealTickDriver implements TickDriver {
  RealTickDriver({this.tickRateHz = 30, this.maxCatchUp = 5});
  final int tickRateHz;
  final int maxCatchUp;
  final Stopwatch _sw = Stopwatch();
  Timer? _timer;
  int _done = 0;

  int get _tickMicros => 1000000 ~/ tickRateHz;

  @override
  void start(void Function() onTick) {
    _sw.start();
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ (tickRateHz * 2)), (_) {
      final due = _sw.elapsedMicroseconds ~/ _tickMicros;
      var budget = maxCatchUp;
      while (_done < due && budget-- > 0) {
        onTick();
        _done++;
      }
      if (_done < due) _done = due; // drop missed ticks; never spiral
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    _sw.stop();
  }
}
