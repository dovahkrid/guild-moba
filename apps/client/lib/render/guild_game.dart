import 'dart:ui'; // Color for the FX tints (flame/components does not re-export it)

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:netcode/netcode.dart'
    show MatchView, RenderEntity, RenderFx, HitFx, KillFx, TowerFallFx, CoreFx, HeroDownFx;
import 'package:sim/sim.dart' show EntityKind, heroElement;

import '../match/match_binding.dart';
import 'coord.dart';
import 'entity_view.dart';
import 'field_view.dart';
import 'fx/attack_streak.dart';
import 'fx/burst.dart';
import 'fx/damage_number.dart';
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
  final Set<int> _downed = {};

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
    // Despawn (animate) views whose entity is gone (dead creep / fallen tower / dead core).
    final gone = _views.keys.where((id) => !seen.contains(id)).toList();
    for (final id in gone) {
      _views.remove(id)?.playDeathAndRemove();
      _downed.remove(id);
    }

    // Respawn: a hero that was downed and now has hp pops back in.
    for (final re in v.entities) {
      if (_downed.contains(re.id) && re.hp > 0) {
        _downed.remove(re.id);
        _views[re.id]?.respawn();
      }
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
    // Combat FX surfaced this frame.
    for (final fx in binding.drainFx()) {
      _handleFx(fx);
    }
    // Reaction pop-text (flat vs amplify) + burst.
    for (final r in binding.drainReactions()) {
      final pos = Vector2(worldToFlameX(r.x), worldToFlameY(r.y));
      world.add(ReactionLabel(text: reactionText(r.reaction, r.multiplierRaw), position: pos.clone()));
      world.add(spawnBurst(pos, const Color(0xFFFFD54F), count: 12, speed: 70));
    }
  }

  void _handleFx(RenderFx fx) {
    switch (fx) {
      case HeroDownFx(:final heroId):
        _downed.add(heroId);
        _views[heroId]?.setDowned(true);
      case HitFx(:final victimId, :final sourceId, :final sourceKind, :final amountRaw, :final x, :final y):
        final pos = Vector2(worldToFlameX(x), worldToFlameY(y));
        _views[victimId]?.flash();
        world.add(DamageNumber(amountRaw: amountRaw, sourceKind: sourceKind, position: pos.clone()..y -= 14));
        final src = _views[sourceId];
        if (src != null &&
            (sourceKind == EntityKind.hero.index || sourceKind == EntityKind.tower.index)) {
          world.add(AttackStreak(from: src.position.clone(), to: pos, color: const Color(0xCCFFF0B0)));
        }
        world.add(spawnBurst(pos, const Color(0xFFFFE082), count: 6, speed: 40));
      case KillFx(:final x, :final y):
        world.add(spawnBurst(
          Vector2(worldToFlameX(x), worldToFlameY(y)),
          const Color(0xFFB0BEC5),
          count: 12,
          speed: 80,
        ));
      case TowerFallFx():
      case CoreFx():
        break; // wired in Task 6
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
