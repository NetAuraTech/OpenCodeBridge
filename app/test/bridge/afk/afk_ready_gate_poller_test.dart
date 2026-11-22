import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_ready_gate_poller.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';
import 'package:opencodebridge/bridge/afk/github_reader.dart';
import 'package:opencodebridge/bridge/events/bridge_event.dart';

/// A fake [GitHubReader] keyed by the repo it was built for — the poller's
/// per-project seam: each armed repo gets its own reader (built from its own
/// checkout directory), so its ready issues are admitted under its own repo
/// identity, and one repo's failure never reaches another. No network, no `gh`.
class _FakeReader implements GitHubReader {
  _FakeReader(this.repo);

  /// The repo identity this reader was built for (its checkout's identity).
  final String repo;

  /// The ready issues this reader lists (scripted per repo).
  List<ReadyIssue> ready = const [];

  /// When true, [listReadyIssues] throws (a `gh` failure for this repo only).
  bool listThrows = false;

  int calls = 0;

  @override
  Future<List<ReadyIssue>> listReadyIssues() async {
    calls++;
    if (listThrows) throw StateError('gh unavailable in $repo');
    return List.of(ready);
  }

  @override
  Future<IssueComment?> readLastComment(int issueNumber) async => IssueComment(
    id: 'IC_${repo}_$issueNumber',
    body: 'comment $repo $issueNumber',
  );

  @override
  Future<String> readIssueState(int issueNumber) async => 'OPEN';

  @override
  Future<bool> hasLabel(int issueNumber, String label) async => true;

  @override
  Future<PrInfo?> readPr(int prNumber) async => PrInfo(
    number: prNumber,
    url: 'https://github.com/$repo/pull/$prNumber',
    state: 'OPEN',
  );

  @override
  Future<void> addLabel(int issueNumber, String label) async {}

  @override
  Future<void> addComment(int issueNumber, String body) async {}
}

/// An [AfkStore] whose writes fail — the poller's store-failure path.
class _ThrowingStore extends AfkStore {
  _ThrowingStore(File file) : super(file: file);

  @override
  Future<void> addRun(
    String repo,
    int issueNumber,
    String title, {
    String state = 'idle',
  }) async {
    throw StateError('disk full');
  }
}

/// The AFK Ready gate's admission poller, per-project (spec #407, T2): it
/// iterates the **armed** repo identities each pass, admitting each newly ready
/// issue through its own repo's reader (built from that repo's checkout
/// directory) as a repo-scoped row plus one `afk.ready_admitted` event. A
/// disarmed repo is inert, a repo with no resolvable checkout is inert for the
/// tick, and a failed read in one repo admits nothing for that repo only. All
/// through the faked per-repo reader seam.
void main() {
  late Directory dir;
  late File file;
  late AfkStore store;
  late Map<String, _FakeReader> readers;
  late List<String> payloads;
  late Set<String> armed;
  late Map<String, String> directories;
  late List<String> providerCalls;
  late AfkReadyGatePoller? poller;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-afk-gate');
    file = File('${dir.path}/afk.json');
    store = AfkStore(file: file);
    readers = {};
    payloads = [];
    armed = {};
    directories = {};
    providerCalls = [];
    poller = null;
  });

  tearDown(() async {
    poller?.stop();
    await dir.delete(recursive: true);
  });

  /// The reader for [repo], created on demand (one per armed repo, from its
  /// checkout directory).
  _FakeReader readerFor(String repo) =>
      readers.putIfAbsent(repo, () => _FakeReader(repo));

  AfkReadyGatePoller newPoller() {
    poller = AfkReadyGatePoller(
      store: store,
      armedRepos: () => armed,
      repoDirectories: () async {
        providerCalls.add('resolve');
        return Map.of(directories);
      },
      readerFor: (repo, checkout) {
        // The reader the poller builds for a repo must be the one for that
        // repo's resolved checkout directory (the wiring's contract).
        expect(
          checkout,
          directories[repo],
          reason:
              'the reader is built from the armed repo\'s checkout directory',
        );
        return readerFor(repo);
      },
      emitEvent: payloads.add,
      pollInterval: const Duration(milliseconds: 5),
    );
    return poller!;
  }

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met in time');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  group('per-project admission (the poller passes)', () {
    test(
      'two armed repos admit independently: each issue lands under its own '
      'repo + event, and a label in one repo never creates a row in the other',
      () async {
        readerFor('a/alpha').ready = [
          const ReadyIssue(number: 7, title: 'A issue'),
        ];
        readerFor('b/beta').ready = [
          const ReadyIssue(number: 9, title: 'B issue'),
        ];
        armed = {'a/alpha', 'b/beta'};
        directories = {'a/alpha': '/chk/alpha', 'b/beta': '/chk/beta'};
        final p = newPoller();
        await p.pollOnce();
        // Each issue is admitted under its own repo, with its own row.
        final runA = store.runFor('a/alpha', 7);
        final runB = store.runFor('b/beta', 9);
        expect(runA, isNotNull);
        expect(runA!.title, 'A issue');
        expect(runB, isNotNull);
        expect(runB!.title, 'B issue');
        // A's label never creates a B row, and vice-versa.
        expect(store.runFor('b/beta', 7), isNull);
        expect(store.runFor('a/alpha', 9), isNull);
        // One event per admission, each carrying its own repo identity.
        expect(payloads, hasLength(2));
        final events = payloads
            .map((payload) => jsonDecode(payload) as Map<String, dynamic>)
            .toList(growable: false);
        expect(
          events.every((e) => e['type'] == BridgeEventType.afkReadyAdmitted),
          isTrue,
        );
        final dataByNumber = {
          for (final e in events)
            (e['data'] as Map<String, dynamic>)['issueNumber'] as int:
                e['data'] as Map<String, dynamic>,
        };
        expect(dataByNumber[7], {
          'repo': 'a/alpha',
          'issueNumber': 7,
          'title': 'A issue',
        });
        expect(dataByNumber[9], {
          'repo': 'b/beta',
          'issueNumber': 9,
          'title': 'B issue',
        });
        // Each repo was polled through its own reader (from its own checkout).
        expect(readerFor('a/alpha').calls, 1);
        expect(readerFor('b/beta').calls, 1);
      },
    );

    test(
      'disarming repo A stops A\'s admissions while B\'s continue',
      () async {
        readerFor('a/alpha').ready = [
          const ReadyIssue(number: 7, title: 'A issue'),
        ];
        readerFor('b/beta').ready = [
          const ReadyIssue(number: 9, title: 'B issue'),
        ];
        armed = {'a/alpha', 'b/beta'};
        directories = {'a/alpha': '/chk/alpha', 'b/beta': '/chk/beta'};
        final p = newPoller();
        await p.pollOnce();
        expect(store.runFor('a/alpha', 7), isNotNull);
        expect(store.runFor('b/beta', 9), isNotNull);
        // Disarm A: A's newly ready issue is no longer admitted; B continues.
        readerFor('a/alpha').ready = [
          const ReadyIssue(number: 11, title: 'A new'),
        ];
        readerFor('b/beta').ready = [
          const ReadyIssue(number: 9, title: 'B issue'),
          const ReadyIssue(number: 13, title: 'B new'),
        ];
        armed = {'b/beta'}; // A disarmed.
        directories = {
          'b/beta': '/chk/beta',
        }; // A has no resolvable checkout now.
        await p.pollOnce();
        expect(
          store.runFor('a/alpha', 11),
          isNull,
          reason: 'disarmed A is inert',
        );
        expect(
          readerFor('a/alpha').calls,
          1,
          reason: 'A is not polled once disarmed',
        );
        expect(store.runFor('b/beta', 13), isNotNull, reason: 'B still admits');
      },
    );

    test('a failed read in A admits nothing for A only; B proceeds; the next '
        'tick retries A', () async {
      readerFor('a/alpha').ready = [
        const ReadyIssue(number: 7, title: 'A issue'),
      ];
      readerFor('b/beta').ready = [
        const ReadyIssue(number: 9, title: 'B issue'),
      ];
      armed = {'a/alpha', 'b/beta'};
      directories = {'a/alpha': '/chk/alpha', 'b/beta': '/chk/beta'};
      final p = newPoller();
      readerFor('a/alpha').listThrows = true; // A's `gh` is down.
      await p.pollOnce();
      expect(
        store.runFor('a/alpha', 7),
        isNull,
        reason: 'A\'s read failed: nothing admitted for A',
      );
      expect(
        store.runFor('b/beta', 9),
        isNotNull,
        reason: 'B proceeds independently',
      );
      expect(payloads, hasLength(1));
      final data =
          (jsonDecode(payloads.single) as Map<String, dynamic>)['data']
              as Map<String, dynamic>;
      expect(data['repo'], 'b/beta');
      // The next tick retries A (the failure was not permanent) and does not
      // re-admit B.
      readerFor('a/alpha').listThrows = false;
      await p.pollOnce();
      expect(
        store.runFor('a/alpha', 7),
        isNotNull,
        reason: 'the next tick retries A',
      );
      expect(
        store.runsFor('b/beta'),
        hasLength(1),
        reason: 'B is not re-admitted',
      );
      expect(payloads, hasLength(2));
    });

    test('no duplicate per (repo, issue) across ticks: a repo with stored '
        'rows emits nothing new', () async {
      readerFor('o/r').ready = [
        const ReadyIssue(number: 7, title: 'A'),
        const ReadyIssue(number: 9, title: 'B'),
      ];
      armed = {'o/r'};
      directories = {'o/r': '/chk'};
      final p = newPoller();
      await p.pollOnce();
      expect(store.runsFor('o/r'), hasLength(2));
      expect(payloads, hasLength(2));
      await p.pollOnce(); // Unchanged: no duplicate rows, no new events.
      expect(store.runsFor('o/r'), hasLength(2));
      expect(payloads, hasLength(2));
    });

    test('a legacy flat afk.run.<n> row is invisible to the dedup: the same '
        'issue is admitted as a repo-scoped row', () async {
      // A pre-scoping flat run row (no repo identity), written directly to the
      // store file: it is not a row of any repo, so it must not dedup the
      // (repo, issue) admission (spec #407: the tolerant decode ignores it).
      final legacy = {
        'afk.run.7': jsonEncode({
          'issueNumber': 7,
          'title': 'legacy',
          'state': 'idle',
        }),
      };
      await file.writeAsString(jsonEncode(legacy));
      readerFor('o/r').ready = [const ReadyIssue(number: 7, title: 'A')];
      armed = {'o/r'};
      directories = {'o/r': '/chk'};
      final p = newPoller();
      await p.pollOnce();
      // The legacy flat row did not dedup: issue 7 is admitted under 'o/r'.
      final run = store.runFor('o/r', 7);
      expect(run, isNotNull);
      expect(run!.ownerRepo, 'o/r');
      expect(run.title, 'A');
      // The store now holds exactly the repo-scoped row (the legacy flat key is
      // dropped on the admission's write — no migration).
      expect(store.allRuns(), [run]);
      expect(payloads, hasLength(1));
    });
  });

  group('arming (the poller schedule)', () {
    test('inert when no repo is armed: no directory resolution, no reader, no '
        'rows, no events', () async {
      armed = {};
      final p = newPoller();
      p.start();
      expect(
        p.isPolling,
        isTrue,
        reason: 'the schedule runs; the pass is inert',
      );
      await p.pollOnce();
      expect(providerCalls, isEmpty);
      expect(store.allRuns(), isEmpty);
      expect(payloads, isEmpty);
    });

    test('an armed repo with no resolvable checkout is inert for the tick: no '
        'reader, no admission, no crash', () async {
      armed = {'o/r'};
      directories = {}; // 'o/r' has no resolvable checkout (a closed project).
      final p = newPoller();
      await p.pollOnce();
      expect(
        providerCalls,
        hasLength(1),
        reason: 'the directories are resolved',
      );
      expect(
        readerFor('o/r').calls,
        0,
        reason: 'no checkout: no reader is built',
      );
      expect(store.allRuns(), isEmpty);
      expect(payloads, isEmpty);
    });

    test('the timer admits while armed; stop ends the schedule', () async {
      readerFor('o/r').ready = [const ReadyIssue(number: 7, title: 'A')];
      armed = {'o/r'};
      directories = {'o/r': '/chk'};
      final p = newPoller();
      p.start();
      expect(p.isPolling, isTrue);
      await until(() => readerFor('o/r').calls > 0);
      await until(() => store.runsFor('o/r').isNotEmpty);
      p.stop();
      expect(p.isPolling, isFalse);
    });

    test('syncArmed: true schedules, false stops (the pass reads the arming '
        'live per tick, per repo)', () {
      final p = newPoller();
      p.syncArmed(true);
      expect(p.isPolling, isTrue);
      p.syncArmed(false);
      expect(p.isPolling, isFalse);
    });
  });

  group('failures (the poller admits nothing, emits nothing)', () {
    test('a failed store write emits nothing (for that repo)', () async {
      final throwing = _ThrowingStore(file);
      readerFor('o/r').ready = [const ReadyIssue(number: 7, title: 'A')];
      armed = {'o/r'};
      directories = {'o/r': '/chk'};
      poller = AfkReadyGatePoller(
        store: throwing,
        armedRepos: () => armed,
        repoDirectories: () async => Map.of(directories),
        readerFor: (repo, checkout) => readerFor(repo),
        emitEvent: payloads.add,
        pollInterval: const Duration(milliseconds: 5),
      );
      await poller!.pollOnce();
      expect(throwing.runFor('o/r', 7), isNull);
      expect(payloads, isEmpty);
    });
  });
}
