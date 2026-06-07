import 'package:flame/game.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show BrowserContextMenu;

import 'app_config.dart';
import 'match/match_binding.dart';
import 'net/dev_lag_transport.dart';
import 'net/ws_transport.dart';
import 'render/guild_game.dart';
import 'ui/dev_panel.dart';
import 'ui/hud_overlay.dart';
import 'ui/result_overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Right-click drives gameplay (LoL controls), so suppress the browser's
  // native context menu on web.
  if (kIsWeb) {
    await BrowserContextMenu.disableContextMenu();
  }

  const config = ClientConfig();

  final wsTransport = WebSocketChannelTransport(Uri.parse(config.wsUrl));
  final devTransport = DevLagTransport(
    wsTransport,
    latencyMs: config.devLatencyMs,
    lossPct: config.devLossPct,
  );
  final binding = MatchBinding(devTransport);
  final game = GuildGame(binding);

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Guild',
      home: Scaffold(
        body: GameWidget(
          game: game,
          overlayBuilderMap: {
            'hud': (context, _) => HudOverlay(binding: binding),
            'dev': (context, _) => DevPanel(transport: devTransport),
            'result': (context, _) => ResultOverlay(binding: binding),
          },
          initialActiveOverlays: const ['hud', 'dev'],
        ),
      ),
    ),
  );
}
