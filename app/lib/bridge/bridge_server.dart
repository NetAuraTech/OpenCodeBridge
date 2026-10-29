import 'dart:convert';
import 'dart:io';

import 'health.dart';
import 'sessions/backend.dart';
import 'sessions/opencode_http_service.dart';
import 'sessions/opencode_service.dart';
import 'sessions/session_store.dart';
import 'terminal/opencode_http_terminal_service.dart';
import 'terminal/terminal_attach_proxy.dart';
import 'terminal/terminal_backend.dart';
import 'terminal/terminal_frames.dart';
import 'terminal/terminal_window_token.dart';

/// The embedded bridge (ADR-0001): a localhost-only HTTP server that is the
/// single API the app consumes, in every mode and on every machine.
///
/// This slice exposes the health endpoint plus the sessions endpoints of
/// spec section 5 (#1 `GET /api/sessions`, #4 `DELETE /api/sessions/{id}`).
class BridgeServer {
  BridgeServer._(this._server, this._terminals);

  /// The fixed port the bridge listens on. It is pinned so the tunnel
  /// configuration (spec section 9) can point the ingress at it.
  static const int defaultPort = 48201;

  /// The loopback host. The bridge never listens on anything else.
  static const String loopbackHost = '127.0.0.1';

  static const String healthPath = '/api/health';

  /// The home-list endpoint (spec section 5, endpoint 1).
  static const String sessionsPath = '/api/sessions';

  final HttpServer _server;

  /// The terminal backend (endpoint 10); `null` when this machine has no
  /// shared opencode service, in which case the terminal endpoint is 404.
  final TerminalBackend? _terminals;

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
  /// [terminals], when provided, serves the terminal attach endpoint (10,
  /// tests); the default builds a [TerminalBackend] over the shared opencode
  /// terminal service and a fresh window token.
  ///
  /// The port is bound first so a port conflict (e.g. a second server-mode
  /// instance) fails fast, before any opencode service or on-disk work.
  static Future<BridgeServer> start({
    String host = loopbackHost,
    int port = defaultPort,
    HealthReport Function()? health,
    SessionsBackend? sessions,
    TerminalBackend? terminals,
  }) async {
    final server = await HttpServer.bind(host, port);
    final backend = sessions ?? await BridgeServer._defaultSessions();
    final termBackend = terminals ?? await BridgeServer._defaultTerminals();
    server.listen((request) async {
      final sessionId = BridgeServer._terminalSessionIn(request.uri.path);
      if (termBackend != null &&
          sessionId != null &&
          request.method == 'GET' &&
          BridgeServer._isWebSocket(request)) {
        await BridgeServer._handleTerminal(request, sessionId, termBackend);
        return;
      }
      await BridgeServer._handle(
        request,
        health ?? BridgeServer._scaffoldHealth,
        backend,
      );
    });
    return BridgeServer._(server, termBackend);
  }

  /// Where the bridge listens, e.g. `http://127.0.0.1:48201/`.
  Uri get baseUri =>
      Uri.parse('http://${_server.address.host}:${_server.port}/');

  /// The health endpoint, e.g. `http://127.0.0.1:48201/api/health`.
  Uri get healthUri => baseUri.replace(path: healthPath);

  Future<void> stop() async {
    await _server.close(force: true);
    await _terminals?.close();
  }

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

  /// The default terminal backend: the real shared opencode terminal service
  /// plus a fresh window token (spec §10, §14) and a session->cwd resolver
  /// over the service's session list. Returns `null` when this machine has no
  /// shared opencode service (no descriptor), in which case endpoint 10 is
  /// 404.
  static Future<TerminalBackend?> _defaultTerminals() async {
    try {
      final terminalService = await OpencodeHttpTerminalService.fromHost();
      final sessions = await OpencodeHttpService.fromHost();
      return TerminalBackend(
        service: terminalService,
        token: TerminalWindowToken.generate(),
        sessionCwd: (String id) async {
          final rows = await sessions.listSessions();
          for (final row in rows) {
            if (row.id == id) return row.location;
          }
          throw const OpencodeServiceError(404, 'no such session');
        },
      );
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

  /// The single session id in a terminal path, or `null` when [path] is not
  /// `api/sessions/{id}/terminal` (exactly one segment, so it falls through to
  /// the 404).
  static String? _terminalSessionIn(String path) {
    const prefix = '/api/sessions/';
    const suffix = '/terminal';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final id = path.substring(prefix.length, path.length - suffix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return Uri.decodeComponent(id);
  }

  /// Whether [request] is a WebSocket upgrade request (the attach endpoint is
  /// a WebSocket; a plain GET to it falls through to the 404).
  static bool _isWebSocket(HttpRequest request) {
    final upgrade = request.headers.value(HttpHeaders.upgradeHeader);
    if (upgrade == null || !upgrade.toLowerCase().contains('websocket')) {
      return false;
    }
    return request.headers.value('Sec-WebSocket-Key') != null;
  }

  /// Endpoint 10: the terminal attach WebSocket. Authenticates with the
  /// window token (spec §10, §14), attaches a downstream to the session's
  /// [TerminalAttachProxy], and pipes frames both ways.
  static Future<void> _handleTerminal(
    HttpRequest request,
    String sessionId,
    TerminalBackend terminals,
  ) async {
    final ws = await WebSocketTransformer.upgrade(request);
    try {
      final presented = request.uri.queryParameters['token'];
      if (!terminals.verifyToken(presented)) {
        await ws.close(1008, 'unauthorized');
        return;
      }
      final cursor =
          int.tryParse(request.uri.queryParameters['cursor'] ?? '') ?? 0;
      TerminalAttacher attacher;
      try {
        attacher = await terminals.proxyFor(sessionId).attach(cursor: cursor);
      } catch (_) {
        // The PTY could not be resolved/attached (e.g. the service is down);
        // the attach client auto-reconnects with backoff.
        await ws.close(1011, 'attach failed');
        return;
      }
      BridgeServer._pipeAttachment(ws, attacher);
    } catch (_) {
      // The client went away or the socket broke; closing is best-effort.
      try {
        await ws.close();
      } catch (_) {}
    }
  }

  /// The bidirectional frame pipe between one attach WebSocket and its
  /// downstream [TerminalAttacher] (the proxy's ordered frame stream).
  static void _pipeAttachment(WebSocket ws, TerminalAttacher attacher) {
    attacher.frames.listen(
      (frame) {
        if (frame is TerminalOutput) {
          ws.add(frame.bytes);
        } else if (frame is TerminalReplayComplete) {
          ws.add(encodeReplayComplete(frame.endOffset));
        }
      },
      onDone: () {
        ws.close();
      },
      onError: (Object error, StackTrace stackTrace) {
        ws.close(1011, 'terminal stream error');
      },
    );
    ws.listen(
      (event) {
        if (event is List<int>) {
          attacher.write(event);
        } else if (event is String) {
          final resize = parseResize(event);
          if (resize != null) {
            attacher.resize(resize.cols, resize.rows);
          } else {
            attacher.write(utf8.encode(event));
          }
        }
      },
      onDone: () => attacher.close(),
      onError: (Object error, StackTrace stackTrace) => attacher.close(),
    );
  }
}
