import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/client/authenticated_http.dart';

/// The app-side client of the bridge's filesystem endpoints (issue #54's
/// "New project" file-picker): the host's drives and the subdirectories of a
/// directory, one level at a time. Like every other bridge endpoint it works
/// in both modes — loopback in server mode, the tunnel in client mode (issue
/// #23: every request carries `Authorization: Bearer` from [auth] — see
/// [bridgeRequest]).
class FsClient {
  FsClient(this._base, {this._auth});

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// The Access login's header provider (issue #23); `null` in server mode.
  final AuthHeaderProvider? _auth;

  /// The host's drives (the picker's top level), a sorted list of absolute
  /// paths.
  Future<List<String>> drives() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/fs/drives'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw FsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) item as String];
    } on FsClientError {
      rethrow;
    } catch (error) {
      throw FsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The subdirectories of [path] (directories only, no files), a sorted list
  /// of absolute paths.
  Future<List<String>> subdirectories(String path) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(
          path: 'api/fs/directories',
          queryParameters: {'path': path},
        ),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw FsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) item as String];
    } on FsClientError {
      rethrow;
    } catch (error) {
      throw FsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }
}

/// A failure of a bridge filesystem endpoint, carrying the bridge's status
/// (0 when the bridge could not be reached at all).
class FsClientError implements Exception {
  const FsClientError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'FsClientError($statusCode: $message)';
}
