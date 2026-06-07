import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('Element/Reaction enum indices are stable (serialized as .index)', () {
    expect(Element.pyro.index, 0);
    expect(Element.hydro.index, 1);
    expect(Reaction.vaporize.index, 0);
  });

  test('ReactionTriggered carries unit, reaction, multiplier and source', () {
    const r = ReactionTriggered(
        unitId: 1, reaction: 0, multiplierRaw: 85197, sourceId: 0);
    expect(r.unitId, 1);
    expect(r.reaction, 0);
    expect(r.multiplierRaw, 85197); // Q16.16 raw of ×1.3 (Fixed.fromNum(1.3).raw)
    expect(r.sourceId, 0);
    expect(<SimEvent>[r], hasLength(1)); // still a SimEvent
  });

  test('ElementalField holds owner, stationary center, element and timer', () {
    final f = ElementalField(
        ownerId: 0, center: FVec2(Fixed.fromInt(2), Fixed.zero),
        element: Element.pyro.index, timer: 120);
    expect(f.ownerId, 0);
    expect(f.center.x.toDouble(), 2.0);
    expect(f.element, Element.pyro.index);
    expect(f.timer, 120);
    f.timer -= 1; // timer is mutable (decremented each tick)
    expect(f.timer, 119);
  });
}
