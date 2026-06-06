import 'package:server/src/net/ws_server.dart';

Future<void> main(List<String> args) async {
  final port = int.tryParse(args.isNotEmpty ? args[0] : '') ?? 8080;
  final server = await GuildWsServer.start(host: '0.0.0.0', port: port, seed: 1337);
  // ignore: avoid_print
  print('Guild server listening on ws://localhost:${server.port}/ws');
}
