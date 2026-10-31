import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/client/authenticated_http.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/project.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// The app-side client of the bridge's sessions endpoints (spec section 5).
/// The app talks only to the bridge (ADR-0001): in server mode that is
/// loopback, in client mode the same API behind the tunnel (issue #23:
/// every request carries `Authorization: Bearer` from [auth], refreshed
/// on `401` — see [bridgeRequest]).
class SessionsClient {
  SessionsClient(this._base, {this._auth});

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// The Access login's header provider (issue #23); `null` in server mode.
  final AuthHeaderProvider? _auth;

  /// Every session on the shared service, newest first (spec section 5,
  /// endpoint 1).
  Future<List<Session>> list() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions'),
        auth: _auth,
      );
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

  /// The project list (spec section 5, fill-in †): the new-session project
  /// picker's rows, id + display name + canonical directory.
  Future<List<Project>> projects() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/projects'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) Project.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Create a session in [projectId]'s project (spec section 5, fill-in †,
  /// endpoint 2). The body is only the project id; the bridge records the
  /// launch, opens the session's terminal window, and returns the session
  /// (classified `app-launched-live` once the window is open).
  Future<Session> create(String projectId) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions'),
        body: jsonEncode({'project': projectId}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.created) {
        throw SessionsClientError(response.statusCode, body);
      }
      return Session.fromJson(jsonDecode(body));
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Reopen the terminal window of a closed app-launched session (spec
  /// section 5, endpoint 3).
  Future<void> openWindow(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/window'),
        auth: _auth,
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(
          response.statusCode,
          'window of $id was not opened',
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

  /// Deletes a session (spec section 5, endpoint 4): the bridge performs the
  /// service deletion and the persistence-record removal in one action.
  Future<void> delete(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'DELETE',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}'),
        auth: _auth,
      );
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

  /// The session's detail — state plus costs and token usage (spec
  /// section 5, endpoint 5).
  Future<SessionDetail> getDetail(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      return SessionDetail.fromJson(jsonDecode(body));
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The session's history as structured-view messages, the tools in
  /// flight included (spec section 5, endpoint 6).
  Future<List<SessionMessage>> getMessages(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/messages'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) SessionMessage.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Send a prompt (spec section 5, endpoint 7). The prompt is enabled at
  /// any time: the bridge forwards it to the service with `delivery:
  /// steer`, which queues a mid-turn prompt.
  Future<void> prompt(String id, String text) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/sessions/${Uri.encodeComponent(id)}/messages'),
        body: jsonEncode({'text': text}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.accepted) {
        throw SessionsClientError(response.statusCode, body);
      }
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The session's pending permission requests (spec section 5, endpoint
  /// 8).
  Future<List<PermissionRequest>> getPermissions(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(
          path: 'api/sessions/${Uri.encodeComponent(id)}/permissions',
        ),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) PermissionRequest.fromJson(item)];
    } on SessionsClientError {
      rethrow;
    } catch (error) {
      throw SessionsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Reply to a pending permission request (spec section 5, endpoint 9).
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(
          path:
              'api/sessions/${Uri.encodeComponent(id)}/permissions/'
              '${Uri.encodeComponent(requestID)}/reply',
        ),
        body: jsonEncode({'reply': reply.wire}),
        contentType: ContentType.json,
        auth: _auth,
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw SessionsClientError(
          response.statusCode,
          'reply to $requestID was not accepted',
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
