import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/model/tunnel_report.dart';

/// The app-side client of the bridge's tunnel endpoints (issue #22). The
/// app talks only to the bridge (ADR-0001): in server mode that is
/// loopback, in client mode the same API behind the tunnel.
class TunnelClient {
  TunnelClient(this._base);

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// The current tunnel status: the cloudflared child's liveness plus its
  /// registered edge connections, and the setup steps still missing.
  Future<TunnelReport> report() async {
    final body = await TunnelClient._get(_base, 'api/tunnel');
    return TunnelReport.fromJson(jsonDecode(body));
  }

  /// Re-runs the precondition pass on the bridge (the guided-setup recheck)
  /// and returns the fresh tunnel report.
  Future<TunnelReport> check() async {
    final body = await TunnelClient._post(_base, 'api/tunnel/check');
    return TunnelReport.fromJson(jsonDecode(body));
  }

  /// The manual tunnel start, for after the guided setup or a capped
  /// auto-respawn. The bridge answers with the fresh tunnel report.
  Future<TunnelReport> start() async {
    final body = await TunnelClient._post(_base, 'api/tunnel/start');
    return TunnelReport.fromJson(jsonDecode(body));
  }

  /// The app-driven Cloudflare login (issue #37, ADR-0003): the bridge runs
  /// the app-managed `cloudflared tunnel login`, which opens the default
  /// browser on Cloudflare's consent page and stores the session in the
  /// user's own `~/.cloudflared/`. [TunnelClientError] when the login
  /// fails or times out.
  Future<void> login() async {
    await TunnelClient._post(_base, 'api/tunnel/login');
  }

  /// The assisted setup (issue #34, ADR-0003): the bridge, the sole file
  /// owner, writes the app-owned files from the pasted credentials and the
  /// chosen hostname, then re-runs the precondition pass, answering with
  /// the fresh tunnel report.
  ///
  /// [credentials] is optional (issue #37): when absent, the bridge drives
  /// `cloudflared tunnel create <tunnel>` (the Cloudflare login is
  /// required) and uses the credentials file the CLI writes.
  Future<TunnelReport> setup(
    String tunnel,
    String hostname, [
    String? credentials,
  ]) async {
    final payload = <String, Object?>{'tunnel': tunnel, 'hostname': hostname};
    if (credentials != null) payload['credentials'] = credentials;
    final body = await TunnelClient._post(
      _base,
      'api/tunnel/setup',
      body: jsonEncode(payload),
    );
    return TunnelReport.fromJson(jsonDecode(body));
  }

  static Future<String> _get(Uri base, String path) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(base.replace(path: path));
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw TunnelClientError(response.statusCode, body);
      }
      return body;
    } on TunnelClientError {
      rethrow;
    } catch (error) {
      throw TunnelClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _post(
    Uri base,
    String path, {
    String body = '{}',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(base.replace(path: path));
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close();
      final raw = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw TunnelClientError(response.statusCode, raw);
      }
      return raw;
    } on TunnelClientError {
      rethrow;
    } catch (error) {
      throw TunnelClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }
}

/// A failure of a bridge tunnel endpoint, carrying the bridge's status
/// (0 when the bridge could not be reached at all).
class TunnelClientError implements Exception {
  const TunnelClientError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'TunnelClientError($statusCode: $message)';
}
