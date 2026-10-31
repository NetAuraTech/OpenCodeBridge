import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'browser_opener.dart';
import 'loopback_server.dart';
import 'oauth_client.dart';
import 'token_store.dart';

/// The user's Access login state for one tunnel host (issue #23; shown in
/// Settings as connect / logged-in / logged-out).
enum AccessLoginState { loggedOut, connecting, loggedIn }

/// How long the loopback waits for the IdP's redirect (the user is typing
/// a one-time passcode in the browser).
const Duration _loginTimeout = Duration(minutes: 5);

/// The Cloudflare Access login session for one tunnel host (issue #23):
/// orchestrates discovery + dynamic registration + the browser login
/// ([OAuthLoopbackServer] + [AccessOAuthClient]) and the silent refresh of
/// the opaque token pair until the grant session ends, persisted in
/// [AccessTokenStore] so a restart within the grant session does not force
/// a re-login.
///
/// Exposes [authorizationHeader], an [`AuthHeaderProvider`
/// ](../client/authenticated_http.dart): the current
/// `Authorization: Bearer` header, refreshing proactively or on demand
/// (`forceRefresh`, i.e. after a `401`), and logging out when the grant
/// session ends.
class AccessSession {
  AccessSession({
    required this._tunnelBase,
    required this._store,
    this._openBrowser = openInBrowser,
  });

  /// The tunnel base, read at use (not at construction): the tunnel URL in
  /// Settings is live, so the base follows it.
  final Uri Function() _tunnelBase;
  final AccessTokenStore _store;
  final BrowserOpener _openBrowser;

  AccessLoginState _state = AccessLoginState.loggedOut;
  Completer<String?>? _refreshInFlight;
  final List<void Function(AccessLoginState)> _listeners = [];

  /// The tunnel host the login is for. Read live: the tunnel URL in
  /// Settings can change without a restart.
  String get tunnelHost => _tunnelBase().host;

  AccessLoginState get state => _state;

  void addListener(void Function(AccessLoginState) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(AccessLoginState) listener) =>
      _listeners.remove(listener);

  void _setState(AccessLoginState next) {
    if (next == _state) return;
    _state = next;
    for (final listener in List.of(_listeners)) {
      listener(next);
    }
  }

  /// Restores the persisted login after an app restart (issue #23): a
  /// record within the grant session means no re-login.
  Future<void> restore() async {
    final record = _store.recordFor(tunnelHost);
    if (record == null) {
      _setState(AccessLoginState.loggedOut);
      return;
    }
    if (_tokensOf(record).isExpired(DateTime.now()) &&
        record.refreshToken == null) {
      // The login ended while the app was closed.
      _store.delete(tunnelHost);
      _setState(AccessLoginState.loggedOut);
      return;
    }
    _setState(AccessLoginState.loggedIn);
  }

  /// The interactive login (issue #23, steps 2-4): dynamic client
  /// registration, the IdP login in the user's browser, the code exchange.
  /// Throws [OAuthError] on failure (state returns to what it was).
  Future<void> connect() async {
    final previous = _state;
    _setState(AccessLoginState.connecting);
    final loopback = await OAuthLoopbackServer.start();
    // The tunnel base is read now, not at construction: the URL in Settings
    // is live (the user may have just typed it).
    final client = AccessOAuthClient(_tunnelBase());
    try {
      final clientId = await client.registerClient(
        loopback.redirectUri.toString(),
      );
      final state = _randomState();
      final redirectUri = loopback.redirectUri.toString();
      await _openBrowser(client.authorizationUrl(clientId, redirectUri, state));
      final callback = await loopback.waitForRedirect(_loginTimeout);
      if (callback.state != state) {
        throw const OAuthError(
          'state_mismatch',
          'the browser redirect carried a different state (CSRF)',
        );
      }
      final tokens = await client.exchangeCode(
        clientId,
        callback.code,
        redirectUri,
      );
      _store.save(
        tunnelHost,
        AccessLoginRecord(
          clientId: clientId,
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          accessTokenExpiresAt: tokens.expiresAt,
        ),
      );
      _setState(AccessLoginState.loggedIn);
    } catch (_) {
      _setState(previous);
      rethrow;
    } finally {
      await loopback.close();
    }
  }

  /// Logs out (issue #23): drops the record; the next request re-runs the
  /// browser login.
  Future<void> logout() async {
    _store.delete(tunnelHost);
    _setState(AccessLoginState.loggedOut);
  }

  /// The current `Authorization: Bearer <opaque token>` header (the
  /// [`AuthHeaderProvider`
  /// ](../client/authenticated_http.dart) for [bridgeRequest
  /// ](../client/authenticated_http.dart)), or `null` when logged out.
  ///
  /// Refreshes proactively near the access token's expiry and when
  /// [forceRefresh] is set (a `401` was just received). When the grant
  /// session ends ([OAuthError.grantEnded]), the record is dropped, the
  /// state goes to logged-out, and `null` is returned so the caller sees
  /// the (second) `401` and can surface "log in again".
  Future<String?> authorizationHeader({bool forceRefresh = false}) async {
    final record = _store.recordFor(tunnelHost);
    if (record == null) return null;
    if (!forceRefresh && !_tokensOf(record).isExpired(DateTime.now())) {
      return 'Bearer ${record.accessToken}';
    }
    final refreshToken = record.refreshToken;
    if (refreshToken == null) {
      await logout();
      return null;
    }
    return _refresh(record.clientId, refreshToken);
  }

  Future<String?> _refresh(String clientId, String refreshToken) async {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight.future;
    final pending = Completer<String?>();
    _refreshInFlight = pending;
    try {
      final tokens = await AccessOAuthClient(_tunnelBase())
          .refresh(clientId, refreshToken);
      _store.save(
        tunnelHost,
        AccessLoginRecord(
          clientId: clientId,
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          accessTokenExpiresAt: tokens.expiresAt,
        ),
      );
      _setState(AccessLoginState.loggedIn);
      pending.complete('Bearer ${tokens.accessToken}');
    } on OAuthError catch (error) {
      if (error.grantEnded) {
        _store.delete(tunnelHost);
        _setState(AccessLoginState.loggedOut);
      }
      pending.complete(null);
    } catch (_) {
      // An unexpected failure: resolve the in-flight waiters (`null` → they
      // see the `401` and retry) and let the caller keep the error.
      pending.complete(null);
      rethrow;
    } finally {
      _refreshInFlight = null;
    }
    return pending.future;
  }

  /// [AccessTokens] view over the persisted record, for the
  /// [`isExpired`](oauth_client.dart) check.
  static AccessTokens _tokensOf(AccessLoginRecord record) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return AccessTokens(
      accessToken: record.accessToken,
      refreshToken: record.refreshToken,
      expiresIn: record.accessTokenExpiresAt.difference(epoch),
      acquiredAt: epoch,
    );
  }

  static String _randomState() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
