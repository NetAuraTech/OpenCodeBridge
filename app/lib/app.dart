import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'access/access_session.dart';
import 'access/token_store.dart';
import 'app_mode.dart';
import 'bridge/bridge_server.dart';
import 'client/connection_monitor.dart';
import 'notify/notification_service.dart';
import 'settings/app_settings.dart';
import 'tunnel_url.dart';
import 'ui/home_shell.dart';
import 'ui/mode_choice_screen.dart';

/// The app root.
///
/// Desktop (Linux) launches show the mode choice at every launch; Android
/// (and future client-only desktops) go straight to client mode. Server
/// mode hosts the embedded bridge and points the client at it on loopback;
/// client mode connects to the tunnel URL from Settings.
class OpenCodeBridgeApp extends StatefulWidget {
  const OpenCodeBridgeApp({super.key});

  @override
  State<OpenCodeBridgeApp> createState() => OpenCodeBridgeAppState();
}

class OpenCodeBridgeAppState extends State<OpenCodeBridgeApp>
    with WidgetsBindingObserver {
  final ConnectionMonitor _monitor = ConnectionMonitor();
  AppSettings? _settings;
  AppMode? _mode;
  BridgeServer? _bridge;
  String? _serverError;
  AccessSession? _access;
  NotificationService? _notifications;

  /// The desktop host: server or client at every launch.
  bool get _showsModeChoice => defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Android suspends the app (issue #41): on returning to the foreground,
    // re-probe the bridge now so the indicator does not wait for the next
    // tick. (If Android killed the process, a fresh launch already runs the
    // full restore: settings, Access login, and connections.)
    if (state == AppLifecycleState.resumed) _monitor.reprobe();
  }

  Future<void> _boot() async {
    final settings = await AppSettings.load();
    if (!mounted) return;
    setState(() => _settings = settings);
    if (!_showsModeChoice) {
      await _enter(settings, AppMode.client);
    }
  }

  void _choose(AppMode mode) {
    _enter(_settings!, mode);
  }

  Future<void> _enter(AppSettings settings, AppMode mode) async {
    // A re-entry makes a new client session: detach from the previous one.
    _access?.removeListener(_onAccessState);
    if (mode == AppMode.server) {
      try {
        // The bridge is the tunnel's supervisor (ADR-0002): it starts the
        // cloudflared child after the port is bound, so a second instance
        // (detected by the port conflict) never spawns a second tunnel.
        final bridge = await BridgeServer.start(
          tunnel: BridgeServer.defaultTunnel(),
        );
        _bridge = bridge;
        _serverError = null;
        _mode = mode;
        _monitor.connect(() => bridge.healthUri);
      } catch (error) {
        // E.g. the bridge port is already held by another instance.
        _serverError = 'Could not start the bridge: $error';
      }
      _access = null;
      _monitor.setAuth(null);
      await _notifications?.stop();
      _notifications = null;
    } else {
      _mode = mode;
      _serverError = null;
      final url = settings.tunnelUrl.trim();
      if (url.isEmpty) {
        _monitor.disconnect();
        _access = null;
        _monitor.setAuth(null);
        await _notifications?.stop();
        _notifications = null;
      } else {
        // The session and the monitor read the tunnel URL live: the Settings
        // field writes it on every keystroke, so the login and the health
        // probe follow the URL before it is committed.
        final session = AccessSession(
          tunnelBase: () => parseTunnelUrl(settings.tunnelUrl),
          store: await AccessTokenStore.load(),
        );
        _access = session;
        _monitor.setAuth(session.authorizationHeader);
        _monitor.connect(
          () =>
              parseTunnelUrl(settings.tunnelUrl)
                  .replace(path: BridgeServer.healthPath),
        );
        // The login finishing must re-probe now, not on the next tick: the
        // browser bounce brought the app to the foreground before the token
        // exchange finished, so the foreground re-probe saw a `401`
        // (issue #41).
        session.addListener(_onAccessState);
        // A restart within the grant session must not re-login (issue #23).
        await session.restore();
        // Push (issue #24): this device registers its FCM token with the
        // bridge behind the tunnel (the registration rides the same
        // `Authorization` header as every other client request). The flow
        // is a no-op off Android (no FCM) and until the Firebase project
        // is pasted in Settings.
        _startNotifications(settings, session);
      }
    }
    if (mounted) setState(() {});
  }

  /// The Access login state changed: on logged-in, the token is in hand, so
  /// the connection indicator re-probes immediately rather than on the next
  /// tick (issue #41).
  void _onAccessState(AccessLoginState state) {
    if (state == AccessLoginState.loggedIn) _monitor.reprobe();
  }

  /// (Re)starts this device's push flow against the bridge behind the tunnel
  /// (issue #24): a fresh [NotificationService] per call, so a Firebase
  /// project saved in Settings re-initializes the flow. The flow is a no-op
  /// off Android (no FCM) and until the project is pasted.
  void _startNotifications(AppSettings settings, AccessSession session) {
    final old = _notifications;
    _notifications = null;
    unawaited(old?.stop());
    final notifications = NotificationService(
      settings: settings,
      bridgeBase: parseTunnelUrl(settings.tunnelUrl).replace(path: '/'),
      auth: session.authorizationHeader,
    );
    _notifications = notifications;
    unawaited(notifications.start());
    // The new service has a fresh deep-link stream: rebuild HomeShell so it
    // subscribes to it (and the Settings tab's status text picks up the
    // saved project).
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    final mode = _mode;
    if (mode == null) {
      return _showsModeChoice
          ? MaterialApp(
              home: ModeChoiceScreen(
                settings: settings,
                onSelected: _choose,
                error: _serverError,
              ),
            )
          : const MaterialApp(
              home: Scaffold(body: Center(child: CircularProgressIndicator())),
            );
    }
    return MaterialApp(
      title: 'OpenCodeBridge',
      home: HomeShell(
        monitor: _monitor,
        settings: settings,
        mode: mode,
        localBridgeUri: _bridge?.healthUri,
        terminals: _bridge?.terminals,
        onTunnelUrlCommitted: () => _enter(settings, AppMode.client),
        auth: _mode == AppMode.client ? _access?.authorizationHeader : null,
        access: _mode == AppMode.client ? _access : null,
        deepLinks: _notifications?.deepLinks,
        onNotifyToggled: () {
          unawaited(_notifications?.reregister());
        },
        onPushProjectCommitted: () {
          final settings = _settings;
          final access = _access;
          if (settings == null || access == null) return;
          _startNotifications(settings, access);
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _monitor.dispose();
    unawaited(_notifications?.stop());
    final bridge = _bridge;
    if (bridge != null) bridge.stop();
    super.dispose();
  }
}
