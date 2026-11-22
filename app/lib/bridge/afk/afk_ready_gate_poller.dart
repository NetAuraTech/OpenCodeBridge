import 'dart:async';

import '../events/bridge_event.dart';
import 'afk_store.dart';
import 'github_reader.dart';

/// The AFK Ready gate's admission poller (spec #407, T2, reshaping #376's
/// single-repo gate): each pass it iterates the **armed** repo identities, and
/// for every armed repo it admits the newly ready issues read from *that repo's
/// own checkout* (its own [GitHubReader], built from that repo's project
/// directory). Each admission is a **repo-scoped** store row (state `idle`, the
/// repo identity, the issue number, the title) and one ready-admission event
/// carrying the repo identity.
///
/// The per-repo rules (unchanged in shape from #376):
/// - **No duplicates per (repo, issue).** A (repo, issue) with a row already in
///   the store ([AfkStore.runFor]) is not re-admitted or re-emitted; a pass
///   that finds no change emits nothing. The pre-scoping flat `afk.run.<issue>`
///   rows are *not* rows of any repo, so they are invisible to this dedup.
/// - **Inert for a disarmed repo.** A repo that is not armed is not polled: its
///   rows are left alone (a disarm holds everything — the run service's
///   concern, user story #24).
/// - **A failed read admits nothing for that repo only.** A `gh` failure in one
///   checkout does not block the others (the #376 F1 posture, per repo); the
///   next pass retries.
///
/// A repo with no resolvable checkout directory (a closed project) is inert for
/// the tick: no reader is built for it, nothing is admitted, and the tick
/// simply goes on to the next repo.
///
/// **Armed only.** [start] schedules the periodic pass; each tick re-reads the
/// armed set live (a disarm mid-pass stops that repo's admissions without a
/// restart). [stop] cancels the schedule, and [syncArmed] is the bridge's
/// settings-notification hook (start when any repo is armed, stop when none is).
/// The poller **admits; it never aborts** — a label removal does not touch the
/// store (the run service's concern, a later ticket).
class AfkReadyGatePoller {
  AfkReadyGatePoller({
    required this.store,
    required this.armedRepos,
    required this.repoDirectories,
    required this.readerFor,
    required this.emitEvent,
    this.pollInterval = defaultPollInterval,
  });

  /// The spec's ~60 s pass pace; tests inject milliseconds.
  static const Duration defaultPollInterval = Duration(seconds: 60);

  /// The AFK run store the admissions go to.
  final AfkStore store;

  /// The live arming — the set of armed repo identities (`owner/repo`), read
  /// each pass (a change of arming is picked up without a restart). Empty is
  /// the inert state: no armed repo means the pass admits nothing.
  final Set<String> Function() armedRepos;

  /// The per-repo directory resolution: the map of repo identity → its
  /// checkout directory (the first list-order project carrying that identity,
  /// per the bridge's project list + [repoIdentityOf]). Resolved on each pass
  /// that has an armed repo (cheap: the project list + one git read per armed
  /// repo — the cost of an armed pass is small anyway), and never when no repo
  /// is armed. A repo identity absent from the returned map has no resolvable
  /// checkout (a closed project): its poll is inert for the tick.
  final Future<Map<String, String>> Function() repoDirectories;

  /// The per-repo reader builder: one [GitHubReader] per (armed) repo, built
  /// from that repo's checkout [directory] (the real [GhGitHubReader] runs
  /// every `gh` call from it). The seam the tests fake to observe the per-repo
  /// admission; the bridge wires [GhGitHubReader] here.
  final GitHubReader Function(String repo, String directory) readerFor;

  /// The event hub's emit — the ready-admission events go out on it.
  final void Function(String rawPayload) emitEvent;

  /// The pass pace (the spec's ~60 s; tests inject milliseconds).
  final Duration pollInterval;

  Timer? _timer;
  bool _inFlight = false;

  /// Whether the periodic pass is scheduled.
  bool get isPolling => _timer != null;

  /// Start the periodic pass. Idempotent — a start replaces any running
  /// schedule. (The armed set is read live on each tick, so an empty arming
  /// simply makes the pass inert rather than stopping it.)
  void start() {
    stop();
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  /// Cancel the periodic pass.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Re-sync the schedule with the arming state: [armed] true starts, false
  /// stops. Idempotent — the bridge calls it from its settings notification
  /// (the tick still re-reads the armed set live, so a later re-arm is picked
  /// up without a restart).
  void syncArmed(bool armed) {
    if (armed) {
      start();
    } else {
      stop();
    }
  }

  /// One pass over the armed repos (the timer's body, and the test seam): inert
  /// when no repo is armed; for each armed repo it reads the ready issues from
  /// the repo's own checkout and admits the new ones (a repo-scoped row + one
  /// event). A repo with no resolvable checkout is skipped; a failed read
  /// admits nothing for that repo only — the others proceed; a failed store
  /// write admits nothing for that (repo, issue).
  Future<void> pollOnce() async {
    final armed = armedRepos();
    if (armed.isEmpty) return;
    final directories = await repoDirectories();
    for (final repo in armed) {
      final directory = directories[repo];
      if (directory == null) {
        continue; // No resolvable checkout: inert for this tick.
      }
      final List<ReadyIssue> ready;
      try {
        ready = await readerFor(repo, directory).listReadyIssues();
      } catch (_) {
        continue; // A `gh` failure for this repo only: the others proceed.
      }
      for (final issue in ready) {
        // No duplicates: a stored (repo, issue) is not re-admitted or
        // re-emitted (a pre-scoping flat row is not a row of any repo).
        if (store.runFor(repo, issue.number) != null) continue;
        try {
          await store.addRun(repo, issue.number, issue.title);
        } catch (_) {
          continue;
        }
        emitEvent(
          bridgeEvent(
            type: BridgeEventType.afkReadyAdmitted,
            data: {
              'repo': repo,
              'issueNumber': issue.number,
              'title': issue.title,
            },
          ),
        );
      }
    }
  }

  void _tick() {
    if (_inFlight) return; // The previous pass still runs.
    _inFlight = true;
    unawaited(pollOnce().whenComplete(() => _inFlight = false));
  }
}
