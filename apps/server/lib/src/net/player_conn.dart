import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Everything the match needs from a connection — no dart:io / WS type leaks
/// into the pure loop.
abstract class PlayerConn {
  Stream<List<int>> get messages; // inbound encoded protocol frames
  Future<void> get onClose;
  void send(List<int> frame);
  void close();
}

class WsPlayerConn implements PlayerConn {
  WsPlayerConn(this._channel) {
    _channel.sink.done.whenComplete(() {
      if (!_closed.isCompleted) _closed.complete();
    });
  }
  final WebSocketChannel _channel;
  final _closed = Completer<void>();

  @override
  Stream<List<int>> get messages => _channel.stream.map((m) {
        if (m is String) {
          throw StateError('expected binary WS frame, got String');
        }
        return (m as List<int>);
      });

  @override
  Future<void> get onClose => _closed.future;
  @override
  void send(List<int> frame) =>
      _channel.sink.add(frame is Uint8List ? frame : Uint8List.fromList(frame));
  @override
  void close() => _channel.sink.close();
}
