import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('shouldSnapshot emits 20 of every 30 ticks (2-of-3)', () {
    final emitted = [for (var t = 0; t < 30; t++) if (shouldSnapshot(t)) t];
    expect(emitted.length, 20);
    expect(shouldSnapshot(0), isTrue);
    expect(shouldSnapshot(1), isTrue);
    expect(shouldSnapshot(2), isFalse);
  });
}
