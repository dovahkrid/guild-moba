import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guild_client/match/match_binding.dart';
import 'package:guild_client/net/transport.dart';
import 'package:guild_client/render/guild_game.dart';
import 'package:protocol/protocol.dart';

/// Minimal in-memory transport — no real sockets.
class _FakeTransport implements Transport {
  final _controller = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get inbound => _controller.stream;

  @override
  void send(List<int> frame) {}

  @override
  Future<void> close() => _controller.close();

  void push(List<int> frame) => _controller.add(frame);
}

void main() {
  testWidgets('GameWidget mounts GuildGame without throwing', (tester) async {
    final transport = _FakeTransport();
    final binding = MatchBinding(transport);
    final game = GuildGame(binding);

    await tester.pumpWidget(
      GameWidget(game: game),
    );

    // Push a MatchStart so binding.view becomes non-null.
    transport.push(
      ProtocolCodec.encode(
        const MatchStartMsg(
          yourSlot: 0,
          seed: 1337,
          tickRateHz: 30,
          snapshotRateHz: 20,
          startTick: 0,
        ),
      ),
    );

    await tester.pump();

    // If we reach here without an exception the smoke test passes.
    expect(find.byType(GameWidget<GuildGame>), findsOneWidget);
  });
}
