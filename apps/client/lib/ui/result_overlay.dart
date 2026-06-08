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
    final bool won = winner != null && winner >= 0 && winner == me;
    final bool decided = winner != null && winner >= 0;
    final String text = !decided ? 'MATCH ENDED' : (won ? 'VICTORY' : 'DEFEAT');
    final Color accent = !decided
        ? const Color(0xFFB0BEC5)
        : (won ? const Color(0xFF7CD06B) : const Color(0xFFF44336));

    return Container(
      color: const Color(0xCC0B0F12),
      alignment: Alignment.center,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1.0),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        builder: (context, s, child) => Transform.scale(scale: s, child: child),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 28),
          decoration: BoxDecoration(
            color: const Color(0xFF12181D),
            border: Border.all(color: accent, width: 4),
            boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 24)],
          ),
          child: Text(
            text,
            style: TextStyle(
              color: accent,
              fontSize: 52,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              letterSpacing: 4,
            ),
          ),
        ),
      ),
    );
  }
}
