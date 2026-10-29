import 'dart:convert';
import 'dart:io';

import 'health.dart';
import 'sessions/backend.dart';
import 'sessions/opencode_http_service.dart';
import 'sessions/opencode_service.dart';
import 'sessions/session_store.dart';

/// The embedded bridge (ADR-0001): a localhost-only HTTP server that is the
/// single API the app consumes, in every mode and on every machine.
///
/// This slice exposes the health endpoint plus the sessions endpoints of
/// spec section 5 (#1 `GET /api/sessions`, #4 `DELETE /api/sessions/{id}`).
class BridgeServer {
  BridgeServer._(this._server);

  /// The fixed port the bridge listens on. It is pinned so the tunnel
  /// configuration (spec section 9) can point the ingress at it.
  static const int defaultPort = 48201;

  /// The loopback host. The bridge never listens on anything else.
  static const String loopbackHost = '127.0.0.1';

  static const String healthPath = '/api/health';

  /// The home-list endpoint (spec section 5, endpoint 1).
  static const String sessionsPath = '/api/sessions';

  final HttpServer _server;

  /// Starts the bridge on [host] and [port].
  ///
  /// Pass [port] as 0 to let the OS assign a free port (tests).
  /// [health], when provided, computes the report served on every health
  /// request; the scaffold default reports the bridge as up and the
  /// opencode service and Docker as not configured yet.
  /// [sessions], when provided, serves the sessions endpoints (tests);
  /// the default builds a [SessionsBackend] over the shared opencode
  /// service and `~/.config/opencodebridge/sessions.json` and runs the
  /// startup orphan reconciliation (spec section 11) against it.
  ///
  /// The port is bound first so a port conflict (e.g. a second server-mode
  /// instance) fails fast, before any opencode service or on-disk work.
  static Future<BridgeServer> start({
    String host = loopbackHost,
    int port = defaultPort,
    HealthReport Function()? health,
    SessionsBackend? sessions,
  }) async {
    final server = await HttpServer.bind(host, port);
    final backend = sessions ?? await BridgeServer._defaultSessions();
    server.listen(
      (request) => BridgeServer._handle(
        request,
        health ?? BridgeServer._scaffoldHealth,
        backend,
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

  /// The default sessions backend: the real shared opencode service plus the
  /// on-disk persistence, with the startup orphan reconciliation (spec §11).
  /// Returns `null` when this machine has no shared opencode service (no
  /// service descriptor), in which case the sessions endpoints report
  /// `opencode_unavailable`.
  static Future<SessionsBackend?> _defaultSessions() async {
    try {
      final service = await OpencodeHttpService.fromHost();
      final store = await SessionStore.load();
      final backend = SessionsBackend(service: service, store: store);
      try {
        await backend.reconcile();
      } catch (_) {
        // The service is not up yet; orphan records get reconciled at the
        // next bridge startup.
      }
      return backend;
    } catch (_) {
      return null;
    }
  }

  static HealthReport _scaffoldHealth() => const HealthReport(
    bridge: ComponentStatus.ok,
    opencode: ComponentStatus.notConfigured,
    docker: ComponentStatus.notConfigured,
  );

  static Future<void> _handle(
    HttpRequest request,
    HealthReport Function() report,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.healthPath) {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode(report().toJson()));
        await response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.sessionsPath) {
        await BridgeServer._listSessions(request, sessions);
        return;
      }
      if (request.method == 'DELETE') {
        final id = BridgeServer._sessionIdIn(request.uri.path);
        if (id != null) {
          await BridgeServer._deleteSession(request, id, sessions);
          return;
        }
      }
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
      await response.close();
    } catch (_) {
      // The client went away or the socket broke; the response is unusable.
      try {
        response.close();
      } catch (_) {}
    }
  }

  /// The single session id in a `DELETE` path, or `null` when the path is
  /// not `api/sessions/{id}` (exactly one segment, so it falls through to
  /// the 404).
  static String? _sessionIdIn(String path) {
    if (path.length <= sessionsPath.length) return null;
    final rest = path.substring(sessionsPath.length + 1);
    if (rest.isEmpty || rest.contains('/')) return null;
    return Uri.decodeComponent(rest);
  }

  static Future<void> _listSessions(
    HttpRequest request,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    try {
      final rows = await sessions.list();
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode([for (final s in rows) s.toJson()]));
    } on OpencodeServiceError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'opencode_unreachable'}));
    }
    await response.close();
  }

  static Future<void> _deleteSession(
    HttpRequest request,
    String id,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    try {
      await sessions.delete(id);
      response.statusCode = HttpStatus.noContent;
    } on OpencodeServiceError catch (e) {
      if (e.statusCode == HttpStatus.notFound) {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'not_found'}));
      } else {
        response.statusCode = HttpStatus.badGateway;
        response.write(jsonEncode({'error': 'opencode_unreachable'}));
      }
    }
    await response.close();
  }

  static void _unavailable(HttpResponse response) {
    response.statusCode = HttpStatus.serviceUnavailable;
    response.write(jsonEncode({'error': 'opencode_unavailable'}));
    response.close();
  }
}
