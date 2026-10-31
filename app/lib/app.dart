import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'access/access_session.dart';
import 'access/token_store.dart';
import 'app_mode.dart';
import 'bridge/bridge_server.dart';
import 'client/connection_monitor.dart';
import 'settings/app_settings.dart';
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
  State<OpenCodeBridgeApp> createState() => _OpenCodeBridgeAppState();
}

class _OpenCodeBridgeAppState extends State<OpenCodeBridgeApp> {
  final ConnectionMonitor _monitor = ConnectionMonitor();
  AppSettings? _settings;
  AppMode? _mode;
  BridgeServer? _bridge;
  String? _serverError;
  AccessSession? _access;

  /// The desktop host: server or client at every launch.
  bool get _showsModeChoice => defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    _boot();
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
        _monitor.connect(bridge.healthUri);
      } catch (error) {
        // E.g. the bridge port is already held by another instance.
        _serverError = 'Could not start the bridge: $error';
      }
      _access = null;
      _monitor.setAuth(null);
    } else {
      _mode = mode;
      _serverError = null;
      final url = settings.tunnelUrl.trim();
      if (url.isEmpty) {
        _monitor.disconnect();
        _access = null;
        _monitor.setAuth(null);
      } else {
        final base = Uri.parse(url);
        final session = AccessSession(
          tunnelBase: base,
          store: await AccessTokenStore.load(),
        );
        _access = session;
        _monitor.setAuth(session.authorizationHeader);
        _monitor.connect(base.replace(path: BridgeServer.healthPath));
        // A restart within the grant session must not re-login (issue #23).
        await session.restore();
      }
    }
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
      ),
    );
  }

  @override
  void dispose() {
    _monitor.dispose();
    final bridge = _bridge;
    if (bridge != null) bridge.stop();
    super.dispose();
  }
}
