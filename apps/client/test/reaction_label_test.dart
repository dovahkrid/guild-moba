import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/render/reaction_label.dart';
import 'package:sim/sim.dart' show Reaction, kVaporizeMult;

void main() {
  test('reactionText shows no multiplier for a flat (field-overlap) reaction', () {
    expect(reactionText(Reaction.vaporize.index, 0), 'VAPORIZE');
  });

  test('reactionText shows x1.3 for an attack-amplify reaction', () {
    // kVaporizeMult is ×1.3; reactionText renders it to one decimal place.
    expect(reactionText(Reaction.vaporize.index, kVaporizeMult.raw), 'VAPORIZE x1.3');
  });
}
