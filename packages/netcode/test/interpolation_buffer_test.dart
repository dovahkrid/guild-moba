import 'package:netcode/netcode.dart';
import 'package:test/test.dart';

void main() {
  test('lerps on the segment between two bracketing snapshots', () {
    final b = InterpolationBuffer()
      ..add(0, 0, 0) // serverTick 0 -> time 0ms, pos (0,0)
      ..add(3, 99, 0); // serverTick 3 -> time 99ms, pos (99,0)
    // sample at 49.5ms -> halfway
    final p = b.sample(49);
    expect(p.x, closeTo(49.0, 1.0));
    expect(p.y, 0.0);
  });

  test('holds at newest when target is past the last snapshot (no extrapolation)', () {
    final b = InterpolationBuffer()..add(0, 0, 0)..add(3, 30, 0);
    final p = b.sample(10000); // far future
    expect(p.x, 30.0);
  });

  test('holds at oldest when target precedes the first snapshot', () {
    final b = InterpolationBuffer()..add(3, 30, 0)..add(6, 60, 0);
    final p = b.sample(0);
    expect(p.x, 30.0);
  });

  test('dedupes by serverTick (duplicate add is a no-op)', () {
    final b = InterpolationBuffer()..add(3, 30, 0)..add(3, 999, 0);
    expect(b.length, 1);
  });

  test('ignores out-of-order older serverTick', () {
    final b = InterpolationBuffer()..add(6, 60, 0)..add(3, 30, 0);
    expect(b.length, 1); // the stale tick 3 after 6 is dropped
  });
}
