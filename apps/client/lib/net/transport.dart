/// Network seam. Real = WebSocketChannelTransport; dev = DevLagTransport.
abstract class Transport {
  Stream<List<int>> get inbound; // frames from the server
  void send(List<int> frame); // frames to the server
  Future<void> close();
}
