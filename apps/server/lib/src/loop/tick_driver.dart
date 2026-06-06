/// Drives ticks in real time on the SERVER. The sim never sees a wall-clock
/// value; this only decides WHEN / HOW MANY TIMES to call the pure tick fn.
abstract class TickDriver {
  void start(void Function() onTick);
  void stop();
}
