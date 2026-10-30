import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/model/container.dart';
import 'package:opencodebridge/sse/sse.dart';

/// The app-side client of the bridge's docker endpoints (issue #21). The
/// app talks only to the bridge (ADR-0001): in server mode that is
/// loopback, in client mode the same API behind the tunnel.
class DockerClient {
  DockerClient(this._base);

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// Every container on the host: name, image, state, uptime (issue #21).
  Future<List<DockerContainer>> list() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        _base.replace(path: 'api/docker/containers'),
      );
      final response = await request.close();
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

  /// Take the [action] on the container named [name] (issue #21). The
  /// bridge blocks until the docker CLI's command completes.
  Future<void> action(String name, DockerAction action) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        _base.replace(
          path: 'api/docker/containers/${Uri.encodeComponent(name)}/action',
        ),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'action': action.wire}));
      final response = await request.close();
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
      final request = await client.getUrl(
        _base.replace(
          path: 'api/docker/containers/${Uri.encodeComponent(name)}/logs',
          query: follow ? 'follow=1' : null,
        ),
      );
      final response = await request.close();
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
