import 'dart:typed_data';
import 'package:sim/sim.dart'; // ByteWriter, ByteReader

import 'messages.dart';

/// Single binary codec shared by server, client, and FakeTransport.
/// 1-byte type tag + ByteWriter/ByteReader. Binary frames only.
class ProtocolCodec {
  static const int _tagMatchStart = 1;
  static const int _tagInput = 2;
  static const int _tagSnapshot = 3;
  static const int _tagMatchEnd = 4;

  static Uint8List encode(Msg msg) {
    final w = ByteWriter();
    switch (msg) {
      case final MatchStartMsg m:
        w.bytes([_tagMatchStart]);
        w.i32(m.yourSlot);
        w.i32(m.seed);
        w.i32(m.tickRateHz);
        w.i32(m.snapshotRateHz);
        w.i32(m.startTick);
      case final InputMsg m:
        w.bytes([_tagInput]);
        w.i32(m.slot);
        w.i32(m.seq);
        w.i32(m.clientTick);
        w.i32(m.aimX);
        w.i32(m.aimY);
        w.i32(m.type);
      case final SnapshotMsg m:
        w.bytes([_tagSnapshot]);
        w.i32(m.serverTick);
        w.i32(m.ackedSeq[0]);
        w.i32(m.ackedSeq[1]);
        w.i32(m.stateBytes.length);
        w.bytes(m.stateBytes);
      case final MatchEndMsg m:
        w.bytes([_tagMatchEnd]);
        w.i32(m.reason.index);
    }
    return w.toBytes();
  }

  static Msg decode(Object frame) {
    if (frame is! List<int>) {
      throw ArgumentError('protocol frames must be binary, got ${frame.runtimeType}');
    }
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
    final tag = bytes[0];
    final r = ByteReader(Uint8List.sublistView(bytes, 1));
    switch (tag) {
      case _tagMatchStart:
        return MatchStartMsg(
            yourSlot: r.i32(), seed: r.i32(), tickRateHz: r.i32(),
            snapshotRateHz: r.i32(), startTick: r.i32());
      case _tagInput:
        return InputMsg(
            slot: r.i32(), seq: r.i32(), clientTick: r.i32(),
            aimX: r.i32(), aimY: r.i32(), type: r.i32());
      case _tagSnapshot:
        final st = r.i32();
        final a0 = r.i32();
        final a1 = r.i32();
        final len = r.i32();
        return SnapshotMsg(serverTick: st, ackedSeq: [a0, a1], stateBytes: r.bytes(len));
      case _tagMatchEnd:
        return MatchEndMsg(reason: EndReason.values[r.i32()]);
      default:
        throw ArgumentError('unknown protocol tag $tag');
    }
  }
}
