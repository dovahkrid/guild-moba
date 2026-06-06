import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'player_conn.dart';
import 'real_tick_driver.dart';
import 'room_manager.dart';

/// Thin real-socket shell: shelf webSocketHandler -> WsPlayerConn -> RoomManager.
class GuildWsServer {
  GuildWsServer._(this._server, this.port);
  final HttpServer _server;
  final int port;

  static Future<GuildWsServer> start({
    String host = '0.0.0.0',
    int port = 8080,
    int seed = 1337,
  }) async {
    final rooms = RoomManager(seed: seed, driverFactory: () => RealTickDriver());
    final handler = webSocketHandler((WebSocketChannel channel, String? _) {
      rooms.connect(WsPlayerConn(channel));
    });
    final server = await shelf_io.serve(handler, host, port);
    return GuildWsServer._(server, server.port);
  }

  Future<void> close() => _server.close(force: true);
}
