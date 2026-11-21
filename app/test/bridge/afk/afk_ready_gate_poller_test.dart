import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_ready_gate_poller.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';
import 'package:opencodebridge/bridge/afk/github_reader.dart';
import 'package:opencodebridge/bridge/events/bridge_event.dart';

/// A fake [GitHubReader] — the poller's only I/O seam: scripted ready
/// issues and a scripted read failure; no network, no `gh` process.
class _FakeReader implements GitHubReader {
  List<ReadyIssue> ready = [];
  int calls = 0;
  bool listThrows = false;

  @override
  Future<List<ReadyIssue>> listReadyIssues() async {
    calls++;
    if (listThrows) throw StateError('gh unavailable');
    return List.of(ready);
  }

  @override
  Future<IssueComment?> readLastComment(int issueNumber) async =>
      IssueComment(id: 'IC_$issueNumber', body: 'comment $issueNumber');

  @override
  Future<String> readIssueState(int issueNumber) async => 'OPEN';

  @override
  Future<bool> hasLabel(int issueNumber, String label) async => true;

  @override
  Future<PrInfo?> readPr(int prNumber) async => PrInfo(
    number: prNumber,
    url: 'https://github.com/o/r/pull/$prNumber',
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

/// The AFK Ready gate's admission poller (spec #376, "The Ready gate and the
/// feed", T2): while armed it admits newly ready issues (store row + one
/// event per issue); it is inert when disarmed and never re-admits or
/// aborts — all through the faked reader seam.
void main() {
  late Directory dir;
  late File file;
  late AfkStore store;
  late _FakeReader reader;
  late List<String> payloads;
  late bool armed;
  late String? repo;
  late AfkReadyGatePoller? poller;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-afk-gate');
    file = File('${dir.path}/afk.json');
    store = AfkStore(file: file);
    reader = _FakeReader();
    payloads = [];
    armed = false;
    repo = null;
    poller = null;
  });

  tearDown(() async {
    poller?.stop();
    await dir.delete(recursive: true);
  });

  AfkReadyGatePoller newPoller() {
    poller = AfkReadyGatePoller(
      reader: reader,
      store: store,
      isArmed: () => armed,
      repo: () => repo,
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

  group('admission (the poller passes)', () {
    test('admits a newly ready issue: store row (idle, number, title) + one '
        'ready-admission event', () async {
      reader.ready = [const ReadyIssue(number: 7, title: 'Add a README')];
      armed = true;
      repo = 'o/r';
      final p = newPoller();
      await p.pollOnce();
      final run = store.runFor('o/r', 7);
      expect(run, isNotNull);
      expect(run!.issueNumber, 7);
      expect(run.title, 'Add a README');
      expect(run.state, 'idle');
      expect(store.runsFor('o/r').map((r) => r.issueNumber).toSet(), {7});
      expect(payloads, hasLength(1));
      final decoded = jsonDecode(payloads.single) as Map<String, dynamic>;
      expect(decoded['type'], BridgeEventType.afkReadyAdmitted);
      expect(decoded['data'], {'issueNumber': 7, 'title': 'Add a README'});
    });

    test(
      'admits each new issue once: a repeated pass emits nothing new',
      () async {
        reader.ready = [
          const ReadyIssue(number: 7, title: 'A'),
          const ReadyIssue(number: 9, title: 'B'),
        ];
        armed = true;
        repo = 'o/r';
        final p = newPoller();
        await p.pollOnce();
        expect(store.runsFor('o/r'), hasLength(2));
        expect(payloads, hasLength(2));
        await p.pollOnce(); // Unchanged: no duplicate rows, no new events.
        expect(store.runsFor('o/r'), hasLength(2));
        expect(payloads, hasLength(2));
      },
    );

    test('the poller never aborts: removing the label does not alter the '
        'stored row', () async {
      reader.ready = [const ReadyIssue(number: 7, title: 'A')];
      armed = true;
      repo = 'o/r';
      final p = newPoller();
      await p.pollOnce();
      expect(store.runFor('o/r', 7), isNotNull);
      // The label is gone: the reader lists open issues with the label, so 7
      // is absent now.
      reader.ready = [];
      await p.pollOnce();
      final run = store.runFor('o/r', 7);
      expect(run, isNotNull);
      expect(run!.state, 'idle');
      expect(run.title, 'A');
      expect(payloads, hasLength(1)); // Still exactly the one admission.
    });
  });

  group('arming (the poller schedule)', () {
    test(
      'inert when disarmed: no reader calls, no store rows, no events',
      () async {
        reader.ready = [const ReadyIssue(number: 7, title: 'A')];
        armed = false;
        final p = newPoller();
        p.start();
        expect(p.isPolling, isFalse);
        await p.pollOnce();
        expect(reader.calls, 0);
        expect(store.runsFor('o/r'), isEmpty);
        expect(payloads, isEmpty);
      },
    );

    test('the timer admits while armed; stop ends the schedule', () async {
      reader.ready = [const ReadyIssue(number: 7, title: 'A')];
      armed = true;
      repo = 'o/r';
      final p = newPoller();
      p.start();
      expect(p.isPolling, isTrue);
      await until(() => reader.calls > 0);
      await until(() => store.runsFor('o/r').isNotEmpty);
      p.stop();
      expect(p.isPolling, isFalse);
    });

    test('syncArmed: disarmed stops, armed schedules', () {
      armed = true;
      repo = 'o/r';
      final p = newPoller();
      p.syncArmed(true);
      expect(p.isPolling, isTrue);
      p.syncArmed(false);
      expect(p.isPolling, isFalse);
      armed = false;
      p.syncArmed(true); // Still disarmed: nothing scheduled.
      expect(p.isPolling, isFalse);
    });
  });

  group('failures (the poller admits nothing, emits nothing)', () {
    test('a failed read admits nothing and emits nothing', () async {
      reader.listThrows = true;
      armed = true;
      repo = 'o/r';
      final p = newPoller();
      await p.pollOnce();
      expect(reader.calls, 1);
      expect(store.runsFor('o/r'), isEmpty);
      expect(payloads, isEmpty);
    });

    test('a failed store write emits nothing', () async {
      final throwing = _ThrowingStore(file);
      reader.ready = [const ReadyIssue(number: 7, title: 'A')];
      armed = true;
      repo = 'o/r';
      poller = AfkReadyGatePoller(
        reader: reader,
        store: throwing,
        isArmed: () => armed,
        repo: () => repo,
        emitEvent: payloads.add,
        pollInterval: const Duration(milliseconds: 5),
      );
      await poller!.pollOnce();
      expect(throwing.runFor('o/r', 7), isNull);
      expect(payloads, isEmpty);
    });
  });
}
