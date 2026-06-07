import 'package:sim/sim.dart';
import 'package:test/test.dart';

void main() {
  test('combat SimEvents carry their payloads', () {
    const d = DamageDealt(sourceId: 0, targetId: 1, amountRaw: 8 * 65536);
    const k = CreepKilled(creepId: 1000, killerId: 0, gold: 18);
    const t = TowerDestroyed(towerId: 12, teamId: 0, killerId: 1);
    const c = CoreDestroyed(teamId: 0, winnerTeam: 1);
    expect(d.targetId, 1);
    expect(k.gold, 18);
    expect(t.killerId, 1);
    expect(c.winnerTeam, 1);
    expect(<SimEvent>[d, k, t, c], hasLength(4));
  });
}
