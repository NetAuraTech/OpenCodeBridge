// The AFK run service (spec #376, "The per-issue state machine
// (bridge-owned)", T3; per repo by spec #407, T4): the feed (a pure
// availability notice through the existing prompt path, gated on the ROW'S
// REPO being armed), the wait (the idle-wait long-poll as the trigger), the
// terminal narration (the run's signal, read through the row's repo's own
// reader), the transitions (pr-open, done — the PR and issue state read from
// the row's repo), the bounded retry with backoff (ordinary FIFO re-feeds),
// the terminal failure (needs-triage + event, the event carrying the row's
// repo), the deliberate retry (gated on the row's repo being armed), and the
// per-repo startup reconciliation (a `gh` failure in one repo leaves that
// repo's rows untouched while the other repos' rows are still settled) —
// all through the faked per-repo GitHub readers and the per-repo session
// port, on an injected clock and a millisecond poll interval (the orb task
// service's pattern): no test sleeps for real minutes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_run_service.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';
import 'package:opencodebridge/bridge/afk/github_reader.dart';

/// A fake [GitHubReader] — the service's only GitHub seam: scripted labels,
/// last comments, issue states, and PRs; recorded writes; no network, no
/// `gh` process. One instance per repo in the service's tests (the per-repo
/// reader the service resolves from the row's repo's checkout directory).
class _FakeReader implements GitHubReader {
  final Map<int, Set<String>> labels = {};
  final Map<int, IssueComment?> lastComments = {};
  final Map<int, String> issueStates = {};
  final Map<int, PrInfo?> prs = {};
  final List<(int, String)> addLabelCalls = [];
  final List<(int, String)> addCommentCalls = [];
  // A scripted `gh` read failure (a failed/unreadable read THROWS — the
  // reader's contract, the same posture as the writes; an absent entry
  // models the genuine "no comments" case and answers null).
  final Set<int> lastCommentReadFails = {};
  // A scripted `gh` write failure for the hand-back (the comment write
  // fails while the label write lands, unless the label write fails too).
  bool addCommentFails = false;
  bool addLabelFails = false;
  int lastCommentCalls = 0;
  int hasLabelCalls = 0;

  @override
  Future<List<ReadyIssue>> listReadyIssues() async => const [];

  @override
  Future<String> readIssueState(int issueNumber) async =>
      issueStates[issueNumber] ?? 'OPEN';

  @override
  Future<IssueComment?> readLastComment(int issueNumber) async {
    lastCommentCalls++;
    if (lastCommentReadFails.contains(issueNumber)) {
      throw StateError('gh issue view failed (simulated gh outage)');
    }
    return lastComments[issueNumber];
  }

  @override
  Future<bool> hasLabel(int issueNumber, String label) async {
    hasLabelCalls++;
    return labels[issueNumber]?.contains(label) ?? false;
  }

  @override
  Future<PrInfo?> readPr(int prNumber) async => prs[prNumber];

  @override
  Future<void> addLabel(int issueNumber, String label) async {
    if (addLabelFails) {
      throw StateError('gh issue edit failed (simulated)');
    }
    addLabelCalls.add((issueNumber, label));
    labels[issueNumber] = {...?labels[issueNumber], label};
  }

  @override
  Future<void> addComment(int issueNumber, String body) async {
    if (addCommentFails) {
      throw StateError('gh issue comment failed (simulated)');
    }
    addCommentCalls.add((issueNumber, body));
  }
}

/// The per-repo reader registry the service's tests fake: the row's repo's
/// reader, resolved through the same provider/builder pair the Ready-gate
/// poller rides (the bridge's `_afkRepoDirectories` + `readerFor` shape).
///
/// The **production arming-scoping** the fake mirrors (spec #407, the review
/// fixups): the run service's directory provider resolves checkouts only for
/// the repos it is told about — its armed set **plus** the repos that still
/// hold rows in the store (so a disarm never strands an in-flight run's
/// directory). [reposToldAbout] is that live set; [directoriesFuture]
/// resolves each of its members to the registered checkout directory (a
/// repo that is told about but has no registered checkout stays absent —
/// inert). A fake that resolved every registered repo regardless of what the
/// provider is told about would pass tests the production wiring fails, so
/// this scoping is part of the harness contract, not an implementation
/// detail.
///
/// The default harness resolves every told-about repo to its own checkout
/// directory and returns that repo's [_FakeReader] — so a cross-repo read
/// (repo A's row read through B's reader/directory) is observable: each
/// reader is a distinct instance and the builder fails for an unknown repo.
class _ReaderTable {
  final Map<String, _FakeReader> readers = {};
  final Map<String, String> directories = {};

  /// The repos the production directory provider is told about, read live:
  /// the run service's armed set ∪ the repos that still hold rows in the
  /// store. Set by the harness [setUp] to the production expression.
  late Set<String> Function() reposToldAbout;

  /// The repo's reader (created on demand).
  _FakeReader readerFor(String repo) =>
      readers.putIfAbsent(repo, _FakeReader.new);

  /// The service's [AfkRunService.repoDirectories] seam: resolves the
  /// directory only for the repos the provider is told about ([reposToldAbout]
  /// ∩ the registered checkouts) — the production arming-scoping the fake
  /// mirrors, never for a repo the provider is not told about.
  Future<Map<String, String>> directoriesFuture() async {
    final toldAbout = reposToldAbout();
    return {
      for (final entry in directories.entries)
        if (toldAbout.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// The service's [AfkRunService.readerFor] seam (throws for an unknown
  /// repo — the builder's failure degrades to the row being inert).
  GitHubReader build(String repo, String directory) {
    final reader = readers[repo];
    if (reader == null) {
      throw StateError('no reader for repo $repo');
    }
    return reader;
  }
}

/// A fake [AfkSessionPort] — the service's session seam (spec #407: scoped
/// per repo): a scripted session id (per repo), recorded feeds keyed by repo
/// (a run of repo A is fed through A's session, never B's), and a scripted
/// idle-wait answer.
class _FakeSessions implements AfkSessionPort {
  /// The session id per repo (`null` for a repo without a scripted id).
  final Map<String, String?> idsByRepo = {};

  /// The recorded feeds, `(repo, text)` — the repo the feed went to.
  final List<(String, String)> prompts = [];

  bool idle = true;
  int waitCalls = 0;

  /// The feeds' text only (the service's tests assert on the notice text).
  List<String> get promptTexts =>
      prompts.map((p) => p.$2).toList(growable: false);

  /// The repos the wait was asked for (the per-repo wait seam, spec #407
  /// T4: a run of repo A is waited on through A's session, never B's).
  final List<String> waitedRepos = [];

  String? idFor(String repo) => idsByRepo[repo];

  @override
  Future<String?> sessionId(String repo) async => idFor(repo);

  @override
  Future<void> prompt(String repo, String text) async {
    prompts.add((repo, text));
  }

  @override
  Future<bool> waitIdle(String repo, {Duration? timeout}) async {
    waitCalls++;
    waitedRepos.add(repo);
    return idle;
  }
}

Map<String, dynamic> _decode(String payload) =>
    jsonDecode(payload) as Map<String, dynamic>;

List<Map<String, dynamic>> _eventsOfType(List<String> payloads, String type) {
  final out = <Map<String, dynamic>>[];
  for (final p in payloads) {
    final d = _decode(p);
    if (d['type'] == type) out.add(d);
  }
  return out;
}

const _min = 60 * 1000;

void main() {
  late Directory dir;
  late File file;
  late AfkStore store;
  late _ReaderTable table;
  late _FakeSessions sessions;
  late List<String> payloads;
  late Set<String> armed;
  late Map<String, bool> sessionActiveByRepo;
  late int orbsInFlight;
  late DateTime clock;
  late AfkRunService service;

  final base = DateTime.utc(2026, 11, 20, 12, 0, 0);

  /// The harness repo (the pre-T4 single-repo shape, now one repo of many):
  /// its session is scripted and its checkout is resolvable.
  const repoA = 'o/r';

  void addRepo(String repo) {
    table.directories[repo] = '/checkouts/$repo';
    table.readerFor(repo);
  }

  /// The row's repo's reader (a test helper on top of the table).
  _FakeReader reader(String repo) => table.readerFor(repo);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-afk-runs');
    file = File('${dir.path}/afk.json');
    store = AfkStore(file: file);
    table = _ReaderTable();
    // The production directory-provider scoping (spec #407, the review
    // fixups): the run service resolves checkouts for the armed repos **plus**
    // the repos that still hold rows in the store (a disarm never strands an
    // in-flight run's directory). Read live so a test's disarm / arming is
    // picked up on the next pass.
    table.reposToldAbout = () => {
      ...armed,
      for (final run in store.allRuns()) run.ownerRepo,
    };
    addRepo(repoA);
    sessions = _FakeSessions()..idsByRepo[repoA] = 'ses_afk';
    payloads = [];
    armed = {repoA};
    sessionActiveByRepo = {}; // No per-repo session active by default.
    orbsInFlight = 0; // No AFK-attributed orb in flight (host total).
    clock = base;
    service = AfkRunService(
      repoDirectories: table.directoriesFuture,
      readerFor: table.build,
      store: store,
      sessions: sessions,
      emitEvent: payloads.add,
      // The per-repo arming gate (spec #407, T4): the row's repo in the
      // armed set.
      isArmed: (repo) => armed.contains(repo),
      // The per-repo liveness (spec #407, T4): the row's repo's session
      // active (per-repo fact) + the AFK-attributed orbs in flight (the
      // host total — any repo's AFK orb keeps every row live).
      liveness: (repo) async => AfkLiveness(
        afkOrbsInFlight: orbsInFlight,
        sessionActive: sessionActiveByRepo[repo] ?? false,
      ),
      pollInterval: const Duration(milliseconds: 5),
      now: () => clock,
    );
  });

  tearDown(() async {
    service.stop();
    await dir.delete(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met in time');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  // ------------------------------------------------------------------------
  // The per-repo routing (spec #407, T4): each row is fed and read through
  // ITS OWN repo's session port and reader — never another repo's.

  group('per-repo routing (spec #407, T4)', () {
    test('a run of repo A is fed through A session and its narration read '
        'through A reader — never B (no cross-repo call)', () async {
      // Two repos, both armed, both resolvable.
      const repoB = 'o/b';
      addRepo(repoB);
      sessions.idsByRepo[repoB] = 'ses_afk_b';
      armed = {repoA, repoB}; // Both repos armed (each on its own session).

      await store.addRun(repoA, 7, 'A run');
      await store.addRun(repoB, 8, 'B run');
      reader(repoA).labels[7] = {'ready-for-agent'};
      reader(repoB).labels[8] = {'ready-for-agent'};
      await service.pollOnce();

      // Both runs dispatched, each fed through ITS OWN session:
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(store.runFor(repoB, 8)!.state, 'dispatched');
      expect(sessions.prompts, [
        ('o/r', 'Issue #7: A run'),
        ('o/b', 'Issue #8: B run'),
      ]);
      // ... and each label read went through the row's repo's reader (no
      // cross-repo read: A's reader only saw A's issue, B's only B's).
      expect(reader(repoA).hasLabelCalls, 1);
      expect(reader(repoB).hasLabelCalls, 1);

      // Both sessions go idle with their narrations; each run's PR is read
      // through ITS OWN repo's reader (A's PR 41 lives in A's reader, B's
      // PR 55 in B's).
      reader(repoA).lastComments[7] = IssueComment(
        id: 'ICA1',
        body: 'PR opened: https://github.com/o/r/pull/41',
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      reader(repoB).lastComments[8] = IssueComment(
        id: 'ICB1',
        body: 'PR opened: https://github.com/o/b/pull/55',
      );
      reader(repoB).prs[55] = PrInfo(
        number: 55,
        url: 'https://github.com/o/b/pull/55',
        state: 'OPEN',
      );
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'pr-open');
      expect(store.runFor(repoA, 7)!.prNumber, 41);
      expect(store.runFor(repoB, 8)!.state, 'pr-open');
      expect(store.runFor(repoB, 8)!.prNumber, 55);
      // Each wait went to the row's repo's session (never the other's):
      // A was waited once through A, B once through B.
      expect(sessions.waitedRepos.where((r) => r == repoA), hasLength(1));
      expect(sessions.waitedRepos.where((r) => r == repoB), hasLength(1));
      // No reader ever read the other repo's issue (the narration read is
      // per repo: A's reader counted 2 reads = label + comment, B's too).
      expect(reader(repoA).hasLabelCalls, 1);
      expect(reader(repoA).lastCommentCalls, 1);
      expect(reader(repoB).hasLabelCalls, 1);
      expect(reader(repoB).lastCommentCalls, 1);
    });

    test(
      'arming B does not feed A idle runs: the feed is gated per repo',
      () async {
        const repoB = 'o/b';
        addRepo(repoB);
        sessions.idsByRepo[repoB] = 'ses_afk_b';
        await store.addRun(repoA, 7, 'A run');
        await store.addRun(repoB, 8, 'B run');
        reader(repoA).labels[7] = {'ready-for-agent'};
        reader(repoB).labels[8] = {'ready-for-agent'};

        // Only B is armed: B's idle run is fed, A's is not (and A's reader is
        // not even read — the new-work gate short-circuits before any GitHub
        // read of A's issue).
        armed = {repoB};
        await service.pollOnce();
        expect(store.runFor(repoB, 8)!.state, 'dispatched');
        expect(store.runFor(repoA, 7)!.state, 'idle');
        expect(sessions.prompts, [('o/b', 'Issue #8: B run')]);
        expect(reader(repoA).hasLabelCalls, 0, reason: 'A was gated out');

        // A is armed: the next pass feeds A too (each on its own session).
        armed = {repoA, repoB};
        await service.pollOnce();
        expect(store.runFor(repoA, 7)!.state, 'dispatched');
        expect(sessions.prompts, [
          ('o/b', 'Issue #8: B run'),
          ('o/r', 'Issue #7: A run'),
        ]);
      },
    );

    test('a repo with no resolvable checkout is inert for its rows (no '
        'crash, no read)', () async {
      const repoB = 'o/b';
      sessions.idsByRepo[repoB] = 'ses_afk_b';
      armed = {repoB}; // The repo is armed (arming is not the point here).
      await store.addRun(repoB, 8, 'B run');
      reader(repoB).labels[8] = {'ready-for-agent'};
      // repoB has no checkout in the resolved directories: the row's reads
      // are inert for the pass (no reader built, no feed, no crash).
      await service.pollOnce();
      expect(store.runFor(repoB, 8)!.state, 'idle');
      expect(sessions.prompts, isEmpty);
      expect(reader(repoB).hasLabelCalls, 0, reason: 'no reader built');

      // The checkout appears: the next pass feeds it.
      addRepo(repoB);
      await service.pollOnce();
      expect(store.runFor(repoB, 8)!.state, 'dispatched');
      expect(sessions.prompts, [('o/b', 'Issue #8: B run')]);
    });
  });

  // ------------------------------------------------------------------------
  // The per-repo liveness (spec #407, T4): the session-active fact is per
  // repo; the AFK-attributed-orbs-in-flight fact is the host total.

  group('per-repo liveness (spec #407, T4)', () {
    test('a dispatched run of A is live while A session is active even if B '
        'is inactive (and vice-versa)', () async {
      const repoB = 'o/b';
      addRepo(repoB);
      sessions.idsByRepo[repoB] = 'ses_afk_b';

      // Case 1: A's session active, B's inactive. Both dispatched runs have
      // no narration and no PR, so liveness is the only thing that keeps
      // them from being lost: A is live (its repo's session is active) and
      // stays untouched, B is not (its repo's session is inactive) and is
      // the lost run (retried once) — the liveness fact is per repo.
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'A run',
          state: 'dispatched',
        ),
      );
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoB,
          issueNumber: 8,
          title: 'B run',
          state: 'dispatched',
        ),
      );
      sessionActiveByRepo = {repoA: true, repoB: false};
      await service.reconcile();
      expect(
        store.runFor(repoA, 7)!.retryCount,
        0,
        reason: 'A is live (A session active, even though B is inactive)',
      );
      expect(
        store.runFor(repoB, 8)!.retryCount,
        1,
        reason: 'B is NOT live (B session inactive) → lost, retried once',
      );

      // Case 2 (vice-versa): fresh runs, B's session active, A's inactive.
      // B is live; A is the lost run (the liveness is per repo, not global).
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 17,
          title: 'A run 2',
          state: 'dispatched',
        ),
      );
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoB,
          issueNumber: 18,
          title: 'B run 2',
          state: 'dispatched',
        ),
      );
      sessionActiveByRepo = {repoA: false, repoB: true};
      await service.reconcile();
      expect(
        store.runFor(repoB, 18)!.retryCount,
        0,
        reason: 'B is live (B session active, even though A is inactive)',
      );
      expect(
        store.runFor(repoA, 17)!.retryCount,
        1,
        reason: 'A is NOT live (A session inactive) → lost, retried once',
      );
    });

    test('an AFK-attributed orb in flight (any repo) keeps a dispatched run '
        'live (the host total, spec #407, T4/AC3)', () async {
      const repoB = 'o/b';
      addRepo(repoB);
      sessions.idsByRepo[repoB] = 'ses_afk_b';
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'A run',
          state: 'dispatched',
        ),
      );
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoB,
          issueNumber: 8,
          title: 'B run',
          state: 'dispatched',
        ),
      );
      // No session active, but an AFK-attributed orb (created by any repo's
      // AFK session) is in flight: the host total keeps BOTH rows live.
      orbsInFlight = 1;
      await service.reconcile();
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(store.runFor(repoA, 7)!.retryCount, 0);
      expect(store.runFor(repoB, 8)!.state, 'dispatched');
      expect(store.runFor(repoB, 8)!.retryCount, 0);
      expect(payloads, isEmpty);
    });
  });

  // ------------------------------------------------------------------------
  // The per-repo startup reconciliation (spec #407, T4; the #376 F1 posture,
  // scoped): a `gh` read failure for repo A at reconciliation leaves A's
  // rows untouched while B's rows are still settled.

  group('per-repo reconciliation (spec #407, T4)', () {
    test('a gh failure in A at reconciliation leaves A rows unchanged while '
        'B rows are still settled (a B pr-open with a closed issue settles '
        'to done)', () async {
      const repoB = 'o/b';
      addRepo(repoB);
      sessions.idsByRepo[repoB] = 'ses_afk_b';
      // A has a lost run (no liveness, no narration — but its read FAILS,
      // simulating the gh outage) — it must stay untouched.
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'A run',
          state: 'dispatched',
        ),
      );
      reader(repoA).lastCommentReadFails.add(7);
      // B has a pr-open run with a closed issue: it settles to done.
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoB,
          issueNumber: 8,
          title: 'B run',
          state: 'pr-open',
          prNumber: 55,
          prUrl: 'https://github.com/o/b/pull/55',
        ),
      );
      reader(repoB).prs[55] = PrInfo(
        number: 55,
        url: 'https://github.com/o/b/pull/55',
        state: 'MERGED',
      );
      reader(repoB).issueStates[8] = 'CLOSED';

      await service.reconcile();
      // A: the failed read is inert (the #376 F1 posture, per repo).
      final a = store.runFor(repoA, 7)!;
      expect(a.state, 'dispatched', reason: 'A untouched by its own outage');
      expect(a.retryCount, 0, reason: 'no retry burned by the outage');
      expect(a.retryAt, isNull);
      expect(a.lastFailureReason, isNull);
      // B: settled to done despite A's outage (the outage is per repo).
      expect(store.runFor(repoB, 8)!.state, 'done');
      expect(payloads, isEmpty);
    });

    test('a lost run of A (no liveness, no narration, no PR) is routed to A '
        'failure path (retry, then terminal at the cap) and emits afk.failed '
        'carrying A repo identity', () async {
      const repoB = 'o/b';
      addRepo(repoB);
      sessions.idsByRepo[repoB] = 'ses_afk_b';
      // A lost run, already at its retry cap (a prior FAILED + retries):
      // the terminal failure.
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'A run',
          state: 'dispatched',
          retryCount: 3,
        ),
      );
      // B has a pr-open run with a closed issue: it settles to done (the
      // reconciliation proceeds for B while A is terminal-failing).
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoB,
          issueNumber: 8,
          title: 'B run',
          state: 'pr-open',
          prNumber: 55,
          prUrl: 'https://github.com/o/b/pull/55',
        ),
      );
      reader(repoB).prs[55] = PrInfo(
        number: 55,
        url: 'https://github.com/o/b/pull/55',
        state: 'MERGED',
      );
      reader(repoB).issueStates[8] = 'CLOSED';

      await service.reconcile();
      // A: terminal failure (lost run at the cap), its event carries A's
      // repo identity.
      expect(store.runFor(repoA, 7)!.state, 'failed');
      expect(
        store.runFor(repoA, 7)!.lastFailureReason,
        AfkRunService.lostRunReason,
      );
      final failedData =
          _eventsOfType(payloads, 'afk.failed').single['data'] as Map;
      expect(failedData['repo'], repoA, reason: 'the event carries A identity');
      expect(failedData['issueNumber'], 7);
      // B: settled to done.
      expect(store.runFor(repoB, 8)!.state, 'done');
    });

    test('the deliberate retry re-dispatches only when the run repo is '
        'armed; the counter resets', () async {
      const repoB = 'o/b';
      addRepo(repoB);
      sessions.idsByRepo[repoB] = 'ses_afk_b';
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'A run',
          state: 'failed',
          retryCount: 3,
          narrationId: 'IC4',
        ),
      );
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoB,
          issueNumber: 8,
          title: 'B run',
          state: 'failed',
          retryCount: 3,
          narrationId: 'IC4',
        ),
      );
      // Both issues re-labelled ready-for-agent (the human's deliberate
      // retry), but only B is armed.
      reader(repoA).labels[7] = {'needs-triage', 'ready-for-agent'};
      reader(repoB).labels[8] = {'needs-triage', 'ready-for-agent'};
      armed = {repoB}; // B only.
      await service.pollOnce();
      // B re-dispatches (its repo armed), counter reset.
      expect(store.runFor(repoB, 8)!.state, 'dispatched');
      expect(store.runFor(repoB, 8)!.retryCount, 0, reason: 'B counter reset');
      // A does NOT re-dispatch (its repo not armed), counter intact.
      expect(store.runFor(repoA, 7)!.state, 'failed');
      expect(store.runFor(repoA, 7)!.retryCount, 3, reason: 'A counter intact');
      expect(sessions.prompts, [('o/b', 'Issue #8: B run')]);

      // A is armed: the next pass re-dispatches A (its counter resets).
      armed = {repoA, repoB};
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(store.runFor(repoA, 7)!.retryCount, 0, reason: 'A counter reset');
      expect(sessions.prompts, [
        ('o/b', 'Issue #8: B run'),
        ('o/r', 'Issue #7: A run'),
      ]);
    });
  });

  // ------------------------------------------------------------------------
  // The per-repo events (spec #407, T4): afk.pr_open and afk.failed carry
  // the row's repo identity.

  group('per-repo events (spec #407, T4)', () {
    test('afk.pr_open carries the row repo identity', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/41',
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      sessions.idle = true;
      await service.pollOnce();
      final prOpenData =
          _eventsOfType(payloads, 'afk.pr_open').single['data'] as Map;
      expect(prOpenData['repo'], repoA);
      expect(prOpenData['issueNumber'], 7);
      expect(prOpenData['prNumber'], 41);
      expect(prOpenData['prUrl'], 'https://github.com/o/r/pull/41');
    });
  });

  group('the feed (idle → dispatched)', () {
    test('a ready issue is fed with the availability notice only and becomes '
        'dispatched', () async {
      await store.addRun(repoA, 7, 'Add a README');
      reader(repoA).labels[7] = {'ready-for-agent'};
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      // The feed is the pure availability notice (number + title, nothing
      // more) — and it is the only thing sent (to o/r's session).
      expect(sessions.prompts, [('o/r', 'Issue #7: Add a README')]);
    });

    test('an idle issue without the ready label is not fed (the gate is the '
        'entry)', () async {
      await store.addRun(repoA, 7, 'Add a README');
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'idle');
      expect(sessions.prompts, isEmpty);
    });

    test('an idle issue with no (yet) available session is not fed (asked '
        'again next pass)', () async {
      await store.addRun(repoA, 7, 'Add a README');
      reader(repoA).labels[7] = {'ready-for-agent'};
      sessions.idsByRepo[repoA] = null;
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'idle');
      expect(sessions.prompts, isEmpty);
      // The session becomes available: the next pass feeds it.
      sessions.idsByRepo[repoA] = 'ses_afk';
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(sessions.prompts, [('o/r', 'Issue #7: Add a README')]);
    });
  });

  group('end to end (fakes)', () {
    test(
      'a ready issue is fed; the PR opened narration + an open PR moves it '
      'to pr-open (PR recorded); closing the issue moves it to done',
      () async {
        await store.addRun(repoA, 7, 'Add a README');
        reader(repoA).labels[7] = {'ready-for-agent'};
        await service.pollOnce(); // dispatch
        expect(store.runFor(repoA, 7)!.state, 'dispatched');

        // The agent posts its terminal narration; the PR is open; the
        // session is idle.
        reader(repoA).lastComments[7] = IssueComment(
          id: 'IC1',
          body: 'PR opened: https://github.com/o/r/pull/41',
        );
        reader(repoA).prs[41] = PrInfo(
          number: 41,
          url: 'https://github.com/o/r/pull/41',
          state: 'OPEN',
        );
        sessions.idle = true;
        await service.pollOnce();
        final prOpen = store.runFor(repoA, 7)!;
        expect(prOpen.state, 'pr-open');
        expect(prOpen.prNumber, 41);
        expect(prOpen.prUrl, 'https://github.com/o/r/pull/41');
        expect(prOpen.closedUnmerged, isFalse);
        expect(_eventsOfType(payloads, 'afk.pr_open'), hasLength(1));
        // The event carries the repo identity (spec #407, T4).
        final prOpenData =
            _eventsOfType(payloads, 'afk.pr_open').single['data'] as Map;
        expect(prOpenData['repo'], repoA);

        // The human's review is the exit: the issue closes.
        reader(repoA).issueStates[7] = 'CLOSED';
        await service.pollOnce();
        expect(store.runFor(repoA, 7)!.state, 'done');
      },
    );
  });

  group('the wait (the idle-wait is the trigger, not the signal)', () {
    test('while the session is still running the service reads nothing; at '
        'idle it reads the narration', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/41',
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      sessions.idle = false; // The agent is still working.
      await service.pollOnce();
      expect(
        reader(repoA).lastCommentCalls,
        0,
        reason: 'the wait did not return idle',
      );
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(sessions.waitCalls, 1);

      // The session goes idle: the service reads the narration.
      sessions.idle = true;
      await service.pollOnce();
      expect(reader(repoA).lastCommentCalls, 1);
      expect(store.runFor(repoA, 7)!.state, 'pr-open');
    });
  });

  group('the pr-open confirmation (the bridge confirms the PR is open)', () {
    test('a PR opened narration is not confirmed while the PR is not open '
        '(the run stays in flight; re-read next pass)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/41',
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'CLOSED',
      );
      sessions.idle = true;
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(payloads, isEmpty);

      // The PR opens: the next pass confirms.
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'pr-open');
      expect(store.runFor(repoA, 7)!.prNumber, 41);
    });

    test(
      'a PR opened narration whose URL names no PR is not confirmed',
      () async {
        await store.updateRun(
          const AfkRun(
            ownerRepo: repoA,
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
          ),
        );
        reader(repoA).lastComments[7] = IssueComment(
          id: 'IC1',
          body: 'PR opened: https://github.com/o/r/issues/41',
        );
        sessions.idle = true;
        await service.pollOnce();
        expect(store.runFor(repoA, 7)!.state, 'dispatched');
        expect(payloads, isEmpty);
      },
    );
  });

  group('the retry (FAILED narration, bounded, with backoff)', () {
    test('a FAILED narration retries up to 3 times with the 5/10 backoff, each '
        're-feed an ordinary FIFO feed; the terminal failure lands failed, '
        'labels needs-triage, and emits the failure event', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      sessions.idle = true;

      // FAILED #1 → retry 1 (5 min).
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'FAILED: model under load',
      );
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(store.runFor(repoA, 7)!.retryCount, 1);
      expect(
        store.runFor(repoA, 7)!.retryAt,
        base.millisecondsSinceEpoch + 5 * _min,
      );
      expect(payloads, isEmpty, reason: 'no push on a retry');

      // In backoff (before the deadline): no re-feed, no read.
      clock = base.add(const Duration(minutes: 4));
      await service.pollOnce();
      expect(sessions.prompts, isEmpty, reason: 'still in backoff');

      // The deadline passes: the re-feed is an ordinary FIFO feed (the same
      // availability notice as any feed).
      clock = base.add(const Duration(minutes: 5));
      await service.pollOnce();
      expect(sessions.prompts, [
        ('o/r', 'Issue #7: Add a README'),
      ], reason: 're-feed #1');
      expect(store.runFor(repoA, 7)!.retryAt, isNull);

      // FAILED #2 → retry 2 (10 min).
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC2',
        body: 'FAILED: model under load',
      );
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.retryCount, 2);
      expect(
        store.runFor(repoA, 7)!.retryAt,
        clock.millisecondsSinceEpoch + 10 * _min,
      );

      // Backoff, then re-feed #2.
      clock = clock.add(const Duration(minutes: 10));
      await service.pollOnce();
      expect(sessions.prompts, hasLength(2), reason: 're-feed #2');

      // FAILED #3 → retry 3 (10 min).
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC3',
        body: 'FAILED: model under load',
      );
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.retryCount, 3);

      // Backoff, then re-feed #3.
      clock = clock.add(const Duration(minutes: 10));
      await service.pollOnce();
      expect(sessions.prompts, hasLength(3), reason: 're-feed #3');

      // FAILED #4 → retries exhausted: the terminal failure.
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC4',
        body: 'FAILED: model under load',
      );
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'failed');
      expect(_eventsOfType(payloads, 'afk.failed'), hasLength(1));
      final failedData =
          _eventsOfType(payloads, 'afk.failed').single['data'] as Map;
      expect(failedData['issueNumber'], 7);
      expect(failedData['title'], 'Add a README');
      expect(failedData['reason'], 'model under load');
      // The repo identity (spec #407, T3/T4): the failure push's deep-link
      // resolves the failed repo's AFK session from this.
      expect(failedData['repo'], repoA);

      // The hand-back rides the failed state's pass: needs-triage label +
      // a comment naming the failure.
      await service.pollOnce();
      expect(reader(repoA).addLabelCalls, contains((7, 'needs-triage')));
      expect(reader(repoA).addCommentCalls, hasLength(1));
      expect(
        reader(repoA).addCommentCalls.single.$2,
        contains('model under load'),
      );
    });

    test(
      'a processed narration is not re-processed (dedup by comment id): a '
      're-feed that posts no new narration does not schedule a 2nd retry',
      () async {
        await store.updateRun(
          const AfkRun(
            ownerRepo: repoA,
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
          ),
        );
        sessions.idle = true;
        reader(repoA).lastComments[7] = IssueComment(
          id: 'IC1',
          body: 'FAILED: boom',
        );
        await service.pollOnce();
        expect(store.runFor(repoA, 7)!.retryCount, 1);
        expect(store.runFor(repoA, 7)!.narrationId, 'IC1');

        // The backoff elapses: the re-feed goes out (retryAt cleared).
        clock = clock.add(const Duration(minutes: 5));
        await service.pollOnce();
        expect(sessions.prompts, [('o/r', 'Issue #7: Add a README')]);
        expect(store.runFor(repoA, 7)!.retryAt, isNull);

        // The agent goes idle again but posts no new narration (the last
        // comment is still IC1): the old narration is not re-processed.
        await service.pollOnce();
        expect(store.runFor(repoA, 7)!.retryCount, 1, reason: 'no 2nd retry');
        expect(store.runFor(repoA, 7)!.retryAt, isNull);
        expect(sessions.prompts, hasLength(1), reason: 'no 2nd re-feed');
      },
    );
  });

  group('a run with an open PR is never retried', () {
    test('a FAILED-like narration after the PR is a no-op (the run stays '
        'pr-open)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      // A spurious/late failure narration.
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC9',
        body: 'FAILED: something broke',
      );
      sessions.idle = true;
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'pr-open', reason: 'never retried');
      expect(store.runFor(repoA, 7)!.retryCount, 0);
      expect(payloads, isEmpty);
      expect(sessions.prompts, isEmpty);
    });
  });

  group('pr-open → done (the bridge follows the PR to the run\'s end)', () {
    test('a PR closed unmerged lands done, recorded as closed unmerged (the '
        'issue may still be open)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'CLOSED',
      );
      reader(repoA).issueStates[7] = 'OPEN';
      await service.pollOnce();
      final run = store.runFor(repoA, 7)!;
      expect(run.state, 'done');
      expect(run.closedUnmerged, isTrue);
    });

    test('a merged PR with the issue still open is not done yet (the human '
        'closes the issue)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'MERGED',
      );
      reader(repoA).issueStates[7] = 'OPEN';
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'pr-open');
    });

    test('a done run is a no-op', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'done',
        ),
      );
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'done');
      expect(payloads, isEmpty);
    });
  });

  group('the deliberate retry (the human re-adds ready-for-agent)', () {
    test('re-labelling a failed issue ready-for-agent re-dispatches it with '
        'the retry counter reset', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'failed',
          retryCount: 3,
          narrationId: 'IC4',
        ),
      );
      reader(repoA).labels[7] = {'needs-triage'};
      // A failed pass with no ready label: the hand-back stands, no re-feed.
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'failed');
      expect(sessions.prompts, isEmpty);

      // The human re-adds the gate's label (the repo is armed).
      reader(repoA).labels[7] = {'needs-triage', 'ready-for-agent'};
      await service.pollOnce();
      final run = store.runFor(repoA, 7)!;
      expect(run.state, 'dispatched');
      expect(run.retryCount, 0, reason: 'the counter is reset');
      expect(sessions.prompts, [('o/r', 'Issue #7: Add a README')]);
    });
  });

  group('the terminal failure hand-back (retried until it fully lands)', () {
    test('a partial hand-back (label landed, comment write failed) is '
        'retried: the next pass posts the comment and marks the row landed '
        '(no duplicate label, exactly one comment across passes)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'failed',
          retryCount: 3,
        ),
      );
      // The label write lands; the comment write fails once.
      reader(repoA).addCommentFails = true;
      await service.pollOnce();
      expect(reader(repoA).addLabelCalls, [
        (7, 'needs-triage'),
      ], reason: 'the label was posted');
      expect(
        reader(repoA).addCommentCalls,
        isEmpty,
        reason: 'the comment failed',
      );
      expect(
        store.runFor(repoA, 7)!.handbackLanded,
        isFalse,
        reason: 'the hand-back is not recorded as landed',
      );
      expect(store.runFor(repoA, 7)!.state, 'failed');

      // The comment write recovers: the next pass sees the label is present
      // but the row says not landed, so it posts the comment and marks the
      // hand-back landed — without a second label.
      reader(repoA).addCommentFails = false;
      await service.pollOnce();
      expect(reader(repoA).addCommentCalls, hasLength(1));
      expect(
        reader(repoA).addCommentCalls.single.$2,
        contains('the agent reported a failure'),
      );
      expect(reader(repoA).addLabelCalls, [
        (7, 'needs-triage'),
      ], reason: 'no duplicate label');
      expect(store.runFor(repoA, 7)!.handbackLanded, isTrue);

      // The hand-back stands: a further pass posts nothing (the landed row
      // short-circuits the hand-back).
      await service.pollOnce();
      expect(reader(repoA).addCommentCalls, hasLength(1));
      expect(reader(repoA).addLabelCalls, hasLength(1));
      expect(store.runFor(repoA, 7)!.handbackLanded, isTrue);
    });

    test(
      'a failed label write posts nothing, marks nothing, and is retried',
      () async {
        await store.updateRun(
          const AfkRun(
            ownerRepo: repoA,
            issueNumber: 7,
            title: 'Add a README',
            state: 'failed',
            retryCount: 3,
          ),
        );
        // The label write fails: the comment is never attempted.
        reader(repoA).addLabelFails = true;
        await service.pollOnce();
        expect(reader(repoA).addLabelCalls, isEmpty);
        expect(reader(repoA).addCommentCalls, isEmpty);
        expect(store.runFor(repoA, 7)!.handbackLanded, isFalse);
        expect(store.runFor(repoA, 7)!.state, 'failed');

        // The write recovers: the next pass posts label + comment and marks
        // the hand-back landed.
        reader(repoA).addLabelFails = false;
        await service.pollOnce();
        expect(reader(repoA).addLabelCalls, [(7, 'needs-triage')]);
        expect(reader(repoA).addCommentCalls, hasLength(1));
        expect(store.runFor(repoA, 7)!.handbackLanded, isTrue);
      },
    );
  });

  group('the failure posture (inert, never a throw)', () {
    test('a run in an unknown state is left alone (the refusal, not an '
        'admission)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'garbage',
        ),
      );
      reader(repoA).labels[7] = {'ready-for-agent'};
      await service.pollOnce();
      expect(store.runFor(repoA, 7)!.state, 'garbage');
      expect(payloads, isEmpty);
    });

    test('disarmed: the pass is a gate for new work, never a stop for '
        'in-flight runs (user story #24, per repo)', () async {
      const repoB = 'o/b';
      addRepo(repoB);
      sessions.idsByRepo[repoB] = 'ses_afk_b';
      // A ready-but-idle issue: disarmed ⇒ no feed, no label read, no state
      // change (the new-work gate reads no GitHub at all).
      await store.addRun(repoA, 7, 'Add a README');
      reader(repoA).labels[7] = {'ready-for-agent'};
      armed = {}; // Nothing armed.
      await service.pollOnce();
      expect(reader(repoA).hasLabelCalls, 0);
      expect(store.runFor(repoA, 7)!.state, 'idle');
      expect(sessions.prompts, isEmpty);

      // An in-flight run in the same disarmed pass: the follow does not read
      // the arming — at idle it reads the narration and the PR-open
      // transition still lands (a run finishes to its PR through a disarm).
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 9,
          title: 'Ship the widget',
          state: 'dispatched',
        ),
      );
      reader(repoA).lastComments[9] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/42',
      );
      reader(repoA).prs[42] = PrInfo(
        number: 42,
        url: 'https://github.com/o/r/pull/42',
        state: 'OPEN',
      );
      sessions.idle = true;
      await service.pollOnce();
      expect(store.runFor(repoA, 9)!.state, 'pr-open');
      expect(_eventsOfType(payloads, 'afk.pr_open'), hasLength(1));
      // And the idle run stayed idle all along (the disarm gated it).
      expect(store.runFor(repoA, 7)!.state, 'idle');
    });

    test('a disarmed repo holding in-flight rows keeps them driven (the '
        'production provider resolves its checkout while the repo still holds '
        'rows — armed ∪ repos with rows) while its idle rows are not fed (the '
        'new-work gate still holds)', () async {
      // A holds an idle ready row and a dispatched in-flight row; the repo
      // is disarmed mid-run. The production run-service provider resolves
      // A's checkout because A still holds rows in the store (the run
      // service's armedRepos ∪ repos-with-rows shape) — the fake mirrors
      // that scoping, so this is exactly what the bridge wiring would do.
      await store.addRun(repoA, 7, 'Add a README'); // idle, ready.
      reader(repoA).labels[7] = {'ready-for-agent'};
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 9,
          title: 'Ship the widget',
          state: 'dispatched',
        ),
      );
      reader(repoA).lastComments[9] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/42',
      );
      reader(repoA).prs[42] = PrInfo(
        number: 42,
        url: 'https://github.com/o/r/pull/42',
        state: 'OPEN',
      );
      sessions.idle = true;
      armed = {}; // Disarmed; A still holds rows ⇒ its checkout resolves.
      await service.pollOnce();
      // The in-flight row is still driven through A's own reader: the
      // narration is read and the PR-open transition lands — a disarm
      // never strands an in-flight run (spec #407: "disarming R holds
      // everything").
      expect(store.runFor(repoA, 9)!.state, 'pr-open');
      expect(_eventsOfType(payloads, 'afk.pr_open'), hasLength(1));
      expect(
        reader(repoA).lastCommentCalls,
        1,
        reason: 'the narration was read through the row repo own reader',
      );
      // The idle row is NOT fed: the new-work gate is armed-only and still
      // holds — no label read, no prompt, no state change.
      expect(store.runFor(repoA, 7)!.state, 'idle');
      expect(
        reader(repoA).hasLabelCalls,
        0,
        reason: 'the idle row feed is gated on the repo being armed',
      );
      expect(sessions.prompts, isEmpty);
    });
  });

  group('arming (the pass schedule)', () {
    test(
      'the pass runs from start to stop regardless of the arming (user story '
      '#24); the arming gates only the new-work steps, read live',
      () async {
        // Disarmed at start: the schedule still runs (a disarm is not a
        // stop), but the idle ready issue is not fed (the new-work gate).
        await store.addRun(repoA, 7, 'Add a README');
        reader(repoA).labels[7] = {'ready-for-agent'};
        armed = {};
        service.start();
        expect(
          service.isPolling,
          isTrue,
          reason: 'the pass is not armed-gated',
        );
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(
          store.runFor(repoA, 7)!.state,
          'idle',
          reason: 'disarmed: no feed',
        );
        expect(sessions.prompts, isEmpty);

        // The arm arrives: the live read on the next tick feeds it.
        armed = {repoA};
        await until(() => store.runFor(repoA, 7)!.state == 'dispatched');

        // A disarm mid-run stops nothing: the schedule keeps ticking and the
        // in-flight run is still driven (the follow is not armed-gated).
        armed = {};
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(service.isPolling, isTrue, reason: 'a disarm never stops it');

        service.stop();
        expect(service.isPolling, isFalse);
      },
    );

    test('a disarm mid-run lets the in-flight run finish to its PR', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/41',
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      sessions.idle = true;
      armed = {}; // Disarmed mid-run.
      service.start();
      await until(() => store.runFor(repoA, 7)!.state == 'pr-open');
      service.stop();
    });
  });

  group('the pure helpers', () {
    test('availabilityNotice is the issue number + title, nothing more', () {
      expect(availabilityNotice(7, 'Add a README'), 'Issue #7: Add a README');
    });

    test('parseTerminalNarration: the two terminal narrations', () {
      final pr = parseTerminalNarration(
        'PR opened: https://github.com/o/r/pull/41',
      );
      expect(pr?.kind, TerminalNarrationKind.prOpened);
      expect(pr?.prUrl, 'https://github.com/o/r/pull/41');

      final failed = parseTerminalNarration('FAILED: model under load');
      expect(failed?.kind, TerminalNarrationKind.failed);
      expect(failed?.reason, 'model under load');
    });

    test(
      'parseTerminalNarration: a FAILED with no reason gets a default; a '
      'non-narration is null; a later line of a multi-line comment counts',
      () {
        expect(
          parseTerminalNarration('FAILED:')?.reason,
          'the agent reported a failure',
        );
        expect(parseTerminalNarration('working on it'), isNull);
        expect(parseTerminalNarration('PR opened:'), isNull);
        final multi = parseTerminalNarration(
          'some preamble\nPR opened: https://github.com/o/r/pull/9',
        );
        expect(multi?.prUrl, 'https://github.com/o/r/pull/9');
      },
    );

    test('parsePrNumber: the number from a PR URL, null otherwise', () {
      expect(parsePrNumber('https://github.com/o/r/pull/41'), 41);
      expect(parsePrNumber('https://github.com/o/r/pull/41/files'), 41);
      expect(parsePrNumber('https://github.com/o/r/issues/41'), isNull);
      expect(parsePrNumber('https://github.com/o/r/pull/'), isNull);
      expect(parsePrNumber(null), isNull);
    });

    test('bootstrapFeed lists the in-flight runs (number, state, retry count, '
        'last failure reason); a fresh run lists only its state', () {
      final feed = bootstrapFeed(const [
        AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          retryCount: 1,
          lastFailureReason: 'model under load',
        ),
        AfkRun(
          ownerRepo: repoA,
          issueNumber: 9,
          title: 'Ship the widget',
          state: 'pr-open',
        ),
      ]);
      expect(feed, contains('#7'));
      expect(feed, contains('Add a README'));
      expect(feed, contains('dispatched'));
      expect(feed, contains('retry 1'));
      expect(feed, contains('last failure: model under load'));
      expect(feed, contains('#9'));
      expect(feed, contains('Ship the widget'));
      expect(feed, contains('pr-open'));
      // A fresh run (no retry, no failure) carries no detail parentheses —
      // its line is the bare "- #N title: state" (it is the feed's last line).
      expect(feed, endsWith('- #9 Ship the widget: pr-open'));
      expect(feed, isNot(contains('pr-open (')));
    });
  });

  // ------------------------------------------------------------------------
  // The startup reconciliation (spec #376, T6; per repo by spec #407, T4):
  // "a restart never strands a run". One pass over every stored run at
  // startup, through each row's repo's reader: a lost run is detected and
  // routed to the failure path, a pr-open run is settled to its closure, a
  // live dispatched run is left alone, and failed/idle/done are left to
  // their owners (the human, the ready gate, the end).

  group('the startup reconciliation (spec #376, T6; per repo, T4)', () {
    test('a dispatched run with a live AFK orb survives a restart: no re-feed, '
        'no state change (the run continues on its own)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      orbsInFlight = 2; // An AFK-attributed orb is in flight (host total).
      await service.reconcile();
      expect(
        store.runFor(repoA, 7)!.state,
        'dispatched',
        reason: 'no state change',
      );
      expect(store.runFor(repoA, 7)!.retryCount, 0, reason: 'no retry counted');
      expect(store.runFor(repoA, 7)!.retryAt, isNull);
      expect(sessions.prompts, isEmpty, reason: 'no re-feed');
      expect(payloads, isEmpty, reason: 'no event');
    });

    test('a dispatched run that is live because the session is active (no orb) '
        'survives a restart: no re-feed, no state change', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      sessionActiveByRepo[repoA] = true; // The run's repo's session active.
      await service.reconcile();
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(sessions.prompts, isEmpty);
    });

    test(
      'a dispatched run whose orb is gone and whose session is inactive, with '
      'no narration and no PR, is lost: routed to the failure path (the retry '
      'counter increments, the backoff is scheduled)',
      () async {
        await store.updateRun(
          const AfkRun(
            ownerRepo: repoA,
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
          ),
        );
        // No liveness (orbsInFlight 0, sessionActive false — the default), no
        // terminal narration, no PR.
        await service.reconcile();
        final run = store.runFor(repoA, 7)!;
        expect(
          run.state,
          'dispatched',
          reason: 'still in flight, being retried',
        );
        expect(run.retryCount, 1, reason: 'counted in the retry');
        expect(
          run.retryAt,
          base.millisecondsSinceEpoch + 5 * _min,
          reason: 'the 1st retry backoff',
        );
        expect(run.lastFailureReason, AfkRunService.lostRunReason);
        expect(payloads, isEmpty, reason: 'no event on a retry');
      },
    );

    test('a lost run that keeps dying across restarts hits the cap of 3 and is '
        'handed to the human (the terminal failure: failed + the afk.failed '
        'event)', () async {
      // The run has already burned its 3 retries (a prior FAILED + retries);
      // this restart finds it lost again → terminal failure.
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          retryCount: 3,
        ),
      );
      await service.reconcile();
      final run = store.runFor(repoA, 7)!;
      expect(run.state, 'failed');
      expect(run.lastFailureReason, AfkRunService.lostRunReason);
      final failedData =
          _eventsOfType(payloads, 'afk.failed').single['data'] as Map;
      expect(failedData['issueNumber'], 7);
      expect(failedData['reason'], AfkRunService.lostRunReason);
      expect(failedData['repo'], repoA);
    });

    test('a dispatched run with no liveness but a terminal FAILED narration is '
        'not lost (the periodic pass will process the narration)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader(repoA).lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'FAILED: model under load',
      );
      await service.reconcile();
      expect(
        store.runFor(repoA, 7)!.state,
        'dispatched',
        reason: 'left for the pass',
      );
      expect(
        store.runFor(repoA, 7)!.retryCount,
        0,
        reason: 'the reconciliation does not double-count',
      );
    });

    test('a dispatched run with no liveness but a recorded PR is not lost (the '
        'periodic pass will follow the PR)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      await service.reconcile();
      expect(store.runFor(repoA, 7)!.state, 'dispatched');
      expect(store.runFor(repoA, 7)!.retryCount, 0);
    });

    test('an idle run is left alone at startup (the first poll admits it as '
        'usual — no special handling)', () async {
      await store.addRun(repoA, 7, 'Add a README');
      reader(repoA).labels[7] = {'ready-for-agent'};
      await service.reconcile();
      expect(
        store.runFor(repoA, 7)!.state,
        'idle',
        reason: 'reconciliation does not feed idle',
      );
      expect(sessions.prompts, isEmpty);
    });

    test('a failed run is left alone at startup (no re-feed until the label is '
        're-added)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'failed',
          retryCount: 3,
        ),
      );
      await service.reconcile();
      expect(store.runFor(repoA, 7)!.state, 'failed');
      expect(sessions.prompts, isEmpty, reason: 'no re-feed at startup');
    });

    test(
      'a pr-open run whose issue is closed is settled to done at startup',
      () async {
        await store.updateRun(
          const AfkRun(
            ownerRepo: repoA,
            issueNumber: 7,
            title: 'Add a README',
            state: 'pr-open',
            prNumber: 41,
            prUrl: 'https://github.com/o/r/pull/41',
          ),
        );
        reader(repoA).prs[41] = PrInfo(
          number: 41,
          url: 'https://github.com/o/r/pull/41',
          state: 'MERGED',
        );
        reader(repoA).issueStates[7] = 'CLOSED';
        await service.reconcile();
        expect(store.runFor(repoA, 7)!.state, 'done');
      },
    );

    test('a pr-open run whose PR was closed unmerged is settled to done, '
        'recorded as closed unmerged', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'CLOSED',
      );
      reader(repoA).issueStates[7] = 'OPEN';
      await service.reconcile();
      final run = store.runFor(repoA, 7)!;
      expect(run.state, 'done');
      expect(run.closedUnmerged, isTrue);
    });

    test('a pr-open run whose PR is still open and the issue is open is left '
        'pr-open at startup (the human has not closed it yet)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader(repoA).prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      reader(repoA).issueStates[7] = 'OPEN';
      await service.reconcile();
      expect(store.runFor(repoA, 7)!.state, 'pr-open');
    });

    test('a corrupted state string is left alone (the refusal, never an '
        'admission)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'garbage',
        ),
      );
      await service.reconcile();
      expect(store.runFor(repoA, 7)!.state, 'garbage');
      expect(sessions.prompts, isEmpty);
    });

    test(
      'a dispatched run whose comment READ FAILS is left unchanged (a gh '
      'outage is not a lost verdict; the next startup retries the read)',
      () async {
        await store.updateRun(
          const AfkRun(
            ownerRepo: repoA,
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
          ),
        );
        // No liveness, and the `gh` read fails (a simulated gh outage: the
        // reader throws on a failed/unreadable read).
        reader(repoA).lastCommentReadFails.add(7);
        await service.reconcile();
        final run = store.runFor(repoA, 7)!;
        expect(run.state, 'dispatched', reason: 'the read failure is inert');
        expect(run.retryCount, 0, reason: 'no retry burned by the outage');
        expect(run.retryAt, isNull);
        expect(run.lastFailureReason, isNull);
        expect(sessions.prompts, isEmpty);
        expect(payloads, isEmpty);
      },
    );

    test('a dispatched run whose comment read returns null (genuinely no '
        'comments), with no liveness and no PR, is still lost (the lost '
        'verdict is preserved for the real case)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      // No liveness, no PR, and a readable issue with no comments at all
      // (the genuine "none" answer, distinct from a failed read).
      reader(repoA).lastComments[7] = null;
      await service.reconcile();
      final run = store.runFor(repoA, 7)!;
      expect(run.state, 'dispatched', reason: 'still in flight, being retried');
      expect(run.retryCount, 1, reason: 'counted in the retry');
      expect(
        run.retryAt,
        base.millisecondsSinceEpoch + 5 * _min,
        reason: 'the 1st retry backoff',
      );
      expect(run.lastFailureReason, AfkRunService.lostRunReason);
      expect(payloads, isEmpty, reason: 'no event on a retry');
    });
  });

  // ------------------------------------------------------------------------
  // The fresh-agent handoff (spec #376, T6; scoped per repo by spec #407,
  // T3): a wiped/lost AFK session is recreated (the arming) and the first
  // feed is a bootstrap — *that repo's* in-flight runs from the store. A run
  // of another repo never appears in this repo's bootstrap (the store is
  // keyed per repo). A normal restart (the session still present) reuses the
  // session — no recreation, no re-bootstrap.

  group('the fresh-agent handoff (bootstrap, spec #376, T6; per repo, T3)', () {
    test(
      'a recreated session is booted with the bootstrap: the in-flight runs '
      '(number, state, retry count, last failure reason) from the store',
      () async {
        // The in-flight runs: a dispatched run mid-retry and a pr-open run.
        await store.updateRun(
          const AfkRun(
            ownerRepo: repoA,
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
            retryCount: 1,
            lastFailureReason: 'model under load',
          ),
        );
        await store.updateRun(
          const AfkRun(
            ownerRepo: repoA,
            issueNumber: 9,
            title: 'Ship the widget',
            state: 'pr-open',
            prNumber: 41,
            prUrl: 'https://github.com/o/r/pull/41',
          ),
        );
        sessions.idsByRepo[repoA] = 'ses_afk_new'; // The recreated session.
        await service.bootstrap(repoA);
        // One feed, the bootstrap, to o/r's session, listing both in-flight
        // runs.
        expect(sessions.prompts, hasLength(1));
        expect(
          sessions.prompts.single.$1,
          repoA,
          reason: 'the feed goes to the repo own session',
        );
        final feed = sessions.prompts.single.$2;
        expect(feed, contains('#7'));
        expect(feed, contains('dispatched'));
        expect(feed, contains('retry 1'));
        expect(feed, contains('last failure: model under load'));
        expect(feed, contains('#9'));
        expect(feed, contains('pr-open'));
        // The terminal runs are not in-flight: not listed.
        expect(feed, isNot(contains('#10')));
      },
    );

    test('a recreated session with no in-flight runs gets no bootstrap feed '
        '(a wiped store: nothing to hand over)', () async {
      sessions.idsByRepo[repoA] = 'ses_afk_new';
      await service.bootstrap(repoA);
      expect(sessions.prompts, isEmpty);
    });

    test('a run of another repo never appears in this repo bootstrap '
        '(the store is keyed per repo, spec #407, AC3)', () async {
      // In-flight runs in two repos.
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      await store.updateRun(
        const AfkRun(
          ownerRepo: 'o/other',
          issueNumber: 55,
          title: 'Other repo run',
          state: 'dispatched',
        ),
      );
      sessions.idsByRepo[repoA] = 'ses_afk_a';
      sessions.idsByRepo['o/other'] = 'ses_afk_b';
      // o/r bootstrap lists only o/r runs (never o/other).
      await service.bootstrap(repoA);
      expect(sessions.prompts, hasLength(1));
      expect(sessions.prompts.single.$1, repoA);
      expect(sessions.prompts.single.$2, contains('#7'));
      expect(
        sessions.prompts.single.$2,
        isNot(contains('#55')),
        reason: 'a run of another repo never appears',
      );
      // o/other bootstrap lists only o/other runs (never o/r).
      await service.bootstrap('o/other');
      expect(sessions.prompts, hasLength(2));
      expect(sessions.prompts[1].$1, 'o/other');
      expect(sessions.prompts[1].$2, contains('#55'));
      expect(sessions.prompts[1].$2, isNot(contains('#7')));
    });

    test('idle and failed runs are not in-flight: the bootstrap lists only '
        'dispatched and pr-open runs', () async {
      await store.addRun(repoA, 7, 'Idle issue'); // idle
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 8,
          title: 'Failed issue',
          state: 'failed',
        ),
      );
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 9,
          title: 'Ship the widget',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      sessions.idsByRepo[repoA] = 'ses_afk_new';
      await service.bootstrap(repoA);
      expect(sessions.prompts, hasLength(1));
      final feed = sessions.prompts.single.$2;
      expect(feed, isNot(contains('#7')), reason: 'idle is not in-flight');
      expect(feed, isNot(contains('#8')), reason: 'failed is not in-flight');
      expect(feed, contains('#9'), reason: 'pr-open is in-flight');
    });

    test('a recreated session with no (yet) session id is not booted (nothing '
        'to feed)', () async {
      await store.updateRun(
        const AfkRun(
          ownerRepo: repoA,
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      sessions.idsByRepo[repoA] = null; // No session to feed.
      await service.bootstrap(repoA);
      expect(sessions.prompts, isEmpty);
    });
  });
}
