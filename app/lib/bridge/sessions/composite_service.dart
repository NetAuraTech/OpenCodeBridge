import '../../model/command.dart';
import '../../model/message.dart';
import '../../model/orb.dart';
import '../../model/permission.dart';
import '../../model/question.dart';
import '../../model/session_detail.dart';
import 'opencode_http_service.dart';
import 'opencode_service.dart';

/// The aggregate [OpencodeService] over the shared host service and every
/// running orb (issue #95, spec §7.2): the app cannot tell an orb session
/// from a host session.
///
/// - The home-list reads ([listSessions], [activeSessionIds], [projectNames])
///   merge the host and every running orb into one stream; the composite
///   stamps each orb session with its [OpencodeSession.orb] id.
/// - The per-session operations route by an in-memory `sessionID -> orb`
///   table (session ids are globally unique). Every route first reconciles
///   the upstream set (a stopped or respawned orb is handled at once); a
///   table miss triggers one registration pass; still unknown falls back to
///   the host.
/// - The per-orb descriptor has no file (spec §7.1): the URL is the running
///   orb record's ephemeral URL and the password is the last `server
///   password` line of the orb's container log, both re-derived at every
///   refresh. When either is gone (the orb is not running, or its log has no
///   password yet), the orb gets no upstream and its sessions are invisible
///   to the composite for that pass.
///
/// Degradation: a host failure propagates (the host is primary); a per-orb
/// failure is swallowed (that orb's rows/routing degrade for this pass and
/// the next refresh re-tries).
class CompositeOpencodeService implements OpencodeService {
  CompositeOpencodeService({
    required this.host,
    required this.orbList,
    required this.orbPassword,
    this.upstreamFactory = _defaultUpstreamFactory,
  });

  /// The per-orb client: the same HTTP service as the host, pointed at the
  /// orb's ephemeral URL with the orb's derived password (Basic
  /// `opencode:<password>`, spec §7.1).
  static OpencodeService _defaultUpstreamFactory(
    Uri baseUrl,
    String password,
  ) => OpencodeHttpService(baseUrl: baseUrl, password: password);

  final OpencodeService host;

  /// The running orb list (labels; `url` only for a running orb). May throw
  /// when docker is down (the composite degrades to host-only).
  final Future<List<OrbRecord>> Function() orbList;

  /// The orb's current `server password` (the last log line wins on a
  /// respawn), or `null` when it cannot be derived.
  final Future<String?> Function(String orbId) orbPassword;

  /// Builds the per-orb client from its ephemeral URL + derived password
  /// (injectable for tests; the default is the same HTTP client as the host).
  final OpencodeService Function(Uri baseUrl, String password) upstreamFactory;

  /// The live per-orb services, keyed by orb id.
  final Map<String, _OrbUpstream> _upstreams = {};

  /// The routing table: session id -> orb id (only orb sessions are
  /// registered; an unregistered id belongs to the host).
  final Map<String, String> _owner = {};

  Future<void>? _refreshing;

  @override
  Future<List<OpencodeSession>> listSessions() async {
    await _refresh();
    final all = <OpencodeSession>[];
    all.addAll(await host.listSessions()); // A host failure propagates.
    for (final entry in _upstreams.entries) {
      try {
        all.addAll([
          for (final session in await entry.value.service.listSessions())
            OpencodeSession(
              id: session.id,
              title: session.title,
              projectId: session.projectId,
              created: session.created,
              location: session.location,
              orb: entry.key,
            ),
        ]);
      } catch (_) {
        // A degraded orb is absent from the home list for this pass.
      }
    }
    return all;
  }

  @override
  Future<Map<String, String>> projectNames() async {
    await _refresh();
    final names = <String, String>{};
    for (final entry in _upstreams.entries) {
      try {
        names.addAll(await entry.value.service.projectNames());
      } catch (_) {
        // A degraded orb contributes no names for this pass.
      }
    }
    names.addAll(await host.projectNames()); // The host wins on a shared id.
    return names;
  }

  @override
  Future<Set<String>> activeSessionIds() async {
    await _refresh();
    final active = <String>{...await host.activeSessionIds()};
    for (final entry in _upstreams.entries) {
      try {
        active.addAll(await entry.value.service.activeSessionIds());
      } catch (_) {
        // A degraded orb contributes no active ids for this pass.
      }
    }
    return active;
  }

  // The per-session operations: routed through the `sessionID -> orb` table.

  @override
  Future<SessionDetail> getDetail(String id) async =>
      (await _route(id)).getDetail(id);

  @override
  Future<List<SessionMessage>> getMessages(String id) async =>
      (await _route(id)).getMessages(id);

  @override
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async => (await _route(id)).prompt(id, text, files: files, skills: skills);

  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async =>
      (await _route(id)).pendingPermissions(id);

  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async => (await _route(id)).replyPermission(id, requestID, reply);

  @override
  Future<List<QuestionForm>> pendingQuestions(String id) async =>
      (await _route(id)).pendingQuestions(id);

  @override
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) async => (await _route(id)).answerQuestion(id, formID, answers);

  @override
  Future<void> dismissQuestion(String id, String formID) async =>
      (await _route(id)).dismissQuestion(id, formID);

  @override
  Future<void> runCommand(String id, String name, String text) async =>
      (await _route(id)).runCommand(id, name, text);

  @override
  Future<ModelRef?> currentModel(String id) async =>
      (await _route(id)).currentModel(id);

  @override
  Future<void> setModel(String id, ModelRef model) async =>
      (await _route(id)).setModel(id, model);

  @override
  Future<void> setAgent(String id, String agentId) async =>
      (await _route(id)).setAgent(id, agentId);

  @override
  Future<void> activateSkill(String id, String skillId) async =>
      (await _route(id)).activateSkill(id, skillId);

  @override
  Future<void> compact(String id) async => (await _route(id)).compact(id);

  @override
  Future<void> undo(String id) async => (await _route(id)).undo(id);

  @override
  Future<void> redo(String id) async => (await _route(id)).redo(id);

  @override
  Future<String> fork(String id) async {
    final service = await _route(id);
    final newId = await service.fork(id);
    final parentOrb = _owner[id];
    if (parentOrb != null) _owner[newId] = parentOrb; // The child lives on
    // the parent's service.
    return newId;
  }

  @override
  Future<void> rename(String id, String title) async =>
      (await _route(id)).rename(id, title);

  @override
  Future<String> exportSession(String id) async =>
      (await _route(id)).exportSession(id);

  @override
  Future<void> move(String id, String directory) async =>
      (await _route(id)).move(id, directory);

  @override
  Future<String> generate(String id, String prompt) async =>
      (await _route(id)).generate(id, prompt);

  @override
  Future<String> diff(String id) async => (await _route(id)).diff(id);

  @override
  Future<String> stats(String id) async => (await _route(id)).stats(id);

  @override
  Future<String> worktrees(String sessionId) async =>
      (await _route(sessionId)).worktrees(sessionId);

  @override
  Future<List<String>> findFiles(String id, String query) async =>
      (await _route(id)).findFiles(id, query);

  @override
  Future<void> deleteSession(String id) async {
    final service = await _route(id);
    await service.deleteSession(id);
    _owner.remove(id);
  }

  // The host-only surface: the registries are identical across orbs (spec
  // §7.4) and creation happens on the host.

  @override
  Future<List<OpencodeProject>> projects() => host.projects();

  @override
  Future<OpencodeSession> createSession(String projectId) =>
      host.createSession(projectId);

  @override
  Future<OpencodeSession> createSessionInDirectory(String directory) =>
      host.createSessionInDirectory(directory);

  @override
  Future<List<OpencodeCommand>> listCommands() => host.listCommands();

  @override
  Future<List<ModelOption>> listModels() => host.listModels();

  @override
  Future<List<AgentOption>> listAgents() => host.listAgents();

  @override
  Future<List<SkillOption>> listSkills() => host.listSkills();

  @override
  Future<String> usage() => host.usage();

  @override
  Future<String> mcps() => host.mcps();

  @override
  Future<String> integrations() => host.integrations();

  @override
  Future<String> connectIntegration(String integrationId, String methodId) =>
      host.connectIntegration(integrationId, methodId);

  @override
  Future<String> status() => host.status();

  @override
  Future<String> pair() => host.pair();

  @override
  Future<void> reload() => host.reload();

  @override
  Future<String> plugins() => host.plugins();

  // ------------------------------------------------------------------------
  // The orb set + routing table.

  /// The service a session id routes to: the owning orb's current upstream
  /// when the table knows it, else one registration pass (a late-discovered
  /// orb's sessions), and, if still unknown, the host. The upstream set is
  /// reconciled first, so a stopped or respawned orb is handled even while
  /// the table still points at its id.
  Future<OpencodeService> _route(String id) async {
    await _coalesced(_reconcileUpstreams);
    final upstream = _upstreamFor(_owner[id]);
    if (upstream != null) return upstream.service;
    await _coalesced(_registerOwners);
    final retried = _upstreamFor(_owner[id]);
    if (retried != null) return retried.service;
    return host;
  }

  _OrbUpstream? _upstreamFor(String? orbId) {
    if (orbId == null) return null;
    return _upstreams[orbId];
  }

  /// Coalesced step: concurrent callers share one in-flight pass.
  Future<void> _coalesced(Future<void> Function() step) {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final future = step();
    _refreshing = future;
    future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
    return future;
  }

  /// The full pass the home-list reads take: reconcile the upstream set,
  /// then register the live orbs' sessions in the routing table.
  Future<void> _refresh() => _coalesced(() async {
    await _reconcileUpstreams();
    await _registerOwners();
  });

  /// Re-derives the live per-orb upstream set from the labels + the container
  /// log (a respawned orb has a new port/password, so the `(url, password)`
  /// key changes): a started orb gets an upstream, a stopped one's is dropped
  /// (and its table entries cleared), a changed key's is replaced.
  Future<void> _reconcileUpstreams() async {
    final records = <OrbRecord>[];
    try {
      records.addAll(await orbList());
    } catch (_) {
      // Docker is down (or the labels unreadable): degrade to host-only.
    }
    final live = <String>{};
    for (final record in records) {
      final url = record.url;
      if (record.state != 'running' || url == null) continue;
      final password = await orbPassword(record.id);
      if (password == null) continue; // Still booting (no log line yet).
      live.add(record.id);
      final key = '$url|$password';
      final existing = _upstreams[record.id];
      if (existing != null && existing.key == key) continue;
      final service = upstreamFactory(Uri.parse(url), password);
      _upstreams[record.id] = _OrbUpstream(key: key, service: service);
    }
    for (final gone
        in _upstreams.keys.where((id) => !live.contains(id)).toList()) {
      _upstreams.remove(gone);
      for (final sessionId in _owner.keys.toList()) {
        if (_owner[sessionId] == gone) _owner.remove(sessionId);
      }
    }
  }

  /// Registers the live orbs' sessions in the routing table (an unregistered
  /// id belongs to the host). A degraded orb is simply absent for this pass;
  /// an earlier entry stands until its orb is dropped.
  Future<void> _registerOwners() async {
    for (final entry in _upstreams.entries) {
      try {
        final sessions = await entry.value.service.listSessions();
        for (final session in sessions) {
          _owner[session.id] = entry.key;
        }
      } catch (_) {
        // The orb is unreachable right now: any earlier table entry stands
        // (degraded), the next pass re-tries.
      }
    }
  }
}

/// One live per-orb service and the `(url, password)` key it was derived
/// from (a key change — a respawn's new port/password — replaces it).
class _OrbUpstream {
  const _OrbUpstream({required this.key, required this.service});

  final String key;
  final OpencodeService service;
}
