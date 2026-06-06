import 'package:protocol/protocol.dart';
import 'package:server/src/loop/intent_buffer.dart';
import 'package:test/test.dart';

InputMsg input(int slot, int seq, {int aimX = 0}) =>
    InputMsg(slot: slot, seq: seq, clientTick: 0, aimX: aimX, aimY: 0, type: 1);

void main() {
  test('accepts increasing seq and tracks ackedSeq', () {
    final b = IntentBuffer();
    expect(b.accept(input(0, 1)), isTrue);
    expect(b.accept(input(0, 2)), isTrue);
    expect(b.lastAckedSeq[0], 2);
    expect(b.lastAckedSeq[1], 0);
  });

  test('drops stale/duplicate seq', () {
    final b = IntentBuffer();
    b.accept(input(0, 3));
    expect(b.accept(input(0, 3)), isFalse); // dup
    expect(b.accept(input(0, 1)), isFalse); // stale
    expect(b.lastAckedSeq[0], 3);
  });

  test('rejects out-of-range slot', () {
    expect(IntentBuffer().accept(input(2, 1)), isFalse);
  });

  test('drainForTick returns latest move per slot and persists it', () {
    final b = IntentBuffer();
    b.accept(input(0, 1, aimX: 100));
    b.accept(input(1, 1, aimX: 200));
    final a = b.drainForTick();
    expect(a.length, 2);
    // No new input next tick: still returns the held targets (heroes keep seeking).
    expect(b.drainForTick().length, 2);
  });
}
