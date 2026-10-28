import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
        final bridge = await BridgeServer.start();
        _bridge = bridge;
        _serverError = null;
        _mode = mode;
        _monitor.connect(bridge.healthUri);
      } catch (error) {
        // E.g. the bridge port is already held by another instance.
        _serverError = 'Could not start the bridge: $error';
      }
    } else {
      _mode = mode;
      _serverError = null;
      final url = settings.tunnelUrl.trim();
      if (url.isEmpty) {
        _monitor.disconnect();
      } else {
        _monitor.connect(Uri.parse(url).replace(path: BridgeServer.healthPath));
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
        onTunnelUrlCommitted: () => _enter(settings, AppMode.client),
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
