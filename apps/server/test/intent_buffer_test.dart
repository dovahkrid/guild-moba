import 'package:protocol/protocol.dart';
import 'package:server/src/loop/intent_buffer.dart';
import 'package:sim/sim.dart';
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

  test('rejects out-of-range type and does not throw', () {
    final b = IntentBuffer();
    final badMsg = const InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 0, aimY: 0, type: 99);
    expect(b.accept(badMsg), isFalse);
    expect(b.lastAckedSeq[0], 0); // unchanged
  });

  test('ability is one-shot: drained once then cleared (no auto-recast)', () {
    final b = IntentBuffer();
    b.accept(InputMsg(
        slot: 0, seq: 1, clientTick: 0, aimX: 0, aimY: 0, type: IntentType.ability.index));
    final first = b.drainForTick();
    expect(first.where((i) => i.type == IntentType.ability), hasLength(1)); // fires this tick
    final second = b.drainForTick();
    expect(second.where((i) => i.type == IntentType.ability), isEmpty); // NOT repeated next tick
  });

  test('a held move persists while a one-shot ability fires exactly once', () {
    final b = IntentBuffer();
    b.accept(input(0, 1, aimX: 100)); // move (type 1), held
    b.accept(InputMsg(
        slot: 0, seq: 2, clientTick: 0, aimX: 5, aimY: 0, type: IntentType.ability.index));
    final t0 = b.drainForTick();
    expect(t0.where((i) => i.type == IntentType.move), hasLength(1));
    expect(t0.where((i) => i.type == IntentType.ability), hasLength(1));
    final t1 = b.drainForTick();
    expect(t1.where((i) => i.type == IntentType.move), hasLength(1)); // move still held
    expect(t1.where((i) => i.type == IntentType.ability), isEmpty); // ability gone
    expect(b.lastAckedSeq[0], 2); // both inputs acked
  });
}
