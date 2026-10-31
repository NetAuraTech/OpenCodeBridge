import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:opencodebridge/client/authenticated_http.dart';

/// The state of the app's link to the bridge, as driven by the health
/// endpoint. This is what the discreet connection indicator reflects.
enum LinkState { connecting, connected, disconnected }

/// Probes a bridge health URI and reports whether the bridge answers.
/// Returns `true` when reachable.
typedef HealthProbe = Future<bool> Function(Uri healthUri);

/// Polls a bridge health endpoint and publishes the resulting [LinkState].
///
/// This is the single source of truth for the connection indicator: server
/// mode points it at the embedded bridge on loopback, client mode at the
/// tunnel URL from Settings.
class ConnectionMonitor extends ChangeNotifier {
  ConnectionMonitor({
    this.interval = const Duration(seconds: 5),
    this._probe,
    this._auth,
  });

  /// How often the health endpoint is polled.
  final Duration interval;

  final HealthProbe? _probe;
  AuthHeaderProvider? _auth;

  /// (Re)sets the Access header provider (issue #23): the default probe
  /// reads it on every tick.
  void setAuth(AuthHeaderProvider? auth) => _auth = auth;
  Timer? _timer;
  Uri Function()? _target;
  LinkState _state = LinkState.connecting;

  /// The current link state.
  LinkState get state => _state;

  /// Begins polling the health URI that [healthUri] provides. Replaces any
  /// previous target; [healthUri] is read on every tick, so a target that
  /// follows a live setting (the client-mode tunnel URL) needs no rewiring.
  void connect(Uri Function() healthUri) {
    _target = healthUri;
    _setState(LinkState.connecting);
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
    _tick();
  }

  /// Stops polling and reports disconnected.
  void disconnect() {
    _timer?.cancel();
    _timer = null;
    _target = null;
    _setState(LinkState.disconnected);
  }

  Future<void> _tick() async {
    final targetProvider = _target;
    if (targetProvider == null) return;
    bool reachable = false;
    try {
      final probe = _probe ?? (Uri uri) => _defaultProbe(uri, _auth);
      reachable = await probe(targetProvider());
    } catch (_) {
      reachable = false;
    }
    // Ignore the result if we disconnected meanwhile.
    if (targetProvider == _target) {
      _setState(reachable ? LinkState.connected : LinkState.disconnected);
    }
  }

  void _setState(LinkState next) {
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  /// The default probe: a `GET` on the health URI (issue #23: with [auth],
  /// carrying the `Authorization: Bearer` header and refreshing on `401`).
  static Future<bool> _defaultProbe(
    Uri healthUri,
    AuthHeaderProvider? auth,
  ) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        healthUri,
        auth: auth,
      ).timeout(const Duration(seconds: 3));
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
