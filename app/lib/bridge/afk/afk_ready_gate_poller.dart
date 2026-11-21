import 'dart:async';

import '../events/bridge_event.dart';
import 'afk_store.dart';
import 'github_reader.dart';

/// The AFK Ready gate's admission poller (spec #376, "The Ready gate and the
/// feed", T2): while armed, it polls the GitHub reader for open issues newly
/// carrying the `ready-for-agent` label, records each in the AFK run store
/// (state `idle`, issue number, title), and emits one ready-admission
/// bridge event on the event hub per admitted issue.
///
/// - **Armed only.** [start] schedules the periodic pass only while
///   [isArmed] is true; the tick re-checks armed, so a disarm racing a start
///   or an in-flight pass admits nothing. [stop] cancels the schedule, and
///   [syncArmed] is the bridge's settings-notification hook (start on arm,
///   stop on disarm). The poller **admits; it never aborts** — a label
///   removal does not touch the store (the run service's concern, a later
///   ticket).
/// - **No duplicates.** An issue with a row already in the store
///   ([AfkStore.runFor]) is not re-admitted or re-emitted; a pass that finds
///   no change emits nothing.
/// - **Failures inert.** A failed read, or a failed store write, admits
///   nothing and emits nothing (the next pass retries).
class AfkReadyGatePoller {
  AfkReadyGatePoller({
    required this.reader,
    required this.store,
    required this.isArmed,
    required this.repo,
    required this.emitEvent,
    this.pollInterval = defaultPollInterval,
  });

  /// The spec's ~60 s pass pace; tests inject milliseconds.
  static const Duration defaultPollInterval = Duration(seconds: 60);

  /// The reader the poller admits through.
  final GitHubReader reader;

  /// The AFK run store the admissions go to.
  final AfkStore store;

  /// The live arming predicate — the poller runs only while this is true.
  final bool Function() isArmed;

  /// The live repo the admissions are scoped to (spec #407, T1): the run rows
  /// are keyed per repo identity, so the poller admits under this repo. Read
  /// live each pass (a change of armed repo is picked up without a restart);
  /// `null` when no repo is armed — the pass is inert (the per-project
  /// poller, one reader per armed repo, lands in T2).
  final String? Function() repo;

  /// The event hub's emit — the ready-admission events go out on it.
  final void Function(String rawPayload) emitEvent;

  /// The pass pace (the spec's ~60 s; tests inject milliseconds).
  final Duration pollInterval;

  Timer? _timer;
  bool _inFlight = false;

  /// Whether the periodic pass is scheduled.
  bool get isPolling => _timer != null;

  /// Start the periodic pass: schedules only while [isArmed]; the tick
  /// re-checks armed, so a disarm racing a start admits nothing. Idempotent
  /// — a start replaces any running schedule.
  void start() {
    stop();
    if (!isArmed()) return;
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  /// Cancel the periodic pass.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Re-sync the schedule with the live arming state: [armed] true starts
  /// (the tick re-checks armed), false stops. Idempotent — the bridge calls
  /// it from its settings notification.
  void syncArmed(bool armed) {
    if (armed) {
      start();
    } else {
      stop();
    }
  }

  /// One pass over the ready issues (the timer's body, and the test seam):
  /// inert when disarmed or when no repo is armed (the rows are keyed per
  /// repo identity); a failed read, or a failed store write, admits nothing
  /// and emits nothing — the next pass retries.
  Future<void> pollOnce() async {
    if (!isArmed()) return;
    final repo = this.repo();
    if (repo == null) return; // No armed repo: nothing to admit under.
    final List<ReadyIssue> ready;
    try {
      ready = await reader.listReadyIssues();
    } catch (_) {
      return;
    }
    for (final issue in ready) {
      // No duplicates: a stored (repo, issue) is not re-admitted or re-
      // emitted.
      if (store.runFor(repo, issue.number) != null) continue;
      try {
        await store.addRun(repo, issue.number, issue.title);
      } catch (_) {
        continue;
      }
      emitEvent(
        bridgeEvent(
          type: BridgeEventType.afkReadyAdmitted,
          data: {'issueNumber': issue.number, 'title': issue.title},
        ),
      );
    }
  }

  void _tick() {
    if (_inFlight) return; // The previous pass still runs.
    _inFlight = true;
    unawaited(pollOnce().whenComplete(() => _inFlight = false));
  }
}
