import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';

import '../match/match_binding.dart';
import 'coord.dart';
import 'entity_view.dart';
import 'world_backdrop.dart';

/// The Flame game. Renders MatchView as colored shapes; holds ZERO gameplay
/// truth — all positions come from [binding.view].
class GuildGame extends FlameGame with TapCallbacks {
  GuildGame(this.binding);

  final MatchBinding binding;

  late final EntityView _local;
  late final EntityView _opponent;
  late final EntityView _wanderer;

  @override
  Future<void> onLoad() async {
    // Fixed-resolution camera so the lane always fills ~960x540.
    camera = CameraComponent.withFixedResolution(
      width: 960,
      height: 540,
      world: world,
    );

    // Backdrop added to the world so it scrolls with the camera.
    await world.add(WorldBackdrop());

    _local = EntityView(role: EntityRole.local);
    _opponent = EntityView(role: EntityRole.opponent);
    _wanderer = EntityView(role: EntityRole.wanderer);
    await world.addAll([_local, _opponent, _wanderer]);

    // Start the camera following the local hero.
    camera.follow(_local);
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Advance binding by wall-clock dt (converts to ms).
    binding.tick((dt * 1000).round());

    final v = binding.view;
    if (v == null) return; // No MatchStart yet.

    // Sync entity targets from MatchView (world-unit doubles → Flame pixels).
    _local.target.setValues(
      worldToFlameX(v.local.x),
      worldToFlameY(v.local.y),
    );
    _opponent.target.setValues(
      worldToFlameX(v.opponent.x),
      worldToFlameY(v.opponent.y),
    );
    _wanderer.target.setValues(
      worldToFlameX(v.wanderer.x),
      worldToFlameY(v.wanderer.y),
    );
  }

  @override
  void onTapUp(TapUpEvent event) {
    // Convert canvas position → world position → raw Q16.16.
    final worldPos = camera.globalToLocal(event.canvasPosition);
    final worldX = flameToWorld(worldPos.x);
    final worldY = flameToWorld(worldPos.y);
    binding.submitMoveTo(worldToRaw(worldX), worldToRaw(worldY));
  }
}
