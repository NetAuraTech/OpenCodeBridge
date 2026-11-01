import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import 'fcm_sender.dart';
import 'firebase_service_account.dart';

/// One FCM HTTP v1 delivery failure (the spec's fallback sender).
class FcmSendError implements Exception {
  const FcmSendError(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'FcmSendError($statusCode: $body)';
}

/// The fallback sender (issue #24): the raw FCM HTTP v1 API, with manual
/// token handling — `googleapis_auth` exchanges the service-account JWT for
/// a one-hour OAuth2 access token (its auto-refresh client renews it on
/// expiry) and the message is POSTed to `projects/{projectId}/messages:send`.
class FcmHttpV1Sender implements FcmSender {
  FcmHttpV1Sender({
    required this.projectId,
    required this._client,
    this.endpoint,
  });

  /// The project to send as (`projects/{projectId}/messages:send`).
  final String projectId;

  /// The FCM API host; the production host when `null` (tests point it at a
  /// local server).
  final Uri? endpoint;

  /// The authenticated client (its tokens are refreshed automatically).
  final http.Client _client;

  /// The OAuth2 scope the FCM v1 API needs.
  static const String messagingScope =
      'https://www.googleapis.com/auth/firebase.messaging';

  Uri get _endpoint => endpoint ?? Uri.https('fcm.googleapis.com');

  /// Builds the sender over [account]'s service account, with the
  /// `googleapis_auth` auto-refresh client doing the manual token handling
  /// (the JWT exchange and the one-hour token renewal).
  static Future<FcmHttpV1Sender> forServiceAccount(
    FirebaseServiceAccount account,
  ) async {
    final credentials = ServiceAccountCredentials.fromJson(account.rawJson);
    final client = await clientViaServiceAccount(credentials, [
      FcmHttpV1Sender.messagingScope,
    ]);
    return FcmHttpV1Sender(projectId: account.projectId, client: client);
  }

  @override
  Future<void> send({
    required String token,
    required String title,
    required String body,
    required String link,
  }) async {
    final response = await _client.post(
      _endpoint.replace(path: '/v1/projects/$projectId/messages:send'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'message': {
          'token': token,
          'notification': {'title': title, 'body': body},
          // The tap target, as on the Admin-SDK sender.
          'data': {'link': link},
        },
      }),
    );
    if (response.statusCode != 200) {
      throw FcmSendError(response.statusCode, response.body);
    }
  }

  @override
  Future<void> close() async {
    _client.close();
  }
}
