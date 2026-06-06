import 'package:flutter/material.dart';

import '../net/dev_lag_transport.dart';

/// Developer overlay: live sliders for latency and packet-loss knobs on a
/// [DevLagTransport]. Shows in-game so you can tune feel while playing.
class DevPanel extends StatefulWidget {
  const DevPanel({super.key, required this.transport});

  final DevLagTransport transport;

  @override
  State<DevPanel> createState() => _DevPanelState();
}

class _DevPanelState extends State<DevPanel> {
  @override
  Widget build(BuildContext context) {
    final t = widget.transport;
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Material(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Dev: Simulated network',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                _SliderRow(
                  label: 'Latency: ${t.latencyMs} ms',
                  value: t.latencyMs.toDouble(),
                  min: 0,
                  max: 300,
                  onChanged: (v) => setState(() => t.latencyMs = v.round()),
                ),
                _SliderRow(
                  label: 'Loss: ${t.lossPct}%',
                  value: t.lossPct.toDouble(),
                  min: 0,
                  max: 50,
                  onChanged: (v) => setState(() => t.lossPct = v.round()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
        SizedBox(
          width: 150,
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
