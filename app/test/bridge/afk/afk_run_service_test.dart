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
    addLabelCalls.add((issueNumber, label));
    labels[issueNumber] = {...?labels[issueNumber], label};
  }

  @override
  Future<void> addComment(int issueNumber, String body) async {
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
    payloads = [];
    armed = true;
    clock = base;
    service = AfkRunService(
      reader: reader,
      store: store,
      sessions: sessions,
      emitEvent: payloads.add,
      isArmed: () => armed,
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
  });
}
