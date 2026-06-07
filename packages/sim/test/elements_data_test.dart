import 'package:sim/sim.dart';
import 'package:sim/src/data/elements.dart'; // ignore: unnecessary_import — verifies deep path resolves alongside the re-export
import 'package:test/test.dart';

void main() {
  test('elemental constants obey the Fixed magnitude budget (|value| < 32768)', () {
    for (final f in <Fixed>[kVaporizeMult, kFieldRadius, kFieldRadiusSq, kFieldDotDamage]) {
      expect(f.toDouble().abs() < 32768, isTrue, reason: '$f exceeds budget');
    }
    // The worst routed damage × multiplier must stay in budget (no overflow).
    expect((kHeroAttackDamage * kVaporizeMult).toDouble().abs() < 32768, isTrue);
  });

  test('field radius² equals radius squared (lengthSq membership, no sqrt)', () {
    expect(kFieldRadiusSq.toDouble(),
        kFieldRadius.toDouble() * kFieldRadius.toDouble());
  });

  test('durations/cooldowns are integer ticks', () {
    expect(kStatusDurationTicks, isA<int>());
    expect(kReactionIcdTicks, isA<int>());
    expect(kFieldDurationTicks, isA<int>());
    expect(kAbilityCooldownTicks, isA<int>());
    expect(kReactionIcdTicks, greaterThan(0)); // a real per-unit reaction gate
  });

  test('slice roster: hero 0 = Cinderfang (Pyro, self-placed), hero 1 = Marisol (Hydro, aim)', () {
    expect(heroElement(0), Element.pyro.index);
    expect(heroElement(1), Element.hydro.index);
    expect(heroPlacesAtSelf(0), isTrue); // Cinderfang: Ember Field at his feet
    expect(heroPlacesAtSelf(1), isFalse); // Marisol: Tidepool at the aim point
  });
}
