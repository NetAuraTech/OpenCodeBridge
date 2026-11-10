import 'dart:async';

import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../app_mode.dart';
import '../client/authenticated_http.dart';
import '../client/connection_monitor.dart';
import '../notify/deep_link.dart';
import '../settings/app_settings.dart';
import 'connection_indicator.dart';
import 'docker_tab.dart';
import 'orbs_tab.dart';
import 'sessions_tab.dart';
import 'settings_tab.dart';

/// The 4-tab information architecture (spec: section 13, section 9):
/// Sessions (default), Orbs, Docker, Settings — with the discreet connection
/// indicator in the footer, right of the Settings item.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.monitor,
    required this.settings,
    required this.mode,
    this.localBridgeUri,
    this.onTunnelUrlCommitted,
    this.auth,
    this.access,
    this.deepLinks,
    this.onNotifyToggled,
    this.onPushProjectCommitted,
    this.onServiceAccountCommitted,
    this.onThemeModeChanged,
  });

  final ConnectionMonitor monitor;
  final AppSettings settings;
  final AppMode mode;

  /// Present in server mode: where the embedded bridge listens.
  final Uri? localBridgeUri;

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

  /// Re-themes the whole app live from the persisted choice (issue #49);
  /// the Settings tab's Theme section and the structured view's `/themes`
  /// command call it after the choice is persisted.
  final VoidCallback? onThemeModeChanged;

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

  /// The one-shot orb highlight (the session → orb navigation, spec §9.2):
  /// the orb id whose card the Orbs tab should highlight, set when the
  /// Sessions tab's chip is tapped; consumed by the Orbs tab (which reports
  /// back through `onHighlightConsumed` to clear it, so a later identical
  /// tap is a new event).
  String? _orbHighlight;

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
        _tab = 2; // Docker sits behind the Orbs tab.
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
    // No app bar anymore: nothing else consumes the top safe-area inset, so
    // the body keeps it out (the same geometry the former AppBar provided);
    // the bottom inset stays with the bottom bar.
    body: SafeArea(
      top: true,
      child: IndexedStack(
        index: _tab,
        children: [
          SessionsTab(
            apiBase: _apiBase,
            settings: widget.settings,
            onThemeModeChanged: widget.onThemeModeChanged,
            auth: widget.auth,
            access: widget.access,
            deepLinkSession: _sessionTarget,
            onDeepLinkSessionConsumed: () {
              _sessionTarget = null;
            },
            // The structured view's `/settings` command (issue #46): the view
            // closes itself, and the shell lands on the Settings tab.
            onOpenSettings: () {
              if (mounted) setState(() => _tab = 3);
            },
            // The session → orb navigation (spec §9.2): the chip reports the
            // orb id, the shell switches to the Orbs tab and highlights it.
            onOrbChipTapped: (orbId) {
              if (mounted) {
                setState(() {
                  _orbHighlight = orbId;
                  _tab = 1;
                });
              }
            },
          ),
          OrbsTab(
            apiBase: _apiBase,
            auth: widget.auth,
            access: widget.access,
            highlight: _orbHighlight,
            onHighlightConsumed: () {
              if (mounted) setState(() => _orbHighlight = null);
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
            onThemeModeChanged: widget.onThemeModeChanged,
          ),
        ],
      ),
    ),
    bottomNavigationBar: Stack(
      // The bar keeps its full width; the indicator is centred on its right
      // edge, inside the bar — never floating off it.
      children: [
        NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (index) => setState(() => _tab = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Sessions',
            ),
            NavigationDestination(
              icon: Icon(Icons.public_outlined),
              selectedIcon: Icon(Icons.public),
              label: 'Orbs',
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
        // The bridge status indicator, out of the app bar: right of the
        // Settings item, vertically centred on the bar (top/bottom + Center).
        // Rebuilds on every link-state change; the dot itself stays
        // deliberately small.
        Positioned(
          top: 0,
          bottom: 0,
          right: 8,
          child: Center(
            child: AnimatedBuilder(
              animation: widget.monitor,
              builder: (context, _) =>
                  ConnectionIndicator(state: widget.monitor.state),
            ),
          ),
        ),
      ],
    ),
  );
}
