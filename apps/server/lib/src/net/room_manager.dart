import 'package:protocol/protocol.dart';

import '../loop/match.dart';
import '../loop/tick_driver.dart';
import 'player_conn.dart';

/// Hardcoded single 2-player room. First two connections get slots 0/1; the
/// match starts on the second. A third is politely rejected. On match end the
/// room resets so a fresh pair can connect.
class RoomManager {
  RoomManager({required this.seed, required this.driverFactory});
  final int seed;
  final TickDriver Function() driverFactory;

  Match? _match;
  int _filled = 0;

  void connect(PlayerConn conn) {
    if (_match != null && _filled >= 2) {
      conn.send(ProtocolCodec.encode(const MatchEndMsg(reason: EndReason.roomFull)));
      conn.close();
      return;
    }
    _match ??= Match(seed: seed, driver: driverFactory());
    final slot = _filled++;
    _match!.addPlayer(slot, conn);
    if (_filled == 2) _match!.start();
    // Reset the room when this match ends so the next pair can play.
    conn.onClose.then((_) {
      if (_match != null && _match!.ended) {
        _match = null;
        _filled = 0;
      }
    });
  }
}
