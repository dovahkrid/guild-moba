import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/particles.dart';

/// Spawn a short radial particle burst at [position] (Flame coords). Self-removes.
ParticleSystemComponent spawnBurst(Vector2 position, Color color, {int count = 10, double speed = 60}) {
  final rng = math.Random();
  return ParticleSystemComponent(
    position: position,
    particle: Particle.generate(
      count: count,
      lifespan: 0.4,
      generator: (i) {
        final a = (i / count) * 2 * math.pi + rng.nextDouble();
        final v = Vector2(math.cos(a), math.sin(a)) * speed;
        return AcceleratedParticle(
          speed: v,
          child: CircleParticle(radius: 1.6, paint: Paint()..color = color),
        );
      },
    ),
  );
}
