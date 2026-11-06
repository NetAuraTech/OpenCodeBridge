import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/command.dart';
import '../model/compose_project.dart';
import '../model/container.dart';
import '../model/orb.dart';
import '../model/permission.dart';
import '../model/question.dart';
import '../model/tunnel_report.dart';
import '../model/tunnel_setup.dart';
import 'docker/docker_backend.dart';
import 'events/bridge_event.dart';
import 'events/composite_event_service.dart';
import 'events/event_hub.dart';
import 'fs/fs_service.dart';
import 'fs/linux_fs_service.dart';
import 'notify/fcm_http_v1_sender.dart';
import 'notify/fcm_sender.dart';
import 'notify/firebase_service_account.dart';
import '../notify/notify_kind.dart';
import 'notify/notify_service.dart';
import 'notify/push_dispatcher.dart';
import 'events/llama_speed_feed.dart';
import 'events/opencode_http_event_service.dart';
import 'health.dart';
import 'sessions/backend.dart';
import 'sessions/composite_service.dart';
import 'sessions/opencode_cli.dart';
import 'sessions/opencode_http_service.dart';
import 'sessions/paths.dart';
import 'sessions/opencode_service.dart';
import 'tunnel/cloudflared_binary.dart';
import 'tunnel/cloudflared_config.dart';
import 'tunnel/tunnel_cli.dart';
import 'tunnel/tunnel_preconditions.dart';
import 'tunnel/tunnel_setup.dart';
import 'tunnel/tunnel_supervisor.dart';
import 'orb/orb_build_context.dart';
import 'orb/orb_agent_tools.dart';
import 'orb/orb_image_builder.dart';
import 'orb/orb_service.dart';
import 'orb/orb_task_service.dart';

/// The embedded bridge (ADR-0001): a localhost-only HTTP server that is the
/// single API the app consumes, in every mode and on every machine.
///
/// This slice exposes the health endpoint plus the sessions endpoints of
/// spec section 5 (#1 `GET /api/sessions`, #2 `POST /api/sessions` + the
/// `GET /api/projects` fill-in †, #4 `DELETE /api/sessions/{id}`).
class BridgeServer {
  BridgeServer._(
    this._server,
    this._health,
    this._sessions,
    this._fs,
    this._events,
    this._speed,
    this._docker,
    this._orb,
    this._orbs,
    this._tasks,
    this._tunnel,
    this._tunnelSetupService,
    this._dockerLogKeepAlive,
    this._notify,
    this._pushDispatcher,
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

  /// The "New project" file-picker's drives (issue #54): the host's real
  /// filesystem mounts, the picker's top level.
  static const String fsDrivesPath = '/api/fs/drives';

  /// The "New project" file-picker's directory listing (issue #54): the
  /// subdirectories of the `path` query parameter, one level at a time.
  static const String fsDirectoriesPath = '/api/fs/directories';

  /// The unified event stream (spec section 8, endpoint 14): SSE.
  static const String eventsPath = '/api/events';

  /// The push registration (issue #24): the app's FCM device token plus the
  /// events its Settings toggles have enabled.
  static const String deviceTokenPath = '/api/notify/device-token';

  /// The container list (issue #21); the per-container action and logs
  /// endpoints hang off it by name.
  static const String dockerContainersPath = '/api/docker/containers';

  /// The compose project list (issue #21 follow-on): the docker-compose files
  /// found in the repos opencode lists, with their creatable services. The
  /// per-project action hangs off it by the project's address.
  static const String dockerComposePath = '/api/docker/compose';

  /// The tunnel status (issue #22): the cloudflared child the bridge
  /// supervises, and the setup steps still missing when the tunnel is down.
  static const String tunnelPath = '/api/tunnel';

  /// The tunnel recheck (issue #22): re-runs the precondition pass and
  /// answers with the fresh tunnel report.
  static const String tunnelCheckPath = '/api/tunnel/check';

  /// The tunnel (re)start (issue #22): the manual start, for after the
  /// guided setup or a capped auto-respawn.
  static const String tunnelStartPath = '/api/tunnel/start';

  /// The assisted tunnel setup (issue #34, ADR-0003): the bridge, the sole
  /// file owner, writes the app-owned files from the wizard's input and
  /// answers with the fresh tunnel report.
  static const String tunnelSetupPath = '/api/tunnel/setup';

  /// The app-driven Cloudflare login (issue #37, ADR-0003): the bridge runs
  /// the app-managed `cloudflared tunnel login`, which opens the browser on
  /// Cloudflare's consent page and stores the session in the user's own
  /// `~/.cloudflared/`.
  static const String tunnelLoginPath = '/api/tunnel/login';

  /// The explicit shared-base-image rebuild (spec §5.3, §9.5; issue #92):
  /// always rebuilds the image for the expected tag, the build logs streaming
  /// onto the unified event stream.
  static const String orbImageRebuildPath = '/api/orb/image/rebuild';

  /// The orbs (issue #93): `GET` composes the orb list from the `ocb.*`
  /// labels (spec §2.2); `POST` creates one — the body is
  /// `{"project": "<project id>", "name": "<orb name>"}` (spec §2.3).
  static const String orbsPath = '/api/orbs';

  /// The spawn surface's dispatch (issue #99, spec §8.2): `POST` with the
  /// body `{"task": …, "model"?: …, "wait"?: bool, "session"?: …,
  /// "directory"?: …}` — the wake-or-create + task dispatch behind the
  /// global `orb_spawn` tool.
  static const String orbSpawnPath = '/api/orb/spawn';

  /// The spawn surface's wait (issue #99, spec §8.3): `POST` with the body
  /// `{"id": "<task id>"}` — blocks until the task completes and answers the
  /// structured result (behind the global `orb_wait` tool).
  static const String orbWaitPath = '/api/orb/wait';

  // The structured view's `/` command menu, global commands (issue #46).
  // Each is a thin pass-through of a shared-service endpoint; the service is
  // the single source of truth, so the effect is reflected live in any
  // attached TUI.

  /// The account's usage limits (the service's
  /// `GET /api/experimental/usage/limits`).
  static const String usagePath = '/api/usage';

  /// The MCP servers (the service's `GET /api/mcp`).
  static const String mcpsPath = '/api/mcp';

  /// The integrations (the service's `GET /api/integration`); the OAuth
  /// connect is `POST /api/integrations/{id}/connect`.
  static const String integrationsPath = '/api/integrations';

  /// The service's info (the service's `GET /api/info`).
  static const String statusPath = '/api/status';

  /// Pair a device (the service's `POST /api/pair`).
  static const String pairPath = '/api/pair';

  /// Reload the service's configuration (the service's
  /// `POST /api/location/reload`).
  static const String reloadPath = '/api/reload';

  /// The worktrees (the service's `GET /api/worktree?projectID=…`, the
  /// project resolved from the `sessionID` query on the service).
  static const String worktreesPath = '/api/worktrees';

  /// The plugins (the service's `GET /api/plugin`).
  static const String pluginsPath = '/api/plugins';

  final HttpServer _server;

  /// The health report served on every health request (the `start`
  /// parameter, or the scaffold default).
  final HealthReport Function() _health;

  /// The sessions backend (spec section 5); `null` when this machine has no
  /// shared opencode service, in which case the sessions endpoints report
  /// `opencode_unavailable`.
  final SessionsBackend? _sessions;

  /// The host filesystem seam the "New project" file-picker browses (issue
  /// #54, the Linux adapter of ADR-0002's per-OS seam).
  final FsService _fs;

  /// The unified event hub (endpoint 14); `null` when this machine has no
  /// shared opencode service, in which case the events endpoint reports
  /// `opencode_unavailable`.
  final EventHub? _events;

  /// The local llama.cpp speed feed (the app header's prefill/decode tok/s);
  /// `null` when this machine has no shared opencode service, in which case
  /// the speed header stays empty.
  final LlamaSpeedFeed? _speed;

  /// The Docker backend (issue #21); `null` when this machine has no docker
  /// CLI, in which case the docker endpoints report `docker_unavailable`.
  final DockerBackend? _docker;

  /// The orb shared-base-image pipeline (issue #92): the materialized
  /// build context plus the docker build of the `orb:<hash>` image; `null`
  /// when this machine has no docker CLI, in which case the rebuild
  /// endpoint reports `docker_unavailable`.
  final OrbImageBuilder? _orb;

  /// The orb create/list service (issue #93): the bridge-owned creation
  /// sequence (spec §2.3) and the label-composed list (spec §2.2); `null`
  /// when this machine has no docker CLI, no git CLI, or no image builder,
  /// in which case the orbs endpoints report `docker_unavailable`.
  final OrbService? _orbs;

  /// The spawn surface's task service (issue #99, spec §8.2/§8.3): the
  /// wake-or-create + dispatch + wait + completion injection behind the
  /// global `orb_spawn`/`orb_wait` tools; `null` when this machine has no
  /// orbs service or no sessions backend, in which case the spawn endpoints
  /// report `opencode_unavailable`.
  final OrbTaskService? _tasks;

  /// The listener on the host's docker-bridge address (spec §8.5): orb
  /// containers reach the bridge as `http://host.docker.internal:<port>`,
  /// which `--add-host` maps to that address (not loopback). `null` when
  /// the bind is unneeded (loopback/0.0.0.0) or failed (degraded mode: the
  /// loopback app is unaffected, the containers just cannot reach the
  /// bridge).
  HttpServer? _hostServer;

  /// The tunnel supervisor (issue #22, ADR-0002); `null` when this bridge
  /// does not run a tunnel, in which case the tunnel endpoints report
  /// `not_configured`.
  final TunnelSupervisor? _tunnel;

  /// The assisted-setup service (issue #34, ADR-0003).
  final TunnelSetup Function(TunnelSupervisor) _tunnelSetupService;

  /// The keep-alive pacing on a followed container's log stream.
  final Duration _dockerLogKeepAlive;

  /// The push dispatch (issue #24); `null` when this machine has no
  /// Firebase service account (the setup step not done) or no shared
  /// opencode service, in which case the device-token endpoint reports
  /// `notify_unconfigured`. Replaced wholesale by [reloadNotify] (the
  /// service-account file changed under a running bridge).
  NotifyService? _notify;

  /// The event-hub downstream [reloadNotify] built with [_notify] (the hub
  /// fans its push events out like any other connection); `null` without a
  /// live push dispatch or a hub.
  PushDispatcher? _pushDispatcher;

  /// Starts the bridge on [host] and [port].
  ///
  /// Pass [port] as 0 to let the OS assign a free port (tests).
  /// [health], when provided, computes the report served on every health
  /// request; the scaffold default reports the bridge as up and the
  /// opencode service and Docker as not configured yet.
  /// [sessions], when provided, serves the sessions endpoints (tests);
  /// the default builds a [SessionsBackend] over the shared opencode
  /// service.
  /// [fs], when provided, is the host filesystem seam the "New project"
  /// file-picker browses (issue #54, tests); the default is the Linux
  /// adapter (ADR-0002).
  /// [events], when provided, serves the unified event stream (14, tests);
  /// the default builds an [EventHub] over the shared opencode event
  /// service (the bridge's single upstream subscription).
  /// [docker], when provided, serves the docker endpoints (issue #21,
  /// tests); the default builds a [DockerBackend] over the host docker CLI,
  /// its container exits re-emitted onto the event stream.
  /// [orb], when provided, serves the explicit image-rebuild endpoint
  /// (issue #92, tests); the default materializes the embedded build context
  /// into the app-owned dir (create-if-missing) and builds an
  /// [OrbImageBuilder] over the host docker CLI.
  /// [orbs], when provided, serves the orbs create/list endpoints (issue
  /// #93, tests); the default builds an [OrbService] over the host docker
  /// and git CLIs, the orb state under `~/.config/opencodebridge/orbs`.
  /// [tunnel], when provided, is the cloudflared child the bridge
  /// supervises (issue #22); it is started here, after the port is bound,
  /// so a port conflict (a second server-mode instance) fails before any
  /// tunnel child is spawned. The default is no tunnel, in which case the
  /// tunnel endpoints report `not_configured`; the app passes
  /// [BridgeServer.defaultTunnel] in server mode.
  /// [tunnelSetup], when provided, builds the assisted-setup service
  /// (issue #34, ADR-0003) for the supervisor (tests); the default writes
  /// the app-owned files at the host paths and drives the app-managed
  /// cloudflared CLI (the login and the create, issue #37).
  /// [dockerLogKeepAlive] paces the keep-alive comment on a followed
  /// container's log stream (20s, as on the events stream); the keep-alive
  /// write is what surfaces a client disconnect, so tests shorten it.
  /// [notify], when provided, serves the push registration endpoint
  /// (issue #24, tests); the default builds the [NotifyService] from the
  /// Firebase service account (the setup step) and taps the three push
  /// events off the event hub, or stays `null` (no service account, or no
  /// shared opencode service) in which case the endpoint reports
  /// `notify_unconfigured`. [notifyCredential] pins that account file to an
  /// explicit path (tests; the standard resolution otherwise).
  ///
  /// [autoLifecyclePass] arms the automated lifecycle pass (issue #101,
  /// spec §2.10) on the orb service at [lifecyclePassInterval] (default the
  /// ~1-min pace). Server mode turns it on (the app's bridge start): the
  /// bridge is the single actor of orb automation, and bridge down = no
  /// automation. It stays off elsewhere so no background pass ever runs
  /// against a test's script fakes or a bare library use.
  ///
  /// The port is bound first so a port conflict (e.g. a second server-mode
  /// instance) fails fast, before any opencode service or on-disk work.
  static Future<BridgeServer> start({
    String host = loopbackHost,
    int port = defaultPort,
    HealthReport Function()? health,
    SessionsBackend? sessions,
    FsService? fs,
    EventHub? events,
    LlamaSpeedFeed? speedFeed,
    DockerBackend? docker,
    OrbImageBuilder? orb,
    OrbService? orbs,
    OrbTaskService? tasks,
    TunnelSupervisor? tunnel,
    TunnelSetup Function(TunnelSupervisor)? tunnelSetup,
    Duration dockerLogKeepAlive = const Duration(seconds: 20),
    NotifyService? notify,
    String? notifyCredential,
    Future<FcmSender> Function(FirebaseServiceAccount)? notifySenderFactory,
    bool autoLifecyclePass = false,
    Duration? lifecyclePassInterval,
  }) async {
    final server = await HttpServer.bind(host, port);
    // The orbs are built before the backend and the event hub: the
    // composite sessions/event services (issue #95) reach the orb service
    // through these closures, and the orb defaults need only the image
    // builder and the host CLIs. The orb service's boot-log [emit] is
    // deferred: the event hub does not exist yet, so it forwards to
    // [orbEmit] once the hub is built (any orb creation happens on the HTTP
    // surface, after [start] returns).
    void Function(String)? orbEmit;
    // The spawn surface's global agent tools (issue #99, spec §8.1): the
    // opencode v2 plugin registering orb_spawn/orb_wait, materialized into
    // the global opencode plugins dir at startup (create-if-missing — the
    // on-disk copy wins), so the host opencode has the tools and every orb
    // inherits them through the config copy (§6.2). A failure degrades: the
    // spawn endpoints still serve.
    try {
      await OrbAgentTools.materialize();
    } catch (_) {}
    final orbBuilder =
        orb ?? await BridgeServer._defaultOrb((line) => orbEmit?.call(line));
    // The backend the orb service's PR repo resolver (issue #96) reaches:
    // it does not exist yet when the orbs default is built, so it is a
    // getter — the caller-provided [sessions] up front, the built default
    // once [backend] is assigned (the resolver runs only on the HTTP
    // surface, after [start] returns).
    SessionsBackend? orbBackend;
    final orbService =
        orbs ??
        await BridgeServer._defaultOrbs(orbBuilder, (line) {
          orbEmit?.call(line);
        }, () => orbBackend ?? sessions);
    Future<List<OrbRecord>> orbList() =>
        orbService?.list() ?? Future.value(const []);
    Future<String?> orbPassword(String id) =>
        orbService?.lastPassword(id) ?? Future.value(null);
    final backend =
        sessions ?? await BridgeServer._defaultSessions(orbList, orbPassword);
    orbBackend = backend;
    // The spawn surface's task service (issue #99): the host default wires
    // the orb lifecycle service and the composite sessions backend — both
    // required, and both only built by the bridge itself (a test faking
    // either one injects [tasks], or the spawn endpoints answer 503).
    final taskService =
        tasks ??
        (orbService != null &&
                backend != null &&
                orbs == null &&
                sessions == null
            ? OrbTaskService(
                orbs: orbService,
                sessions: backend,
                file: File(
                  '${homeDirectory()}/.config/opencodebridge/tasks.json',
                ),
              )
            : null);
    final fsService = fs ?? const LinuxFsService();
    final eventHub =
        events ?? await BridgeServer._defaultEvents(orbList, orbPassword);
    orbEmit = eventHub?.emit;
    final speed =
        speedFeed ?? await BridgeServer._defaultSpeedFeed(eventHub?.emit);
    final dockerBackend =
        docker ?? await BridgeServer._defaultDocker(eventHub?.emit);
    NotifyService? notifyService;
    PushDispatcher? pushDispatcher;
    if (notify != null) {
      notifyService = notify;
    } else {
      (notifyService, pushDispatcher) = await BridgeServer._defaultNotify(
        backend,
        eventHub,
        path: notifyCredential,
        senderFactory: notifySenderFactory,
      );
    }
    final tunnelSupervisor = tunnel;
    final tunnelSetupService =
        tunnelSetup ??
        (supervisor) => TunnelSetup(
          supervisor: supervisor,
          bridgePort: defaultPort,
          cli: TunnelCli(binary: supervisor.binary),
          credentialsDir: Directory('${homeDirectory()}/.cloudflared'),
        );
    final bridge = BridgeServer._(
      server,
      health ?? BridgeServer._scaffoldHealth,
      backend,
      fsService,
      eventHub,
      speed,
      dockerBackend,
      orbBuilder,
      orbService,
      taskService,
      tunnelSupervisor,
      tunnelSetupService,
      dockerLogKeepAlive,
      notifyService,
      pushDispatcher,
    );
    speed?.start();
    // The automated lifecycle pass (issue #101, spec §2.10): the bridge is
    // the single actor of orb automation — bridge down = no automation
    // (accepted by construction). Tests arm it explicitly; the pass keeps
    // running until the bridge stops.
    if (autoLifecyclePass) {
      orbService?.startLifecyclePass(interval: lifecyclePassInterval);
    }
    if (tunnelSupervisor != null) {
      await tunnelSupervisor.start();
    }
    server.listen(bridge._route);
    await bridge._listenOnHostIp();
    // The startup recovery (issue #102, spec §2.11): the bridge owns every
    // start. It runs after the port is bound and unawaited — a crashed
    // host's auto-wakes (each a full boot wait) must never hold up the
    // HTTP surface, and a failed one rides its own catch: the fleet shows
    // the boot-failure/broken states, the bridge stays up.
    if (orbService != null) {
      unawaited(
        orbService.recover().catchError((Object _) {
          // A failed recovery degrades to the boot-failure / broken states
          // (spec §2.11) — never a silent data loss, never a dead bridge.
        }),
      );
    }
    return bridge;
  }

  /// The per-request routing (the closure the HTTP server listens on). It
  /// reads the live [_notify] per request, so [reloadNotify] can swap it
  /// under a running bridge without rebinding the port (issue #24, the
  /// Settings save).
  Future<void> _route(HttpRequest request) async {
    await BridgeServer._handle(
      request,
      _health,
      _sessions,
      _fs,
      _events,
      _docker,
      _orb,
      _orbs,
      _tasks,
      _tunnel,
      _tunnelSetupService,
      _dockerLogKeepAlive,
      _notify,
    );
  }

  /// The host-IP listener (spec §8.5): the bridge additionally listens on
  /// the host's docker-bridge address (the `docker0` interface's address)
  /// at the same port, because the orb containers reach it as
  /// `http://host.docker.internal:<port>` and `--add-host` maps that name
  /// to this address — the loopback bind never covers it. A bind failure
  /// is degraded mode: the loopback app is unaffected, the containers just
  /// cannot reach the bridge.
  Future<void> _listenOnHostIp() async {
    final host = await hostDockerHostIp();
    if (host == loopbackHost || host == '0.0.0.0') return;
    try {
      final hostServer = await HttpServer.bind(host, _server.port);
      _hostServer = hostServer;
      hostServer.listen(_route);
    } catch (_) {
      // Degraded mode: the loopback listener serves the app as usual.
    }
  }

  /// The default push dispatch (issue #24): the Firebase service account
  /// from the app-owned config (or `GOOGLE_APPLICATION_CREDENTIALS`), the
  /// Admin-SDK sender (the raw FCM HTTP v1 API stays the fallback,
  /// selected with `OPENCODEBRIDGE_FCM_TRANSPORT=http`), and the three push
  /// events tapped off the event hub. `(null, null)` when this machine has
  /// no service account (the setup step not done), in which case the
  /// device-token endpoint reports `notify_unconfigured`.
  static Future<(NotifyService?, PushDispatcher?)> _defaultNotify(
    SessionsBackend? backend,
    EventHub? hub, {
    String? path,
    Future<FcmSender> Function(FirebaseServiceAccount)? senderFactory,
  }) async {
    final account = FirebaseServiceAccount.tryLoad(path: path);
    if (account == null) return (null, null);
    final sender = await (senderFactory ?? _defaultSenderFactory)(account);
    final service = NotifyService(sender: sender);
    Future<String> label(String id) async {
      if (backend == null) return id;
      try {
        final rows = await backend.list();
        for (final row in rows) {
          if (row.id == id) return row.title.isEmpty ? id : row.title;
        }
      } catch (_) {
        // The service is unreachable: the id is the body fallback.
      }
      return id;
    }

    // The hub fans the push events out like any other downstream; with no
    // hub there is no event stream and no push to send.
    final dispatcher = PushDispatcher(service, sessionLabel: label);
    hub?.add(dispatcher);
    return (service, dispatcher);
  }

  /// The default FCM transport (issue #24): the Admin SDK, with the raw FCM
  /// HTTP v1 API as the fallback (`OPENCODEBRIDGE_FCM_TRANSPORT=http`).
  static Future<FcmSender> _defaultSenderFactory(
    FirebaseServiceAccount account,
  ) async {
    final transport = Platform.environment['OPENCODEBRIDGE_FCM_TRANSPORT'];
    if (transport == 'http') {
      return FcmHttpV1Sender.forServiceAccount(account);
    }
    return FirebaseAdminFcmSender.forServiceAccount(account);
  }

  /// Rebuilds the push dispatch after the service-account file changed
  /// (issue #24, the Settings save): closes the live [NotifyService] and
  /// its event-hub dispatcher, then re-runs [_defaultNotify] from the file
  /// on disk ([path] or the standard resolution, like [start]'s
  /// `notifyCredential`). With a valid service account, push goes live on
  /// the running bridge (no restart); without one, the device-token
  /// endpoint reports `notify_unconfigured` again. [senderFactory]
  /// overrides the default FCM transport (tests).
  Future<void> reloadNotify({
    String? path,
    Future<FcmSender> Function(FirebaseServiceAccount)? senderFactory,
  }) async {
    final dispatcher = _pushDispatcher;
    if (dispatcher != null) {
      _events?.remove(dispatcher);
      await dispatcher.close();
    }
    await _notify?.close();
    final (service, newDispatcher) = await BridgeServer._defaultNotify(
      _sessions,
      _events,
      path: path,
      senderFactory: senderFactory,
    );
    _notify = service;
    _pushDispatcher = newDispatcher;
  }

  /// Where the bridge listens, e.g. `http://127.0.0.1:48201/`.
  Uri get baseUri =>
      Uri.parse('http://${_server.address.host}:${_server.port}/');

  /// The health endpoint, e.g. `http://127.0.0.1:48201/api/health`.
  Uri get healthUri => baseUri.replace(path: healthPath);

  Future<void> stop() async {
    _orbs?.stopLifecyclePass();
    _tasks?.close();
    await _server.close(force: true);
    await _hostServer?.close(force: true);
    await _events?.close();
    await _speed?.close();
    await _docker?.close();
    await _tunnel?.stop();
    await _notify?.close();
  }

  /// The default sessions backend: the aggregate [CompositeOpencodeService]
  /// (issue #95, spec §7.2) over the real shared opencode service and every
  /// running orb (reached through [orbList]/[orbPassword]). Returns `null`
  /// when this machine has no shared opencode service (no service
  /// descriptor — the orbs cannot replace the host), in which case the
  /// sessions endpoints report `opencode_unavailable`.
  static Future<SessionsBackend?> _defaultSessions(
    Future<List<OrbRecord>> Function() orbList,
    Future<String?> Function(String) orbPassword,
  ) async {
    try {
      final host = await OpencodeHttpService.fromHost();
      return SessionsBackend(
        service: CompositeOpencodeService(
          host: host,
          orbList: orbList,
          orbPassword: orbPassword,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// The default event hub (endpoint 14): the aggregate
  /// [CompositeOpencodeEventService] (issue #95, spec §7.3) — one
  /// self-healing upstream `GET /api/event` per live service (the host plus
  /// every running orb, reached through [orbList]/[orbPassword]) — fanned
  /// out to the app SSE connections. Returns `null` when this machine has no
  /// shared opencode service (no descriptor), in which case endpoint 14
  /// reports `opencode_unavailable`.
  static Future<EventHub?> _defaultEvents(
    Future<List<OrbRecord>> Function() orbList,
    Future<String?> Function(String) orbPassword,
  ) async {
    try {
      final host = await OpencodeHttpEventService.fromHost();
      return EventHub(
        service: CompositeOpencodeEventService(
          host: host,
          orbList: orbList,
          orbPassword: orbPassword,
        ),
      );
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

  /// The default orb image pipeline (issue #92): the embedded build context
  /// materialized into the app-owned dir at startup (create-if-missing —
  /// the on-disk copy is the single source of truth for image content), and
  /// the image builder over the host docker CLI. Returns `null` when this
  /// machine has no docker CLI (the rebuild endpoint then reports
  /// `docker_unavailable`); a materialization failure likewise degrades to
  /// `null` rather than keeping the bridge from starting.
  static Future<OrbImageBuilder?> _defaultOrb(
    void Function(String)? emit,
  ) async {
    final context = OrbBuildContext();
    try {
      await context.materialize();
    } catch (_) {
      return null;
    }
    final cli = DockerBackend.hostCli();
    if (cli == null) return null;
    return OrbImageBuilder(
      context: context,
      run: cli.run,
      spawn: cli.spawn,
      emit: emit,
    );
  }

  /// The default orb create/list service (issue #93): the host docker CLI
  /// (the creation sequence's commands) and the host git CLI (the remote
  /// probe and the identity read), the host user's home (the mounted
  /// `~/.ssh`/`~/.config/gh`, the opencode config+auth source), and the
  /// state root `~/.config/opencodebridge/orbs`. The host gh CLI, when
  /// present on the PATH, backs the PR-state read of `list(includePr: true)`
  /// (issue #96): [projectBackend] resolves the project's repo — the
  /// backend does not exist yet when this runs, so it is a getter that
  /// answers `null` until [start] has built it. Returns `null` when this
  /// machine has no docker CLI, no git CLI, or no image builder, in which
  /// case the orbs endpoints report `docker_unavailable`.
  static Future<OrbService?> _defaultOrbs(
    OrbImageBuilder? builder,
    void Function(String)? emit,
    SessionsBackend? Function()? projectBackend,
  ) async {
    final cli = DockerBackend.hostCli();
    final gitBinary = findHostGit();
    if (cli == null || gitBinary == null || builder == null) return null;
    final ghBinary = findHostGh();
    final home = homeDirectory();
    final git = hostGitRunner(gitBinary);
    // The session-move dependencies (issue #97): the host opencode CLI, the
    // host sessions service (the shared-service descriptor), and the
    // project-checkout lookup. Each degrades to `null` — the lifecycle
    // endpoints then answer 503 `opencode_unavailable` — so a host missing
    // one of them still gets the orb list/create/delete.
    final opencodeBinary = findHostOpencode();
    OpencodeService? hostService;
    try {
      hostService = await OpencodeHttpService.fromHost();
    } catch (_) {
      // No shared-service descriptor on this host: the host sessions
      // service is unreachable (the stop and the move-to-orb refuse with
      // 503).
    }
    return OrbService(
      imageBuilder: builder,
      run: cli.run,
      spawn: cli.spawn,
      git: git,
      home: home,
      stateRoot: Directory('$home/.config/opencodebridge/orbs'),
      bridgePort: defaultPort,
      emit: emit,
      opencodeCli: opencodeBinary == null
          ? null
          : hostOpencodeRunner(opencodeBinary),
      hostSessions: hostService,
      checkoutFor: projectBackend == null
          ? null
          : (projectId) async {
              final backend = projectBackend();
              if (backend == null) return null;
              try {
                final projects = await backend.projects();
                for (final candidate in projects) {
                  if (candidate.id == projectId) {
                    return candidate.canonical;
                  }
                }
              } catch (_) {
                // The opencode service is down, or the project list cannot
                // be read: no checkout (the stop and the move's create
                // refuse with 503).
              }
              return null;
            },
      gh: ghBinary == null ? null : hostGhRunner(ghBinary),
      repoFor: ghBinary == null || projectBackend == null
          ? null
          : (projectId) async {
              final backend = projectBackend();
              if (backend == null) return null;
              OpencodeProject? project;
              try {
                final projects = await backend.projects();
                for (final candidate in projects) {
                  if (candidate.id == projectId) {
                    project = candidate;
                    break;
                  }
                }
              } catch (_) {
                // The opencode service is down, or the project list cannot
                // be read: no PR state (it degrades to a missing badge).
                return null;
              }
              if (project == null) return null;
              try {
                final result = await git([
                  'remote',
                  'get-url',
                  'origin',
                ], workingDirectory: project.canonical);
                if (result.exitCode != 0) return null;
                return OrbService.githubRepo(result.stdout.trim());
              } catch (_) {
                // The checkout is gone from the host: no PR state.
                return null;
              }
            },
    );
  }

  /// The default tunnel supervisor (issue #22, ADR-0002): the app-managed
  /// pinned cloudflared binary, the app-owned config
  /// `~/.config/opencodebridge/cloudflared.yml`, and the precondition
  /// checker against the bridge's fixed port. It is not started here:
  /// [BridgeServer.start] starts it, after the port is bound, so a second
  /// server-mode instance (detected by the port conflict) never spawns a
  /// second tunnel child.
  static TunnelSupervisor defaultTunnel() {
    final binary = CloudflaredBinary();
    final configFile = CloudflaredConfigFile();
    return TunnelSupervisor(
      binary: binary,
      configFile: configFile,
      preconditions: TunnelPreconditionChecker(
        binary: binary,
        configFile: configFile,
        bridgePort: defaultPort,
      ),
    );
  }

  static HealthReport _scaffoldHealth() => const HealthReport(
    bridge: ComponentStatus.ok,
    opencode: ComponentStatus.notConfigured,
    docker: ComponentStatus.notConfigured,
  );

  /// The tunnel status (issue #22): the child's liveness plus its registered
  /// edge connections. A bridge without a tunnel supervisor (one that does
  /// not run a tunnel) answers `not_configured`.
  static Future<void> _tunnelStatus(
    HttpRequest request,
    TunnelSupervisor? tunnel,
  ) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.statusCode = HttpStatus.ok;
    final report = tunnel == null
        ? const TunnelReport(
            status: TunnelStatus.notConfigured,
            running: false,
            registeredConnections: 0,
          )
        : await tunnel.report();
    response.write(jsonEncode(report.toJson()));
    await response.close();
  }

  /// The tunnel recheck and manual start (issue #22): each runs its half of
  /// the supervisor, then answers with the fresh report. A bridge without a
  /// tunnel supervisor answers 404.
  static Future<void> _tunnelAction(
    HttpRequest request,
    TunnelSupervisor? tunnel,
    Future<void> Function(TunnelSupervisor) action,
  ) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (tunnel == null) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'tunnel_not_configured'}));
      await response.close();
      return;
    }
    await action(tunnel);
    response.statusCode = HttpStatus.ok;
    final report = await tunnel.report();
    response.write(jsonEncode(report.toJson()));
    await response.close();
  }

  /// The assisted tunnel setup (issue #34, ADR-0003): the bridge, the sole
  /// file owner, writes the app-owned files from the pasted credentials and
  /// the chosen hostname, then re-runs the precondition pass and, when
  /// every step is met, (re)starts the tunnel child — answering with the
  /// fresh report. An invalid payload answers 400 with the explanation;
  /// unwriteable files answer 500; a bridge without a tunnel supervisor
  /// answers 404.
  static Future<void> _tunnelSetup(
    HttpRequest request,
    TunnelSupervisor? tunnel,
    TunnelSetup Function(TunnelSupervisor) tunnelSetup,
  ) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (tunnel == null) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'tunnel_not_configured'}));
      await response.close();
      return;
    }
    final body = await utf8.decodeStream(request);
    try {
      await tunnelSetup(tunnel).apply(body);
    } on TunnelSetupError catch (e) {
      response.statusCode = HttpStatus.badRequest;
      response.write(
        jsonEncode({'error': 'invalid_body', 'details': e.message}),
      );
      await response.close();
      return;
    } on TunnelSetupCreateError catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(
        jsonEncode({'error': 'tunnel_create_failed', 'details': e.message}),
      );
      await response.close();
      return;
    } on TunnelSetupWriteError catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(
        jsonEncode({
          'error': 'tunnel_files_not_writable',
          'details': e.message,
        }),
      );
      await response.close();
      return;
    }
    response.statusCode = HttpStatus.ok;
    final report = await tunnel.report();
    response.write(jsonEncode(report.toJson()));
    await response.close();
  }

  /// The app-driven Cloudflare login (issue #37, ADR-0003): the bridge runs
  /// the app-managed `cloudflared tunnel login`, which opens the default
  /// browser on Cloudflare's consent page and stores the session in the
  /// user's own `~/.cloudflared/` — the app never sees a token. Answers
  /// `{'status': 'ok'}`; a failed or timed-out login answers 500 with the
  /// explanation; a bridge without a tunnel supervisor answers 404.
  static Future<void> _tunnelLogin(
    HttpRequest request,
    TunnelSupervisor? tunnel,
    TunnelSetup Function(TunnelSupervisor) tunnelSetup,
  ) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (tunnel == null) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'tunnel_not_configured'}));
      await response.close();
      return;
    }
    try {
      final run = await tunnelSetup(tunnel).cli.login();
      if (!run.success) {
        throw CloudflaredCliError(
          'the Cloudflare login failed: ${run.firstOutputLine}',
        );
      }
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode({'status': 'ok'}));
      await response.close();
    } on CloudflaredCliError catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(
        jsonEncode({'error': 'tunnel_login_failed', 'details': e.message}),
      );
      await response.close();
    }
  }

  static Future<void> _handle(
    HttpRequest request,
    HealthReport Function() report,
    SessionsBackend? sessions,
    FsService fs,
    EventHub? events,
    DockerBackend? docker,
    OrbImageBuilder? orb,
    OrbService? orbs,
    OrbTaskService? tasks,
    TunnelSupervisor? tunnel,
    TunnelSetup Function(TunnelSupervisor) tunnelSetup,
    Duration dockerLogKeepAlive,
    NotifyService? notify,
  ) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.eventsPath) {
        await BridgeServer._handleEvents(request, events);
        return;
      }
      // The push registration (issue #24), checked before the session
      // matchers (a bare list path would otherwise read as a session id
      // to them).
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.deviceTokenPath) {
        await BridgeServer._deviceToken(request, notify);
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
      // The "New project" file-picker's fs endpoints (issue #54), checked
      // before the session matchers (a bare path would otherwise read as a
      // session id to them).
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.fsDrivesPath) {
        await BridgeServer._fsDrives(request, fs);
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.fsDirectoriesPath) {
        await BridgeServer._fsDirectories(request, fs);
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.fsDirectoriesPath) {
        await BridgeServer._fsCreateDirectory(request, fs);
        return;
      }
      // The docker endpoints (issue #21), checked before the session matchers
      // (a bare list path would otherwise read as a session id to them).
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.dockerContainersPath) {
        await BridgeServer._listDockerContainers(request, docker);
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.dockerComposePath) {
        await BridgeServer._listComposeProjects(request, sessions, docker);
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
      if (request.method == 'POST') {
        final dir = BridgeServer._composeActionIn(request.uri.path);
        if (dir != null) {
          await BridgeServer._handleComposeAction(request, dir, docker);
          return;
        }
      }
      // The orb shared-base-image rebuild (issue #92), checked before the
      // session matchers (a bare path would otherwise read as a session id
      // to them).
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.orbImageRebuildPath) {
        await BridgeServer._handleOrbImageRebuild(request, orb);
        return;
      }
      // The orbs (issue #93): `POST` creates, `GET` composes the list,
      // `DELETE /api/orbs/<id>` is the protected deletion (issue #98 — the
      // guard, the optional `force` body, the orphan cleanup for orphan
      // records). Checked before the session matchers (a bare list path
      // would otherwise read as a session id to them).
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.orbsPath) {
        await BridgeServer._handleOrbCreate(request, sessions, orbs);
        return;
      }
      // The spawn surface (issue #99, spec §8.2/§8.3): the global
      // `orb_spawn`/`orb_wait` tools' endpoints, checked before the session
      // matchers like the other bare paths.
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.orbSpawnPath) {
        await BridgeServer._handleOrbSpawn(request, tasks);
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.orbWaitPath) {
        await BridgeServer._handleOrbWait(request, tasks);
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.orbsPath) {
        await BridgeServer._handleOrbList(request, orbs);
        return;
      }
      if (request.method == 'DELETE') {
        final orbId = BridgeServer._orbIdIn(request.uri.path);
        if (orbId != null) {
          await BridgeServer._handleOrbDelete(request, orbId, orbs);
          return;
        }
      }
      // The orb lifecycle actions (issue #97, #98, #102): `POST
      // /api/orbs/<id>/stop` (the single trigger for every orb death path —
      // the sessions moved to the host, the container stopped last, the
      // `ocb.stopped` marker set), `POST /api/orbs/<id>/wake` (the full
      // start path re-run, the marker off), `POST /api/orbs/<id>/sessions`
      // (a new session in the orb workspace), `POST /api/orbs/<id>/update`
      // (the per-orb image update, spec §2.8), `POST /api/orbs/<id>/export`
      // (the `docker cp` tar.gz export, spec §3.4), `POST
      // /api/orbs/<id>/fresh-state` (the broken orb's wake over a recreated
      // state dir, issue #102). Checked before the
      // session matchers (a bare path would otherwise read as a session id
      // to them).
      if (request.method == 'POST') {
        final orbAction = BridgeServer._orbActionIn(request.uri.path);
        if (orbAction != null) {
          await BridgeServer._handleOrbAction(
            request,
            orbAction.$1,
            orbAction.$2,
            orbs,
          );
          return;
        }
      }
      // The tunnel endpoints (issue #22), checked before the session matchers
      // (a bare list path would otherwise read as a session id to them).
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.tunnelPath) {
        await BridgeServer._tunnelStatus(request, tunnel);
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.tunnelCheckPath) {
        await BridgeServer._tunnelAction(
          request,
          tunnel,
          (supervisor) => supervisor.check(),
        );
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.tunnelStartPath) {
        await BridgeServer._tunnelAction(
          request,
          tunnel,
          (supervisor) => supervisor.restart(),
        );
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.tunnelSetupPath) {
        await BridgeServer._tunnelSetup(request, tunnel, tunnelSetup);
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.tunnelLoginPath) {
        await BridgeServer._tunnelLogin(request, tunnel, tunnelSetup);
        return;
      }
      // The structured view's `/` command menu, global commands (issue
      // #46), checked before the session matchers (a bare list path would
      // otherwise read as a session id to them).
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.usagePath) {
        await BridgeServer._commandPayload(request, sessions, (s) => s.usage());
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.mcpsPath) {
        await BridgeServer._commandPayload(request, sessions, (s) => s.mcps());
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.integrationsPath) {
        await BridgeServer._commandPayload(
          request,
          sessions,
          (s) => s.integrations(),
        );
        return;
      }
      if (request.method == 'POST') {
        final connect = BridgeServer._integrationConnectIn(request.uri.path);
        if (connect != null) {
          await BridgeServer._commandConnect(request, connect, sessions);
          return;
        }
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.statusPath) {
        await BridgeServer._commandPayload(
          request,
          sessions,
          (s) => s.status(),
        );
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.pairPath) {
        await BridgeServer._commandPayload(request, sessions, (s) => s.pair());
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.reloadPath) {
        await BridgeServer._commandReload(request, sessions);
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.worktreesPath) {
        await BridgeServer._commandWorktrees(request, sessions);
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == BridgeServer.pluginsPath) {
        await BridgeServer._commandPayload(
          request,
          sessions,
          (s) => s.plugins(),
        );
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == BridgeServer.sessionsPath) {
        await BridgeServer._createSession(request, sessions);
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
      // The structured-view question forms (issue #50): the agent's
      // `question` tool, surfaced and answered from the structured view.
      // Checked before the `/` command menu's fallthrough so the
      // subpath wins.
      if (request.method == 'GET') {
        final id = BridgeServer._questionsSessionIn(request.uri.path);
        if (id != null) {
          await BridgeServer._questions(request, id, sessions);
          return;
        }
      }
      if (request.method == 'POST') {
        final answer = BridgeServer._questionAnswerIn(request.uri.path);
        if (answer != null) {
          await BridgeServer._questionAnswer(
            request,
            answer.$1,
            answer.$2,
            sessions,
          );
          return;
        }
      }
      if (request.method == 'DELETE') {
        final dismiss = BridgeServer._questionDismissIn(request.uri.path);
        if (dismiss != null) {
          await BridgeServer._questionDismiss(
            request,
            dismiss.$1,
            dismiss.$2,
            sessions,
          );
          return;
        }
      }
      if (request.method == 'DELETE') {
        final id = BridgeServer._sessionIdIn(request.uri.path);
        if (id != null) {
          await BridgeServer._deleteSession(request, id, sessions, events);
          return;
        }
      }
      // The host→orb session move (issue #97): one action, entirely through
      // the bridge — the target orb is woken (or created) before the move.
      // Checked before the command-menu fallthrough (its subpath would
      // otherwise read as a `/` command to it).
      if (request.method == 'POST') {
        final moveId = BridgeServer._moveToOrbIn(request.uri.path);
        if (moveId != null) {
          await BridgeServer._handleMoveToOrb(request, moveId, sessions, orbs);
          return;
        }
      }
      // The structured view's `/` command menu, per-session commands (issue
      // #46), checked after the endpoint 5–9 matchers (which own
      // messages/permissions) and the single-segment detail/delete matcher,
      // so their subpaths win.
      final command = BridgeServer._sessionCommandIn(request.uri.path);
      if (command != null) {
        await BridgeServer._handleCommand(
          request,
          command.$1,
          command.$2,
          sessions,
        );
        return;
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

  /// The push registration (issue #24): the app's FCM device token plus the
  /// events its Settings toggles have enabled,
  /// `{"token": "…", "events": ["permissionAsked", …]}`. Anything else is a
  /// 400; a bridge without a notify service (the setup step not done) is a
  /// 503.
  static Future<void> _deviceToken(
    HttpRequest request,
    NotifyService? notify,
  ) async {
    final response = request.response;
    if (notify == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.write(jsonEncode({'error': 'notify_unconfigured'}));
      await response.close();
      return;
    }
    Object? token;
    Set<NotifyKind>? events;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        token = decoded['token'];
        events = NotifyKind.parseEvents(decoded['events']);
      }
    } catch (_) {
      // A malformed body (or a torn connection) is a 400.
    }
    if (token is! String || token.isEmpty || events == null) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    notify.registerDevice(token, events);
    response.statusCode = HttpStatus.ok;
    response.write(jsonEncode({}));
    await response.close();
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

  /// The single session id in a questions path, or `null` when [path] is not
  /// `api/sessions/{id}/questions` (issue #50).
  static String? _questionsSessionIn(String path) {
    const prefix = '/api/sessions/';
    const suffix = '/questions';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final id = path.substring(prefix.length, path.length - suffix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return Uri.decodeComponent(id);
  }

  /// The (session id, question id) in a question-answer path, or `null` when
  /// [path] is not `api/sessions/{id}/questions/{questionID}/answer`
  /// (issue #50).
  static (String, String)? _questionAnswerIn(String path) {
    const prefix = '/api/sessions/';
    const mid = '/questions/';
    const suffix = '/answer';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final rest = path.substring(prefix.length, path.length - suffix.length);
    final i = rest.indexOf(mid);
    if (i < 0) return null;
    final id = rest.substring(0, i);
    final questionID = rest.substring(i + mid.length);
    if (id.isEmpty ||
        id.contains('/') ||
        questionID.isEmpty ||
        questionID.contains('/')) {
      return null;
    }
    return (Uri.decodeComponent(id), Uri.decodeComponent(questionID));
  }

  /// The (session id, question id) in a question-dismiss path, or `null` when
  /// [path] is not `api/sessions/{id}/questions/{questionID}` (issue #50;
  /// exactly two segments, so the answer subpath falls through).
  static (String, String)? _questionDismissIn(String path) {
    const prefix = '/api/sessions/';
    const mid = '/questions/';
    if (!path.startsWith(prefix)) return null;
    final rest = path.substring(prefix.length);
    final i = rest.indexOf(mid);
    if (i < 0) return null;
    final id = rest.substring(0, i);
    final questionID = rest.substring(i + mid.length);
    if (id.isEmpty ||
        id.contains('/') ||
        questionID.isEmpty ||
        questionID.contains('/')) {
      return null;
    }
    return (Uri.decodeComponent(id), Uri.decodeComponent(questionID));
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
    List<Map<String, Object?>>? files;
    List<Map<String, Object?>>? skills;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        text = decoded['text'] as String?;
        files = BridgeServer._attachmentList(decoded['files']);
        skills = BridgeServer._attachmentList(decoded['skills']);
      }
    } catch (_) {
      text = null; // A non-JSON body or a malformed attachment array is an
      // invalid body.
    }
    if (text == null || text.trim().isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    try {
      await sessions.prompt(id, text, files: files, skills: skills);
      response.statusCode = HttpStatus.accepted;
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// A prompt attachment array (`files` / `skills`), or `null` when the
  /// field is absent: a JSON array of objects, forwarded to the service
  /// as-is. Anything else (a scalar, a non-object entry) throws into the
  /// caller's invalid-body path.
  static List<Map<String, Object?>>? _attachmentList(Object? value) {
    final list = value as List?;
    if (list == null) return null;
    return [for (final item in list) item as Map<String, Object?>];
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

  /// The session's pending question forms (issue #50): the agent's `question`
  /// tool, flattened to the [QuestionForm] contract (no `q0`/`q1` keys).
  /// Unknown session is a 404; a service failure is a 502.
  static Future<void> _questions(
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
      final forms = await sessions.pendingQuestions(id);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode([for (final f in forms) f.toJson()]));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// Submit the answers to a pending question form (issue #50). The body is
  /// `{"answers": [[...], [...]]}` — one entry per question, in the form's
  /// field order — or a bare `[[...], [...]]`; anything else is a 400. An
  /// unknown session or form is a 404; a service failure is a 502.
  static Future<void> _questionAnswer(
    HttpRequest request,
    String id,
    String questionID,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    final answers = await BridgeServer._answersBody(request);
    if (answers == null) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    try {
      await sessions.answerQuestion(id, questionID, answers);
      response.statusCode = HttpStatus.noContent;
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// Dismiss a pending question form (issue #50): the agent continues without
  /// an answer. An unknown session or form is a 404; a service failure is a
  /// 502.
  static Future<void> _questionDismiss(
    HttpRequest request,
    String id,
    String questionID,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    try {
      await sessions.dismissQuestion(id, questionID);
      response.statusCode = HttpStatus.noContent;
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// The question-answer body, parsed leniently to one entry per question
  /// (in the form's field order), each a list of selected option labels (or
  /// the typed text). Accepts `{"answers": [[...], ...]}` or a bare
  /// `[[...], ...]`, and a bare string entry (a free-text answer); `null`
  /// when the body is none of those shapes.
  static Future<List<List<String>>?> _answersBody(HttpRequest request) async {
    Object? decoded;
    try {
      decoded = jsonDecode(await utf8.decodeStream(request));
    } catch (_) {
      return null;
    }
    final value = decoded is Map<String, Object?>
        ? decoded['answers']
        : decoded;
    final list = value is List ? value : null;
    if (list == null) return null;
    final answers = <List<String>>[];
    for (final entry in list) {
      if (entry is String) {
        answers.add([entry]);
        continue;
      }
      if (entry is List) {
        final labels = <String>[];
        for (final item in entry) {
          if (item is! String) return null;
          labels.add(item);
        }
        answers.add(labels);
        continue;
      }
      return null;
    }
    return answers;
  }

  /// The `/` command menu's global commands (issue #46): a service endpoint
  /// that returns its decoded JSON as a string, which the bridge writes as a
  /// JSON string (the client decodes it back to the string and displays or
  /// re-parses it). Unknown session is n/a; a service failure is a 502.
  static Future<void> _commandPayload(
    HttpRequest request,
    SessionsBackend? sessions,
    Future<String> Function(SessionsBackend) call,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    try {
      final data = await call(sessions);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode(data));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// The `/` command menu's `reload` (issue #46): the service's
  /// `POST /api/location/reload`.
  static Future<void> _commandReload(
    HttpRequest request,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    try {
      await sessions.reload();
      response.statusCode = HttpStatus.noContent;
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// The (integration id) in a connect path, or `null` when [path] is not
  /// `api/integrations/{id}/connect` (the `/` command menu's `/connect`).
  static String? _integrationConnectIn(String path) {
    const prefix = '/api/integrations/';
    const suffix = '/connect';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final id = path.substring(prefix.length, path.length - suffix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return Uri.decodeComponent(id);
  }

  /// The `/` command menu's `/connect` (issue #46): start an integration's
  /// OAuth flow. The body is `{"methodID": "…"}` (the integration's method,
  /// from the service's integration list); anything else is a 400. The
  /// response is the service's decoded JSON (the flow's URL, when the
  /// service hands one out).
  static Future<void> _commandConnect(
    HttpRequest request,
    String integrationId,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    final methodId = BridgeServer._stringField(
      await BridgeServer._jsonBody(request),
      'methodID',
    );
    if (methodId == null || methodId.isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    try {
      final data = await sessions.connectIntegration(integrationId, methodId);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode(data));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// The `/` command menu's `/worktrees` (issue #46): the open session's
  /// project's worktrees; the service resolves the project from the
  /// `sessionID` query. A missing id is a 400; a service failure is a 502.
  static Future<void> _commandWorktrees(
    HttpRequest request,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    final sessionId = request.uri.queryParameters['sessionID'];
    if (sessionId == null || sessionId.isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_request'}));
      await response.close();
      return;
    }
    try {
      final data = await sessions.worktrees(sessionId);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode(data));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// The (session id, subpath) in a command-menu path (issue #46), or
  /// `null` when [path] is not `api/sessions/{id}/…` with a non-empty
  /// subpath (so it falls through to the 404).
  static (String, String)? _sessionCommandIn(String path) {
    const prefix = '/api/sessions/';
    if (!path.startsWith(prefix)) return null;
    final rest = path.substring(prefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final id = rest.substring(0, slash);
    final sub = rest.substring(slash + 1);
    if (sub.isEmpty || sub.contains('//')) return null;
    return (Uri.decodeComponent(id), sub);
  }

  /// The structured view's `/` command menu, per-session commands (issue
  /// #46): thin pass-throughs of the shared-service command endpoints. The
  /// service is the single source of truth, so the effect is reflected live
  /// in any attached TUI. Unknown session is a 404; a service failure is a
  /// 502 (the [_serviceError] mapping).
  static Future<void> _handleCommand(
    HttpRequest request,
    String id,
    String sub,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    final method = request.method;
    final parts = sub.split('/');
    Map<String, Object?>? body;
    if (method != 'GET') {
      body = await BridgeServer._jsonBody(request);
    }
    try {
      switch ((method, parts)) {
        case ('GET', ['commands']):
          final commands = await sessions.listCommands();
          await BridgeServer._jsonOk(
            response,
            jsonEncode([for (final c in commands) c.toJson()]),
          );
          return;
        case ('POST', ['commands', final name]):
          await sessions.runCommand(
            id,
            name,
            BridgeServer._stringField(body, 'text') ?? '',
          );
          await BridgeServer._jsonAccepted(response);
          return;
        case ('GET', ['models']):
          final models = await sessions.listModels();
          await BridgeServer._jsonOk(
            response,
            jsonEncode([for (final m in models) m.toJson()]),
          );
          return;
        case ('GET', ['model']):
          final model = await sessions.currentModel(id);
          await BridgeServer._jsonOk(
            response,
            jsonEncode({'model': model?.toJson()}),
          );
          return;
        case ('POST', ['models']):
          final model = BridgeServer._modelRef(body);
          if (model == null) {
            await BridgeServer._invalidBody(response);
            return;
          }
          await sessions.setModel(id, model);
          await BridgeServer._noContent(response);
          return;
        case ('GET', ['agents']):
          final agents = await sessions.listAgents();
          await BridgeServer._jsonOk(
            response,
            jsonEncode([for (final a in agents) a.toJson()]),
          );
          return;
        case ('POST', ['agents']):
          final agent = BridgeServer._stringField(body, 'agent');
          if (agent == null || agent.isEmpty) {
            await BridgeServer._invalidBody(response);
            return;
          }
          await sessions.setAgent(id, agent);
          await BridgeServer._noContent(response);
          return;
        case ('GET', ['skills']):
          final skills = await sessions.listSkills();
          await BridgeServer._jsonOk(
            response,
            jsonEncode([for (final s in skills) s.toJson()]),
          );
          return;
        case ('GET', ['files']):
          // The `@` mention menu's file rows (issue #58): the service's
          // file search re-queried per typed token. The token is the
          // `query` param (the TUI re-queries on every keystroke).
          final query = request.uri.queryParameters['query'] ?? '';
          final files = await sessions.findFiles(id, query);
          await BridgeServer._jsonOk(response, jsonEncode(files));
          return;
        case ('POST', ['skills', final skillId]):
          await sessions.activateSkill(id, skillId);
          await BridgeServer._noContent(response);
          return;
        case ('POST', ['compact']):
          await sessions.compact(id);
          await BridgeServer._noContent(response);
          return;
        case ('POST', ['undo']):
          await sessions.undo(id);
          await BridgeServer._noContent(response);
          return;
        case ('POST', ['redo']):
          await sessions.redo(id);
          await BridgeServer._noContent(response);
          return;
        case ('POST', ['fork']):
          final forked = await sessions.fork(id);
          await BridgeServer._jsonOk(response, jsonEncode({'id': forked}));
          return;
        case ('POST', ['rename']):
          final title = BridgeServer._stringField(body, 'title');
          if (title == null || title.trim().isEmpty) {
            await BridgeServer._invalidBody(response);
            return;
          }
          await sessions.rename(id, title);
          await BridgeServer._noContent(response);
          return;
        case ('GET', ['export']):
          final data = await sessions.exportSession(id);
          await BridgeServer._jsonOk(response, jsonEncode(data));
          return;
        case ('POST', ['move']):
          final directory = BridgeServer._stringField(body, 'directory');
          if (directory == null || directory.trim().isEmpty) {
            await BridgeServer._invalidBody(response);
            return;
          }
          await sessions.move(id, directory);
          await BridgeServer._noContent(response);
          return;
        case ('POST', ['btw']):
          final prompt = BridgeServer._stringField(body, 'prompt');
          if (prompt == null || prompt.trim().isEmpty) {
            await BridgeServer._invalidBody(response);
            return;
          }
          final answer = await sessions.generate(id, prompt);
          await BridgeServer._jsonOk(response, jsonEncode({'text': answer}));
          return;
        case ('GET', ['diff']):
          final data = await sessions.diff(id);
          await BridgeServer._jsonOk(response, jsonEncode(data));
          return;
        case ('GET', ['stats']):
          final data = await sessions.stats(id);
          await BridgeServer._jsonOk(response, jsonEncode(data));
          return;
        default:
          await BridgeServer._notFound(response);
      }
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
      await response.close();
    }
  }

  /// The request's JSON object body, or `null` when it is absent or not a
  /// JSON object (a body-less command is fine on the body-less endpoints).
  static Future<Map<String, Object?>?> _jsonBody(HttpRequest request) async {
    try {
      final raw = await utf8.decodeStream(request);
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null; // A non-JSON body is not a body.
    }
  }

  /// A string field of a command body, or `null` when absent or not a string.
  static String? _stringField(Map<String, Object?>? body, String key) {
    final value = body?[key];
    return value is String ? value : null;
  }

  /// The `model` field of a set-model body as the service's `Model.Ref`, or
  /// `null` when the body carries none.
  static ModelRef? _modelRef(Map<String, Object?>? body) {
    final model = body?['model'];
    return model is Map<String, Object?> ? ModelRef.fromJson(model) : null;
  }

  static Future<void> _jsonOk(HttpResponse response, String json) async {
    response.statusCode = HttpStatus.ok;
    response.write(json);
    await response.close();
  }

  static Future<void> _jsonAccepted(HttpResponse response) async {
    response.statusCode = HttpStatus.accepted;
    await response.close();
  }

  static Future<void> _noContent(HttpResponse response) async {
    response.statusCode = HttpStatus.noContent;
    await response.close();
  }

  static Future<void> _invalidBody(HttpResponse response) async {
    response.statusCode = HttpStatus.badRequest;
    response.write(jsonEncode({'error': 'invalid_body'}));
    await response.close();
  }

  static Future<void> _notFound(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;
    response.write(jsonEncode({'error': 'not_found'}));
    await response.close();
  }

  /// The "New project" file-picker's drives (issue #54): the host's real
  /// filesystem mounts, a JSON list of absolute paths, sorted.
  static Future<void> _fsDrives(HttpRequest request, FsService fs) async {
    final response = request.response;
    try {
      final drives = await fs.drives();
      await BridgeServer._jsonOk(response, jsonEncode(drives));
    } on FsError catch (e) {
      BridgeServer._fsError(response, e);
    }
  }

  /// The "New project" file-picker's directory listing (issue #54): the
  /// subdirectories of the `path` query parameter (directories only), a JSON
  /// list of absolute paths, sorted. A missing or non-absolute `path` is a
  /// 400 `invalid_path`.
  static Future<void> _fsDirectories(HttpRequest request, FsService fs) async {
    final response = request.response;
    final path = request.uri.queryParameters['path'];
    if (path == null || !isAbsolutePath(path)) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_path'}));
      await response.close();
      return;
    }
    try {
      final subdirectories = await fs.subdirectories(path);
      await BridgeServer._jsonOk(response, jsonEncode(subdirectories));
    } on FsError catch (e) {
      BridgeServer._fsError(response, e);
    }
  }

  /// The "New project" file-picker's directory creation (issue #54's
  /// "New folder"): the body's `path` is created as an empty directory and
  /// the response is a 201. A missing or non-absolute `path` is a 400
  /// `invalid_path`; a missing parent is a 404 `not_found`; an existing
  /// entry is a 409 `already_exists`.
  static Future<void> _fsCreateDirectory(
    HttpRequest request,
    FsService fs,
  ) async {
    final response = request.response;
    String? path;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final p = decoded['path'];
        path = p is String && isAbsolutePath(p) ? p : null;
      }
    } catch (_) {
      path = null; // A non-JSON body is an invalid path.
    }
    if (path == null) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_path'}));
      await response.close();
      return;
    }
    try {
      await fs.createDirectory(path);
      response.statusCode = HttpStatus.created;
      await response.close();
    } on FsError catch (e) {
      BridgeServer._fsError(response, e);
    }
  }

  /// Maps an [FsError] to the bridge contract: [FsErrorKind.badPath] is a
  /// 400 `invalid_path`, [FsErrorKind.notFound] is a 404 `not_found`,
  /// [FsErrorKind.permissionDenied] is a 403 `permission_denied`, and
  /// [FsErrorKind.alreadyExists] is a 409 `already_exists`.
  static void _fsError(HttpResponse response, FsError e) {
    final (status, code) = switch (e.kind) {
      FsErrorKind.badPath => (HttpStatus.badRequest, 'invalid_path'),
      FsErrorKind.notFound => (HttpStatus.notFound, 'not_found'),
      FsErrorKind.permissionDenied => (
        HttpStatus.forbidden,
        'permission_denied',
      ),
      FsErrorKind.alreadyExists => (HttpStatus.conflict, 'already_exists'),
    };
    response.statusCode = status;
    response.write(jsonEncode({'error': code}));
    response.close();
  }

  /// Endpoint 2 (spec section 5, fill-in †): create a session on the shared
  /// service, returning the session. The body is `{"project": "<id>"}` or
  /// `{"directory": "<absolute path>"}` (issue #54's "New project": the
  /// directory is the working directory as-is, and the service auto-creates
  /// a project for one it has never seen). The app opens the session's
  /// structured view. A body with neither or both is a 400; a directory
  /// missing on this host is a 404; a service failure is a 502.
  static Future<void> _createSession(
    HttpRequest request,
    SessionsBackend? sessions,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    String? project;
    String? directory;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final p = decoded['project'];
        project = p is String && p.trim().isNotEmpty ? p : null;
        final d = decoded['directory'];
        directory = d is String && isAbsolutePath(d) ? d : null;
      }
    } catch (_) {
      project = null; // A non-JSON body is an invalid body.
      directory = null;
    }
    final byProject = project != null;
    final byDirectory = directory != null;
    if (byProject == byDirectory) {
      // Neither (the legacy absent case) or both at once: an invalid body.
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    try {
      final row = byDirectory
          ? await sessions.createInDirectory(directory)
          : await sessions.create(project!);
      response.statusCode = HttpStatus.created;
      response.write(jsonEncode(row));
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

  static Future<void> _deleteSession(
    HttpRequest request,
    String id,
    SessionsBackend? sessions,
    EventHub? events,
  ) async {
    final response = request.response;
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    try {
      // The service deletion and the persistence-record removal in one
      // action (spec section 5, endpoint 4).
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

  /// The compose project list (issue #21 follow-on): the docker-compose files
  /// found in the repos opencode lists (the project list's canonical
  /// directories), each with its creatable services and their live state.
  /// Without docker the endpoint reports `docker_unavailable`; without an
  /// opencode service (no projects to scan) it is an empty list. A compose
  /// file that cannot be read is a 502.
  static Future<void> _listComposeProjects(
    HttpRequest request,
    SessionsBackend? sessions,
    DockerBackend? docker,
  ) async {
    final response = request.response;
    if (docker == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    try {
      var projects = const <ComposeProject>[];
      if (sessions != null) {
        final projectList = await sessions.projects();
        final dirs = [for (final p in projectList) p.canonical];
        projects = await docker.composeProjects(dirs);
      }
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode([for (final p in projects) p.toJson()]));
    } on ComposeNotFoundError {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    } on OpencodeServiceError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'opencode_unreachable'}));
    }
    await response.close();
  }

  /// The compose project action (issue #21 follow-on): the body is
  /// `{"action": "up"|"stop", "service": "<name>"?}`; a `service` targets one
  /// service, its absence the whole project. Anything but up/stop is a 400;
  /// a directory with no compose file is a 404; a docker failure is a 502.
  static Future<void> _handleComposeAction(
    HttpRequest request,
    String dir,
    DockerBackend? docker,
  ) async {
    final response = request.response;
    if (docker == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    ComposeAction? action;
    String? service;
    try {
      final raw = await utf8.decodeStream(request);
      final decoded = jsonDecode(raw);
      final map = decoded is Map<String, Object?>
          ? decoded
          : const <String, Object?>{};
      action = ComposeAction.fromWire(
        map['action'],
      ); // throws on an unknown value
      final serviceValue = map['service'];
      service = serviceValue is String && serviceValue.isNotEmpty
          ? serviceValue
          : null;
    } catch (_) {
      action = null; // A non-JSON body or unknown action is invalid.
    }
    if (action == null) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_body'}));
      await response.close();
      return;
    }
    final services = service == null ? null : [service];
    try {
      switch (action) {
        case ComposeAction.up:
          await docker.composeUp(dir, services: services);
        case ComposeAction.stop:
          await docker.composeStop(dir, services: services);
      }
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode({'path': dir, 'service': ?service}));
    } on ComposeNotFoundError {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    }
    await response.close();
  }

  /// The explicit shared-base-image rebuild (spec §5.3, §9.5; issue #92):
  /// always rebuilds the image for the expected tag, the build logs streaming
  /// as events. No docker CLI on the host is a 503 `docker_unavailable`; a
  /// daemon failure or a failed build is a 502 (`docker_unreachable` /
  /// `docker_build_failed`); success is a 200 with the tag.
  static Future<void> _handleOrbImageRebuild(
    HttpRequest request,
    OrbImageBuilder? orb,
  ) async {
    final response = request.response;
    if (orb == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    try {
      final tag = await orb.rebuild();
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode({'tag': tag}));
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    } on OrbImageBuildError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_build_failed'}));
    }
    await response.close();
  }

  /// The orb create (issue #93, spec §2.3): the body's project id resolves
  /// to the project's canonical checkout (the `.env*` source and the git
  /// remote probe), then the full bridge-owned creation sequence runs,
  /// waiting for the boot. The service password is derived and verified
  /// internally (ADR-0001 — it never rides the bridge); the 201 record
  /// carries the ephemeral-URL descriptor.
  static Future<void> _handleOrbCreate(
    HttpRequest request,
    SessionsBackend? sessions,
    OrbService? orbs,
  ) async {
    final response = request.response;
    if (orbs == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    final body = await BridgeServer._jsonBody(request);
    final projectId = BridgeServer._stringField(body, 'project');
    final name = BridgeServer._stringField(body, 'name');
    if (projectId == null || name == null) {
      await BridgeServer._invalidBody(response);
      return;
    }
    OpencodeProject? project;
    try {
      final projects = await sessions.projects();
      for (final candidate in projects) {
        if (candidate.id == projectId) {
          project = candidate;
          break;
        }
      }
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
      await response.close();
      return;
    }
    if (project == null) {
      BridgeServer._notFound(response);
      return;
    }
    try {
      final record = await orbs.create(
        project: projectId,
        name: name,
        checkout: project.canonical,
      );
      response.statusCode = HttpStatus.created;
      response.write(jsonEncode(record.toJson()));
    } on OrbNameTakenError {
      response.statusCode = HttpStatus.conflict;
      response.write(jsonEncode({'error': 'name_taken', 'name': name}));
    } on OrbRefusalError catch (e) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': e.code, 'details': e.message}));
    } on OrbBootError catch (e) {
      response.statusCode = HttpStatus.badGateway;
      response.write(
        jsonEncode({
          'error': 'orb_boot_failed',
          'details': e.detail,
          'logTail': e.logTail,
        }),
      );
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    } on OrbImageBuildError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_build_failed'}));
    }
    await response.close();
  }

  /// The spawn surface's dispatch (issue #99, spec §8.2): `POST` with the
  /// body `{"task": "free text", "model"?: {"id", "providerID", "variant"?},
  /// "wait"?: bool (default true), "session"?: the calling session id,
  /// "directory"?: the calling working directory}`. The
  /// session/directory pair identifies the caller (the tool's context): the
  /// project is resolved from them — never an argument — and the session is
  /// the completion-injection target. `wait: true` blocks until the task
  /// completes and answers the structured result; `wait: false` answers the
  /// dispatched task immediately.
  static Future<void> _handleOrbSpawn(
    HttpRequest request,
    OrbTaskService? tasks,
  ) async {
    final response = request.response;
    if (tasks == null) {
      BridgeServer._unavailable(response);
      await response.close();
      return;
    }
    final body = await BridgeServer._jsonBody(request);
    final task = BridgeServer._stringField(body, 'task');
    if (task == null || task.trim().isEmpty) {
      await BridgeServer._invalidBody(response);
      return;
    }
    final waitField = body?['wait'];
    final wait = waitField is bool ? waitField : true;
    try {
      final dispatched = await tasks.spawn(
        task: task,
        model: BridgeServer._modelRef(body),
        wait: wait,
        callerSession: BridgeServer._stringField(body, 'session'),
        callerDirectory: BridgeServer._stringField(body, 'directory'),
      );
      response.statusCode = wait ? HttpStatus.ok : HttpStatus.created;
      response.write(jsonEncode(dispatched.toJson()));
    } on OrbSpawnProjectError {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'project_unknown'}));
    } on OrbAmbiguousError catch (e) {
      // The targeting argument is issue #100's; the tool reports the list.
      response.statusCode = HttpStatus.conflict;
      response.write(jsonEncode({'error': 'orb_ambiguous', 'orbs': e.names}));
    } on OrbTaskNotFoundError catch (e) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found', 'id': e.id}));
    } on OrbNameTakenError catch (e) {
      response.statusCode = HttpStatus.conflict;
      response.write(jsonEncode({'error': 'name_taken', 'name': e.name}));
    } on OrbRefusalError catch (e) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': e.code, 'details': e.message}));
    } on OrbBootError catch (e) {
      response.statusCode = HttpStatus.badGateway;
      response.write(
        jsonEncode({
          'error': 'orb_boot_failed',
          'details': e.detail,
          'logTail': e.logTail,
        }),
      );
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    } on OrbImageBuildError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_build_failed'}));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// The spawn surface's wait (issue #99, spec §8.3): `POST` with the body
  /// `{"id": "<task id>"}` — blocks until the task completes and answers the
  /// structured result (status, summary, results, branch, PR once it
  /// exists). An unknown task id is a 404.
  static Future<void> _handleOrbWait(
    HttpRequest request,
    OrbTaskService? tasks,
  ) async {
    final response = request.response;
    if (tasks == null) {
      BridgeServer._unavailable(response);
      await response.close();
      return;
    }
    final body = await BridgeServer._jsonBody(request);
    final id = BridgeServer._stringField(body, 'id');
    if (id == null || id.isEmpty) {
      await BridgeServer._invalidBody(response);
      return;
    }
    try {
      final settled = await tasks.wait(id);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode(settled.toJson()));
    } on OrbTaskNotFoundError catch (e) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found', 'id': e.id}));
    }
    await response.close();
  }

  /// The orb list (issue #93, spec §2.2): composed from the `ocb.*` labels
  /// (no registry file) — the labeled containers (running with their
  /// ephemeral URL, or stopped/broken) plus the labeled volumes without a
  /// container (orphans). `?pr=1` asks for the PR state of each row's branch
  /// (issue #96, spec §9.1 — the Orbs tab's badge); without it the list
  /// costs nothing for the PR (the composite services' hot path).
  static Future<void> _handleOrbList(
    HttpRequest request,
    OrbService? orbs,
  ) async {
    final response = request.response;
    if (orbs == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    final includePr = request.uri.queryParameters['pr'] == '1';
    try {
      final rows = await orbs.list(includePr: includePr);
      response.statusCode = HttpStatus.ok;
      response.write(jsonEncode([for (final row in rows) row.toJson()]));
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    }
    await response.close();
  }

  /// The protected deletion (issue #98, spec §2.7): `DELETE /api/orbs/<id>`
  /// — with the optional JSON body `{"force": true}` (no body is
  /// non-forced) — evaluates the deletion guard first (an `orphan` record
  /// goes through the explicit orphan cleanup) and removes the container,
  /// the workspace and data volumes, and the state dir. A guard refusal is
  /// a 409 `deletion_refused` carrying the guard's reasons (the human's
  /// force-delete overrides it — the automated path never forces,
  /// §2.10.2); a missing orb or orphan is a 404; a daemon failure is a 502.
  static Future<void> _handleOrbDelete(
    HttpRequest request,
    String id,
    OrbService? orbs,
  ) async {
    final response = request.response;
    if (orbs == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    final body = await BridgeServer._jsonBody(request);
    final force = body?['force'] == true;
    try {
      await orbs.delete(id, force: force);
      response.statusCode = HttpStatus.noContent;
    } on OrbDeletionRefusedError catch (e) {
      response.statusCode = HttpStatus.conflict;
      response.write(
        jsonEncode({
          'error': 'deletion_refused',
          'id': e.id,
          'reasons': e.guard.reasons,
          'dirty': e.guard.dirty,
          'unpushedCount': e.guard.unpushedCount,
        }),
      );
    } on OrbNotFoundError {
      await BridgeServer._notFound(response);
      return;
    } on OrbOrphanNotFoundError {
      await BridgeServer._notFound(response);
      return;
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    }
    await response.close();
  }

  /// The orb lifecycle actions (issue #97, #98): `stop` (the single
  /// trigger for every orb death path — every session exported to the host
  /// and deleted from the orb only after its import, the container stopped
  /// last, the `ocb.stopped` marker set; a re-issue while stopped is a safe
  /// no-op) answers 204; `wake` (the full start path re-run, the marker
  /// off) answers 200 with the running record; `sessions` (a new session in
  /// the orb workspace, its row stamped with the orb) answers 201 with the
  /// row; `update` (the per-orb image update, spec §2.8 — the container
  /// recreated on the current image over the same volumes, never forced)
  /// answers 200 with the record (a stopped orb stays stopped); `export`
  /// (the `docker cp` tar.gz of the whole workspace, spec §3.4) answers 200
  /// with `{'path': <the export file>}`; `fresh-state` (issue #102, spec
  /// §9.4 — the broken orb's wake over a recreated state dir: keeps the
  /// workspace, loses the in-orb sessions) answers 200 with the running
  /// record. The error mapping: a missing orb a
  /// 404; a named refusal a 400 with its code and message; a failed boot a
  /// 502 `orb_boot_failed` with the log tail; a missing session
  /// prerequisite (no host CLI, no host service, no checkout, no orb
  /// password) a 503 `opencode_unavailable`; a failed session move a 502
  /// `session_move_failed`; a service error the [_serviceError] mapping; a
  /// daemon failure a 502 `docker_unreachable`.
  static Future<void> _handleOrbAction(
    HttpRequest request,
    String id,
    String action,
    OrbService? orbs,
  ) async {
    final response = request.response;
    if (orbs == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    try {
      switch (action) {
        case 'stop':
          await orbs.stop(id);
          response.statusCode = HttpStatus.noContent;
          break;
        case 'wake':
          final record = await orbs.wake(id);
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode(record.toJson()));
          break;
        case 'update':
          final updated = await orbs.update(id);
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode(updated.toJson()));
          break;
        case 'export':
          final path = await orbs.export(id);
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode({'path': path}));
          break;
        case 'fresh-state':
          // The broken orb's start-with-fresh-state (issue #102, spec
          // §9.4): the full wake over a recreated state dir; the error
          // mapping is the wake's.
          final fresh = await orbs.startWithFreshState(id);
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode(fresh.toJson()));
          break;
        default: // 'sessions'
          final session = await orbs.createSessionOnOrb(id);
          response.statusCode = HttpStatus.created;
          response.write(jsonEncode(session.toJson()));
      }
    } on OrbNotFoundError {
      await BridgeServer._notFound(response);
      return;
    } on OrbRefusalError catch (e) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': e.code, 'details': e.message}));
    } on OrbBootError catch (e) {
      response.statusCode = HttpStatus.badGateway;
      response.write(
        jsonEncode({
          'error': 'orb_boot_failed',
          'details': e.detail,
          'logTail': e.logTail,
        }),
      );
    } on OrbSessionsUnavailableError {
      BridgeServer._unavailable(response);
      return;
    } on OrbSessionMoveError catch (e) {
      response.statusCode = HttpStatus.badGateway;
      response.write(
        jsonEncode({
          'error': 'session_move_failed',
          'session': e.session,
          'details': e.detail,
        }),
      );
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// The host→orb session move (issue #97): one action, entirely through
  /// the bridge. The body is `{"orb": "<name>"}`; the target orb is resolved
  /// in the session's project — woken when stopped, created (the full
  /// spec §2.3 sequence) when absent, otherwise refused — and the session
  /// moves onto its workspace. A 204 on the move (a re-run over an already
  /// moved session is the 409-idempotent success); the error mapping is the
  /// lifecycle actions' plus the create's (a taken name is a 409
  /// `name_taken`, a build failure a 502 `docker_build_failed`).
  static Future<void> _handleMoveToOrb(
    HttpRequest request,
    String session,
    SessionsBackend? sessions,
    OrbService? orbs,
  ) async {
    final response = request.response;
    if (orbs == null) {
      BridgeServer._dockerUnavailable(response);
      return;
    }
    if (sessions == null) {
      BridgeServer._unavailable(response);
      return;
    }
    final body = await BridgeServer._jsonBody(request);
    final orbName = BridgeServer._stringField(body, 'orb');
    if (orbName == null) {
      await BridgeServer._invalidBody(response);
      return;
    }
    try {
      await orbs.moveSessionToOrb(session: session, orbName: orbName);
      response.statusCode = HttpStatus.noContent;
    } on OrbNotFoundError {
      await BridgeServer._notFound(response);
      return;
    } on OrbRefusalError catch (e) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': e.code, 'details': e.message}));
    } on OrbNameTakenError {
      response.statusCode = HttpStatus.conflict;
      response.write(jsonEncode({'error': 'name_taken', 'name': orbName}));
    } on OrbBootError catch (e) {
      response.statusCode = HttpStatus.badGateway;
      response.write(
        jsonEncode({
          'error': 'orb_boot_failed',
          'details': e.detail,
          'logTail': e.logTail,
        }),
      );
    } on OrbImageBuildError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_build_failed'}));
    } on OrbSessionsUnavailableError {
      BridgeServer._unavailable(response);
      return;
    } on OrbSessionMoveError catch (e) {
      response.statusCode = HttpStatus.badGateway;
      response.write(
        jsonEncode({
          'error': 'session_move_failed',
          'session': e.session,
          'details': e.detail,
        }),
      );
    } on DockerUnavailableError {
      response.statusCode = HttpStatus.badGateway;
      response.write(jsonEncode({'error': 'docker_unreachable'}));
    } on OpencodeServiceError catch (e) {
      BridgeServer._serviceError(response, e);
    }
    await response.close();
  }

  /// The orb id behind an orb-detail path (`/api/orbs/<id>`), or `null`
  /// when [path] is not one (the bare list path has no id segment, and a
  /// multi-segment path is not an orb detail either).
  static String? _orbIdIn(String path) {
    const prefix = '/api/orbs/';
    if (!path.startsWith(prefix)) return null;
    final id = path.substring(prefix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return id;
  }

  /// The (orb id, action) behind an orb lifecycle path
  /// `/api/orbs/<id>/<action>` (issue #97, #98, #102), or `null` when
  /// [path] is not one (the bare orb-detail path has no action segment, and
  /// any word outside [_orbActions] is not an action).
  static (String, String)? _orbActionIn(String path) {
    const prefix = '/api/orbs/';
    if (!path.startsWith(prefix)) return null;
    final rest = path.substring(prefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final id = rest.substring(0, slash);
    final action = rest.substring(slash + 1);
    if (id.isEmpty || id.contains('/') || action.contains('/')) return null;
    if (!_orbActions.contains(action)) return null;
    return (id, action);
  }

  /// The action words of `/api/orbs/<id>/<action>` (issues #97, #98, #102).
  static const Set<String> _orbActions = {
    'stop',
    'wake',
    'sessions',
    'update',
    'export',
    'fresh-state',
  };

  /// The session id in a move-to-orb path `/api/sessions/{id}/move-to-orb`
  /// (issue #97), or `null` when [path] is not one (the body carries the
  /// target orb name).
  static String? _moveToOrbIn(String path) {
    const prefix = '/api/sessions/';
    const suffix = '/move-to-orb';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    final id = path.substring(prefix.length, path.length - suffix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return Uri.decodeComponent(id);
  }

  /// The project directory behind a compose action path, or `null` when
  /// [path] is not a compose action path. The client percent-encodes the
  /// directory so it rides the path as a single segment; `Uri.path` keeps
  /// percent-escapes, so the extracted id is decoded back to the directory.
  static String? _composeActionIn(String path) {
    const prefix = '/api/docker/compose/';
    const suffix = '/action';
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
    // An empty id (`.../compose/action`) is not a compose action path.
    if (path.length < prefix.length + suffix.length) return null;
    final id = path.substring(prefix.length, path.length - suffix.length);
    // A raw `/` would mean the id is not the percent-encoded directory.
    if (id.contains('/')) return null;
    return Uri.decodeComponent(id);
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
}
