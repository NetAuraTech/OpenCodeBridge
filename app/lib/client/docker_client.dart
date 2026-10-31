import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/client/authenticated_http.dart';
import 'package:opencodebridge/model/compose_project.dart';
import 'package:opencodebridge/model/container.dart';
import 'package:opencodebridge/sse/sse.dart';

/// The app-side client of the bridge's docker endpoints (issue #21). The
/// app talks only to the bridge (ADR-0001): in server mode that is
/// loopback, in client mode the same API behind the tunnel (issue #23:
/// every request carries `Authorization: Bearer` from [auth], refreshed
/// on `401` — see [bridgeRequest]).
class DockerClient {
  DockerClient(this._base, {this._auth});

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// The Access login's header provider (issue #23); `null` in server mode.
  final AuthHeaderProvider? _auth;

  /// Every container on the host: name, image, state, uptime (issue #21).
  Future<List<DockerContainer>> list() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/docker/containers'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw DockerClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) DockerContainer.fromJson(item)];
    } on DockerClientError {
      rethrow;
    } catch (error) {
      throw DockerClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The compose projects among the repos opencode lists (issue #21 follow-
  /// on): the docker-compose files found, each with its creatable services and
  /// their live state.
  Future<List<ComposeProject>> compose() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/docker/compose'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw DockerClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) ComposeProject.fromJson(item)];
    } on DockerClientError {
      rethrow;
    } catch (error) {
      throw DockerClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Take the [action] on the compose project [id] (its URL-encoded
  /// directory), or on one of its services when [service] is given (issue #21
  /// follow-on). The bridge blocks until the `docker compose` command
  /// completes.
  Future<void> composeAction(
    String id,
    ComposeAction action, {
    String? service,
  }) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/docker/compose/$id/action'),
        body: jsonEncode({'action': action.wire, 'service': ?service}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw DockerClientError(response.statusCode, body);
      }
    } on DockerClientError {
      rethrow;
    } catch (error) {
      throw DockerClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Take the [action] on the container named [name] (issue #21). The
  /// bridge blocks until the docker CLI's command completes.
  Future<void> action(String name, DockerAction action) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(
          path: 'api/docker/containers/${Uri.encodeComponent(name)}/action',
        ),
        body: jsonEncode({'action': action.wire}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw DockerClientError(response.statusCode, body);
      }
    } on DockerClientError {
      rethrow;
    } catch (error) {
      throw DockerClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The container's log lines, one per event, from the bridge's SSE log
  /// stream (issue #21). With [follow] the stream stays open on the
  /// container's new output; keyword filtering is this client's caller's
  /// job (the bridge never filters). The stream errors with a
  /// [DockerClientError] when the bridge rejects the request (unknown
  /// container, docker unreachable) or the bridge goes away mid-stream.
  Stream<String> logs(String name, {bool follow = true}) async* {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(
          path: 'api/docker/containers/${Uri.encodeComponent(name)}/logs',
          query: follow ? 'follow=1' : null,
        ),
        auth: _auth,
      );
      if (response.statusCode != HttpStatus.ok) {
        final body = await response.transform(const Utf8Decoder()).join();
        throw DockerClientError(response.statusCode, body);
      }
      await for (final line in sseDataLines(
        response.transform(const Utf8Decoder()),
      )) {
        yield line;
      }
    } on DockerClientError {
      rethrow;
    } catch (error) {
      throw DockerClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }
}

/// A failure of a bridge docker endpoint, carrying the bridge's status
/// (0 when the bridge could not be reached at all).
class DockerClientError implements Exception {
  const DockerClientError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'DockerClientError($statusCode: $message)';
}
