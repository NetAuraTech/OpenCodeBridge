import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/model/session.dart';

/// The app-side client of the bridge's sessions endpoints (spec section 5,
/// endpoints 1 & 4). The app talks only to the bridge (ADR-0001): in server
/// mode that is loopback, in client mode the same API behind the tunnel.
class SessionsClient {
  SessionsClient(this._base);

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// Every session on the shared service, newest first (spec section 5,
  /// endpoint 1).
  Future<List<Session>> list() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(_base.replace(path: 'api/sessions'));
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) Session.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Deletes a session (spec section 5, endpoint 4): the bridge performs the
  /// service deletion and the persistence-record removal in one action.
  Future<void> delete(String id) async {
    final client = HttpClient();
    try {
      final request = await client.deleteUrl(
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}'),
      );
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(
          response.statusCode,
          'delete of $id was not accepted',
        );
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }
}

/// A failure of a bridge sessions endpoint, carrying the bridge's status
/// (0 when the bridge could not be reached at all).
class SessionsClientError implements Exception {
  const SessionsClientError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SessionsClientError($statusCode: $message)';
}
