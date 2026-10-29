import 'package:flutter/material.dart';

import '../client/connection_monitor.dart';

/// A discreet, non-screen connection indicator driven by the bridge health
/// endpoint. A small colored dot: green = connected, red = disconnected,
/// grey = connecting.
class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key, required this.state});

  final LinkState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      LinkState.connected => Colors.green,
      LinkState.disconnected => Colors.red,
      LinkState.connecting => Colors.grey,
    };
    final label = switch (state) {
      LinkState.connected => 'Bridge connected',
      LinkState.disconnected => 'Bridge disconnected',
      LinkState.connecting => 'Connecting to bridge',
    };
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: Container(
          key: const Key('connection-indicator-dot'),
          width: 12,
          height: 12,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
