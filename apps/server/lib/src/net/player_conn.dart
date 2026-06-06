/// Everything the match needs from a connection — no dart:io / WS type leaks
/// into the pure loop.
abstract class PlayerConn {
  Stream<List<int>> get messages; // inbound encoded protocol frames
  Future<void> get onClose;
  void send(List<int> frame);
  void close();
}
