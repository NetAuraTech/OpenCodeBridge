import 'dart:convert';
import 'dart:io';

import 'health.dart';

/// The embedded bridge (ADR-0001): a localhost-only HTTP server that is the
/// single API the app consumes, in every mode and on every machine.
///
/// This slice exposes only the health endpoint; the wrapper endpoints of
/// spec section 5 arrive in later slices.
class BridgeServer {
  BridgeServer._(this._server);

  /// The fixed port the bridge listens on. It is pinned so the tunnel
  /// configuration (spec section 9) can point the ingress at it.
  static const int defaultPort = 48201;

  /// The loopback host. The bridge never listens on anything else.
  static const String loopbackHost = '127.0.0.1';

  static const String healthPath = '/api/health';

  final HttpServer _server;

  /// Starts the bridge on [host] and [port].
  ///
  /// Pass [port] as 0 to let the OS assign a free port (tests).
  /// [health], when provided, computes the report served on every health
  /// request; the scaffold default reports the bridge as up and the
  /// opencode service and Docker as not configured yet.
  static Future<BridgeServer> start({
    String host = loopbackHost,
    int port = defaultPort,
    HealthReport Function()? health,
  }) async {
    final server = await HttpServer.bind(host, port);
    server.listen(
      (request) => BridgeServer._handleRequest(
        request,
        health ?? BridgeServer._scaffoldHealth,
      ),
    );
    return BridgeServer._(server);
  }

  /// Where the bridge listens, e.g. `http://127.0.0.1:48201/`.
  Uri get baseUri =>
      Uri.parse('http://${_server.address.host}:${_server.port}/');

  /// The health endpoint, e.g. `http://127.0.0.1:48201/api/health`.
  Uri get healthUri => baseUri.replace(path: healthPath);

  Future<void> stop() => _server.close(force: true);

  static HealthReport _scaffoldHealth() => const HealthReport(
    bridge: ComponentStatus.ok,
    opencode: ComponentStatus.notConfigured,
    docker: ComponentStatus.notConfigured,
  );

  static void _handleRequest(
    HttpRequest request,
    HealthReport Function() report,
  ) {
    final response = request.response;
    response.headers.contentType = ContentType.json;

    if (request.method == 'GET' &&
        request.uri.path == BridgeServer.healthPath) {
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode(report().toJson()));
      response.close();
    } else {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
      response.close();
    }
  }
}
