import 'dart:async';

import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../app_mode.dart';
import '../bridge/terminal/terminal_backend.dart';
import '../client/authenticated_http.dart';
import '../client/connection_monitor.dart';
import '../notify/deep_link.dart';
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
    this.deepLinks,
    this.onNotifyToggled,
    this.onPushProjectCommitted,
    this.onServiceAccountCommitted,
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

  /// The tapped-notification deep links (issue #24, client mode); `null`
  /// when this device has no push registration (server mode, no tunnel URL
  /// yet, or the flow never started).
  final Stream<DeepLink>? deepLinks;

  /// Re-registers this device's push with the Settings toggles as they are
  /// now (issue #24); the Settings tab calls it on every toggle change.
  final VoidCallback? onNotifyToggled;

  /// Restarts this device's push flow with the Settings as they are now
  /// (issue #24); the Settings tab calls it when the user saves the Firebase
  /// project.
  final VoidCallback? onPushProjectCommitted;

  /// Reloads the running bridge's push dispatch with the freshly saved
  /// service account (issue #24, server mode); the Settings tab calls it
  /// when the user saves the service account.
  final VoidCallback? onServiceAccountCommitted;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  StreamSubscription<DeepLink>? _deepLinksSub;

  /// The one-shot deep-link targets: the session id / container name to
  /// open, `null` when there is nothing to open. Set by a tapped
  /// notification, consumed by the tab that opens it (issue #24).
  String? _sessionTarget;
  String? _containerTarget;

  /// Subscribes to the deep links when the push flow comes up (the service
  /// is created after the client entry, once the login is restored).
  void _setDeepLinks(Stream<DeepLink>? stream) {
    final sub = _deepLinksSub;
    _deepLinksSub = null;
    if (sub != null) sub.cancel();
    if (stream == null) return;
    _deepLinksSub = stream.listen(_onDeepLink);
  }

  /// A tapped notification: switch to its tab and hand it the target to
  /// open (the tab consumes it through its `onDeepLink*Consumed` callback).
  void _onDeepLink(DeepLink link) {
    setState(() {
      if (link.isSession) {
        _containerTarget = null;
        _sessionTarget = link.id;
        _tab = 0;
      } else {
        _sessionTarget = null;
        _containerTarget = link.id;
        _tab = 1;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _setDeepLinks(widget.deepLinks);
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.deepLinks != oldWidget.deepLinks) {
      _setDeepLinks(widget.deepLinks);
    }
  }

  @override
  void dispose() {
    _deepLinksSub?.cancel();
    super.dispose();
  }

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
          deepLinkSession: _sessionTarget,
          onDeepLinkSessionConsumed: () {
            _sessionTarget = null;
          },
          // The structured view's `/settings` command (issue #46): the view
          // closes itself, and the shell lands on the Settings tab.
          onOpenSettings: () {
            if (mounted) setState(() => _tab = 2);
          },
        ),
        DockerTab(
          apiBase: _apiBase,
          auth: widget.auth,
          access: widget.access,
          deepLinkContainer: _containerTarget,
          onDeepLinkContainerConsumed: () {
            _containerTarget = null;
          },
        ),
        SettingsTab(
          settings: widget.settings,
          mode: widget.mode,
          localBridgeUri: widget.localBridgeUri,
          onTunnelUrlCommitted: widget.onTunnelUrlCommitted,
          access: widget.access,
          auth: widget.auth,
          onNotifyToggled: widget.onNotifyToggled,
          onPushProjectCommitted: widget.onPushProjectCommitted,
          onServiceAccountCommitted: widget.onServiceAccountCommitted,
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
