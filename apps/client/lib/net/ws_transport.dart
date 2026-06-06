import 'package:web_socket_channel/web_socket_channel.dart';
import 'transport.dart';

class WebSocketChannelTransport implements Transport {
  WebSocketChannelTransport(Uri url) : _ch = WebSocketChannel.connect(url);
  final WebSocketChannel _ch;

  @override
  Stream<List<int>> get inbound => _ch.stream.map((m) {
        if (m is String) throw StateError('expected binary WS frame, got String');
        return m as List<int>;
      });

  @override
  void send(List<int> frame) => _ch.sink.add(frame);

  @override
  Future<void> close() => _ch.sink.close();
}
