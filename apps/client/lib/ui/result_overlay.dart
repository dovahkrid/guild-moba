import 'package:flutter/material.dart';

import '../match/match_binding.dart';

/// Full-screen victory/defeat banner shown when the match ends.
class ResultOverlay extends StatelessWidget {
  const ResultOverlay({super.key, required this.binding});

  final MatchBinding binding;

  @override
  Widget build(BuildContext context) {
    final winner = binding.winnerSlot;
    final me = binding.localSlot;
    final String text;
    if (winner == null || winner < 0) {
      text = 'MATCH ENDED';
    } else {
      text = winner == me ? 'VICTORY' : 'DEFEAT';
    }
    return Container(
      color: const Color(0x99000000),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 48,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
