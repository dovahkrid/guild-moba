import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/render/reaction_label.dart';
import 'package:sim/sim.dart' show Reaction;

void main() {
  test('reactionText shows no multiplier for a flat (field-overlap) reaction', () {
    expect(reactionText(Reaction.vaporize.index, 0), 'VAPORIZE');
  });

  test('reactionText shows x1.3 for an attack-amplify reaction', () {
    // 85197 = Fixed.fromNum(1.3).raw (Q16.16) → 85197 / 65536 ≈ 1.3.
    expect(reactionText(Reaction.vaporize.index, 85197), 'VAPORIZE x1.3');
  });
}
