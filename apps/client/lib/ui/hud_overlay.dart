import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../match/match_binding.dart';

/// HUD overlay: shows tick stats from the MatchBinding.
class HudOverlay extends StatefulWidget {
  const HudOverlay({super.key, required this.binding});

  final MatchBinding binding;

  @override
  State<HudOverlay> createState() => _HudOverlayState();
}

class _HudOverlayState extends State<HudOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    // Rebuild every frame so stats stay fresh.
    _ticker = createTicker((_) => setState(() {}))..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.binding.view;
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('gold: ${v?.localGold ?? '-'}'),
              Text(
                'predictedTick: ${v?.predictedTick ?? '-'}',
              ),
              Text(
                'lastServerTick: ${v?.lastServerTick ?? '-'}',
              ),
              Text(
                'pendingInputs: ${v?.pendingInputCount ?? '-'}',
              ),
              Text(
                'correctionDist: ${v?.lastCorrectionDist.toStringAsFixed(3) ?? '-'}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
