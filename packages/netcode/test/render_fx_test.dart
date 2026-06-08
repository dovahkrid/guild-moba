import 'package:netcode/netcode.dart';
import 'package:sim/sim.dart';
import 'package:test/test.dart';

EntitySnap _snap(double x, int kind, int team) =>
    EntitySnap(x: x, y: 0, kind: kind, teamId: team);

void main() {
  test('DamageDealt -> HitFx at the victim position, with source kind', () {
    final before = {
      0: _snap(-2, EntityKind.hero.index, 0),
      1: _snap(3, EntityKind.hero.index, 1),
    };
    final fx = projectFx(
      const [DamageDealt(sourceId: 0, targetId: 1, amountRaw: 524288)], // 8.0
      before,
      before,
    );
    expect(fx, hasLength(1));
    final hit = fx.single as HitFx;
    expect(hit.victimId, 1);
    expect(hit.sourceKind, EntityKind.hero.index);
    expect(hit.x, 3);
    expect(hit.amountRaw, 524288);
  });

  test('CreepKilled resolves position from the BEFORE snapshot (entity gone after)', () {
    final before = {7: _snap(1, EntityKind.creep.index, 2)};
    final after = <int, EntitySnap>{}; // creep removed by the death sweep
    final fx = projectFx(
      const [CreepKilled(creepId: 7, killerId: 0, gold: 1)],
      before,
      after,
    );
    expect((fx.single as KillFx).x, 1);
  });

  test('CoreDestroyed finds the core position by team', () {
    final before = {
      15: _snap(11, EntityKind.core.index, 1),
    };
    final fx = projectFx(
      const [CoreDestroyed(teamId: 1, winnerTeam: 0)],
      before,
      before,
    );
    final core = fx.single as CoreFx;
    expect(core.winnerTeam, 0);
    expect(core.x, 11);
  });

  test('ReactionTriggered / LevelUp / BossSpawned produce no RenderFx', () {
    final fx = projectFx(
      const [
        ReactionTriggered(unitId: 0, reaction: 0, multiplierRaw: 0, sourceId: 1),
        LevelUp(heroId: 0, level: 2),
        BossSpawned(bossId: 9, teamId: 0),
      ],
      const {},
      const {},
    );
    expect(fx, isEmpty);
  });
}
