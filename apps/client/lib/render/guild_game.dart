import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:netcode/netcode.dart' show MatchView, RenderEntity;
import 'package:sim/sim.dart' show EntityKind, heroElement;

import '../match/match_binding.dart';
import 'coord.dart';
import 'entity_view.dart';
import 'field_view.dart';
import 'reaction_label.dart';
import 'sprites/sprite_catalog.dart';
import 'world_backdrop.dart';

/// The Flame game. Renders MatchView's entity list as colored shapes; holds ZERO
/// gameplay truth. Spawns/despawns EntityViews via an id-keyed diff each frame.
class GuildGame extends FlameGame with SecondaryTapCallbacks, TapCallbacks {
  GuildGame(this.binding);

  final MatchBinding binding;
  final Map<int, EntityView> _views = {};
  final Map<int, FieldView> _fieldViews = {}; // keyed by field ownerId
  final SpriteCatalog _catalog = SpriteCatalog();

  @override
  Future<void> onLoad() async {
    camera = CameraComponent.withFixedResolution(width: 960, height: 540, world: world);
    await _catalog.load();
    await world.add(WorldBackdrop());
  }

  @override
  void update(double dt) {
    super.update(dt);
    binding.tick((dt * 1000).round());

    if (binding.isOver && !overlays.isActive('result')) {
      overlays.add('result');
    }

    final v = binding.view;
    if (v == null) return;

    final seen = <int>{};
    for (final re in v.entities) {
      seen.add(re.id);
      var view = _views[re.id];
      if (view == null) {
        view = EntityView(
          kind: re.kind,
          teamId: re.teamId,
          element: re.kind == EntityKind.hero.index ? heroElement(re.id) : -1,
          isLocal: re.id == v.localSlot,
          catalog: _catalog,
        );
        _views[re.id] = view;
        world.add(view);
        if (re.id == v.localSlot) camera.follow(view);
      }
      view.target.setValues(worldToFlameX(re.x), worldToFlameY(re.y));
      view.hpRatio = re.maxHp > 0 ? re.hp / re.maxHp : 1.0;
      view.statusElement = re.statusElement; // discrete; never interpolated
    }
    // Despawn views whose entity is gone (dead creep / fallen tower / dead core).
    final gone = _views.keys.where((id) => !seen.contains(id)).toList();
    for (final id in gone) {
      _views.remove(id)?.removeFromParent();
    }

    // Diff field zones (keyed by ownerId).
    final seenFields = <int>{};
    for (final rf in v.fields) {
      seenFields.add(rf.ownerId);
      var fv = _fieldViews[rf.ownerId];
      if (fv == null || fv.element != rf.element) {
        fv?.removeFromParent();
        fv = FieldView(element: rf.element, radius: rf.radius);
        _fieldViews[rf.ownerId] = fv;
        world.add(fv);
      }
      fv.position.setValues(worldToFlameX(rf.x), worldToFlameY(rf.y));
    }
    for (final id in _fieldViews.keys.where((id) => !seenFields.contains(id)).toList()) {
      _fieldViews.remove(id)?.removeFromParent();
    }
    // Spawn a pop-text per reaction that fired this frame (flat vs amplify).
    for (final r in binding.drainReactions()) {
      world.add(ReactionLabel(
        text: reactionText(r.reaction, r.multiplierRaw),
        position: Vector2(worldToFlameX(r.x), worldToFlameY(r.y)),
      ));
    }
  }

  /// LoL right-click semantics: right-clicking ON an enemy locks an attack onto
  /// it; right-clicking the ground issues a move (which clears any lock).
  /// Left-click is the ability aim (see [onTapUp]).
  @override
  void onSecondaryTapUp(SecondaryTapUpEvent event) {
    final worldPos = camera.globalToLocal(event.canvasPosition);
    final wx = flameToWorld(worldPos.x);
    final wy = flameToWorld(worldPos.y);
    final v = binding.view;
    if (v != null) {
      final targetId = _enemyAt(v, wx, wy);
      if (targetId != null) {
        binding.submitAttack(targetId);
        return;
      }
    }
    binding.submitMoveTo(worldToRaw(wx), worldToRaw(wy));
  }

  /// Left-click = ability aim: cast the hero's field at the clicked world point.
  @override
  void onTapUp(TapUpEvent event) {
    final worldPos = camera.globalToLocal(event.canvasPosition);
    binding.submitAbility(
        worldToRaw(flameToWorld(worldPos.x)), worldToRaw(flameToWorld(worldPos.y)));
  }

  /// Nearest valid enemy entity within a small click radius (world units), else null.
  int? _enemyAt(MatchView v, double wx, double wy) {
    const clickR2 = 1.5 * 1.5;
    int? best;
    var bestD2 = clickR2;
    for (final re in v.entities) {
      if (!_isEnemyKind(re, v.localSlot)) continue;
      final dx = re.x - wx, dy = re.y - wy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = re.id;
      }
    }
    return best;
  }

  bool _isEnemyKind(RenderEntity re, int localSlot) {
    if (re.kind == EntityKind.wanderer.index) return false; // never targetable
    if (re.kind == EntityKind.creep.index) return true; // neutral fodder
    return re.teamId != localSlot; // hero/tower/core: enemy = other team (team==slot in 1v1)
  }
}
