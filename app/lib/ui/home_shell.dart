import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../app_mode.dart';
import '../client/authenticated_http.dart';
import '../client/connection_monitor.dart';
import '../client/events_client.dart';
import '../settings/app_settings.dart';
import 'connection_indicator.dart';
import 'deep_link_target.dart';
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
    this.onEventSource,
    this.onAfkChanged,
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

  /// The one-shot deep-link target (issues #24, #287): the tapped
  /// notification's link (who to open), owned by this model, which the app
  /// holds across remounts so a target set while the shell was away is
  /// still on the model when it comes back. `null` when this device has no
  /// push registration (server mode, no tunnel URL yet, or the flow never
  /// started).
  final DeepLinkTarget? deepLinks;

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

  /// Hands the Sessions tab's unified-event source to the app (issue #246):
  /// the desktop session sounds subscribe to the same stream the tab uses,
  /// so the sounds play on any tab and in an unfocused window alike, on one
  /// SSE connection. Called with the source when it comes up and with
  /// `null` when it goes away (the tunnel URL cleared).
  final void Function(EventSource? source)? onEventSource;

  /// Hands the AFK settings to the in-process bridge on every change (spec
  /// #376, T1, server mode): the next orb spawn reads the new cap, the next
  /// AFK session creation the new model. The Settings tab calls it; `null` in
  /// client mode (the bridge runs on the host, not here).
  final VoidCallback? onAfkChanged;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  /// The one-shot orb highlight (the session → orb navigation, spec §9.2):
  /// the orb id whose card the Orbs tab should highlight, set when the
  /// Sessions tab's chip is tapped; consumed by the Orbs tab (which reports
  /// back through `onHighlightConsumed` to clear it, so a later identical
  /// tap is a new event).
  String? _orbHighlight;

  /// A tapped notification (issue #24): switch to its tab. The target to
  /// open is already on the model (the notify layer put it there) — the tab
  /// reads it from there and clears it through [DeepLinkTarget.consume]
  /// when it opens it (issue #287).
  void _onDeepLinkTarget() {
    final target = widget.deepLinks?.target;
    if (target == null) return;
    // Docker sits behind the Orbs tab.
    setState(() => _tab = target.isSession ? 0 : 2);
  }

  @override
  void initState() {
    super.initState();
    // The model is a stable owner (the app holds it across remounts):
    // listening it means "switch the tab when the target changes" — and a
    // target set while the shell was away is still on the model (the tabs
    // open it on their next load), never dropped, and a re-attach can never
    // throw. A listener does not replay an already-set target, so a remount
    // (or a cold start whose link was buffered by the service) re-reads the
    // model once here and lands on the right tab.
    final target = widget.deepLinks?.target;
    if (target != null) {
      _tab = target.isSession ? 0 : 2; // Docker sits behind the Orbs tab.
    }
    widget.deepLinks?.addListener(_onDeepLinkTarget);
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new push flow (a saved Firebase project) means a new model: re-attach
    // to it so the tab switch follows the new service's taps.
    if (widget.deepLinks != oldWidget.deepLinks) {
      oldWidget.deepLinks?.removeListener(_onDeepLinkTarget);
      widget.deepLinks?.addListener(_onDeepLinkTarget);
    }
  }

  @override
  void dispose() {
    widget.deepLinks?.removeListener(_onDeepLinkTarget);
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
            deepLinks: widget.deepLinks,
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
            // The desktop session sounds (issue #246): the app-level listener
            // rides the tab's event stream (no second SSE connection).
            onEventSource: widget.onEventSource,
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
            deepLinks: widget.deepLinks,
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
            onAfkChanged: widget.onAfkChanged,
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
