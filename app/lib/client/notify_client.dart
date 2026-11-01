import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/client/authenticated_http.dart';
import 'package:opencodebridge/notify/notify_kind.dart';

/// The app-side client of the bridge's push registration (issue #24):
/// the FCM device token plus the events the Settings toggles have enabled.
/// In server mode the bridge is loopback (ADR-0001); `auth` is `null` then.
class NotifyClient {
  NotifyClient(this._base, {this._auth});

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// The Access login's header provider (issue #23); `null` in server mode.
  final AuthHeaderProvider? _auth;

  /// Registers (or re-registers) the device's FCM [token] with exactly the
  /// enabled [events]; the bridge's latest call wins.
  Future<void> registerDevice(String token, Set<NotifyKind> events) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/notify/device-token'),
        body: jsonEncode({
          'token': token,
          'events': [for (final kind in events) kind.wire],
        }),
        contentType: ContentType.json,
        auth: _auth,
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw NotifyClientError(
          response.statusCode,
          'the device token was not registered',
        );
      }
    } on NotifyClientError {
      rethrow;
    } catch (error) {
      throw NotifyClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }
}

/// One failed push registration (the bridge is unreachable — status 0 — or
/// answered an error: 400 on a malformed body, 503 when push is not
/// configured on this machine).
class NotifyClientError implements Exception {
  const NotifyClientError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'NotifyClientError($statusCode: $message)';
}
