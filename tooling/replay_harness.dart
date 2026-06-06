// Cross-platform deterministic replay harness. Prints exactly one line:
//   REPLAY_HASH <8-hex>
// The fixture is injected as a base64 -D define so all three runtimes read
// byte-identical input (no dart:io, so it compiles to js & wasm).
import 'dart:convert';

import 'package:sim/sim.dart';

const String _fixtureB64 = String.fromEnvironment('FIXTURE_JSON', defaultValue: '');

void main(List<String> args) {
  if (_fixtureB64.isEmpty) {
    throw StateError('no fixture: pass -DFIXTURE_JSON=<base64 of replay json>');
  }
  final fx = jsonDecode(utf8.decode(base64Decode(_fixtureB64))) as Map<String, dynamic>;
  final seed = (fx['seed'] as num).toInt();
  final ticks = (fx['ticks'] as num).toInt();
  final inputLog = _parseInputLog(fx['inputLog']);

  final sim = Simulation.create(SimConfig(seed: seed));
  final hasher = FnvHasher();
  for (var t = 0; t < ticks; t++) {
    sim.step(t, inputLog[t] ?? const <Intent>[]);
    hasher.addBytes(sim.canonicalBytes()); // chain every tick (catches mid-replay drift)
  }
  print('REPLAY_HASH ${hasher.hex8()}');
}

Map<int, List<Intent>> _parseInputLog(dynamic raw) {
  final map = <int, List<Intent>>{};
  if (raw == null) return map;
  (raw as Map<String, dynamic>).forEach((k, v) {
    final tick = int.parse(k);
    final list = <Intent>[
      for (final item in (v as List))
        Intent(
          playerSlot: ((item as Map<String, dynamic>)['playerSlot'] as num).toInt(),
          type: IntentType.values[(item['type'] as num).toInt()],
          aimX: (item['aimX'] as num?)?.toInt() ?? 0,
          aimY: (item['aimY'] as num?)?.toInt() ?? 0,
          seq: (item['seq'] as num?)?.toInt() ?? 0,
          clientTick: (item['clientTick'] as num?)?.toInt() ?? tick,
        ),
    ]..sort((a, b) =>
        a.playerSlot != b.playerSlot ? a.playerSlot - b.playerSlot : a.seq - b.seq);
    map[tick] = list;
  });
  return map;
}
