import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

/// A [CircleComponent] whose outline is drawn as evenly spaced dash arcs.
/// Same placement as a solid CircleComponent (anchor-centered on its parent),
/// but dashed — used as a non-interactive range/aim overlay. Purely cosmetic.
class DashedCircle extends CircleComponent {
  DashedCircle({
    required double radius,
    required Color color,
    this.dashCount = 36,
    double strokeWidth = 1.5,
  }) : super(
          radius: radius,
          anchor: Anchor.center,
          paint: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = color,
        );

  final int dashCount;

  @override
  void render(Canvas canvas) {
    // CircleComponent sizes itself to 2*radius, so its local centre is (r, r).
    final r = radius;
    final rect = Rect.fromCircle(center: Offset(r, r), radius: r);
    const tau = 2 * math.pi;
    final seg = tau / dashCount;
    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(rect, i * seg, seg * 0.5, false, paint); // dash = half each segment
    }
  }
}
