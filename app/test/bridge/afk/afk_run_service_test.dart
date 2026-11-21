// The AFK run service (spec #376, "The per-issue state machine
// (bridge-owned)", T3): the feed (a pure availability notice through the
// existing prompt path), the wait (the idle-wait long-poll as the trigger),
// the terminal narration (the run's signal), the transitions (pr-open,
// done), the bounded retry with backoff (ordinary FIFO re-feeds), the
// terminal failure (needs-triage + event), and the deliberate retry — all
// through the faked GitHub reader and session port, on an injected clock
// and a millisecond poll interval (the orb task service's pattern): no test
// sleeps for real minutes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_run_service.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';
import 'package:opencodebridge/bridge/afk/github_reader.dart';

/// A fake [GitHubReader] — the service's only GitHub seam: scripted labels,
/// last comments, issue states, and PRs; recorded writes; no network, no
/// `gh` process.
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

/// A fake [AfkSessionPort] — the service's session seam: a scripted session
/// id, recorded feeds (prompts), and a scripted idle-wait answer.
class _FakeSessions implements AfkSessionPort {
  String? sessionIdValue = 'ses_afk';
  final List<String> prompts = [];
  bool idle = true;
  int waitCalls = 0;

  @override
  Future<String?> sessionId() async => sessionIdValue;

  @override
  Future<void> prompt(String text) async {
    prompts.add(text);
  }

  @override
  Future<bool> waitIdle({Duration? timeout}) async {
    waitCalls++;
    return idle;
  }
}

/// A fake liveness (spec #376, T6): scripted AFK-attributed orbs in flight and
/// AFK-session-active answers, so the reconciliation's liveness check is
/// deterministic.
class _FakeLiveness {
  int orbsInFlight = 0;
  bool sessionActive = false;

  Future<AfkLiveness> get value async =>
      AfkLiveness(afkOrbsInFlight: orbsInFlight, sessionActive: sessionActive);
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
  late _FakeReader reader;
  late _FakeSessions sessions;
  late _FakeLiveness liveness;
  late List<String> payloads;
  late bool armed;
  late DateTime clock;
  late AfkRunService service;

  final base = DateTime.utc(2026, 11, 20, 12, 0, 0);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-afk-runs');
    file = File('${dir.path}/afk.json');
    store = AfkStore(file: file);
    reader = _FakeReader();
    sessions = _FakeSessions();
    liveness = _FakeLiveness(); // No liveness by default (the reconciliation's non-live case).
    payloads = [];
    armed = true;
    clock = base;
    service = AfkRunService(
      reader: reader,
      store: store,
      sessions: sessions,
      emitEvent: payloads.add,
      isArmed: () => armed,
      liveness: () => liveness.value,
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

  group('the feed (idle → dispatched)', () {
    test('a ready issue is fed with the availability notice only and becomes '
        'dispatched', () async {
      await store.addRun(7, 'Add a README');
      reader.labels[7] = {'ready-for-agent'};
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'dispatched');
      // The feed is the pure availability notice (number + title, nothing
      // more) — and it is the only thing sent.
      expect(sessions.prompts, ['Issue #7: Add a README']);
    });

    test('an idle issue without the ready label is not fed (the gate is the '
        'entry)', () async {
      await store.addRun(7, 'Add a README');
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'idle');
      expect(sessions.prompts, isEmpty);
    });

    test('an idle issue with no (yet) available session is not fed (asked '
        'again next pass)', () async {
      await store.addRun(7, 'Add a README');
      reader.labels[7] = {'ready-for-agent'};
      sessions.sessionIdValue = null;
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'idle');
      expect(sessions.prompts, isEmpty);
      // The session becomes available: the next pass feeds it.
      sessions.sessionIdValue = 'ses_afk';
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'dispatched');
      expect(sessions.prompts, ['Issue #7: Add a README']);
    });
  });

  group('end to end (fakes)', () {
    test(
      'a ready issue is fed; the PR opened narration + an open PR moves it '
      'to pr-open (PR recorded); closing the issue moves it to done',
      () async {
        await store.addRun(7, 'Add a README');
        reader.labels[7] = {'ready-for-agent'};
        await service.pollOnce(); // dispatch
        expect(store.runFor(7)!.state, 'dispatched');

        // The agent posts its terminal narration; the PR is open; the
        // session is idle.
        reader.lastComments[7] = IssueComment(
          id: 'IC1',
          body: 'PR opened: https://github.com/o/r/pull/41',
        );
        reader.prs[41] = PrInfo(
          number: 41,
          url: 'https://github.com/o/r/pull/41',
          state: 'OPEN',
        );
        sessions.idle = true;
        await service.pollOnce();
        final prOpen = store.runFor(7)!;
        expect(prOpen.state, 'pr-open');
        expect(prOpen.prNumber, 41);
        expect(prOpen.prUrl, 'https://github.com/o/r/pull/41');
        expect(prOpen.closedUnmerged, isFalse);
        expect(_eventsOfType(payloads, 'afk.pr_open'), hasLength(1));

        // The human's review is the exit: the issue closes.
        reader.issueStates[7] = 'CLOSED';
        await service.pollOnce();
        expect(store.runFor(7)!.state, 'done');
      },
    );
  });

  group('the wait (the idle-wait is the trigger, not the signal)', () {
    test('while the session is still running the service reads nothing; at '
        'idle it reads the narration', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader.lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/41',
      );
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      sessions.idle = false; // The agent is still working.
      await service.pollOnce();
      expect(
        reader.lastCommentCalls,
        0,
        reason: 'the wait did not return idle',
      );
      expect(store.runFor(7)!.state, 'dispatched');
      expect(sessions.waitCalls, 1);

      // The session goes idle: the service reads the narration.
      sessions.idle = true;
      await service.pollOnce();
      expect(reader.lastCommentCalls, 1);
      expect(store.runFor(7)!.state, 'pr-open');
    });
  });

  group('the pr-open confirmation (the bridge confirms the PR is open)', () {
    test('a PR opened narration is not confirmed while the PR is not open '
        '(the run stays in flight; re-read next pass)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader.lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/41',
      );
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'CLOSED',
      );
      sessions.idle = true;
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'dispatched');
      expect(payloads, isEmpty);

      // The PR opens: the next pass confirms.
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'pr-open');
      expect(store.runFor(7)!.prNumber, 41);
    });

    test(
      'a PR opened narration whose URL names no PR is not confirmed',
      () async {
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
          ),
        );
        reader.lastComments[7] = IssueComment(
          id: 'IC1',
          body: 'PR opened: https://github.com/o/r/issues/41',
        );
        sessions.idle = true;
        await service.pollOnce();
        expect(store.runFor(7)!.state, 'dispatched');
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
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      sessions.idle = true;

      // FAILED #1 → retry 1 (5 min).
      reader.lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'FAILED: model under load',
      );
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'dispatched');
      expect(store.runFor(7)!.retryCount, 1);
      expect(store.runFor(7)!.retryAt, base.millisecondsSinceEpoch + 5 * _min);
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
        'Issue #7: Add a README',
      ], reason: 're-feed #1');
      expect(store.runFor(7)!.retryAt, isNull);

      // FAILED #2 → retry 2 (10 min).
      reader.lastComments[7] = IssueComment(
        id: 'IC2',
        body: 'FAILED: model under load',
      );
      await service.pollOnce();
      expect(store.runFor(7)!.retryCount, 2);
      expect(
        store.runFor(7)!.retryAt,
        clock.millisecondsSinceEpoch + 10 * _min,
      );

      // Backoff, then re-feed #2.
      clock = clock.add(const Duration(minutes: 10));
      await service.pollOnce();
      expect(sessions.prompts, hasLength(2), reason: 're-feed #2');

      // FAILED #3 → retry 3 (10 min).
      reader.lastComments[7] = IssueComment(
        id: 'IC3',
        body: 'FAILED: model under load',
      );
      await service.pollOnce();
      expect(store.runFor(7)!.retryCount, 3);

      // Backoff, then re-feed #3.
      clock = clock.add(const Duration(minutes: 10));
      await service.pollOnce();
      expect(sessions.prompts, hasLength(3), reason: 're-feed #3');

      // FAILED #4 → retries exhausted: the terminal failure.
      reader.lastComments[7] = IssueComment(
        id: 'IC4',
        body: 'FAILED: model under load',
      );
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'failed');
      expect(_eventsOfType(payloads, 'afk.failed'), hasLength(1));
      final failedData =
          _eventsOfType(payloads, 'afk.failed').single['data'] as Map;
      expect(failedData['issueNumber'], 7);
      expect(failedData['title'], 'Add a README');
      expect(failedData['reason'], 'model under load');

      // The hand-back rides the failed state's pass: needs-triage label +
      // a comment naming the failure.
      await service.pollOnce();
      expect(reader.addLabelCalls, contains((7, 'needs-triage')));
      expect(reader.addCommentCalls, hasLength(1));
      expect(reader.addCommentCalls.single.$2, contains('model under load'));
    });

    test(
      'a processed narration is not re-processed (dedup by comment id): a '
      're-feed that posts no new narration does not schedule a 2nd retry',
      () async {
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
          ),
        );
        sessions.idle = true;
        reader.lastComments[7] = IssueComment(id: 'IC1', body: 'FAILED: boom');
        await service.pollOnce();
        expect(store.runFor(7)!.retryCount, 1);
        expect(store.runFor(7)!.narrationId, 'IC1');

        // The backoff elapses: the re-feed goes out (retryAt cleared).
        clock = clock.add(const Duration(minutes: 5));
        await service.pollOnce();
        expect(sessions.prompts, ['Issue #7: Add a README']);
        expect(store.runFor(7)!.retryAt, isNull);

        // The agent goes idle again but posts no new narration (the last
        // comment is still IC1): the old narration is not re-processed.
        await service.pollOnce();
        expect(store.runFor(7)!.retryCount, 1, reason: 'no 2nd retry');
        expect(store.runFor(7)!.retryAt, isNull);
        expect(sessions.prompts, hasLength(1), reason: 'no 2nd re-feed');
      },
    );
  });

  group('a run with an open PR is never retried', () {
    test('a FAILED-like narration after the PR is a no-op (the run stays '
        'pr-open)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      // A spurious/late failure narration.
      reader.lastComments[7] = IssueComment(
        id: 'IC9',
        body: 'FAILED: something broke',
      );
      sessions.idle = true;
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'pr-open', reason: 'never retried');
      expect(store.runFor(7)!.retryCount, 0);
      expect(payloads, isEmpty);
      expect(sessions.prompts, isEmpty);
    });
  });

  group('pr-open → done (the bridge follows the PR to the run\'s end)', () {
    test('a PR closed unmerged lands done, recorded as closed unmerged (the '
        'issue may still be open)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'CLOSED',
      );
      reader.issueStates[7] = 'OPEN';
      await service.pollOnce();
      final run = store.runFor(7)!;
      expect(run.state, 'done');
      expect(run.closedUnmerged, isTrue);
    });

    test('a merged PR with the issue still open is not done yet (the human '
        'closes the issue)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'MERGED',
      );
      reader.issueStates[7] = 'OPEN';
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'pr-open');
    });

    test('a done run is a no-op', () async {
      await store.updateRun(
        const AfkRun(issueNumber: 7, title: 'Add a README', state: 'done'),
      );
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'done');
      expect(payloads, isEmpty);
    });
  });

  group('the deliberate retry (the human re-adds ready-for-agent)', () {
    test('re-labelling a failed issue ready-for-agent re-dispatches it with '
        'the retry counter reset', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'failed',
          retryCount: 3,
          narrationId: 'IC4',
        ),
      );
      reader.labels[7] = {'needs-triage'};
      // A failed pass with no ready label: the hand-back stands, no re-feed.
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'failed');
      expect(sessions.prompts, isEmpty);

      // The human re-adds the gate's label.
      reader.labels[7] = {'needs-triage', 'ready-for-agent'};
      await service.pollOnce();
      final run = store.runFor(7)!;
      expect(run.state, 'dispatched');
      expect(run.retryCount, 0, reason: 'the counter is reset');
      expect(sessions.prompts, ['Issue #7: Add a README']);
    });
  });

  group('the terminal failure hand-back (retried until it fully lands)', () {
    test('a partial hand-back (label landed, comment write failed) is '
        'retried: the next pass posts the comment and marks the row landed '
        '(no duplicate label, exactly one comment across passes)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'failed',
          retryCount: 3,
        ),
      );
      // The label write lands; the comment write fails once.
      reader.addCommentFails = true;
      await service.pollOnce();
      expect(reader.addLabelCalls, [
        (7, 'needs-triage'),
      ], reason: 'the label was posted');
      expect(reader.addCommentCalls, isEmpty, reason: 'the comment failed');
      expect(
        store.runFor(7)!.handbackLanded,
        isFalse,
        reason: 'the hand-back is not recorded as landed',
      );
      expect(store.runFor(7)!.state, 'failed');

      // The comment write recovers: the next pass sees the label is present
      // but the row says not landed, so it posts the comment and marks the
      // hand-back landed — without a second label.
      reader.addCommentFails = false;
      await service.pollOnce();
      expect(reader.addCommentCalls, hasLength(1));
      expect(
        reader.addCommentCalls.single.$2,
        contains('the agent reported a failure'),
      );
      expect(reader.addLabelCalls, [
        (7, 'needs-triage'),
      ], reason: 'no duplicate label');
      expect(store.runFor(7)!.handbackLanded, isTrue);

      // The hand-back stands: a further pass posts nothing (the landed row
      // short-circuits the hand-back).
      await service.pollOnce();
      expect(reader.addCommentCalls, hasLength(1));
      expect(reader.addLabelCalls, hasLength(1));
      expect(store.runFor(7)!.handbackLanded, isTrue);
    });

    test(
      'a failed label write posts nothing, marks nothing, and is retried',
      () async {
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'failed',
            retryCount: 3,
          ),
        );
        // The label write fails: the comment is never attempted.
        reader.addLabelFails = true;
        await service.pollOnce();
        expect(reader.addLabelCalls, isEmpty);
        expect(reader.addCommentCalls, isEmpty);
        expect(store.runFor(7)!.handbackLanded, isFalse);
        expect(store.runFor(7)!.state, 'failed');

        // The write recovers: the next pass posts label + comment and marks
        // the hand-back landed.
        reader.addLabelFails = false;
        await service.pollOnce();
        expect(reader.addLabelCalls, [(7, 'needs-triage')]);
        expect(reader.addCommentCalls, hasLength(1));
        expect(store.runFor(7)!.handbackLanded, isTrue);
      },
    );
  });

  group('the failure posture (inert, never a throw)', () {
    test('a run in an unknown state is left alone (the refusal, not an '
        'admission)', () async {
      await store.updateRun(
        const AfkRun(issueNumber: 7, title: 'Add a README', state: 'garbage'),
      );
      reader.labels[7] = {'ready-for-agent'};
      await service.pollOnce();
      expect(store.runFor(7)!.state, 'garbage');
      expect(payloads, isEmpty);
    });

    test('disarmed: the pass is a gate for new work, never a stop for '
        'in-flight runs (user story #24)', () async {
      // A ready-but-idle issue: disarmed ⇒ no feed, no label read, no state
      // change (the new-work gate reads no GitHub at all).
      await store.addRun(7, 'Add a README');
      reader.labels[7] = {'ready-for-agent'};
      armed = false;
      await service.pollOnce();
      expect(reader.hasLabelCalls, 0);
      expect(store.runFor(7)!.state, 'idle');
      expect(sessions.prompts, isEmpty);

      // An in-flight run in the same disarmed pass: the follow does not read
      // the arming — at idle it reads the narration and the PR-open
      // transition still lands (a run finishes to its PR through a disarm).
      await store.updateRun(
        const AfkRun(
          issueNumber: 9,
          title: 'Ship the widget',
          state: 'dispatched',
        ),
      );
      reader.lastComments[9] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/42',
      );
      reader.prs[42] = PrInfo(
        number: 42,
        url: 'https://github.com/o/r/pull/42',
        state: 'OPEN',
      );
      sessions.idle = true;
      await service.pollOnce();
      expect(store.runFor(9)!.state, 'pr-open');
      expect(_eventsOfType(payloads, 'afk.pr_open'), hasLength(1));
      // And the idle run stayed idle all along (the disarm gated it).
      expect(store.runFor(7)!.state, 'idle');
    });
  });

  group('arming (the pass schedule)', () {
    test(
      'the pass runs from start to stop regardless of the arming (user story '
      '#24); the arming gates only the new-work steps, read live',
      () async {
        // Disarmed at start: the schedule still runs (a disarm is not a
        // stop), but the idle ready issue is not fed (the new-work gate).
        await store.addRun(7, 'Add a README');
        reader.labels[7] = {'ready-for-agent'};
        armed = false;
        service.start();
        expect(
          service.isPolling,
          isTrue,
          reason: 'the pass is not armed-gated',
        );
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(store.runFor(7)!.state, 'idle', reason: 'disarmed: no feed');
        expect(sessions.prompts, isEmpty);

        // The arm arrives: the live read on the next tick feeds it.
        armed = true;
        await until(() => store.runFor(7)!.state == 'dispatched');

        // A disarm mid-run stops nothing: the schedule keeps ticking and the
        // in-flight run is still driven (the follow is not armed-gated).
        armed = false;
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(service.isPolling, isTrue, reason: 'a disarm never stops it');

        service.stop();
        expect(service.isPolling, isFalse);
      },
    );

    test('a disarm mid-run lets the in-flight run finish to its PR', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader.lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'PR opened: https://github.com/o/r/pull/41',
      );
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      sessions.idle = true;
      armed = false; // Disarmed mid-run.
      service.start();
      await until(() => store.runFor(7)!.state == 'pr-open');
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
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          retryCount: 1,
          lastFailureReason: 'model under load',
        ),
        AfkRun(issueNumber: 9, title: 'Ship the widget', state: 'pr-open'),
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
  // The startup reconciliation (spec #376, T6): "a restart never strands a
  // run". One pass over every stored run at startup: a lost run is detected
  // and routed to the failure path, a pr-open run is settled to its closure,
  // a live dispatched run is left alone, and failed/idle/done are left to
  // their owners (the human, the ready gate, the end).

  group('the startup reconciliation (spec #376, T6)', () {
    test('a dispatched run with a live AFK orb survives a restart: no re-feed, '
        'no state change (the run continues on its own)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      liveness.orbsInFlight = 2; // An AFK-attributed orb is in flight.
      await service.reconcile();
      expect(store.runFor(7)!.state, 'dispatched', reason: 'no state change');
      expect(store.runFor(7)!.retryCount, 0, reason: 'no retry counted');
      expect(store.runFor(7)!.retryAt, isNull);
      expect(sessions.prompts, isEmpty, reason: 'no re-feed');
      expect(payloads, isEmpty, reason: 'no event');
    });

    test('a dispatched run that is live because the session is active (no orb) '
        'survives a restart: no re-feed, no state change', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      liveness.sessionActive = true; // The AFK session's agent loop is active.
      await service.reconcile();
      expect(store.runFor(7)!.state, 'dispatched');
      expect(sessions.prompts, isEmpty);
    });

    test(
      'a dispatched run whose orb is gone and whose session is inactive, with '
      'no narration and no PR, is lost: routed to the failure path (the retry '
      'counter increments, the backoff is scheduled)',
      () async {
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
          ),
        );
        // No liveness (orbsInFlight 0, sessionActive false — the default), no
        // terminal narration, no PR.
        await service.reconcile();
        final run = store.runFor(7)!;
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
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          retryCount: 3,
        ),
      );
      await service.reconcile();
      final run = store.runFor(7)!;
      expect(run.state, 'failed');
      expect(run.lastFailureReason, AfkRunService.lostRunReason);
      final failedData =
          _eventsOfType(payloads, 'afk.failed').single['data'] as Map;
      expect(failedData['issueNumber'], 7);
      expect(failedData['reason'], AfkRunService.lostRunReason);
    });

    test('a dispatched run with no liveness but a terminal FAILED narration is '
        'not lost (the periodic pass will process the narration)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      reader.lastComments[7] = IssueComment(
        id: 'IC1',
        body: 'FAILED: model under load',
      );
      await service.reconcile();
      expect(store.runFor(7)!.state, 'dispatched', reason: 'left for the pass');
      expect(
        store.runFor(7)!.retryCount,
        0,
        reason: 'the reconciliation does not double-count',
      );
    });

    test('a dispatched run with no liveness but a recorded PR is not lost (the '
        'periodic pass will follow the PR)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      await service.reconcile();
      expect(store.runFor(7)!.state, 'dispatched');
      expect(store.runFor(7)!.retryCount, 0);
    });

    test('an idle run is left alone at startup (the first poll admits it as '
        'usual — no special handling)', () async {
      await store.addRun(7, 'Add a README');
      reader.labels[7] = {'ready-for-agent'};
      await service.reconcile();
      expect(
        store.runFor(7)!.state,
        'idle',
        reason: 'reconciliation does not feed idle',
      );
      expect(sessions.prompts, isEmpty);
    });

    test('a failed run is left alone at startup (no re-feed until the label is '
        're-added)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'failed',
          retryCount: 3,
        ),
      );
      await service.reconcile();
      expect(store.runFor(7)!.state, 'failed');
      expect(sessions.prompts, isEmpty, reason: 'no re-feed at startup');
    });

    test(
      'a pr-open run whose issue is closed is settled to done at startup',
      () async {
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'pr-open',
            prNumber: 41,
            prUrl: 'https://github.com/o/r/pull/41',
          ),
        );
        reader.prs[41] = PrInfo(
          number: 41,
          url: 'https://github.com/o/r/pull/41',
          state: 'MERGED',
        );
        reader.issueStates[7] = 'CLOSED';
        await service.reconcile();
        expect(store.runFor(7)!.state, 'done');
      },
    );

    test('a pr-open run whose PR was closed unmerged is settled to done, '
        'recorded as closed unmerged', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'CLOSED',
      );
      reader.issueStates[7] = 'OPEN';
      await service.reconcile();
      final run = store.runFor(7)!;
      expect(run.state, 'done');
      expect(run.closedUnmerged, isTrue);
    });

    test('a pr-open run whose PR is still open and the issue is open is left '
        'pr-open at startup (the human has not closed it yet)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      reader.prs[41] = PrInfo(
        number: 41,
        url: 'https://github.com/o/r/pull/41',
        state: 'OPEN',
      );
      reader.issueStates[7] = 'OPEN';
      await service.reconcile();
      expect(store.runFor(7)!.state, 'pr-open');
    });

    test('a corrupted state string is left alone (the refusal, never an '
        'admission)', () async {
      await store.updateRun(
        const AfkRun(issueNumber: 7, title: 'Add a README', state: 'garbage'),
      );
      await service.reconcile();
      expect(store.runFor(7)!.state, 'garbage');
      expect(sessions.prompts, isEmpty);
    });

    test(
      'a dispatched run whose comment READ FAILS is left unchanged (a gh '
      'outage is not a lost verdict; the next startup retries the read)',
      () async {
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
          ),
        );
        // No liveness, and the `gh` read fails (a simulated gh outage: the
        // reader throws on a failed/unreadable read).
        reader.lastCommentReadFails.add(7);
        await service.reconcile();
        final run = store.runFor(7)!;
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
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      // No liveness, no PR, and a readable issue with no comments at all
      // (the genuine "none" answer, distinct from a failed read).
      reader.lastComments[7] = null;
      await service.reconcile();
      final run = store.runFor(7)!;
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
  // The fresh-agent handoff (spec #376, T6): a wiped/lost AFK session is
  // recreated (the arming) and the first feed is a bootstrap — the in-flight
  // runs from the store. A normal restart (the session still present) reuses
  // the session — no recreation, no re-bootstrap.

  group('the fresh-agent handoff (bootstrap, spec #376, T6)', () {
    test(
      'a recreated session is booted with the bootstrap: the in-flight runs '
      '(number, state, retry count, last failure reason) from the store',
      () async {
        // The in-flight runs: a dispatched run mid-retry and a pr-open run.
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
            retryCount: 1,
            lastFailureReason: 'model under load',
          ),
        );
        await store.updateRun(
          const AfkRun(
            issueNumber: 9,
            title: 'Ship the widget',
            state: 'pr-open',
            prNumber: 41,
            prUrl: 'https://github.com/o/r/pull/41',
          ),
        );
        sessions.sessionIdValue = 'ses_afk_new'; // The recreated session.
        await service.bootstrap();
        // One feed, the bootstrap, listing both in-flight runs.
        expect(sessions.prompts, hasLength(1));
        final feed = sessions.prompts.single;
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
      sessions.sessionIdValue = 'ses_afk_new';
      await service.bootstrap();
      expect(sessions.prompts, isEmpty);
    });

    test('idle and failed runs are not in-flight: the bootstrap lists only '
        'dispatched and pr-open runs', () async {
      await store.addRun(7, 'Idle issue'); // idle
      await store.updateRun(
        const AfkRun(issueNumber: 8, title: 'Failed issue', state: 'failed'),
      );
      await store.updateRun(
        const AfkRun(
          issueNumber: 9,
          title: 'Ship the widget',
          state: 'pr-open',
          prNumber: 41,
          prUrl: 'https://github.com/o/r/pull/41',
        ),
      );
      sessions.sessionIdValue = 'ses_afk_new';
      await service.bootstrap();
      expect(sessions.prompts, hasLength(1));
      final feed = sessions.prompts.single;
      expect(feed, isNot(contains('#7')), reason: 'idle is not in-flight');
      expect(feed, isNot(contains('#8')), reason: 'failed is not in-flight');
      expect(feed, contains('#9'), reason: 'pr-open is in-flight');
    });

    test('a recreated session with no (yet) session id is not booted (nothing '
        'to feed)', () async {
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      sessions.sessionIdValue = null; // No session to feed.
      await service.bootstrap();
      expect(sessions.prompts, isEmpty);
    });
  });
}
