import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/container.dart';
import '../model/permission.dart';
import '../model/session.dart';
import 'docker/docker_backend.dart';
import 'events/bridge_event.dart';
import 'events/event_hub.dart';
import 'events/llama_speed_feed.dart';
import 'events/opencode_http_event_service.dart';
import 'health.dart';
import 'sessions/backend.dart';
import 'sessions/opencode_http_service.dart';
import 'sessions/opencode_service.dart';
import 'sessions/session_store.dart';
import 'terminal/opencode_http_terminal_service.dart';
import 'terminal/terminal_attach_proxy.dart';
import 'terminal/terminal_backend.dart';
import 'terminal/terminal_frames.dart';
import 'terminal/terminal_window.dart';
import 'terminal/terminal_window_token.dart';
import 'terminal/window_manager.dart';

/// The embedded bridge (ADR-0001): a localhost-only HTTP server that is the
/// single API the app consumes, in every mode and on every machine.
///
/// This slice exposes the health endpoint plus the sessions endpoints of
/// spec section 5 (#1 `GET /api/sessions`, #2 `POST /api/sessions` + the
/// `GET /api/projects` fill-in †, #3 `POST /api/sessions/{id}/window`,
/// #4 `DELETE /api/sessions/{id}`).
class BridgeServer {
  BridgeServer._(
    this._server,
    this._terminals,
    this._events,
    this._windows,
    this._speed,
    this._docker,
  );

  /// The fixed port the bridge listens on. It is pinned so the tunnel
  /// configuration (spec section 9) can point the ingress at it.
  static const int defaultPort = 48201;

  /// The loopback host. The bridge never listens on anything else.
  static const String loopbackHost = '127.0.0.1';

  static const String healthPath = '/api/health';

  /// The home-list endpoint (spec section 5, endpoint 1).
  static const String sessionsPath = '/api/sessions';

  /// The project list endpoint (spec section 5, fill-in †): feeds the
  /// new-session project picker.
  static const String projectsPath = '/api/projects';

  /// The unified event stream (spec section 8, endpoint 14): SSE.
  static const String eventsPath = '/api/events';

  /// The container list (issue #21); the per-container action and logs
  /// endpoints hang off it by name.
  static const String dockerContainersPath = '/api/docker/containers';

  final HttpServer _server;

  /// The terminal backend (endpoint 10); `null` when this machine has no
  /// shared opencode service, in which case the terminal endpoint is 404.
  final TerminalBackend? _terminals;

  /// The unified event hub (endpoint 14); `null` when this machine has no
  /// shared opencode service, in which case the events endpoint reports
  /// `opencode_unavailable`.
  final EventHub? _events;

  /// The terminal window manager (spec §7); `null` when this machine has no
  /// shared opencode service, in which case the window endpoints report
  /// `opencode_unavailable`.
  final TerminalWindowManager? _windows;

  /// The local llama.cpp speed feed (the app header's prefill/decode tok/s);
  /// `null` when this machine has no shared opencode service, in which case
  /// the speed header stays empty.
  final LlamaSpeedFeed? _speed;

  /// The Docker backend (issue #21); `null` when this machine has no docker
  /// CLI, in which case the docker endpoints report `docker_unavailable`.
  final DockerBackend? _docker;

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
  /// [events], when provided, serves the unified event stream (14, tests);
  /// the default builds an [EventHub] over the shared opencode event
  /// service (the bridge's single upstream subscription).
  /// [windows], when provided, owns the terminal windows (spec §7, tests);
  /// the default builds a [TerminalWindowManager] over the host window
  /// spawner, the app binary, and the terminal backend's window token.
  /// [docker], when provided, serves the docker endpoints (issue #21,
  /// tests); the default builds a [DockerBackend] over the host docker CLI,
  /// its container exits re-emitted onto the event stream.
  /// [dockerLogKeepAlive] paces the keep-alive comment on a followed
  /// container's log stream (20s, as on the events stream); the keep-alive
  /// write is what surfaces a client disconnect, so tests shorten it.
  ///
  /// The port is bound first so a port conflict (e.g. a second server-mode
  /// instance) fails fast, before any opencode service or on-disk work.
  static Future<BridgeServer> start({
    String host = loopbackHost,
    int port = defaultPort,
    HealthReport Function()? health,
    SessionsBackend? sessions,
    TerminalBackend? terminals,
    EventHub? events,
    TerminalWindowManager? windows,
    LlamaSpeedFeed? speedFeed,
    DockerBackend? docker,
    Duration dockerLogKeepAlive = const Duration(seconds: 20),
  }) async {
    final server = await HttpServer.bind(host, port);
    final backend = sessions ?? await BridgeServer._defaultSessions();
    final termBackend = terminals ?? await BridgeServer._defaultTerminals();
    final eventHub = events ?? await BridgeServer._defaultEvents();
    final windowManager =
        windows ??
        BridgeServer._defaultWindows(
          backend: backend,
          terminals: termBackend,
          events: eventHub,
        );
    final speed =
        speedFeed ?? await BridgeServer._defaultSpeedFeed(eventHub?.emit);
    final dockerBackend =
        docker ?? await BridgeServer._defaultDocker(eventHub?.emit);
    speed?.start();
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
        eventHub,
        windowManager,
        dockerBackend,
        dockerLogKeepAlive,
      );
    });
    return BridgeServer._(
      server,
      termBackend,
      eventHub,
      windowManager,
      speed,
      dockerBackend,
    );
  }

  /// Where the bridge listens, e.g. `http://127.0.0.1:48201/`.
  Uri get baseUri =>
      Uri.parse('http://${_server.address.host}:${_server.port}/');

  /// The health endpoint, e.g. `http://127.0.0.1:48201/api/health`.
  Uri get healthUri => baseUri.replace(path: healthPath);

  /// The terminal backend (endpoint 10), `null` when this machine has no
  /// shared opencode service (the terminal endpoint reports 404 then). The
  /// app uses it to attach to its sessions' terminals in-process (spec §12).
  TerminalBackend? get terminals => _terminals;

  Future<void> stop() async {
    await _server.close(force: true);
    await _terminals?.close();
    await _events?.close();
    await _windows?.close();
    await _speed?.close();
    await _docker?.close();
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

  /// The default event hub (endpoint 14): the bridge's single upstream
  /// `GET /api/event` subscription over the shared opencode service, fanned
  /// out to the app SSE connections. Returns `null` when this machine has no
  /// shared opencode service (no descriptor), in which case endpoint 14
  /// reports `opencode_unavailable`.
  static Future<EventHub?> _defaultEvents() async {
    try {
      final service = await OpencodeHttpEventService.fromHost();
      return EventHub(service: service);
    } catch (_) {
      return null;
    }
  }

  /// The default llama.cpp speed feed: the local llama.cpp server's
  /// prefill/decode throughput, re-emitted as `llama.speed` bridge events on
  /// the unified stream. `null` when this machine has no shared opencode
  /// service (no [emit] / no descriptor), in which case the app's speed
  /// header stays empty.
  static Future<LlamaSpeedFeed?> _defaultSpeedFeed(
    void Function(String)? emit,
  ) async {
    if (emit == null) return null;
    try {
      return await LlamaSpeedFeed.fromHost(emit: emit);
    } catch (_) {
      return null;
    }
  }

  /// The default Docker backend (issue #21): the host docker CLI, its
  /// container exits re-emitted onto the unified stream through the event
  /// hub when there is one. Returns `null` when this machine has no docker
  /// CLI, in which case the docker endpoints report `docker_unavailable`.
  static Future<DockerBackend?> _defaultDocker(
    void Function(String)? emit,
  ) async {
    try {
      return await DockerBackend.host(emit: emit);
    } catch (_) {
      return null;
    }
  }

  /// The default window manager (spec §7): the host window spawner (gnome
  /// terminal / xterm), the app binary as the attach client, and the
  /// terminal backend's per-startup window token. Returns `null` when this
  /// machine has no sessions backend or terminal backend (no shared opencode
  /// service), in which case the window endpoints report
  /// `opencode_unavailable`.
  static TerminalWindowManager? _defaultWindows({
    required SessionsBackend? backend,
    required TerminalBackend? terminals,
    required EventHub? events,
  }) {
    if (backend == null || terminals == null) return null;
    return TerminalWindowManager(
      liveSessionIds: backend.liveSessionIds,
      spawner: TerminalWindowSpawner.host(),
      terminalBinary: Platform.resolvedExecutable,
      windowToken: () => terminals.token.value,
      onEvent: events?.emit,
    );
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
    EventHub? events,
    TerminalWindowManager? windows,
    DockerBackend? docker,
    Duration dockerLogKeepAlive,
  ) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.eventsPath) {
        await BridgeServer._handleEvents(request, events);
        return;
      }
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
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.projectsPath) {
        await BridgeServer._listProjects(request, sessions);
        return;
      }
      // The docker endpoints (issue #21), checked before the session matchers
      // (a bare list path would otherwise read as a session id to them).
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.dockerContainersPath) {
        await BridgeServer._listDockerContainers(request, docker);
        return;
      }
      if (request.method == 'GET') {
        final logs = BridgeServer._dockerLogsIn(request.uri);
        if (logs != null) {
          await BridgeServer._handleDockerLogs(
            request,
            logs.$1,
            logs.$2,
            docker,
            dockerLogKeepAlive,
          );
          return;
        }
      }
      if (request.method == 'POST') {
        final name = BridgeServer._dockerActionIn(request.uri.path);
        if (name != null) {
          await BridgeServer._handleDockerAction(request, name, docker);
          return;
        }
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.sessionsPath) {
        await BridgeServer._createSession(request, sessions, windows);
        return;
      }
      // The structured-view reads (spec section 5, endpoints 5–8).
      if (request.method == 'GET') {
        final id = BridgeServer._sessionIdIn(request.uri.path);
        if (id != null) {
          await BridgeServer._detail(request, id, sessions);
          return;
        }
      }
      if (request.method == 'GET' || request.method == 'POST') {
        final id = BridgeServer._messagesSessionIn(request.uri.path);
        if (id != null) {
          if (request.method == 'GET') {
            await BridgeServer._messages(request, id, sessions);
          } else {
            await BridgeServer._prompt(request, id, sessions);
          }
          return;
        }
      }
      if (request.method == 'GET') {
        final id = BridgeServer._permissionsSessionIn(request.uri.path);
        if (id != null) {
          await BridgeServer._permissions(request, id, sessions);
          return;
        }
      }
      // Endpoint 9: the permission reply.
      if (request.method == 'POST') {
        final reply = BridgeServer._permissionReplyIn(request.uri.path);
        if (reply != null) {
          await BridgeServer._permissionReply(
            request,
            reply.$1,
            reply.$2,
            sessions,
          );
          return;
        }
      }
      if (request.method == 'POST') {
        final id = BridgeServer._windowSessionIn(request.uri.path);
        if (id != null) {
          await BridgeServer._openWindow(request, id, sessions, windows);
          return;
        }
      }
      if (request.method == 'DELETE') {
        final id = BridgeServer._sessionIdIn(request.uri.path);
        if (id != null) {
          await BridgeServer._deleteSession(
            request,
            id,
            sessions,
            events,
            windows,
          );
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

  /// Endpoint 14: the unified event stream (SSE). Attaches the request as a
  /// downstream connection on the event hub; the hub fans out every opencode
  /// event (verbatim) and every bridge-native event to it.
  static Future<void> _handleEvents(
    HttpRequest request,
    EventHub? events,
  ) async {
    final response = request.response;
    if (events == null) {
      BridgeServer._unavailable(response);
      return;
    }
    // The charset matters: HttpResponse encodes its `write`s with the
    // content-type's charset (default Latin-1, which throws on any character
    // above U+00FF and used to drop the whole SSE connection on one such
    // token). The stream is UTF-8, matching the client's Utf8Decoder.
    response.headers.contentType = ContentType.parse(
      'text/event-stream; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    response.bufferOutput = false;
    response.statusCode = HttpStatus.ok;
    events.add(HttpEventConnection(response));
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

  /// The single session id in a window path, or `null` when [path] is not
  /// `api/sessions/{id}/window` (exactly one segment, so it falls through to
  /// the 404).
  static String? _windowSessionIn(String path) {
    const prefix = '/api/sessions/';
    const suffix = '/window';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final id = path.substring(prefix.length, path.length - suffix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return Uri.decodeComponent(id);
  }

  /// The single session id in a messages path, or `null` when [path] is not
  /// `api/sessions/{id}/messages` (endpoint 6 read, endpoint 7 write).
  static String? _messagesSessionIn(String path) {
    const prefix = '/api/sessions/';
    const suffix = '/messages';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final id = path.substring(prefix.length, path.length - suffix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return Uri.decodeComponent(id);
  }

  /// The single session id in a permissions path, or `null` when [path] is not
  /// `api/sessions/{id}/permissions` (endpoint 8).
  static String? _permissionsSessionIn(String path) {
    const prefix = '/api/sessions/';
    const suffix = '/permissions';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final id = path.substring(prefix.length, path.length - suffix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return Uri.decodeComponent(id);
  }

  /// The (session id, request id) in a permission-reply path, or `null` when
  /// [path] is not `api/sessions/{id}/permissions/{requestID}/reply`
  /// (endpoint 9).
  static (String, String)? _permissionReplyIn(String path) {
    const prefix = '/api/sessions/';
    const mid = '/permissions/';
    const suffix = '/reply';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final rest = path.substring(prefix.length, path.length - suffix.length);
    final i = rest.indexOf(mid);
    if (i < 0) return null;
    final id = rest.substring(0, i);
    final requestID = rest.substring(i + mid.length);
    if (id.isEmpty ||
        id.contains('/') ||
        requestID.isEmpty ||
        requestID.contains('/')) {
      return null;
    }
    return (Uri.decodeComponent(id), Uri.decodeComponent(requestID));
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

  /// The project list (spec section 5, fill-in †): the picker's rows,
  /// id + display name + canonical directory.
  static Future<void> _listProjects(
    HttpRequest request,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    try {
      final projects = await sessions.projects();
      response.statusCode = HttpStatus.ok;
      response.write(
        jsonEncode([
          for (final p in projects)
            {'id': p.id, 'name': p.name, 'canonical': p.canonical},
        ]),
      );
    } on OpencodeServiceError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'opencode_unreachable'}));
    }
    await response.close();
  }

  /// Endpoint 5 (spec section 5): the session's detail — state plus costs and
  /// token usage. Unknown session is a 404; a service failure is a 502.
  static Future<void> _detail(
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
      final detail = await sessions.getDetail(id);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode(detail.toJson()));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// Endpoint 6 (spec section 5): the session's history as structured-view
  /// messages (with the tools in flight). Unknown session is a 404; a service
  /// failure is a 502.
  static Future<void> _messages(
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
      final messages = await sessions.getMessages(id);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode([for (final m in messages) m.toJson()]));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// Endpoint 7 (spec section 5): send a prompt. The body is `{"text": "…"}`;
  /// anything else is a 400. The prompt is enabled at any time — the service
  /// queues a mid-turn prompt (`delivery: steer`). Unknown session is a 404;
  /// a service failure is a 502.
  static Future<void> _prompt(
    HttpRequest request,
    String id,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    String? text;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      text = decoded is Map<String, Object?>
          ? decoded['text'] as String?
          : null;
    } catch (_) {
      text = null; // A non-JSON body is an invalid body.
    }
    if (text == null || text.trim().isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    try {
      await sessions.prompt(id, text);
      response.statusCode = HttpStatus.accepted;
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// Endpoint 8 (spec section 5): the session's pending permission requests.
  /// Unknown session is a 404; a service failure is a 502.
  static Future<void> _permissions(
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
      final requests = await sessions.pendingPermissions(id);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode([for (final r in requests) r.toJson()]));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// Endpoint 9 (spec section 5): reply to a pending permission request. The
  /// body is `{"reply": "once"|"always"|"reject"}`; anything else is a 400.
  /// An unknown session or request is a 404; a service failure is a 502.
  static Future<void> _permissionReply(
    HttpRequest request,
    String id,
    String requestID,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    PermissionReply? reply;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      final decision = decoded is Map<String, Object?>
          ? decoded['reply']
          : null;
      reply = PermissionReply.fromWire(decision); // throws on an unknown value
    } catch (_) {
      reply = null; // A non-JSON body or unknown decision is invalid.
    }
    if (reply == null) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    try {
      await sessions.replyPermission(id, requestID, reply);
      response.statusCode = HttpStatus.noContent;
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// Endpoint 2 (spec section 5, fill-in †): create a session in the
  /// picked project, record the launch (persistence write #1), open its
  /// terminal window, and return the session (classified
  /// `app-launched-live`). A body that is not `{"project": "<id>"}` is a
  /// 400; a project the service does not have is a 404; a service failure
  /// is a 502; a window that cannot be spawned is a 500 (the session
  /// still exists, persisted and closed — it can be reopened).
  static Future<void> _createSession(
    HttpRequest request,
    SessionsBackend? sessions,
    TerminalWindowManager? windows,
  ) async {
    final response = request.response;
    if (sessions == null || windows == null) {
      BridgeServer._unavailable(response);
      return;
    }
    String? project;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      project = decoded is Map<String, Object?>
          ? decoded['project'] as String?
          : null;
    } catch (_) {
      project = null; // A non-JSON body is an invalid body.
    }
    if (project == null || project.trim().isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    try {
      final row = await sessions.create(project);
      await windows.openFor(row.id);
      response.statusCode = HttpStatus.created;
      response.write(
        jsonEncode(
          windows.isLive(row.id)
              ? row.withClassification(SessionClassification.appLaunchedLive)
              : row,
        ),
      );
    } on OpencodeServiceError catch (e) {
      if (e.statusCode == HttpStatus.notFound) {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'not_found'}));
      } else {
        response.statusCode = HttpStatus.badGateway;
        response.write(jsonEncode({'error': 'opencode_unreachable'}));
      }
    } catch (_) {
      // The window could not be spawned (no emulator, launch failure).
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'error': 'window_unavailable'}));
    }
    await response.close();
  }

  /// Endpoint 3 (spec section 5): reopen the terminal window of a closed
  /// app-launched session — a new window running the attach client for
  /// `opencode --session <id>`. Unknown or not-app-launched sessions are a
  /// 404; a session gone from the service is a 404; a service failure is a
  /// 502; a window that cannot be spawned is a 500.
  static Future<void> _openWindow(
    HttpRequest request,
    String id,
    SessionsBackend? sessions,
    TerminalWindowManager? windows,
  ) async {
    final response = request.response;
    if (sessions == null || windows == null) {
      BridgeServer._unavailable(response);
      return;
    }
    if (!sessions.isAppLaunched(id)) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
      await response.close();
      return;
    }
    bool exists;
    try {
      exists = await sessions.exists(id);
    } on OpencodeServiceError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'opencode_unreachable'}));
      await response.close();
      return;
    }
    if (!exists) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
      await response.close();
      return;
    }
    try {
      await windows.openFor(id);
      response.statusCode = HttpStatus.noContent;
    } catch (_) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'error': 'window_unavailable'}));
    }
    await response.close();
  }

  static Future<void> _deleteSession(
    HttpRequest request,
    String id,
    SessionsBackend? sessions,
    EventHub? events,
    TerminalWindowManager? windows,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    try {
      // Delete on a live app-launched session (spec section 5, endpoint 4):
      // close its window first, then delete — the same action.
      await windows?.closeFor(id);
      await sessions.delete(id);
      // Bridge-native `session.closed` (spec §8): every connected app drops the
      // session from its list. Emitted after the delete succeeds.
      events?.emit(
        bridgeEvent(
          type: BridgeEventType.sessionClosed,
          data: {'sessionID': id},
        ),
      );
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

  /// The container list (issue #21): name, image, state, uptime per
  /// container.
  static Future<void> _listDockerContainers(
    HttpRequest request,
    DockerBackend? docker,
  ) async {
    final response = request.response;
    if (docker == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    try {
      final rows = await docker.list();
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode([for (final c in rows) c.toJson()]));
    } on DockerNotFoundError {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    }
    await response.close();
  }

  /// The container action (issue #21): the body is
  /// `{"action": "start"|"stop"|"restart"}`; anything else is a 400. An
  /// unknown container is a 404; a daemon failure is a 502.
  static Future<void> _handleDockerAction(
    HttpRequest request,
    String name,
    DockerBackend? docker,
  ) async {
    final response = request.response;
    if (docker == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    DockerAction? action;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      final value = decoded is Map<String, Object?> ? decoded['action'] : null;
      action = DockerAction.fromWire(value); // throws on an unknown value
    } catch (_) {
      action = null; // A non-JSON body or unknown action is invalid.
    }
    if (action == null) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    try {
      switch (action) {
        case DockerAction.start:
          await docker.start(name);
        case DockerAction.stop:
          await docker.stop(name);
        case DockerAction.restart:
          await docker.restart(name);
      }
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode({'name': name}));
    } on DockerNotFoundError {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    }
    await response.close();
  }

  /// The container's log stream (issue #21): the `docker logs` output as an
  /// SSE stream, one log line per `data:` frame; `?follow=1` keeps the
  /// stream open on the container's new output. The keyword filtering is the
  /// app's (the bridge never filters). An unknown container is a 404; a
  /// daemon failure is a 502.
  static Future<void> _handleDockerLogs(
    HttpRequest request,
    String name,
    bool follow,
    DockerBackend? docker,
    Duration keepAlive,
  ) async {
    final response = request.response;
    if (docker == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    DockerLogStream stream;
    try {
      stream = await docker.logs(name, follow: follow);
    } on DockerNotFoundError {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
      await response.close();
      return;
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
      await response.close();
      return;
    }
    // The charset matters exactly as on the events stream: the response
    // encodes its `write`s with the content-type's charset, and log output
    // is UTF-8.
    response.headers.contentType = ContentType.parse(
      'text/event-stream; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    response.bufferOutput = false;
    response.statusCode = HttpStatus.ok;
    // The initial comment flushes the response headers on connect (the
    // client is blocked on them) and marks the stream live, like the events
    // endpoint: a container with no output yet would otherwise hold the
    // response open without a single byte.
    response.write(': connected\n\n');
    // A keep-alive comment, exactly as on the events stream: an idle tunnel
    // connection must not be reaped, and the keep-alive write is what
    // completes [response.done] when the client disconnects (a silent
    // container would otherwise hold the CLI child with no write left to
    // fail).
    final keepAliveTimer = Timer.periodic(keepAlive, (_) {
      try {
        response.write(': keep-alive\n\n');
      } catch (_) {
        // The client went away; [response.done] kills the CLI child.
      }
    });
    final subscription = stream.lines.listen(
      (line) {
        try {
          response.write('data: $line\n\n');
        } catch (_) {
          // The client went away; [response.done] kills the CLI child.
        }
      },
      onDone: () {
        keepAliveTimer.cancel();
        response.close();
      },
      onError: (Object error) {
        keepAliveTimer.cancel();
        response.close();
      },
    );
    // The CLI child lives for this connection: it is killed when the client
    // disconnects or the log ends.
    unawaited(
      response.done.then((_) {
        keepAliveTimer.cancel();
        unawaited(subscription.cancel());
        unawaited(stream.close());
      }),
    );
  }

  /// The single container name in an action path, or `null` when [path] is
  /// not `api/docker/containers/{name}/action` (exactly one segment, so it
  /// falls through to the 404).
  static String? _dockerActionIn(String path) {
    const prefix = '/api/docker/containers/';
    const suffix = '/action';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    // An empty name (`.../containers/action`) is not a container path.
    if (path.length < prefix.length + suffix.length) return null;
    final name = path.substring(prefix.length, path.length - suffix.length);
    if (name.contains('/')) return null;
    return Uri.decodeComponent(name);
  }

  /// The (container name, follow) of a logs path, or `null` when [uri] is
  /// not `api/docker/containers/{name}/logs` (exactly one segment, so it
  /// falls through to the 404).
  static (String, bool)? _dockerLogsIn(Uri uri) {
    final path = uri.path;
    const prefix = '/api/docker/containers/';
    const suffix = '/logs';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    // An empty name (`.../containers/logs`) is not a container path.
    if (path.length < prefix.length + suffix.length) return null;
    final name = path.substring(prefix.length, path.length - suffix.length);
    if (name.contains('/')) return null;
    return (Uri.decodeComponent(name), uri.queryParameters['follow'] == '1');
  }

  static void _unavailable(HttpResponse response) {
    response.statusCode = HttpStatus.serviceUnavailable;
    response.write(jsonEncode({'error': 'opencode_unavailable'}));
    response.close();
  }

  /// No docker CLI on this host (issue #21).
  static void _dockerUnavailable(HttpResponse response) {
    response.statusCode = HttpStatus.serviceUnavailable;
    response.write(jsonEncode({'error': 'docker_unavailable'}));
    response.close();
  }

  /// Maps a service failure to the bridge contract: a 404 from the service is
  /// a 404; anything else is a 502.
  static void _serviceError(HttpResponse response, OpencodeServiceError e) {
    if (e.statusCode == HttpStatus.notFound) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
    } else {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'opencode_unreachable'}));
    }
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
