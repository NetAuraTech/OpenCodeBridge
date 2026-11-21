import 'dart:async';

import '../events/bridge_event.dart';
import '../sessions/backend.dart';
import 'afk_component.dart';
import 'afk_run_state.dart';
import 'afk_store.dart';
import 'github_reader.dart';

/// The session operations the AFK run service rides (spec #376, T3): the
/// feed through the host shared service's existing prompt path, and the
/// session's idle-wait (the long-poll that is the trigger — not the
/// signal). All injected, all faked in the tests.
///
/// - [sessionId] reads the **resident** AFK session's id (the bridge's
///   stored id — created by the **arming** action, never by this service):
///   `null` when no session is armed yet (no shared opencode service, not
///   armed, or the main checkout unresolved) — the service then feeds
///   nothing on this pass and asks again on the next.
/// - [prompt] is the feed: a prompt admitted while the agent is busy parks
///   in the service's durable inbox and runs in order — the service's
///   inbox is the queue, the bridge keeps no feed queue of its own.
/// - [waitIdle] is the wait: `true` when the session's agent loop is idle
///   (the turn is over — go read the issue), `false` when it is still
///   running (or the wait timed out while it ran — ask again next pass).
abstract class AfkSessionPort {
  /// The AFK session's id, or `null` when no session is (yet) armed —
  /// read-only: the run service never creates the session (the arming
  /// action does).
  Future<String?> sessionId();

  /// Feed [text] to the AFK session (the existing prompt path on the host
  /// shared service).
  Future<void> prompt(String text);

  /// The idle-wait (long-poll, 204 at idle): `true` when the session is
  /// idle, `false` when it is still running (the hold timed out).
  Future<bool> waitIdle({Duration? timeout});
}

/// The AFK run's liveness facts (spec #376, T6): the two bridge-side facts
/// that keep a run from being a **lost** one — an AFK-attributed orb in
/// flight (the bridge's own persisted fact: the task record that created the
/// orb was dispatched by the AFK session, and that orb runs a task), and the
/// AFK session's agent loop being active (the session's active state). A run
/// is **live** while either holds; the startup reconciliation reads both and
/// ORs them ([any]) — a live `dispatched` run survives a restart untouched,
/// a `dispatched` run with no liveness and no terminal narration and no PR is
/// lost (routed to the failure path, a silent death is never silent).
///
/// These are the bridge's persisted facts + the session's active state, read
/// at a seam and injected into the run service — **not** the service inbox
/// (spec #376, T6: liveness is "computed from the bridge's own persisted
/// facts … plus the AFK session's active state — not from the service
/// inbox").
class AfkLiveness {
  const AfkLiveness({
    required this.afkOrbsInFlight,
    required this.sessionActive,
  });

  /// A liveness with neither fact (no AFK session armed, or a bridge without
  /// a task service / sessions backend): every run is non-live.
  const AfkLiveness.none() : this(afkOrbsInFlight: 0, sessionActive: false);

  /// The number of AFK-attributed orbs in flight (running a task).
  final int afkOrbsInFlight;

  /// Whether the AFK session's agent loop is active (its id is in the
  /// service's active set).
  final bool sessionActive;

  /// Whether a run is live (an AFK orb in flight, or the session active).
  bool get any => afkOrbsInFlight > 0 || sessionActive;

  @override
  bool operator ==(Object other) =>
      other is AfkLiveness &&
      other.afkOrbsInFlight == afkOrbsInFlight &&
      other.sessionActive == sessionActive;

  @override
  int get hashCode => Object.hash(afkOrbsInFlight, sessionActive);

  @override
  String toString() =>
      'AfkLiveness(afkOrbsInFlight: $afkOrbsInFlight, sessionActive: $sessionActive)';
}

/// The run service's one port implementation: the composite session
/// service's prompt path + idle-wait, over the AFK session the
/// [AfkComponent] owns (its **stored** id — the one the arming action
/// created and persisted). The bridge wires this at startup (the
/// poller-style wiring). The session id is read, never created, here: a
/// disarmed pass must not create the session as a side effect.
class CompositeAfkSessions implements AfkSessionPort {
  CompositeAfkSessions({required this.component, required this.backend});

  /// The AFK subsystem (the stored session id).
  final AfkComponent component;

  /// The composite sessions backend (host + running orbs; the AFK session
  /// is host-only, so its operations resolve to the host); `null` on a
  /// machine with no shared opencode service (no host to place the AFK
  /// session on — the operations degrade to "not available").
  final SessionsBackend? backend;

  @override
  Future<String?> sessionId() async => component.sessionId;

  @override
  Future<void> prompt(String text) async {
    final id = component.sessionId;
    if (id == null) {
      throw StateError('the AFK session is not armed to feed');
    }
    final backend = this.backend;
    if (backend == null) {
      throw StateError('no shared opencode service to feed the AFK session');
    }
    await backend.service.prompt(id, text);
  }

  @override
  Future<bool> waitIdle({Duration? timeout}) async {
    final backend = this.backend;
    if (backend == null) return false; // No host: never "idle" here.
    final id = component.sessionId;
    if (id == null) return false; // Not armed: nothing to wait on.
    return backend.service.waitIdle(
      id,
      timeout: timeout ?? const Duration(seconds: 25),
    );
  }
}

/// The AFK run service (spec #376, "The per-issue state machine
/// (bridge-owned)", T3): it drives every run row in the AFK store through
/// the per-issue state machine — `idle → dispatched → pr-open → done`,
/// plus the terminal `failed` — shaped on the orb task service (all
/// dependencies injected: the GitHub reader, the session port, the event
/// hub's emit, the arming predicate, the clock, the poll interval; tests
/// inject milliseconds).
///
/// **The arming is a gate for new work, never a destructive kill** (spec
/// #376, user story #24): the periodic pass runs from [start] to [stop]
/// regardless of the arming state, and it keeps driving **in-flight** runs
/// (`dispatched`, `pr-open`, `failed`) to their PR or failure — only the
/// steps that start new work (the `idle → dispatched` feed and the
/// deliberate retry's re-dispatch) read [isArmed] and wait while it is
/// false.
///
/// The per-state work, one pass ([pollOnce], the timer's body and the test
/// seam):
/// - **`idle`** (can dispatch): **armed** and the issue still carries the
///   `ready-for-agent` label → the feed goes out — a **pure availability
///   notice** (issue number + title, nothing more, the charter's) through
///   the existing prompt path — and the row is `dispatched`. Disarmed, an
///   admitted issue simply waits (no feed, no state change).
/// - **`dispatched`**: a pending retry re-feeds once its backoff deadline
///   ([AfkRun.retryAt]) has passed (an **ordinary FIFO feed** — the same
///   prompt as any feed, no priority over newer feeds). Otherwise the
///   service waits (the idle-wait long-poll, the **trigger**): while the
///   session is still running it reads nothing; at idle it reads the
///   issue's last comment — the agent's **terminal narration**, the run's
///   **signal**:
///   - `PR opened: <url>`: the bridge confirms the PR is open (its number
///     and URL recorded on the row) and the run is `pr-open`; one
///     `afk.pr_open` event goes on the hub. An unconfirmable PR (the read
///     fails, the PR is not open) leaves the run in flight — the next pass
///     re-reads.
///   - `FAILED: <reason>` with retries remaining (up to [maxRetries]): the
///     row's retry count increments and the re-feed is scheduled at the
///     backoff deadline (5 min after the 1st, 10 min after the 2nd) — no
///     event (a retry is not a "look now" moment).
///   - `FAILED: <reason>` with retries exhausted: the run is `failed` —
///     the issue is labelled `needs-triage` with a comment, and one
///     `afk.failed` event goes on the hub (the hand-back to the human).
///   - Any other last comment (or a narration already processed — its id
///     is on the row) is a no-op: the service keeps waiting.
/// - **`pr-open`**: the bridge follows the PR to the run's end — the issue
///   closed, or the PR closed unmerged (recorded as such — the PR's fate
///   is a human decision, not a system error) → the run is `done`. A
///   `FAILED`-like narration read here is a no-op (a run with an open PR
///   is **never** retried).
/// - **`failed`**: first the hand-back stands (the `needs-triage` label +
///   comment, re-attempted until they land). Then the deliberate retry —
///   the human re-adds the `ready-for-agent` label, the system is **armed**
///   → the feed goes out again and the run is `dispatched` with the retry
///   counter reset. Disarmed, the re-dispatch waits (the label stands for
///   the arm).
/// - **`done`**: the end; the pass does nothing.
///
/// **Failures are inert**: a failed read, feed, or store write changes
/// nothing and emits nothing — the next pass retries (the poller's
/// posture). A pass that finds no change emits nothing. A row in an
/// unknown state (a corrupted string) is left alone — the refusal, never
/// an implicit admission.
class AfkRunService {
  AfkRunService({
    required this.reader,
    required this.store,
    required this.sessions,
    required this.emitEvent,
    required this.isArmed,
    required this.liveness,
    this.pollInterval = defaultPollInterval,
    DateTime Function()? now,
    this.maxRetries = defaultMaxRetries,
    Duration Function(int retryNumber)? retryBackoff,
  }) : _now = now ?? DateTime.now,
       retryBackoff = retryBackoff ?? defaultRetryBackoff;

  /// The run service's pass pace (the spec's Ready gate polls at ~60 s; the
  /// runs' narrations and closures are followed at a comparable pace).
  /// Tests inject milliseconds.
  static const Duration defaultPollInterval = Duration(seconds: 30);

  /// The run's retry bound (spec #376: "bounded retries (three)"): a
  /// `FAILED` narration re-feeds the run at most this many times; the
  /// next one is the terminal failure.
  static const int defaultMaxRetries = 3;

  /// The retry backoff (spec #376: "5 / 10 minutes"): 5 min after the 1st
  /// retry, 10 min after the 2nd (and every retry after — the bound's
  /// last). [retryNumber] is the retry being scheduled (1-based).
  static Duration defaultRetryBackoff(int retryNumber) => retryNumber == 1
      ? const Duration(minutes: 5)
      : const Duration(minutes: 10);

  /// The gate's entry label (the run service's ready-check and the
  /// deliberate retry's), shared with the reader's listing.
  static const String readyLabel = GhGitHubReader.readyLabel;

  /// The terminal failure's hand-back label (spec #376: the issue is
  /// labelled `needs-triage` with a comment).
  static const String needsTriageLabel = 'needs-triage';

  /// The GitHub reader the service reads through (the issue's labels, the
  /// last comment, the issue/PR state; the terminal failure's writes).
  final GitHubReader reader;

  /// The AFK run store the rows live in (the one home for the machine
  /// state).
  final AfkStore store;

  /// The session operations (the feed, the idle-wait) — injected, faked in
  /// the tests.
  final AfkSessionPort sessions;

  /// The event hub's emit — the run's `afk.pr_open` / `afk.failed` events
  /// go out on it (the push mapping is the push ticket, T5).
  final void Function(String rawPayload) emitEvent;

  /// The live arming predicate — the **new-work gate** (user story #24):
  /// the `idle → dispatched` feed and the deliberate retry's re-dispatch
  /// wait while this is false; the in-flight runs' steps (the follow, the
  /// completion, the hand-back) do not read it, so a disarm never strands
  /// a run in flight (it finishes to its PR or failure).
  final bool Function() isArmed;

  /// The liveness facts the startup reconciliation reads (spec #376, T6):
  /// the AFK-attributed orbs in flight (the bridge's own persisted fact) and
  /// the AFK session's active state, injected as a closure the bridge wires
  /// (it owns the task service + sessions backend the facts are read from).
  /// A run is live while either holds; the reconciliation ORs them via
  /// [AfkLiveness.any]. Injected, faked in the tests.
  final Future<AfkLiveness> Function() liveness;

  /// The pass pace (tests inject milliseconds).
  final Duration pollInterval;

  /// The clock (tests inject one): the backoff deadlines are read against
  /// it — no test sleeps for real minutes.
  final DateTime Function() _now;

  /// The run's retry bound (injectable; [defaultMaxRetries]).
  final int maxRetries;

  /// The retry backoff (injectable; [defaultRetryBackoff]).
  final Duration Function(int retryNumber) retryBackoff;

  Timer? _timer;
  bool _inFlight = false;

  /// Whether the periodic pass is scheduled.
  bool get isPolling => _timer != null;

  /// Start the periodic pass (the bridge calls it once, at startup). The
  /// pass runs from here to [stop] **regardless of the arming state** — the
  /// arming is a gate for the new-work steps, not a switch for the loop
  /// (user story #24: a disarm must let in-flight runs finish). It also runs
  /// the **startup reconciliation** ([reconcile], spec #376, T6) once, before
  /// the periodic pass begins ticking — a lost run is detected and routed to
  /// the failure path, a `pr-open` run is settled to its closure, and a live
  /// `dispatched` run is left alone (it continues on its own). Idempotent —
  /// a start replaces any running schedule.
  void start() {
    stop();
    _runGuarded(
      reconcile,
    ); // The startup reconciliation (guarded with the pass).
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  /// Cancel the periodic pass (the bridge calls it from [stop]).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass over every run row (the timer's body, and the test seam): each
  /// row is driven by its state, one step — the new-work steps gated on
  /// [isArmed], the in-flight steps ungated — and a failed read, feed, or
  /// store write changes nothing (the next pass retries).
  Future<void> pollOnce() async {
    for (final run in store.runs()) {
      try {
        await _advance(run);
      } catch (_) {
        // A transient failure: the row is unchanged, the next pass retries.
      }
    }
  }

  void _tick() {
    _runGuarded(pollOnce);
  }

  /// Run [body] once, guarded: a previous pass (or the startup
  /// reconciliation) still running skips this one. The guard is shared with
  /// the [start] reconciliation, so the two never walk the store concurrently.
  void _runGuarded(Future<void> Function() body) {
    if (_inFlight) return; // The previous pass still runs.
    _inFlight = true;
    unawaited(body().catchError((_) {}).whenComplete(() => _inFlight = false));
  }

  // ------------------------------------------------------------------------
  // The startup reconciliation (spec #376, T6): "a restart never strands a
  // run". One pass over every stored run at startup (before the periodic
  // pass ticks): a lost run is detected and routed to the failure path, a
  // `pr-open` run is settled to its closure, and a live `dispatched` run is
  // left alone (it continues on its own — the orb-completion injection
  // re-wakes the agent, which produces the narration).

  /// The reason a run was detected lost at a startup reconciliation (no
  /// liveness, no terminal narration, no PR): what the fresh agent's
  /// bootstrap and the terminal-failure hand-back name.
  static const String lostRunReason =
      'the run was lost across a restart (no liveness, no terminal '
      'narration, no PR)';

  /// The startup reconciliation: every stored run is driven by its state —
  /// `idle`, `failed`, and `done` are left alone (the first regular pass
  /// feeds the idle run, the failed run waits for the human's re-label, and
  /// `done` is the end); `dispatched` is checked for liveness (live → left
  /// alone, non-live with no progress → the lost run's failure path); and
  /// `pr-open` is settled to its closure. **Not armed-gated** — a disarm
  /// never strands an in-flight run (user story #24); the reconciliation
  /// finishes a lost run to its failure regardless of the arming. A failed
  /// read, or a failed store write, changes nothing (the periodic pass — or
  /// the next startup — retries).
  Future<void> reconcile() async {
    for (final run in store.runs()) {
      try {
        await _reconcileRun(run);
      } catch (_) {
        // A transient failure: the row is unchanged, the next pass retries.
      }
    }
  }

  /// Drive [run] one step in the startup reconciliation, by its state.
  Future<void> _reconcileRun(AfkRun run) async {
    switch (AfkRunState.parse(run.state).kind) {
      case AfkRunStateKind.dispatched:
        await _reconcileDispatched(run);
        break;
      case AfkRunStateKind.prOpen:
        // Follow the PR to the run's closure (the periodic pass does the
        // same; at startup the closure is settled immediately, spec #376's
        // "pr-open → follow the issue to closure").
        await _complete(run, AfkRunState.parse(run.state));
        break;
      case AfkRunStateKind.idle:
      case AfkRunStateKind.failed:
      case AfkRunStateKind.done:
        // Left alone: the idle run is admitted as usual by the first regular
        // pass (the gate's entry), the failed run waits for the human (the
        // re-label is the only way out), and done is the end.
        break;
      case null:
        // A corrupted state string: left alone — the refusal, never an
        // implicit admission.
        break;
    }
  }

  /// The `dispatched` run's reconciliation: a live run (an AFK-attributed orb
  /// in flight, or the AFK session active) is left alone — the run continues
  /// on its own and the orb-completion injection re-wakes the agent. A run
  /// with **no liveness, no terminal narration, and no PR** is **lost** and
  /// is routed to the failure path (counted in the retry; a run that keeps
  /// dying across restarts eventually hits the cap and is handed to the
  /// human — a silent death is never silent). Liveness is the bridge's own
  /// persisted facts + the session's active state, read via [liveness] —
  /// **not** the service inbox.
  Future<void> _reconcileDispatched(AfkRun run) async {
    final liveness = await this.liveness();
    if (liveness.any) return; // Live: the run continues on its own (AC1).
    // No liveness: is there a sign of progress — a terminal narration the
    // periodic pass will process, or a PR the periodic pass will follow?
    final comment = await reader.readLastComment(run.issueNumber);
    final narration = comment == null
        ? null
        : parseTerminalNarration(comment.body);
    if (narration != null) return; // On its way: the periodic pass handles it.
    if (run.prNumber != null) return; // A PR exists: the pass follows it.
    // Lost run: no liveness, no terminal narration, no PR → the failure path.
    await _routeToFailure(run, lostRunReason);
  }

  // ------------------------------------------------------------------------
  // The fresh-agent handoff (spec #376, T6): when the stored AFK session does
  // not exist (first arm on a wiped store, or a lost session), the bridge
  // creates it (checkout directory, pinned model, agent `afk` — the arming
  // action, the [AfkComponent]'s) and the **first feed is a bootstrap**: the
  // in-flight runs (number, state, retry count, last failure reason) from the
  // store, so the recreated agent reconciles with the tracker itself. A plain
  // host-service restart does not lose the session (ids and full state
  // persist), so a normal restart reuses it — no recreation, no re-bootstrap.
  // The bridge triggers [bootstrap] from the arming, after it has ensured the
  // session and learned that it was just created.

  /// Send the bootstrap feed (the fresh-agent handoff's first feed): the
  /// in-flight runs from the store — the runs in `dispatched` or `pr-open`
  /// (the ones with work in motion; `idle` runs get their ordinary feed from
  /// the ready gate, `failed` and `done` runs are terminal) — as one prompt
  /// to the AFK session. Inert when there is no session to feed, or no
  /// in-flight run to reconcile (a wiped store: nothing to hand over).
  Future<void> bootstrap() async {
    final sessionId = await sessions.sessionId();
    if (sessionId == null) return; // No session to feed: nothing to boot.
    final inFlight = store
        .runs()
        .where((run) {
          final kind = AfkRunState.parse(run.state).kind;
          return kind == AfkRunStateKind.dispatched ||
              kind == AfkRunStateKind.prOpen;
        })
        .toList(growable: false);
    if (inFlight.isEmpty) return; // Nothing in flight to reconcile.
    await sessions.prompt(bootstrapFeed(inFlight));
  }

  // ------------------------------------------------------------------------
  // The per-state steps (each one is a state-machine predicate guarded on
  // [AfkRunState] — no ad-hoc state-string comparison).

  /// Drive [run] one step, by its state.
  Future<void> _advance(AfkRun run) async {
    final state = AfkRunState.parse(run.state);
    switch (state.kind) {
      case AfkRunStateKind.idle:
        await _dispatch(run);
        break;
      case AfkRunStateKind.dispatched:
        await _follow(run, state);
        break;
      case AfkRunStateKind.prOpen:
        await _complete(run, state);
        break;
      case AfkRunStateKind.failed:
        // The hand-back (re-attempted until the label lands), then the
        // deliberate retry (the human re-adding the gate's label).
        await _labelNeedsTriage(run);
        await _deliberateRetry(run);
        break;
      case AfkRunStateKind.done:
        // The end: the pass does nothing.
        break;
      case null:
        // A corrupted state string: the row is left alone — the refusal,
        // never an implicit admission.
        break;
    }
  }

  // -- idle → dispatched (the Ready gate's admission feeds the agent) ----

  Future<void> _dispatch(AfkRun run) async {
    final state = AfkRunState.parse(run.state);
    if (!state.canDispatch) return;
    if (!isArmed()) return; // New work waits for the arm (user story #24).
    final ready = await reader.hasLabel(run.issueNumber, readyLabel);
    if (!ready) return; // The gate is the entry: no label, no feed.
    final fed = await _feed(run);
    if (!fed) return; // The session is not (yet) available: ask again.
    await store.updateRun(run.copyWith(state: AfkRunState.dispatchedWire));
  }

  // -- dispatched: the retry backoff, the wait, and the narration ---------

  Future<void> _follow(AfkRun run, AfkRunState state) async {
    if (!state.isDispatched) return;
    // The retry's re-feed, once its backoff deadline has passed: an
    // ordinary FIFO feed (the same prompt as any feed), then the wait
    // resumes on the next pass. The deadline is cleared only when the feed
    // actually went out (a no-session feed is retried on the next pass).
    final retryAt = run.retryAt;
    if (retryAt != null) {
      if (_now().millisecondsSinceEpoch < retryAt) return; // Backoff.
      final fed = await _feed(run);
      if (!fed) return;
      await store.updateRun(run.copyWith(retryAt: null));
      return;
    }
    // The wait (the idle-wait long-poll, the **trigger**): while the
    // session is still running the service reads nothing — the narration
    // is not yet the run's signal.
    final idle = await sessions.waitIdle(timeout: pollInterval);
    if (!idle) return;
    // Idle: go read the issue's last comment — the agent's **terminal
    // narration** (the signal).
    final comment = await reader.readLastComment(run.issueNumber);
    if (comment == null) return;
    if (comment.id == run.narrationId) return; // Already processed.
    final narration = parseTerminalNarration(comment.body);
    if (narration == null) return; // Not a terminal narration: keep waiting.
    await _applyNarration(run, state, comment, narration);
  }

  Future<void> _applyNarration(
    AfkRun run,
    AfkRunState state,
    IssueComment comment,
    TerminalNarration narration,
  ) async {
    switch (narration.kind) {
      case TerminalNarrationKind.prOpened:
        if (!state.canOpenPr) return; // Not in a position to open a PR.
        // The bridge confirms the PR is open (the narration's URL names it)
        // and records its number and URL. An unconfirmable PR (the read
        // fails, the PR is not open) leaves the run in flight — the next
        // pass re-reads (the narration is still the last comment).
        final pr = await _confirmPr(narration.prUrl);
        if (pr == null) return;
        await store.updateRun(
          run.copyWith(
            state: AfkRunState.prOpenWire,
            prNumber: pr.number,
            prUrl: pr.url,
            narrationId: comment.id,
          ),
        );
        emitEvent(
          bridgeEvent(
            type: BridgeEventType.afkPrOpen,
            data: {
              'issueNumber': run.issueNumber,
              'title': run.title,
              'prNumber': pr.number,
              'prUrl': pr.url,
            },
          ),
        );
        break;
      case TerminalNarrationKind.failed:
        if (!state.canRetry && !state.canFail) return;
        // The failure path (the retry, or the terminal failure at the cap) —
        // shared with the startup reconciliation's lost-run detection (T6).
        await _routeToFailure(
          run,
          narration.reason ?? 'the agent reported a failure',
          narrationId: comment.id,
        );
    }
  }

  /// The failure path (spec #376, T3's bounded retry + T6's lost run): a run
  /// that failed is either **retried** (the count increments and the re-feed
  /// is scheduled at the backoff deadline — an ordinary FIFO feed when it
  /// fires, no event: a retry is not a "look now" moment) or, at the retry
  /// cap, **terminally failed** (the hand-back to the human — `failed`, and
  /// one `afk.failed` event on the hub; the issue's `needs-triage` label +
  /// comment ride the `failed` state's pass, re-attempted there until they
  /// land — see [_labelNeedsTriage]).
  ///
  /// [reason] is recorded on the row ([AfkRun.lastFailureReason]) so the
  /// fresh-agent handoff's bootstrap lists why a run is retrying.
  /// [narrationId] is the `FAILED` narration's comment id (the dedup key,
  /// kept — the old narration is still the last comment); the lost-run path
  /// passes none (there is no narration) and leaves the dedup key as it was.
  Future<void> _routeToFailure(
    AfkRun run,
    String reason, {
    String? narrationId,
  }) async {
    if (run.retryCount < maxRetries) {
      // The retry: the count increments and the re-feed is scheduled at the
      // backoff deadline.
      final retryNumber = run.retryCount + 1;
      var next = run.copyWith(
        retryCount: retryNumber,
        retryAt:
            _now().millisecondsSinceEpoch +
            retryBackoff(retryNumber).inMilliseconds,
        lastFailureReason: reason,
      );
      if (narrationId != null) next = next.copyWith(narrationId: narrationId);
      await store.updateRun(next);
    } else {
      // The terminal failure (retries exhausted): the hand-back to the human.
      var next = run.copyWith(
        state: AfkRunState.failedWire,
        lastFailureReason: reason,
      );
      if (narrationId != null) next = next.copyWith(narrationId: narrationId);
      await store.updateRun(next);
      emitEvent(
        bridgeEvent(
          type: BridgeEventType.afkFailed,
          data: {
            'issueNumber': run.issueNumber,
            'title': run.title,
            'reason': reason,
          },
        ),
      );
    }
  }

  /// The `failed` state's pass (spec #376): the terminal failure's
  /// hand-back — the issue is labelled `needs-triage` with a comment
  /// naming the failure. Re-attempted on every pass until it **fully
  /// lands** (a failed `gh` write is inert — the next pass retries): the
  /// hand-back's durability is recorded on the row ([AfkRun.handbackLanded])
  /// — a partial pass (the label landed, the comment write failed) is
  /// retried, so the label alone never short-circuits the missing comment.
  /// The comment is posted once the hand-back has not yet landed, even when
  /// the label is already present (the partial from a previous pass), and
  /// is never duplicated once the row says it landed. The failure's
  /// reason is re-read from the issue (the `FAILED` narration is still its
  /// last comment; a re-read that finds none names the failure without a
  /// reason; a failed read is inert — the next pass retries).
  Future<void> _labelNeedsTriage(AfkRun run) async {
    if (run.handbackLanded) return; // Fully landed: the hand-back stands.
    final labelled = await reader.hasLabel(run.issueNumber, needsTriageLabel);
    final comment = await reader.readLastComment(run.issueNumber);
    final narration = comment == null
        ? null
        : parseTerminalNarration(comment.body);
    var reason = 'the agent reported a failure';
    final narrationKind = narration?.kind;
    if (narrationKind == TerminalNarrationKind.failed &&
        narration != null &&
        narration.reason != null) {
      reason = narration.reason!;
    }
    if (!labelled) {
      await reader.addLabel(run.issueNumber, needsTriageLabel);
    }
    await reader.addComment(run.issueNumber, _failureComment(run, reason));
    await store.updateRun(run.copyWith(handbackLanded: true));
  }

  // -- pr-open → done (the bridge follows the PR to the run's end) -------

  Future<void> _complete(AfkRun run, AfkRunState state) async {
    if (!state.canComplete) return;
    final prNumber = run.prNumber;
    if (prNumber == null) return; // No recorded PR: nothing to follow.
    final pr = await reader.readPr(prNumber);
    // The issue closed → done (the human's review is the exit). The PR
    // closed unmerged also lands here, recorded as such (the PR's fate is a
    // human decision, not a system error). A merged PR with the issue still
    // open is not done yet — the human closes the issue.
    final issueClosed = await reader.readIssueState(run.issueNumber);
    final closedUnmerged = pr?.isClosedUnmerged ?? false;
    if (issueClosed != 'CLOSED' && !closedUnmerged) return;
    await store.updateRun(
      run.copyWith(state: AfkRunState.doneWire, closedUnmerged: closedUnmerged),
    );
  }

  // -- failed → dispatched (the deliberate retry) -------------------------

  Future<void> _deliberateRetry(AfkRun run) async {
    final state = AfkRunState.parse(run.state);
    if (!state.canDispatch) return;
    if (!isArmed()) return; // New work waits for the arm (user story #24).
    // The human re-added the gate's label: the run is dispatched again, the
    // retry counter reset (a fresh bound of retries). The processed
    // narration's id is kept — the old `FAILED` is still the last comment
    // and must not be re-processed; the agent's next narration is a new
    // comment.
    final ready = await reader.hasLabel(run.issueNumber, readyLabel);
    if (!ready) return; // Wait for the human.
    final fed = await _feed(run);
    if (!fed) return; // The session is not (yet) available: ask again.
    await store.updateRun(
      run.copyWith(
        state: AfkRunState.dispatchedWire,
        retryCount: 0,
        retryAt: null,
      ),
    );
  }

  // ------------------------------------------------------------------------
  // The feed (the pure availability notice) and the PR confirmation.

  /// The feed: the AFK session's id must be available (the port creates or
  /// reuses it), and the prompt is the **pure availability notice** — the
  /// issue's number and title, nothing more (the charter's "What a feed
  /// is"). Completes `true` when the prompt went out, `false` when the
  /// session is not (yet) available — the caller then leaves the row as it
  /// stands and asks again on the next pass.
  Future<bool> _feed(AfkRun run) async {
    final sessionId = await sessions.sessionId();
    if (sessionId == null) return false; // Not ready: the next pass asks.
    await sessions.prompt(availabilityNotice(run.issueNumber, run.title));
    return true;
  }

  /// The `pr-open` transition's confirmation (spec #376: "the bridge
  /// confirms the PR is open and records its number"): the narration's URL
  /// names the PR, and the reader's PR read must report it open. `null`
  /// (the read failed, or the PR is not open) refuses the transition — the
  /// run stays in flight and the next pass re-reads.
  Future<PrInfo?> _confirmPr(String? prUrl) async {
    final number = parsePrNumber(prUrl);
    if (number == null) return null; // The URL names no PR.
    final pr = await reader.readPr(number);
    if (pr == null || !pr.isOpen) return null;
    return pr;
  }
}

// --------------------------------------------------------------------------
// The feed's text and the terminal narration (pure, no I/O).

/// The feed's text (spec #376, "The Ready gate and the feed"): the **pure
/// availability notice** — the issue's number and title, nothing more. The
/// agent opens the issue and reads it itself (the charter's "What a feed
/// is"); the bridge hands over no details.
String availabilityNotice(int issueNumber, String title) =>
    'Issue #$issueNumber: $title';

/// The fresh-agent handoff's **bootstrap feed** (spec #376, T6): the first
/// feed a recreated AFK session receives — the in-flight runs (number, state,
/// retry count, last failure reason) from the store, so the agent reconciles
/// with the tracker itself (a restart of the agent loses no work and no
/// state). One line per run; the retry count and last failure reason are
/// listed only when the run carries them (a fresh dispatch has neither, a
/// run at its PR has no failure). Pure, no I/O.
String bootstrapFeed(List<AfkRun> inFlight) {
  final lines = <String>[
    'Bootstrap — the AFK agent session was just recreated. These runs are '
        'in flight (from the bridge\'s store); reconcile with the tracker before '
        'continuing, so the restart loses no work:',
  ];
  for (final run in inFlight) {
    final detail = <String>[
      if (run.retryCount > 0) 'retry ${run.retryCount}',
      if (run.lastFailureReason != null)
        'last failure: ${run.lastFailureReason}',
    ];
    lines.add(
      '- #${run.issueNumber} ${run.title}: ${run.state}'
      '${detail.isEmpty ? '' : ' (${detail.join(', ')})'}',
    );
  }
  return lines.join('\n');
}

/// The shape of the agent's terminal narration on the issue (spec #376:
/// "`PR opened: <url>` or `FAILED: <reason>`"): the run's signal.
class TerminalNarration {
  const TerminalNarration._({required this.kind, this.prUrl, this.reason});

  /// The narration's kind.
  final TerminalNarrationKind kind;

  /// The PR's URL (a `PR opened` narration's `PR opened: <url>`).
  final String? prUrl;

  /// The failure's reason (a `FAILED` narration's `FAILED: <reason>`).
  final String? reason;
}

/// The terminal narration's kinds (the agent's two terminal narrations).
enum TerminalNarrationKind {
  /// `PR opened: <url>` — the run reached a PR.
  prOpened,

  /// `FAILED: <reason>` — the run failed terminally (for the agent).
  failed,
}

/// Parse [body] as a terminal narration, or `null` when it is not one.
///
/// The narration is the line that carries it (the agent's last comment,
/// usually a single line): the first line starting with `PR opened:` or
/// `FAILED:` decides — the prefixes are the contract (the charter's
/// terminal narrations), case-sensitive, with the payload the line's rest
/// (trimmed).
TerminalNarration? parseTerminalNarration(String body) {
  for (final line in body.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('PR opened:')) {
      final url = trimmed.substring('PR opened:'.length).trim();
      if (url.isEmpty) return null;
      return TerminalNarration._(
        kind: TerminalNarrationKind.prOpened,
        prUrl: url,
      );
    }
    if (trimmed.startsWith('FAILED:')) {
      final reason = trimmed.substring('FAILED:'.length).trim();
      return TerminalNarration._(
        kind: TerminalNarrationKind.failed,
        reason: reason.isEmpty ? 'the agent reported a failure' : reason,
      );
    }
  }
  return null;
}

/// The PR number named by its GitHub URL
/// (`https://github.com/<owner>/<repo>/pull/<number>…`), or `null` when the
/// URL is missing or names no PR (the `pr-open` transition's confirmation
/// then refuses — the run stays in flight).
int? parsePrNumber(String? url) {
  if (url == null) return null;
  final match = RegExp(r'/pull/(\d+)').firstMatch(url);
  final number = match?.group(1);
  if (number == null) return null;
  final parsed = int.tryParse(number);
  return parsed;
}

/// The terminal failure's comment on the issue (the hand-back to the
/// human): the failure's reason, the retries the run burned, and the
/// deliberate retry's positive path (re-add `ready-for-agent`).
String _failureComment(AfkRun run, String reason) =>
    'The AFK run failed after ${run.retryCount} retr'
    '${run.retryCount == 1 ? 'y' : 'ies'}: $reason. '
    'This issue is labelled ${AfkRunService.needsTriageLabel}: a human '
    'decision is wanted. To retry deliberately, re-add the '
    '${AfkRunService.readyLabel} label — the run re-dispatches with its '
    'retry counter reset.';
