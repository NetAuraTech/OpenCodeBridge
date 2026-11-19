import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../model/command.dart';
import '../../model/orb.dart';
import '../../model/session_detail.dart';
import '../../notify/deep_link.dart';
import '../../notify/notify_kind.dart';
import '../notify/delivery_policy.dart';
import '../notify/notify_service.dart';
import '../sessions/backend.dart';
import '../sessions/opencode_service.dart';
import 'orb_embedded.dart';
import 'orb_service.dart';
import 'orb_state_machine.dart';
import 'orb_task.dart';
import 'orb_upstreams.dart';

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
///   PR URL if the branch has one, is persisted, and the completion delivery
///   goes out **through the delivery-policy module** (issue #259's
///   [DeliveryPlan], #260): the in-app injection is the primary channel,
///   retried until it lands (a landed task never re-injects), and the push
///   (the FCM path, issue #24) is the once-sent fallback, armed on the
///   primary's first failure and sent at most once for the delivery's whole
///   life (issue #212, #244). The task record owns the delivery's explicit
///   **owed** / **fallback-sent** facts ([OrbTask.deliveryOwed],
///   [OrbTask.fallbackSent]) — persisted, so a restart resumes the retry
///   without re-sending the fallback — and the plan is rebuilt from them.
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
    this.settleIdleWindow = defaultSettleIdleWindow,
    this.settleMissingWindow = defaultSettleMissingWindow,
    this.notifyProvider = _noNotify,
    OrbUpstreamSource? upstreams,
    Random? random,
  }) : _random = random ?? Random(),
       // The task service does not re-derive the composite's routing fact:
       // it takes the live-upstream source and *asks* it for the per-orb
       // verdict (issue #276). The bridge passes its shared module instance
       // (wired once by the composition root, issue #278); a library consumer
       // that does not inject one builds it from the orb service here — the
       // same list + password seams the composites read.
       upstreams = upstreams ?? LiveOrbUpstreams(orbService: orbs) {
    _load();
    unawaited(_resume());
  }

  /// The orb lifecycle service (wake-or-create, the PR read through the
  /// orb list).
  final OrbService orbs;

  /// The live-upstream facts (issue #274, owned by [orb_upstreams]): the
  /// per-orb reachability verdict this service consults for a missing-read's
  /// conclusiveness (issue #211/#276). The bridge injects its shared module
  /// instance (wired once by the composition root, issue #278); a library
  /// consumer that does not pass one gets a source built from [orbs] — the
  /// same list and password seams the composites read — so the task service
  /// *asks* the module instead of re-deriving the composite's routing fact
  /// itself.
  final OrbUpstreamSource upstreams;

  /// The composite sessions backend (host and orb sessions alike, spec
  /// §7.2): the home-list composition ([SessionsBackend.list], the completion
  /// check's [SessionsBackend.detailWithActive]) is its; the raw operations
  /// (the project lookup, the model read/set, the task prompt, the completion
  /// injection) are read through its [SessionsBackend.service] seam.
  final SessionsBackend sessions;

  /// The tasks file (`~/.config/opencodebridge/tasks.json`).
  final File file;

  /// The push fallback's live [NotifyService], read at push time (issue #212,
  /// #260): the out-of-band push a settled task sends when its caller cannot be
  /// reached in-app. The bridge injects this [NotifyService? Function()]
  /// closure at construction, so the task service holds **no mutable notify
  /// field** for the bridge to re-point on a reload (issue #260, acceptance
  /// #3). The closure reads the bridge's live notify at push time, so a settle
  /// after a `reloadNotify` (the Settings service-account save) pushes through
  /// the current sender; a closure that returns `null` (push not configured,
  /// the default [_noNotify]) leaves the in-app retry to stand alone.
  final NotifyService? Function() notifyProvider;

  /// The default [notifyProvider]: push is not configured, so the closure
  /// returns `null` and the in-app retry owns the delivery alone.
  static NotifyService? _noNotify() => null;

  /// The completion poll pace; also the test seam (tests drive completion
  /// with a scripted session detail rather than wall time).
  final Duration pollInterval;

  /// How long a blocking `orb_spawn` (`wait: true`) or an `orb_wait` holds its
  /// response before answering the task as running (issue #143, bounded wait
  /// extended to `orb_wait` by issue #169): the caller's transport (the agent
  /// tool's fetch through Code Mode hop) has its own timeout, and a call that
  /// outlives it looks *unreachable* — the agent retries, and the retry must
  /// not (and now cannot) duplicate the task. The grace window sits under
  /// those timeouts; the caller then polls again, or simply ends its turn and
  /// lets the completion injection wake it (spec §8.3's async path).
  final Duration waitGrace;

  /// [waitGrace]'s default: a long task is normal (a blocking spawn commonly
  /// runs for many minutes), but the agent tool's fetch gives up well before
  /// that, so a bounded answer must come first.
  static const Duration defaultWaitGrace = Duration(seconds: 20);

  /// How long an **idle session without an outcome** must stay that way, on
  /// the completion reads, before the task settles (issue #169): opencode
  /// persists no `outcome` for a turn whose session was migrated to the host
  /// when its orb stopped, so such a session answers 200 without one forever
  /// — without this, the task would run (and the watcher poll) for the life
  /// of the bridge. Time-based, not read-count-based: the watcher and a
  /// concurrent waiter poll the same task, so only wall time distinguishes a
  /// settled turn from a dispatch whose agent has not started its first step.
  final Duration settleIdleWindow;

  /// [settleIdleWindow]'s default: comfortably past any prompt-to-execution
  /// latency, still noise against a task's minutes-long life.
  static const Duration defaultSettleIdleWindow = Duration(seconds: 15);

  /// How long a **missing session** (a 404 — the session is gone) must stay
  /// missing, on the completion reads, before the task settles as failed
  /// (issue #169). Transient service failures (a transport error, a 5xx, a
  /// degraded orb pass routing the read to the host) are not counted: only
  /// the service's own 404 is, and the window absorbs the routing settling.
  final Duration settleMissingWindow;

  /// [settleMissingWindow]'s default: a session the service has reported
  /// gone for a full minute of polling can never report a turn outcome.
  static const Duration defaultSettleMissingWindow = Duration(seconds: 60);

  final Random _random;

  /// When each running task's session was first read idle-without-outcome
  /// (issue #169's settle window); any other read clears the entry.
  final Map<String, DateTime> _idleSince = {};

  /// When each running task's session was first read missing (404).
  final Map<String, DateTime> _missingSince = {};

  /// The live task records, newest first.
  final List<OrbTask> _tasks = [];

  /// Per-project spawn serialization: two concurrent spawns of one project
  /// must not both decide "no orb — create".
  final Map<String, Future<void>> _spawningByProject = {};

  /// The delivery plans of the settled tasks, keyed by task id (issue #260):
  /// one [DeliveryPlan] per settled task, the owner of its **owed** /
  /// **once-sent** decisions. Built at settle (a fresh plan), restored after a
  /// restart from the record's persisted facts ([OrbTask.deliveryOwed] /
  /// [OrbTask.fallbackSent]) — the plan itself is never serialized; the record
  /// owns the durable state, and [planFor] rebuilds the plan from it. A
  /// restored plan never re-sends the fallback (the policy's **once-sent**
  /// decision, issue #259).
  final Map<String, DeliveryPlan> _plans = {};

  /// The task ids whose delivery step is in flight (issue #260): the settle's
  /// first delivery and the watcher's retry share the one plan per task, so
  /// exactly one of them may drive a task's delivery at a time — otherwise two
  /// interleaved [DeliveryPlan.attempt] passes could both reach the once-sent
  /// fallback and push twice. The watcher's retry skips a task another pass is
  /// already delivering; the next pass retries it if it is still owed.
  final Set<String> _delivering = {};

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

    // The orb's boot proved the agent cannot execute (issue #149, spec §6.8):
    // an existing orb's refusal already fired in the targeting, and an orb
    // this spawn just created can boot straight into `broken:shell`. The
    // surface's answer is a settled `refused` record — nothing is dispatched
    // onto it, and `orb_wait`/the card carry the boot's own reason.
    if (OrbState.parse(record.state).isBrokenShell) {
      final refused = OrbTask(
        id: 'task_${_token()}',
        orb: record.id,
        project: record.project,
        orbName: record.name,
        branch: record.branch,
        session: '',
        callerSession: callerSession,
        callerDirectory: callerDirectory,
        callerOrb: await _hostOrbOf(callerSession ?? ''),
        createdOrb: created,
        task: task,
        created: DateTime.now().millisecondsSinceEpoch,
        status: 'refused',
        summary: record.bootReason ?? 'no usable shell',
        completed: DateTime.now().millisecondsSinceEpoch,
        // The image's toolchain (issue #354): the answer carries it even on a
        // refusal — it is a property of the image, not of the run.
        toolchain: OrbEmbedded.toolchain,
      );
      _tasks.insert(0, refused);
      _persist();
      return refused;
    }

    // The task's session on the orb's service (one session per task, so the
    // turn outcome is unambiguous for completion detection).
    final session = await orbs.createSessionOnOrb(record.id);

    // The model: the caller's explicit one, else the calling session's
    // (spec §8.2's default), best-effort.
    final effective = model ?? await _callerModel(callerSession);
    if (effective != null) {
      try {
        await sessions.service.setModel(session.id, effective);
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
      // The sandbox image's toolchain (issue #354, acceptance #1): the
      // driver reads the toolchain off the spawn answer instead of spending
      // a probe orb. It is the image definition's own pins —
      // `OrbEmbedded.toolchain` parses the Dockerfile's ARG defaults — so a
      // pin that moves there moves the answer with it (never a prose copy).
      toolchain: OrbEmbedded.toolchain,
    );
    _tasks.insert(0, dispatched);
    _persist();

    try {
      await sessions.service.prompt(session.id, task);
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

  /// Block until the task completes; returns the settled record (an
  /// already-completed task returns immediately). Used by `wait: true` and
  /// by the tool-facing `orb_wait`.
  ///
  /// [grace] (the bounded blocking wait, issue #143) caps how long the call
  /// holds: when set and the task is still running at the deadline, the task
  /// is returned **as it stands** (`status: running`) — the watcher keeps
  /// polling, so a later call still sees the task through, and the
  /// completion injection (spec §8.3) wakes the caller when it settles.
  ///
  /// Every caller passes [waitGrace] (issue #169): an unbounded wait holds the
  /// HTTP response past the agent tool's own fetch timeout, and the caller
  /// reads the killed connection as "the bridge is unreachable" — the bridge
  /// is up, only its answer came too late. A long task is the norm; the wait
  /// is bounded to match.
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
    return _awaitCompletion(found, grace: waitGrace);
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
        if (row.project == projectId && !OrbState.parse(row.state).isOrphan)
          row,
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
    // A shell-less orb is refused before the wake: waking it cannot help
    // (the probe fails on every start — the entrypoint's stage §6.8), and
    // the refusal must carry the boot's own reason (issue #149).
    final s = OrbState.parse(row.state);
    if (s.isBrokenShell) throw _noShellRefusal(row);
    if (s.isRunning) return row;
    if (s.isWakeable) return orbs.wake(row.id); // == isSpawable, non-running
    throw OrbRefusalError(
      OrbRefusalError.notRunning,
      'the project orb ${row.name} is ${row.state} — spawn refused',
    );
  }

  /// The spawn refusal of an orb whose agent cannot run a command (issue
  /// #149, spec §6.8): the caller gets "spawned, works nowhere" said with
  /// the cause, never a dispatch that buys a well-written "I can't".
  OrbRefusalError _noShellRefusal(OrbRecord row) => OrbRefusalError(
    OrbRefusalError.noShell,
    row.bootReason ??
        'the orb ${row.name} failed its boot shell probe: its agent cannot '
            'run a command, so no code task can land on it',
  );

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
          if (row.project == projectId && !OrbState.parse(row.state).isOrphan)
            row.name,
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
      for (final project in await sessions.service.projects()) {
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
        final projects = await sessions.service.projects();
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
      return await sessions.service.currentModel(callerSession);
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
        if (!OrbState.parse(row.state).isOrphan &&
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

  /// Re-watch the persisted tasks the bridge (or the service) still owes
  /// work on (issue #212): the ones still running (their completion is not
  /// yet detected) and the settled ones whose completion has not been
  /// delivered to the caller (the record's **owed** fact — the injection was
  /// attempted and failed, the push went out once, and the in-app retry is
  /// owed until the caller is reachable again). Their orb sessions live on,
  /// and the injection target a possibly-dead caller (dropped then, spec
  /// §8.3). The settled tasks' delivery plans are also restored here, from
  /// the records' persisted facts, so the retry resumes and the once-sent
  /// fallback is never re-sent (issue #260, the policy's **durable**
  /// decision).
  Future<void> _resume() async {
    for (final task in _tasks) {
      if (task.isDone) planFor(task);
    }
    if (_tasks.any(_owesWork)) _startWatching();
  }

  void _startWatching() {
    if (_watching || _closed) return;
    _watching = true;
    unawaited(_watch());
  }

  /// Stops the completion watcher (the bridge's [BridgeServer.stop]).
  void close() => _closed = true;

  /// Whether the watcher still owes [task] work (issue #212, #260): it is
  /// running (its completion is not yet detected), or it settled while its
  /// caller was unreachable and still owes the completion delivery — the
  /// record's explicit **owed** fact ([OrbTask.deliveryOwed], true only for a
  /// settled task with a reachable-in-principle caller that has not landed).
  bool _owesWork(OrbTask task) => !task.isDone || task.deliveryOwed;

  /// The tasks the watcher still owes, for the loop's stop condition.
  List<OrbTask> _owed() => _tasks.where(_owesWork).toList();

  Future<void> _watch() async {
    while (!_closed && _owed().isNotEmpty) {
      for (final task in List.of(_tasks)) {
        if (task.isDone) {
          // Settled but still owed (issue #212, #260): the caller was
          // unreachable when it settled — retry the in-app injection on this
          // pass through the delivery plan (the once-sent fallback is never
          // re-sent; the policy owns that, not the retry step).
          if (_owesWork(task)) await _retryDelivery(task);
        } else {
          try {
            await _check(task);
          } catch (_) {
            // A transient service failure: the next pass retries.
          }
        }
      }
      if (_owed().isEmpty) break;
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
        for (final row in await sessions.service.projects()) {
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
  ///
  /// A session that reports **no outcome** can still end its task (issue
  /// #169): opencode persists no `outcome` for a turn whose session was
  /// migrated to the host when its orb stopped, so that session answers 200
  /// without one forever. [settleIdleWindow] of idle reads (the session not
  /// in the service's active list either) settle the task as `succeeded` —
  /// the turn ended, its outcome was simply never recorded. Likewise a
  /// session the service reports **gone** (404) for [settleMissingWindow]
  /// can never report an outcome again: its task settles `failed`. The
  /// windows are wall time, not read counts: the watcher and a concurrent
  /// waiter poll the same task, so only time separates a settled turn from a
  /// dispatch whose agent has not started its first step. Any other read
  /// error is transient (a transport failure, a degraded orb pass) and
  /// counts for nothing — the next pass retries.
  ///
  /// The 404 is conclusive only when the task's orb is actually **routable**
  /// (issue #211/#276). The task service does not decide that itself — it
  /// *asks* the live-upstream module (issue #274) for the per-orb verdict,
  /// and settles `failed` only on [UpstreamVerdict.reachable] (the composite
  /// has an upstream, so a session it 404s is a gone one) or
  /// [UpstreamVerdict.gone] (the orb was deleted out from under the task).
  /// On [UpstreamVerdict.unroutable] (the orb is in a readable list but has
  /// no upstream — still booting, stopped, broken) or [UpstreamVerdict.unknown]
  /// (docker down — the list cannot be read, and the composite degrades
  /// host-only), the 404 is the host fallback, not proof the session is gone,
  /// so it is inconclusive and the window restarts once the orb is routable
  /// again. Counting it would settle a mid-flight task `failed` while the
  /// work still runs: the task stays `running` until the orb is routable and
  /// the turn ends for real (or the session is genuinely lost, which the
  /// routable-orb window then settles).
  Future<void> _check(OrbTask target) async {
    if (target.isDone) return;
    final now = DateTime.now();
    final SessionDetail detail;
    try {
      detail = await sessions.detailWithActive(target.session);
    } on OpencodeServiceError catch (e) {
      _idleSince.remove(target.id);
      if (e.statusCode == HttpStatus.notFound) {
        if (!await _missingReadConclusive(target)) {
          // The orb is not up yet (still booting): the 404 is the composite's
          // fallback to a host that cannot know the orb session, not proof
          // the session is gone (issue #211). The window restarts once the
          // orb is running again.
          _missingSince.remove(target.id);
          return;
        }
        final since = _missingSince.putIfAbsent(target.id, () => now);
        if (now.difference(since) >= settleMissingWindow) {
          // The session itself is gone: no turn outcome can ever arrive.
          await _settle(
            target,
            'failed',
            'the orb session no longer exists — its result was lost with it',
          );
        }
        return;
      }
      rethrow;
    }
    _missingSince.remove(target.id);
    final outcome = detail.outcome;
    if (outcome == null) {
      if (detail.active) {
        _idleSince.remove(target.id);
        return;
      }
      final since = _idleSince.putIfAbsent(target.id, () => now);
      if (now.difference(since) < settleIdleWindow) return;
      // A session parked on a permission question is not done: the human
      // answering later resumes the turn, and settling now would announce a
      // completion that never happened.
      try {
        if ((await sessions.service.pendingPermissions(target.session))
            .isNotEmpty) {
          _idleSince.remove(target.id);
          return;
        }
      } on OpencodeServiceError {
        return; // Permissions unknown: the next pass retries the settle.
      }
      // Idle and outcome-less for a full settle window: the turn is over.
      await _settle(
        target,
        'succeeded',
        'the orb session ended its turn (no outcome was reported)',
      );
      return;
    }
    _idleSince.remove(target.id);
    // The reads below cross the event loop, so a concurrent waiter (the
    // `wait: true` path polls too) may have completed the task in the
    // meantime: the settle below is guarded on the task still being open.
    if (target.isDone) return;
    String summary = '';
    try {
      final messages = await sessions.service.getMessages(target.session);
      for (final message in messages.reversed) {
        if (message.role == 'assistant' && (message.text ?? '').isNotEmpty) {
          summary = message.text!;
          break;
        }
      }
    } catch (_) {
      // No summary is a fine degraded completion.
    }
    await _settle(target, outcome, summary);
  }

  /// Whether [target]'s missing-session 404 is conclusive (issue #211/#276):
  /// whether the session is actually gone, or merely unreadable for now.
  ///
  /// The task service does **not** re-derive anything — it *asks* the
  /// live-upstream module (issue #274) for the per-orb verdict and reads the
  /// answer off the module's own derivation,
  /// [UpstreamVerdictAgreement.missingReadConclusive] (issue #277): the same
  /// single reachability predicate (`OrbUpstream.reachable`) the composites
  /// read, so a change to it moves every consumer's answer together, not
  /// independently, and the structural contract
  /// (`test/bridge/orb/orb_upstream_contract.dart`) pins that this service
  /// reads it. The per-verdict semantics (which verdicts settle, which hold
  /// the window open) are documented with the derivation itself — this
  /// method is the read, nothing else.
  Future<bool> _missingReadConclusive(OrbTask target) async =>
      (await upstreams.verdict(target.orb)).missingReadConclusive;

  /// The single settle path (issue #169, decomposed by issue #260): the
  /// terminal fields, a persist, **one named delivery step**, a persist, and
  /// the re-arm. Guarded: a concurrent pass may have settled the task across
  /// the event loop.
  ///
  /// The settled state is persisted **before** the delivery (issue #212): a
  /// process that dies mid-delivery leaves a settled, still-owed record that
  /// a restart resumes as a retry (never a re-settle — so the push, sent once
  /// by the policy inside the delivery, can never be re-sent), not a
  /// re-settle.
  Future<void> _settle(OrbTask target, String status, String summary) async {
    _idleSince.remove(target.id);
    _missingSince.remove(target.id);
    if (target.isDone) return;
    // (a) The terminal fields: the status, the summary (or the settle's own
    // reason when there is none to report), and the PR.
    target.status = status;
    target.summary = summary;
    target.pr = await _prUrl(target);
    // The read above crossed the event loop: a concurrent settler (the
    // watcher and a waiter poll the same task) may have completed it in the
    // meantime. The settle below is single-shot — it delivers the completion
    // once — so re-guard on the task still being open.
    if (target.isDone) return;
    target.completed = DateTime.now().millisecondsSinceEpoch;
    // (b) Persist the settled state **before** the delivery (issue #212): the
    // delivery is freshly owed (for a task with a caller), so a process that
    // dies before the delivery resumes the retry on restart (never a
    // re-settle) — the same "persist not-yet-notified before delivery" the
    // original relied on. A no-caller task is not owed (nothing to deliver).
    final caller = target.callerSession;
    target.applyDeliveryState(
      owed: caller != null && caller.isNotEmpty,
      fallbackSent: false,
    );
    _persist();
    // (c) The named delivery step (issue #260): the in-app injection as the
    // primary channel and the push as the once-sent fallback, decided by the
    // delivery-policy module. The record's explicit delivery facts are the
    // plan's resulting state — the record is the truth, not a return value
    // of a delivery call.
    await _deliverCompletion(target);
    // (d) Persist the delivery facts (owed / fallback-sent): a restart reads
    // them back and resumes the retry without re-sending the fallback.
    _persist();
    // (e) Re-arm: the delivery is still owed (the record's explicit fact) —
    // make sure the watcher is alive to retry the injection on the next
    // chance the caller is reachable (issue #212). A no-op when the watcher
    // already runs.
    if (target.deliveryOwed) _startWatching();
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

  /// The delivery channels of a settle (issue #260): the in-app injection as
  /// the **primary** (retried until it lands) and the push as the **fallback**
  /// (sent at most once), in the policy's order (the primary first).
  List<DeliveryChannel> _deliveryChannels() => [
    const DeliveryChannel(ChannelRole.primary, name: 'in-app'),
    const DeliveryChannel(ChannelRole.fallback, name: 'push'),
  ];

  /// The plan a freshly-settled task is delivered through (issue #260): a
  /// [DeliveryPlan] built on the settle's first delivery step, when the
  /// delivery is newly owed. The same channels, the same send, and durable —
  /// the plan is never itself serialized; the record owns the durable state
  /// (its [OrbTask.deliveryOwed] / [OrbTask.fallbackSent] facts), and
  /// [planFor] rebuilds a restarted bridge's plan from them.
  DeliveryPlan _newPlan(OrbTask target) {
    final plan = DeliveryPlan(
      channels: _deliveryChannels(),
      send: (channel) => _sendOn(channel, target),
      durable: true,
    );
    _plans[target.id] = plan;
    return plan;
  }

  /// The delivery plan of [target] (issue #260): the owner of its **owed** /
  /// **once-sent** decisions, one per settled task. Returns the in-memory plan
  /// when one exists (the settle built it), and otherwise **restores** one
  /// from the record's persisted facts ([OrbTask.deliveryOwed] /
  /// [OrbTask.fallbackSent]) — the restart path, where a restored plan resumes
  /// the retry and never re-sends the once-sent fallback (the policy's
  /// **durable** decision). The record owns the durable state; the plan is
  /// rebuilt from it.
  DeliveryPlan planFor(OrbTask target) {
    final existing = _plans[target.id];
    if (existing != null) return existing;
    final plan = DeliveryPlan.restore(
      channels: _deliveryChannels(),
      send: (channel) => _sendOn(channel, target),
      durable: true,
      state: DeliveryState(
        owed: target.deliveryOwed,
        fallbackSent: target.fallbackSent,
      ),
    );
    _plans[target.id] = plan;
    return plan;
  }

  /// The one named delivery step (issue #260, acceptance #2): build the
  /// settled task's plan fresh, then drive the task's delivery while it is the
  /// only pass allowed to (the settle holds the lock; the watcher's retry skips
  /// a task the settle is still delivering — see [_delivering]).
  Future<void> _deliverCompletion(OrbTask target) async {
    final plan = _newPlan(target);
    _delivering.add(target.id);
    try {
      await plan.attempt();
    } finally {
      _delivering.remove(target.id);
    }
    target.applyDeliveryState(
      owed: plan.state.owed,
      fallbackSent: plan.state.fallbackSent,
    );
  }

  /// The watcher's retry of a settled task's delivery (issue #212, #260): the
  /// caller became reachable (it woke, the host service came up, the app
  /// reopened) — attempt the plan again. It goes **through the same plan** the
  /// settle used (or the restored one after a restart), so "push exactly once"
  /// is the policy's **once-sent** fact (the restored plan never re-sends the
  /// fallback), not the retry step happening not to call the push. A task
  /// another pass (the settle) is still delivering is skipped here — its
  /// delivery is in flight, and the next pass retries it if it is still owed.
  Future<void> _retryDelivery(OrbTask target) async {
    if (_delivering.contains(target.id)) return; // the settle is delivering it
    final plan = planFor(target);
    if (!plan.isOwed) return; // nothing owed (a landed delivery): no re-send
    _delivering.add(target.id);
    try {
      await plan.attempt();
    } finally {
      _delivering.remove(target.id);
    }
    target.applyDeliveryState(
      owed: plan.state.owed,
      fallbackSent: plan.state.fallbackSent,
    );
    if (!plan.isOwed) _persist(); // landed: persist the now-not-owed fact
  }

  /// The [DeliveryPlan.send] this service hands its plan (issue #260): the
  /// producer's sender, mapping each channel to its real send and the send's
  /// real outcome to the policy's [SendOutcome]. The policy never sees a
  /// throw (a throwing send is a [SendOutcome.failed] to it); the producer's
  /// own error handling is below. The primary is the in-app injection, the
  /// fallback the out-of-band push.
  Future<SendOutcome> _sendOn(DeliveryChannel channel, OrbTask target) async {
    final caller = target.callerSession;
    if (channel.role == ChannelRole.primary) {
      // The in-app injection is owed on; it lands only when the caller can be
      // reached. A settled task always has a caller (a no-caller task is not
      // owed, so its plan never sends the primary).
      if (caller == null || caller.isEmpty) return SendOutcome.landed;
      final landed = await _injectInto(caller, target);
      return landed ? SendOutcome.landed : SendOutcome.failed;
    }
    // The out-of-band push fallback: dispatched exactly once (the policy's
    // once-sent decision, "never re-sent — not even re-sent after its own
    // failure"); a no-caller or unconfigured push is a no-op the policy
    // records as sent (the delivery is owed on the injection, not the push).
    // The fallback-sent fact is persisted the moment the fallback send is
    // made (issue #212): a crash between the send and the settle's own
    // persist can then never re-arm a second push on a restart — the durable
    // once-sent fact on the record, not a retry step that happens not to push.
    final dispatched = await _pushCompletion(target);
    target.fallbackSent = true; // the policy marks it sent after any send
    _persist();
    return dispatched ? SendOutcome.landed : SendOutcome.failed;
  }

  /// The in-app completion injection (spec §8.3): the message into the
  /// calling session. Returns whether it landed (a dead caller, or a
  /// refusing service, answers false — the notification is then owed, not
  /// dropped).
  Future<bool> _injectInto(String caller, OrbTask target) async {
    final buffer = StringBuffer()
      ..write('Orb ${target.orbName} done — work on branch `${target.branch}`')
      ..write('\nStatus: ${target.status}');
    if (target.summary.isNotEmpty) buffer.write('\n\n${target.summary}');
    final pr = target.pr;
    if (pr != null) buffer.write('\n\nPR: $pr');
    try {
      await sessions.service.prompt(caller, buffer.toString());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The out-of-band push fallback (issue #212): "Orb X done — work on branch
  /// `orb/<id>`" (the PR link once it exists) through the existing FCM path
  /// (issue #24), deep-linked to the calling session — the same place the
  /// in-app injection targets, where the completion message lands when the
  /// app reopens. Returns whether a push was actually dispatched, so the
  /// delivery plan maps the fallback send to a real outcome (issue #260):
  /// `false` when push is not configured (the closure's [notifyProvider]
  /// returns `null` — the in-app retry still owns the delivery then) or the
  /// dispatch throws (a delivery failure never fails the settle).
  Future<bool> _pushCompletion(OrbTask target) async {
    final service = notifyProvider();
    final caller = target.callerSession;
    if (service == null || caller == null || caller.isEmpty) return false;
    final pr = target.pr;
    final body = pr == null
        ? 'work on branch ${target.branch}'
        : 'work on branch ${target.branch} — PR: $pr';
    try {
      await service.send(
        NotifyKind.turnEnded,
        title: 'Orb ${target.orbName} done',
        body: body,
        link: DeepLink.sessionUri(caller).toString(),
      );
      return true;
    } catch (_) {
      // Push is best-effort out-of-band: a delivery failure never fails the
      // settle — the in-app retry keeps owning the delivery.
      return false;
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
