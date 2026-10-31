import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../app_mode.dart';
import '../bridge/terminal/terminal_backend.dart';
import '../client/authenticated_http.dart';
import '../client/connection_monitor.dart';
import '../settings/app_settings.dart';
import 'connection_indicator.dart';
import 'docker_tab.dart';
import 'sessions_tab.dart';
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
    this.terminals,
    this.onTunnelUrlCommitted,
    this.auth,
    this.access,
  });

  final ConnectionMonitor monitor;
  final AppSettings settings;
  final AppMode mode;

  /// Present in server mode: where the embedded bridge listens.
  final Uri? localBridgeUri;

  /// Present in server mode with a shared opencode service: the terminal
  /// backend the Sessions tab attaches to in-process (spec §12).
  final TerminalBackend? terminals;

  /// Re-points the connection at the tunnel URL after it is committed.
  final VoidCallback? onTunnelUrlCommitted;

  /// The Access login's header provider (issue #23, client mode); `null` in
  /// server mode.
  final AuthHeaderProvider? auth;

  /// The tunnel's Access login (issue #23, client mode) for the Settings
  /// tab; `null` in server mode or without a tunnel URL.
  final AccessSession? access;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  /// Where the bridge's API lives for the client widgets: loopback in
  /// server mode, the tunnel URL from Settings in client mode, or `null`
  /// when the client mode has no tunnel URL yet.
  Uri? get _apiBase {
    if (widget.mode == AppMode.server) {
      return widget.localBridgeUri?.replace(path: '/');
    }
    final tunnel = widget.settings.tunnelUrl.trim();
    return tunnel.isEmpty ? null : Uri.parse(tunnel);
  }

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
        SessionsTab(
          apiBase: _apiBase,
          terminals: widget.terminals,
          auth: widget.auth,
          access: widget.access,
        ),
        DockerTab(apiBase: _apiBase, auth: widget.auth),
        SettingsTab(
          settings: widget.settings,
          mode: widget.mode,
          localBridgeUri: widget.localBridgeUri,
          onTunnelUrlCommitted: widget.onTunnelUrlCommitted,
          access: widget.access,
          auth: widget.auth,
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
