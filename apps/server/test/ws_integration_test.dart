@TestOn('vm')
library;

import 'package:protocol/protocol.dart';
import 'package:server/src/net/ws_server.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:test/test.dart';

void main() {
  test('two real WS clients receive MATCH_START with distinct slots', () async {
    final server = await GuildWsServer.start(host: 'localhost', port: 0, seed: 99);
    final uri = Uri.parse('ws://localhost:${server.port}/ws');

    final a = WebSocketChannel.connect(uri);
    final b = WebSocketChannel.connect(uri);

    final aFirst = await a.stream.first;
    final bFirst = await b.stream.first;
    final ma = ProtocolCodec.decode(aFirst as List<int>) as MatchStartMsg;
    final mb = ProtocolCodec.decode(bFirst as List<int>) as MatchStartMsg;

    expect({ma.yourSlot, mb.yourSlot}, {0, 1});

    await a.sink.close();
    await b.sink.close();
    await server.close();
  });
}
