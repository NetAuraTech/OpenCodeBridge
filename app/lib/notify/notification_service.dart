import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';

import '../client/authenticated_http.dart';
import '../client/notify_client.dart';
import '../settings/app_settings.dart';
import 'deep_link.dart';
import 'firebase_project.dart';
import 'notify_kind.dart';

/// The app side of push (issue #24): collects the FCM token (via
/// `firebase_messaging`), requests the notification permission, and
/// registers the token with the bridge — with the events the Settings
/// toggles have enabled, re-registering on every toggle change. Tapped
/// notifications surface as [deepLinks].
///
/// It runs only where FCM can: Android (the desktop hosts are no-ops).
/// Every setup step degrades to push-off, never to an error: no Firebase
/// project in Settings, no permission granted, bridge unreachable — the
/// rest of the app is untouched.
class NotificationService {
  NotificationService({
    required this._settings,
    required this._bridgeBase,
    this._auth,
  });

  final AppSettings _settings;

  /// The bridge's base URI (loopback in server mode).
  final Uri _bridgeBase;

  /// The Access login's header provider (issue #23); `null` in server mode.
  final AuthHeaderProvider? _auth;

  final StreamController<DeepLink> _deepLinks = StreamController<DeepLink>();

  /// Where a tapped notification lands (the [DeepLink] from its data
  /// payload); a single-subscription stream, buffered until a listener
  /// attaches (a cold-start tap arrives before the UI subscribes).
  Stream<DeepLink> get deepLinks => _deepLinks.stream;

  FirebaseMessaging? _messaging;
  StreamSubscription<RemoteMessage>? _openedSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<String>? _tokenRefreshSub;
  String? _token;

  /// Starts the flow (call once per service, after the bridge is up).
  Future<void> start() async {
    if (!Platform.isAndroid) return; // FCM is a mobile platform.
    final project = FirebaseProject.parse(_settings.firebaseProjectJson);
    if (project == null) return; // The setup step is not done.
    try {
      await Firebase.initializeApp(options: project.options);
    } catch (_) {
      // Already initialized (a previous entry in the same process) or a
      // real failure: continue only when some Firebase app is up.
      if (Firebase.apps.isEmpty) return;
    }
    return _ready();
  }

  /// The Firebase app is up (this one or a previous one's, same project):
  /// wire the messaging streams and the token flow.
  Future<void> _ready() async {
    _messaging = FirebaseMessaging.instance;
    // A tapped notification: the hot start (the app was suspended) and the
    // foreground tap alike; the cold start is [getInitialMessage] below.
    // (The 17.x streams are static, not per-instance.)
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen(_open);
    _foregroundSub = FirebaseMessaging.onMessage.listen(_open);
    unawaited(_startTokenFlow());
  }

  Future<void> _startTokenFlow() async {
    final status = await Permission.notification.request();
    if (!status.isGranted) return; // Push stays off for this device.
    // The classic registration token stays the contract (issue #24): the
    // bridge's sender targets `token` in the FCM v1 API, which the 17.x
    // FID flow does not feed.
    // ignore: deprecated_member_use
    _tokenRefreshSub = _messaging!.onTokenRefresh.listen((token) {
      _token = token;
      unawaited(_register());
    });
    // ignore: deprecated_member_use
    _token = await _messaging!.getToken();
    // The notification that opened the app, when it launched from one.
    final initial = await _messaging!.getInitialMessage();
    if (initial != null) _open(initial);
    await _register();
  }

  /// Re-registers the device with the Settings toggles as they are now
  /// (the Settings tab calls this on every toggle change, issue #24).
  Future<void> reregister() => _register();

  Future<void> _register() async {
    final token = _token;
    if (token == null) return;
    try {
      await NotifyClient(_bridgeBase, auth: _auth).registerDevice(
        token,
        _enabledKinds(),
      );
    } catch (_) {
      // The bridge is unreachable, or push is unconfigured there (503):
      // the next toggle change re-registers.
    }
  }

  /// The enabled push events, from the Settings toggles (issue #24: the
  /// toggles update the registration).
  Set<NotifyKind> _enabledKinds() {
    final kinds = <NotifyKind>{};
    if (_settings.notifyPermissionAsked) kinds.add(NotifyKind.permissionAsked);
    if (_settings.notifyTurnEnded) kinds.add(NotifyKind.turnEnded);
    if (_settings.notifyDockerContainer) {
      kinds.add(NotifyKind.dockerContainer);
    }
    return kinds;
  }

  void _open(RemoteMessage message) {
    final link = message.data['link'];
    if (link == null) return;
    final parsed = DeepLink.tryParse(Uri.parse(link));
    if (parsed != null && !_deepLinks.isClosed) _deepLinks.add(parsed);
  }

  /// Releases the streams (the app's `dispose`).
  Future<void> stop() async {
    await _openedSub?.cancel();
    await _foregroundSub?.cancel();
    await _tokenRefreshSub?.cancel();
    await _deepLinks.close();
  }
}
