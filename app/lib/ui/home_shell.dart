import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../client/connection_monitor.dart';
import '../settings/app_settings.dart';
import 'connection_indicator.dart';
import 'docker_stub.dart';
import 'sessions_stub.dart';
import 'settings_tab.dart';

/// The 3-tab information architecture (spec: section 13):
/// Sessions (default), Docker, Settings — with the discreet connection
/// indicator in the app bar.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.monitor,
    required this.settings,
    required this.mode,
    this.localBridgeUri,
    this.onTunnelUrlCommitted,
  });

  final ConnectionMonitor monitor;
  final AppSettings settings;
  final AppMode mode;

  /// Present in server mode: where the embedded bridge listens.
  final Uri? localBridgeUri;

  /// Re-points the connection at the tunnel URL after it is committed.
  final VoidCallback? onTunnelUrlCommitted;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('OpenCodeBridge'),
      actions: [
        // Rebuilds on every link-state change; the dot itself is
        // deliberately small and unobtrusive.
        AnimatedBuilder(
          animation: widget.monitor,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.only(right: 16),
            child: ConnectionIndicator(state: widget.monitor.state),
          ),
        ),
      ],
    ),
    body: IndexedStack(
      index: _tab,
      children: [
        const SessionsStub(),
        const DockerStub(),
        SettingsTab(
          settings: widget.settings,
          mode: widget.mode,
          localBridgeUri: widget.localBridgeUri,
          onTunnelUrlCommitted: widget.onTunnelUrlCommitted,
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (index) => setState(() => _tab = index),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          selectedIcon: Icon(Icons.chat_bubble),
          label: 'Sessions',
        ),
        NavigationDestination(
          icon: Icon(Icons.inventory_2_outlined),
          selectedIcon: Icon(Icons.inventory_2),
          label: 'Docker',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    ),
  );
}
