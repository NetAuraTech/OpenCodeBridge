import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../model/command.dart';
import '../../model/orb.dart';
import '../sessions/backend.dart';
import '../sessions/opencode_service.dart';
import 'orb_service.dart';
import 'orb_task.dart';

/// The caller could not be resolved to a known session or project directory,
/// so the task's project is unknown (`orb_spawn` takes no project — the
/// session knows it, spec §8.2).
class OrbSpawnProjectError implements Exception {
  const OrbSpawnProjectError();
  @override
  String toString() => 'OrbSpawnProjectError()';
}

/// Several orbs exist in the project and none was targeted (spec §8.2's
/// targeting refusal — the tool lists them and retries with an explicit
/// name).
class OrbAmbiguousError implements Exception {
  const OrbAmbiguousError(this.project, this.names);

  final String project;
  final List<String> names;

  @override
  String toString() => 'OrbAmbiguousError($project: $names)';
}

/// No task with this id (the persisted tasks.json is the single source).
class OrbTaskNotFoundError implements Exception {
  const OrbTaskNotFoundError(this.id);

  final String id;

  @override
  String toString() => 'OrbTaskNotFoundError($id)';
}

/// The caller is an agent and the orb is outside its spawn tree (issue
/// #100, spec §8.4): the agent may only control the orbs it spawned itself
/// or had its subagents spawn — never another agent's orb, never the orb it
/// itself runs inside, never a human-created orb.
class OrbPermissionError implements Exception {
  const OrbPermissionError(this.orb);

  final String orb;

  @override
  String toString() => 'OrbPermissionError($orb)';
}

/// The spawn surface's task service (issue #99 + #100, spec §8): what the
/// bridge does behind the global `orb_spawn`/`orb_wait`/`orb_stop`/
/// `orb_delete`/`orb_export` tools.
///
/// - **Targeting + wake-or-create** (spec §8.2): an explicit orb name wakes
///   or uses that orb, an unused name creates the additional orb (optionally
///   **seeded** from another orb's pushed branch tip, §3.3); no name → the
///   project's single orb: none → create (name derived from the task), one →
///   wake (idempotent — a running orb is returned as-is), several →
///   [OrbAmbiguousError].
/// - **Dispatch**: a fresh session on the orb's service (one session per
///   task), the calling session's model by default, then the task prompt.
/// - **Completion**: the orb session's turn outcome polled on [pollInterval]
///   (spec §7.2: the bridge aggregates the orb's opencode session, so the
///   session detail routes to the orb through the composite). At completion
///   the record takes the status, the agent's summary, the branch, and the
///   PR URL if the branch has one, is persisted, and the completion message
///   is **injected into the calling session** — dropped when that session is
///   dead (the orb keeps running; the result stays persisted, spec §8.3).
/// - **The spawn tree** ([canControl], spec §8.4): the creating-task records
///   are the tree's edges, keyed by session id; every agent-facing orb right
///   is scoped to the caller's tree, the human is unrestricted.
/// - **Persistence**: every task lives in one JSON file (the tasks file,
///   next to the bridge's other app-owned state), rewritten on every change.
///   A restarted bridge resumes watching the tasks that were still running.
class OrbTaskService {
  OrbTaskService({
    required this.orbs,
    required this.sessions,
    required this.file,
    this.pollInterval = const Duration(seconds: 2),
    this.waitGrace = defaultWaitGrace,
    Random? random,
  }) : _random = random ?? Random() {
    _load();
    unawaited(_resume());
  }

  /// The orb lifecycle service (wake-or-create, the PR read through the
  /// orb list).
  final OrbService orbs;

  /// The composite sessions backend: project lookup, the per-orb session
  /// create, the task prompt, and the completion injection all route through
  /// it (host and orb sessions alike, spec §7.2).
  final SessionsBackend sessions;

  /// The tasks file (`~/.config/opencodebridge/tasks.json`).
  final File file;

  /// The completion poll pace; also the test seam (tests drive completion
  /// with a scripted session detail rather than wall time).
  final Duration pollInterval;

  /// How long `wait: true` holds its response before answering the dispatched
  /// task as running (issue #143): the caller's transport (the agent tool's
  /// fetch through Code Mode hop) has its own timeout, and a blocking spawn
  /// that outlives it looks *unreachable* — the agent retries, and the retry
  /// must not (and now cannot) duplicate the task. The grace window sits
  /// under those timeouts; the caller then polls with other waits.
  final Duration waitGrace;

  /// [waitGrace]'s default: a long task is normal (a blocking spawn commonly
  /// runs for many minutes), but the agent tool's fetch gives up well before
  /// that, so a bounded answer must come first.
  static const Duration defaultWaitGrace = Duration(seconds: 20);

  final Random _random;

  /// The live task records, newest first.
  final List<OrbTask> _tasks = [];

  /// Per-project spawn serialization: two concurrent spawns of one project
  /// must not both decide "no orb — create".
  final Map<String, Future<void>> _spawningByProject = {};

  bool _watching = false;
  bool _closed = false;

  /// The persisted + live tasks, newest first.
  List<OrbTask> get tasks => List.unmodifiable(_tasks);

  /// The task with [id], or `null`.
  OrbTask? task(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// Dispatch [task] on the project's orb (spec §8.2) and return it.
  ///
  /// [callerSession] (the calling session id) and [callerDirectory] (its
  /// working directory, as the tool's context reports it) identify the
  /// caller: the project is resolved from the session row, falling back to
  /// the directory; [callerSession] is also the completion-injection target
  /// and the **spawn tree** parent of an orb this call creates (issue #100,
  /// spec §8.4). [orb] (issue #100, spec §8.2) targets by orb **name**: an
  /// existing orb's name wakes-or-uses it, an unused name creates that
  /// additional orb, omitted keeps the single-orb wake-or-create (several
  /// orbs → [OrbAmbiguousError]). [seed] names the orb whose pushed branch
  /// tip the new clone starts from (spec §3.3); it parameterizes a creation
  /// only — with an existing target or no seed orb it is refused.
  /// [model] defaults to the calling session's model. [wait] true (the
  /// tool-facing default) blocks until the task completes; false returns the
  /// dispatched record immediately — the completion watcher then persists
  /// the result and injects the completion message.
  ///
  /// [task] is delivered to the orb's agent exactly as given (trimmed, issue
  /// #147) — no prompt text is prepended or appended. [callerSession] and
  /// [dispatchId] are the dispatch identity ([OrbTaskService._retriedTaskOn]).
  Future<OrbTask> spawn({
    required String task,
    ModelRef? model,
    bool wait = true,
    String? orb,
    String? seed,
    String? callerSession,
    String? callerDirectory,
    String? dispatchId,
  }) async {
    final trimmed = task.trim();
    if (trimmed.isEmpty) {
      throw const OrbSpawnProjectError();
    }
    final projectId = await _resolveProject(callerSession, callerDirectory);
    // Serialize per project so concurrent spawns wake-or-create one orb.
    final previous = _spawningByProject[projectId] ?? Future<void>.value();
    final gate = previous.then((_) {}, onError: (_) {});
    final done = Completer<void>();
    final result = gate.then((_) async {
      try {
        return await _spawnLocked(
          projectId: projectId,
          task: trimmed,
          model: model,
          orb: orb?.trim(),
          seed: seed?.trim(),
          callerSession: callerSession,
          callerDirectory: callerDirectory,
          dispatchId: dispatchId,
        );
      } finally {
        done.complete();
        if (_spawningByProject[projectId] == done.future) {
          _spawningByProject.remove(projectId);
        }
      }
    });
    _spawningByProject[projectId] = done.future;
    final dispatched = await result;
    if (!wait) return dispatched;
    return _awaitCompletion(dispatched, grace: waitGrace);
  }

  Future<OrbTask> _spawnLocked({
    required String projectId,
    required String task,
    ModelRef? model,
    String? orb,
    String? seed,
    String? callerSession,
    String? callerDirectory,
    String? dispatchId,
  }) async {
    final (record, created) = await _targetOrCreateOrb(
      projectId,
      task,
      orb,
      seed,
    );

    // The idempotent dispatch (issue #143, tightened by #147): a retry of a
    // dispatch that is already running on the target orb returns that task —
    // a retried spawn (the caller's transport timed out or the agent repeat
    // the same call) is not a second task. The identity is the raw caller text
    // (exactly what was delivered) plus the calling session and, when the
    // caller sends one, its dispatch id — never a lossy normalization, which
    // bound a substring/superset/punctuation-stripped follow-up to the earlier
    // task and ran the wrong work. The per-project serialization above makes
    // check-then-dispatch race-free.
    final retried = _retriedTaskOn(record.id, task, callerSession, dispatchId);
    if (retried != null) return retried;

    // The task's session on the orb's service (one session per task, so the
    // turn outcome is unambiguous for completion detection).
    final session = await orbs.createSessionOnOrb(record.id);

    // The model: the caller's explicit one, else the calling session's
    // (spec §8.2's default), best-effort.
    final effective = model ?? await _callerModel(callerSession);
    if (effective != null) {
      try {
        await sessions.setModel(session.id, effective);
      } catch (_) {
        // A model the orb's service rejects: the session keeps its default.
      }
    }

    final dispatched = OrbTask(
      id: 'task_${_token()}',
      orb: record.id,
      project: record.project,
      orbName: record.name,
      branch: record.branch,
      session: session.id,
      callerSession: callerSession,
      callerDirectory: callerDirectory,
      callerOrb: await _hostOrbOf(callerSession ?? ''),
      createdOrb: created,
      task: task,
      textHash: _textHash(task),
      dispatchId: dispatchId?.trim(),
      created: DateTime.now().millisecondsSinceEpoch,
    );
    _tasks.insert(0, dispatched);
    _persist();

    try {
      await sessions.prompt(session.id, task);
    } catch (e) {
      // The dispatch itself failed: the task can never run, so it settles
      // failed right here (and the caller sees the error).
      dispatched.status = 'failed';
      dispatched.summary = 'the task prompt could not be delivered: $e';
      dispatched.completed = DateTime.now().millisecondsSinceEpoch;
      _persist();
      rethrow;
    }
    _startWatching();
    return dispatched;
  }

  /// Block until the task completes; returns the completed record (an
  /// already-completed task returns immediately). Used by `wait: true` and
  /// by the tool-facing `orb_wait`.
  ///
  /// [grace] (the bounded blocking wait, issue #143) caps how long the call
  /// holds: when set and the task is still running at the deadline, the task
  /// is returned **as it stands** (`status: running`) — the watcher keeps
  /// polling, so a later `orb_wait` still sees the task through.
  ///
  /// `wait: true` passes [waitGrace]; `orb_wait` passes `null`
  /// (an explicit wait is expected to block).
  ///
  /// [dispatchId] (issue #147) is the caller's own id for this dispatch, when
  /// it sends one: a retry carries the same id and returns the running task
  /// whatever its text, and a dispatch under a new id is always a new task.
  ///
  /// [callerSession] (issue #100, spec §8.4) scopes the wait right to the
  /// caller's spawn tree: an agent waits for the tasks of its own tree —
  /// and always for a task it dispatched itself (the `wait: false` →
  /// `orb_wait` flow); `null` is the human, unrestricted.
  Future<OrbTask> wait(String taskId, {String? callerSession}) async {
    final found = task(taskId);
    if (found == null) throw OrbTaskNotFoundError(taskId);
    if (callerSession != null &&
        callerSession.isNotEmpty &&
        found.callerSession != callerSession &&
        !await canControl(callerSession: callerSession, orbId: found.orb)) {
      throw OrbPermissionError(found.orb);
    }
    return _awaitCompletion(found);
  }

  Future<OrbTask> _awaitCompletion(OrbTask target, {Duration? grace}) async {
    if (target.isDone) return target;
    // Poll the shared record — any path that completes the task (this call,
    // the watcher, a concurrent waiter) settles this one too. A closed
    // service ends the wait with the record as it stands.
    final deadline = grace == null ? null : DateTime.now().add(grace);
    while (!target.isDone && !_closed) {
      try {
        await _check(target);
      } catch (_) {
        // A transient service failure: the next pass retries.
      }
      if (target.isDone) break;
      if (deadline != null && !DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(pollInterval);
    }
    return target;
  }

  /// The running task of orb [orbId] that this dispatch retries, or `null`
  /// (issue #143, tightened by #147): the idempotent dispatch's already-running
  /// match.
  ///
  /// A dispatch is identified by the **raw caller text** [task] (trimmed —
  /// exactly what was delivered to the agent, never a normalized or partial
  /// form), the **caller identity** [callerSession], and [dispatchId] when the
  /// caller sent one. So:
  /// - two different texts are two tasks, even when one contains the other,
  ///   differs only by punctuation, or a retyped variant dedups against the
  ///   running one (the #147 bug bound a later follow-up to an earlier task and
  ///   the bridge ran the wrong work);
  /// - different callers are different tasks — a reply to caller B is never
  ///   dropped because caller A's task is running;
  /// - a transport retry of the *same* dispatch repeats the raw text and the
  ///   same caller session (#143) and so returns the running task, and a
  ///   caller-sent [dispatchId] narrows that further: the same id retries,
  ///   a different id is a new task.
  ///
  /// A record that still says `running` is trusted: the watcher settles
  /// completions on its own pace (the poll interval), while a retry arrives
  /// within the caller's timeout — so shrinking the window on the live
  /// session listing is unnecessary.
  OrbTask? _retriedTaskOn(
    String orbId,
    String task,
    String? callerSession,
    String? dispatchId,
  ) {
    final id = dispatchId?.trim() ?? '';
    final textHash = _textHash(task);
    for (final running in _tasks) {
      if (running.orb != orbId || running.isDone) continue;
      // The text hash compares the raw bytes the agent was given — no
      // normalization, so nothing but an identical text can collide.
      if (running.textHash != textHash) continue;
      if (id.isNotEmpty && running.dispatchId != id) continue;
      // No caller (the human): the raw text is the whole identity.
      if (running.callerSession == null) return running;
      if (callerSession == null || callerSession.isEmpty) continue;
      if (running.callerSession == callerSession) return running;
    }
    return null;
  }

  /// The dispatch text's identity in the tasks file: a SHA-256 of the raw
  /// caller text (exactly what was delivered, issue #147), so the file
  /// carries no instruction text twice and no lossy comparison can make two
  /// different instructions collide.
  static String _textHash(String task) =>
      sha256.convert(utf8.encode(task)).toString();

  /// The project's orb for the spawn (spec §8.2's targeting + §3.3's seed),
  /// as `(record, created)` — [created] true when this call created the orb
  /// (the spawn-tree attachment fact, spec §8.4).
  ///
  /// - explicit [orb] name taken → that orb (woken when stopped);
  /// - explicit name not yet taken → the additional orb, a fresh clone
  ///   (from the default branch, or from [seed]'s pushed branch tip when
  ///   given) on a fresh `orb/<id>` branch;
  /// - name omitted → the single-orb wake-or-create: one orb (wake),
  ///   several ([OrbAmbiguousError] with the project's names), none
  ///   (create, name derived from the task).
  ///
  /// [seed] parameterizes a creation only: with an existing target it is
  /// refused ([OrbRefusalError.seedConflict]), and so is a seed with no
  /// target name to create under — a seed never changes a wake.
  Future<(OrbRecord, bool)> _targetOrCreateOrb(
    String projectId,
    String task,
    String? orb,
    String? seed,
  ) async {
    final rows = await orbs.list();
    final inProject = [
      for (final row in rows)
        if (row.project == projectId && row.state != 'orphan') row,
    ];
    if (orb != null && orb.isNotEmpty) {
      final existing = [
        for (final row in inProject)
          if (row.name == orb) row,
      ];
      if (existing.length > 1) {
        throw OrbAmbiguousError(projectId, [orb]);
      }
      if (existing.length == 1) {
        if (seed != null && seed.isNotEmpty) {
          throw const OrbRefusalError(
            OrbRefusalError.seedConflict,
            'the seed only parameterizes a new orb — the targeted orb '
            'already exists (spec §3.3)',
          );
        }
        return (await _wakeOrUse(existing.single), false);
      }
      // The additional orb (spec §8.2): a fresh clone under the name.
      if (seed != null && seed.isNotEmpty) {
        return (await _createSeeded(projectId, orb, seed), true);
      }
      return (await _createOrb(projectId, orb), true);
    }
    // No target name: the single-orb wake-or-create (#99's contract).
    if (seed != null && seed.isNotEmpty) {
      throw const OrbRefusalError(
        OrbRefusalError.seedConflict,
        'the seed parameterizes a new orb — pass it with a new orb name '
        'to spawn (spec §3.3)',
      );
    }
    if (inProject.length > 1) {
      throw OrbAmbiguousError(projectId, [
        for (final row in inProject) row.name,
      ]);
    }
    if (inProject.length == 1) {
      return (await _wakeOrUse(inProject.single), false);
    }
    return (
      await _createOrb(
        projectId,
        _derivedName(task, {for (final row in rows) row.name}),
      ),
      true,
    );
  }

  /// The existing-orb branch of the targeting (spec §8.2): a running orb is
  /// used as-is (idempotent wake), a stopped one is woken, any other state
  /// refuses.
  Future<OrbRecord> _wakeOrUse(OrbRecord row) async {
    if (row.state == 'running') return row;
    if (row.isStoppedLike) return orbs.wake(row.id);
    throw OrbRefusalError(
      OrbRefusalError.notRunning,
      'the project orb ${row.name} is ${row.state} — spawn refused',
    );
  }

  /// The additional orb (fresh clone of the project's default branch).
  Future<OrbRecord> _createOrb(String projectId, String name) async {
    final checkout = await _checkoutOf(projectId);
    return orbs.create(project: projectId, name: name, checkout: checkout);
  }

  /// The seeded clone (spec §3.3): the seed's branch tip, read from the
  /// remote through [OrbService.seedBranch] — the seed parent may be
  /// stopped, and its uncommitted working tree is never part of the seed.
  /// The clone's base label carries the seed's branch: the orb's PR stacks
  /// on the parent's branch, not the default.
  Future<OrbRecord> _createSeeded(
    String projectId,
    String name,
    String seed,
  ) async {
    final checkout = await _checkoutOf(projectId);
    final base = await orbs.seedBranch(
      project: projectId,
      seed: seed,
      checkout: checkout,
    );
    if (base == null) {
      final names = [
        for (final row in await orbs.list())
          if (row.project == projectId && row.state != 'orphan') row.name,
      ];
      throw OrbRefusalError(
        OrbRefusalError.seedNotFound,
        'no orb named $seed in this project — seed with one of: '
        '${names.join(', ').isEmpty ? '(none yet)' : names.join(', ')}',
      );
    }
    return orbs.create(
      project: projectId,
      name: name,
      checkout: checkout,
      base: base,
    );
  }

  /// The project's canonical checkout (the create's clone source and the
  /// seed's remote probe).
  Future<String> _checkoutOf(String projectId) async {
    String? checkout;
    try {
      for (final project in await sessions.projects()) {
        if (project.id == projectId) checkout = project.canonical;
      }
    } on OpencodeServiceError {
      // The service is unreachable: the checkout stays unknown.
    }
    if (checkout == null) throw const OrbSpawnProjectError();
    return checkout;
  }

  /// A short kebab name derived from the task (lowercase, at most three
  /// words, a numeric suffix when taken in the project).
  String _derivedName(String task, Set<String> existing) {
    final words = task
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(3)
        .join('-');
    final base = words.length > 32 ? words.substring(0, 32) : words;
    if (base.isEmpty) return _unique('orb', existing);
    return _unique(base, existing);
  }

  String _unique(String base, Set<String> existing) {
    if (!existing.contains(base)) return base;
    for (var i = 2; ; i++) {
      if (!existing.contains('$base-$i')) return '$base-$i';
    }
  }

  /// Resolve the task's project id (spec §8.2: the session knows its
  /// project): the calling session's project row first, the caller's working
  /// directory against the project list second. An orb-session caller (a
  /// nested spawn, spec §1.4) carries its ORB-side project id, which the
  /// host does not know: it translates through the orb's own record to the
  /// host project the orb belongs to.
  Future<String> _resolveProject(
    String? callerSession,
    String? callerDirectory,
  ) async {
    if (callerSession != null && callerSession.isNotEmpty) {
      try {
        final rows = await sessions.list();
        for (final row in rows) {
          if (row.id != callerSession) continue;
          final orbId = row.orb;
          if (orbId == null) return row.project.id;
          for (final orb in await orbs.list()) {
            if (orb.id == orbId) return orb.project;
          }
          throw const OrbSpawnProjectError();
        }
      } on OpencodeServiceError {
        // The service is unreachable: fall through to the directory.
      }
    }
    final directory = callerDirectory?.trim();
    if (directory != null && directory.isNotEmpty) {
      try {
        final projects = await sessions.projects();
        for (final project in projects) {
          if (project.canonical == directory) return project.id;
        }
      } catch (_) {
        // Same: unknown below.
      }
    }
    throw const OrbSpawnProjectError();
  }

  Future<ModelRef?> _callerModel(String? callerSession) async {
    if (callerSession == null || callerSession.isEmpty) return null;
    try {
      return await sessions.currentModel(callerSession);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------------
  // The spawn tree & permissions (issue #100, spec §8.4)

  /// The orb an agent-facing control call refers to: [ref] is an orb
  /// **name** within the caller's project (the same resolution the spawn
  /// targeting uses), or an orb **id** when no name matches. `null` when
  /// neither resolves. When the caller's project cannot be resolved (a
  /// human call without a session), the name resolves across all projects —
  /// a name taken in several of them is [OrbAmbiguousError] (the id always
  /// disambiguates).
  Future<OrbRecord?> resolveOrb(
    String ref, {
    String? callerSession,
    String? callerDirectory,
  }) async {
    String? projectId;
    try {
      projectId = await _resolveProject(callerSession, callerDirectory);
    } on OrbSpawnProjectError {
      projectId = null; // No project context: resolve globally.
    }
    final rows = await orbs.list();
    final named = [
      for (final row in rows)
        if (row.state != 'orphan' &&
            row.name == ref &&
            (projectId == null || row.project == projectId))
          row,
    ];
    if (named.length > 1) {
      throw OrbAmbiguousError(projectId ?? '', [ref]);
    }
    if (named.length == 1) return named.single;
    for (final row in rows) {
      if (row.id == ref) return row;
    }
    return null;
  }

  /// Whether the caller may act on the orb [orbId] (stop, delete, export):
  /// the agent's rights are **scoped to its spawn tree** — the orbs it
  /// spawned itself or had its subagents spawn — while the human (a caller
  /// that is none of these) is unrestricted (spec §8.4).
  ///
  /// The tree is derived from the persisted task records: a task that
  /// created its orb is the edge from the caller's session id to that orb,
  /// recorded with the orb the caller ran inside at the time ([OrbTask
  /// .callerOrb]) — all of it **keyed by session id and durable**, so it
  /// **survives moves**: a session moved to the host keeps the id the edges
  /// are keyed by (spec §7.2/§8.4). The walk goes up the target orb's
  /// creating-edge chain: the caller is in the tree when it is an edge's
  /// spawner, transitively, with no depth limit (A spawns B, B spawns C ⇒ C
  /// is in A's tree). The chain ends at a human-created orb (no creating
  /// record — out of every agent's reach), and the orb the caller itself
  /// runs inside is outside its own tree (B's agent cannot stop B).
  ///
  /// [callerSession] is the caller as the tool request presents it: an
  /// agent's session id (host or orb side); `null`/empty is the human.
  Future<bool> canControl({
    required String? callerSession,
    required String orbId,
  }) async {
    if (callerSession == null || callerSession.isEmpty) return true;
    // An agent never controls the orb it itself runs inside: its own orb
    // is outside its tree (spec §8.4 — B's agent cannot stop B).
    if (await _hostOrbOf(callerSession) == orbId) return false;
    String? hop = orbId;
    final visited = <String>{};
    while (hop != null && visited.add(hop)) {
      final edge = _creatingTask(hop);
      if (edge == null) return false; // human-created: out of every tree
      if (edge.callerSession == callerSession) return true;
      hop = edge.callerOrb;
    }
    return false;
  }

  /// The orb the session [session] runs inside, or `null` when it is a host
  /// session (its row is not stamped with an orb) or unknown (a dead
  /// session: no hosting chain).
  Future<String?> _hostOrbOf(String session) async {
    if (session.isEmpty) return null;
    try {
      for (final row in await sessions.list()) {
        if (row.id == session) return row.orb;
      }
    } on OpencodeServiceError {
      // The service is unreachable: unknown, like a host session.
    }
    return null;
  }

  /// The creating task of the orb [orbId] (the spawn-tree edge into it), or
  /// `null` when no record created it — a human-created orb ends every
  /// agent's chain (spec §8.4: an agent never touches those).
  OrbTask? _creatingTask(String orbId) {
    for (final task in _tasks) {
      if (task.createdOrb && task.orb == orbId) return task;
    }
    return null;
  }

  // ------------------------------------------------------------------------
  // Completion watching, persistence, injection

  /// Re-watch the persisted tasks that were still running when the bridge
  /// (or the service) started: their orb sessions live on, the results are
  /// still to come, the injection targets a possibly-dead caller (dropped
  /// then, spec §8.3).
  Future<void> _resume() async {
    if (_tasks.any((t) => !t.isDone)) _startWatching();
  }

  void _startWatching() {
    if (_watching || _closed) return;
    _watching = true;
    unawaited(_watch());
  }

  /// Stops the completion watcher (the bridge's [BridgeServer.stop]).
  void close() => _closed = true;

  Future<void> _watch() async {
    while (!_closed && _tasks.any((t) => !t.isDone)) {
      for (final task in List.of(_tasks)) {
        if (!task.isDone) {
          try {
            await _check(task);
          } catch (_) {
            // A transient service failure: the next pass retries.
          }
        }
      }
      if (!_tasks.any((t) => !t.isDone)) break;
      await Future<void>.delayed(pollInterval);
    }
    _watching = false;
  }

  /// The host project id behind the recent tasks an agent-facing spawn is
  /// asking about (issue #143): the explicit [project] id, else the project
  /// whose canonical checkout is [directory] — or the project of the task
  /// dispatched from that directory and still running (a directory the
  /// service no longer lists still names its project through the record).
  /// `null` when neither resolves (the tool answers "nothing recent").
  /// [project] wins over [directory].
  Future<String?> recentProject({String? project, String? directory}) async {
    final id = project?.trim();
    if (id != null && id.isNotEmpty) return id;
    final dir = directory?.trim();
    if (dir != null && dir.isNotEmpty) {
      try {
        for (final row in await sessions.projects()) {
          if (row.canonical == dir) return row.id;
        }
      } on OpencodeServiceError {
        // The service is unreachable: fall through to the records.
      }
      for (final row in _tasks) {
        if (!row.isDone && row.callerDirectory == dir) {
          return row.project.isEmpty ? null : row.project;
        }
      }
    }
    return null;
  }

  /// One completion check: when the orb session reports a turn outcome, the
  /// task completes — status, summary, PR, persistence, injection.
  Future<void> _check(OrbTask target) async {
    if (target.isDone) return;
    final detail = await sessions.getDetail(target.session);
    final outcome = detail.outcome;
    if (outcome == null) return;
    // The reads below cross the event loop, so a concurrent waiter (the
    // `wait: true` path polls too) may have completed the task in the
    // meantime: the settle below is guarded on the task still being open.
    if (target.isDone) return;
    String summary = '';
    try {
      final messages = await sessions.getMessages(target.session);
      for (final message in messages.reversed) {
        if (message.role == 'assistant' && (message.text ?? '').isNotEmpty) {
          summary = message.text!;
          break;
        }
      }
    } catch (_) {
      // No summary is a fine degraded completion.
    }
    target.status = outcome;
    target.summary = summary;
    target.pr = await _prUrl(target);
    target.completed = DateTime.now().millisecondsSinceEpoch;
    _persist();
    await _injectCompletion(target);
  }

  /// The branch's PR URL (the return channel, spec §3.2), read through the
  /// orb list's PR state; `null` when the branch has no PR (yet) or gh
  /// cannot answer.
  Future<String?> _prUrl(OrbTask target) async {
    try {
      final rows = await orbs.list(includePr: true);
      for (final row in rows) {
        if (row.id == target.orb) return row.pr?.url;
      }
    } catch (_) {
      // Docker or gh unreachable: no PR for this completion.
    }
    return null;
  }

  /// Inject the completion message into the calling session (spec §8.3).
  /// A dead caller is a dropped notification — the record stays persisted
  /// and the orb keeps running.
  Future<void> _injectCompletion(OrbTask target) async {
    final caller = target.callerSession;
    if (caller == null || caller.isEmpty) return;
    final buffer = StringBuffer()
      ..write('Orb ${target.orbName} done — work on branch `${target.branch}`')
      ..write('\nStatus: ${target.status}');
    if (target.summary.isNotEmpty) buffer.write('\n\n${target.summary}');
    final pr = target.pr;
    if (pr != null) buffer.write('\n\nPR: $pr');
    try {
      await sessions.prompt(caller, buffer.toString());
    } catch (_) {
      // The calling session is gone (or the service refuses): the
      // notification is dropped, spec §8.3.
    }
  }

  void _persist() {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert([for (final task in _tasks) task.toJson()]),
      );
    } catch (_) {
      // Persistence is best-effort: the live bridge still serves the task.
    }
  }

  void _load() {
    try {
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return;
      for (final row in decoded) {
        _tasks.add(OrbTask.fromJson(row));
      }
      _tasks.sort((a, b) => b.created.compareTo(a.created));
    } catch (_) {
      // A corrupt tasks file starts the surface fresh.
    }
  }

  String _token() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      8,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }
}
