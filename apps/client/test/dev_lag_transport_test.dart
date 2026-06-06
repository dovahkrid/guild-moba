import 'dart:async';
import 'package:guild_client/net/dev_lag_transport.dart';
import 'package:guild_client/net/transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemTransport implements Transport {
  final _in = StreamController<List<int>>.broadcast();
  final List<List<int>> sent = [];
  @override
  Stream<List<int>> get inbound => _in.stream;
  @override
  void send(List<int> f) => sent.add(f);
  @override
  Future<void> close() async => _in.close();
  void serverPush(List<int> f) => _in.add(f);
}

void main() {
  test('0% loss, 0ms latency forwards frames both ways', () async {
    final mem = _MemTransport();
    final lag = DevLagTransport(mem, latencyMs: 0, lossPct: 0);
    final got = <List<int>>[];
    lag.inbound.listen(got.add);
    lag.send([1, 2, 3]);
    mem.serverPush([9, 9]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(mem.sent, [[1, 2, 3]]);
    expect(got, [[9, 9]]);
  });

  test('100% loss drops everything', () async {
    final mem = _MemTransport();
    final lag = DevLagTransport(mem, latencyMs: 0, lossPct: 100);
    final got = <List<int>>[];
    lag.inbound.listen(got.add);
    lag.send([1]);
    mem.serverPush([2]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(mem.sent, isEmpty);
    expect(got, isEmpty);
  });
}
