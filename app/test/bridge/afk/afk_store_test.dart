import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';

/// The bridge's persisted AFK machine state (spec #376, T1): the app-owned
/// file that holds the AFK session id (and, later, the per-issue run state).
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-afk-store');
    file = File('${dir.path}/afk.json');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  group('AfkStore', () {
    test('reads empty when the file is missing (a fresh machine)', () {
      final store = AfkStore(file: file);
      expect(store.sessionId(), isNull);
      expect(store.load(), isEmpty);
    });

    test('degrades to empty on a corrupt or non-object file', () {
      file.writeAsStringSync('not json');
      expect(AfkStore(file: file).load(), isEmpty);
      file.writeAsStringSync(jsonEncode([1, 2, 3]));
      expect(AfkStore(file: file).load(), isEmpty);
    });

    test(
      'stores and re-reads the AFK session id (survives a restart)',
      () async {
        final store = AfkStore(file: file);
        await store.setSessionId('ses_afk_1');
        expect(AfkStore(file: file).sessionId(), 'ses_afk_1');
      },
    );

    test('keeps other stored values when setting the session id (the store '
        'grows with the per-issue run state)', () async {
      // A future ticket's key already lives in the file alongside where the
      // session id will go.
      await file.writeAsString(jsonEncode({'afk.issue.7.state': 'dispatched'}));
      await AfkStore(file: file).setSessionId('ses_afk_1');
      final reloaded = AfkStore(file: file).load();
      expect(reloaded[AfkStore.keySessionId], 'ses_afk_1');
      expect(reloaded['afk.issue.7.state'], 'dispatched');
    });

    test('clearing the session id removes the file when nothing else is stored '
        '(no cruft in the app-owned dir)', () async {
      await AfkStore(file: file).setSessionId('ses_afk_1');
      expect(file.existsSync(), isTrue);

      await AfkStore(file: file).setSessionId(null);
      expect(AfkStore(file: file).sessionId(), isNull);
      expect(file.existsSync(), isFalse);
    });

    test(
      'clearing the session id keeps the file when other values remain',
      () async {
        await file.writeAsString(
          jsonEncode({
            AfkStore.keySessionId: 'ses_afk_1',
            'afk.issue.7.state': 'pr-open',
          }),
        );
        await AfkStore(file: file).setSessionId(null);
        expect(AfkStore(file: file).sessionId(), isNull);
        expect(file.existsSync(), isTrue);
        expect(AfkStore(file: file).load()['afk.issue.7.state'], 'pr-open');
      },
    );
  });

  group('run rows (spec #376, "The Ready gate and the feed", T2: the '
      'poller\'s admissions, beside the session record)', () {
    test(
      'addRun persists + runFor reads back (state idle, number, title)',
      () async {
        final store = AfkStore(file: file);
        await store.addRun(7, 'Add a README');
        final reloaded = AfkStore(file: file);
        final run = reloaded.runFor(7);
        expect(run, isNotNull);
        expect(run!.issueNumber, 7);
        expect(run.title, 'Add a README');
        expect(run.state, 'idle');
      },
    );

    test('runs() lists every row, sorted by issue number', () async {
      final store = AfkStore(file: file);
      await store.addRun(9, 'Nine');
      await store.addRun(7, 'Seven');
      expect(store.runs().map((run) => run.issueNumber).toList(), [7, 9]);
    });

    test('a corrupt run row reads as absent', () async {
      await file.writeAsString(
        jsonEncode({
          'afk.run.7': 'not json',
          'afk.run.9': '{"state":"idle","issueNumber":9,"title":"Nine"}',
        }),
      );
      final store = AfkStore(file: file);
      expect(store.runFor(7), isNull);
      expect(store.runFor(8), isNull);
      expect(store.runs().map((run) => run.issueNumber).toList(), [9]);
    });

    test('addRun upserts: re-adding an issue updates its row', () async {
      final store = AfkStore(file: file);
      await store.addRun(7, 'Old title');
      await store.addRun(7, 'New title');
      final run = store.runFor(7);
      expect(run!.title, 'New title');
      expect(store.runs(), hasLength(1));
    });

    test('run rows coexist with the session record', () async {
      final store = AfkStore(file: file);
      await store.setSessionId('ses_afk_1');
      await store.addRun(7, 'Add a README');
      final reloaded = AfkStore(file: file);
      expect(reloaded.sessionId(), 'ses_afk_1');
      expect(reloaded.runFor(7)!.issueNumber, 7);
    });
  });

  group('the run row grows with the run state (spec #376, T3: the retry '
      'count, the PR number/URL, the backoff deadline, the narration)', () {
    test(
      'updateRun persists the full row; runFor reads every field back',
      () async {
        final store = AfkStore(file: file);
        await store.addRun(7, 'Add a README');
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'pr-open',
            prNumber: 41,
            prUrl: 'https://github.com/org/repo/pull/41',
            narrationId: 'IC_1',
          ),
        );
        final reloaded = AfkStore(file: file);
        final run = reloaded.runFor(7)!;
        expect(run.state, 'pr-open');
        expect(run.retryCount, 0);
        expect(run.prNumber, 41);
        expect(run.prUrl, 'https://github.com/org/repo/pull/41');
        expect(run.closedUnmerged, isFalse);
        expect(run.retryAt, isNull);
        expect(run.narrationId, 'IC_1');
      },
    );

    test('the retry fields: the count, the backoff deadline, the '
        'processed-narration id', () async {
      final store = AfkStore(file: file);
      await store.addRun(7, 'Add a README');
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          retryCount: 2,
          retryAt: 1761000000000,
          narrationId: 'IC_9',
        ),
      );
      final run = AfkStore(file: file).runFor(7)!;
      expect(run.retryCount, 2);
      expect(run.retryAt, 1761000000000);
      expect(run.narrationId, 'IC_9');
    });

    test('updateRun upserts: the row is replaced wholesale (a cleared PR '
        'number stays cleared)', () async {
      final store = AfkStore(file: file);
      await store.addRun(7, 'Add a README');
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
          prNumber: 41,
        ),
      );
      await store.updateRun(
        const AfkRun(
          issueNumber: 7,
          title: 'Add a README',
          state: 'done',
          closedUnmerged: true,
        ),
      );
      final run = store.runFor(7)!;
      expect(run.state, 'done');
      expect(run.prNumber, isNull);
      expect(run.closedUnmerged, isTrue);
    });

    test('a T2-era row (no new fields) reads back with the defaults '
        '(the store grows without migrating the rows)', () async {
      await file.writeAsString(
        jsonEncode({
          'afk.run.7': '{"state":"idle","issueNumber":7,"title":"A"}',
        }),
      );
      final run = AfkStore(file: file).runFor(7)!;
      expect(run.state, 'idle');
      expect(run.retryCount, 0);
      expect(run.prNumber, isNull);
      expect(run.prUrl, isNull);
      expect(run.closedUnmerged, isFalse);
      expect(run.retryAt, isNull);
      expect(run.narrationId, isNull);
    });

    test('a row with a corrupt new field degrades to the default for that '
        'field (never a throw)', () async {
      await file.writeAsString(
        jsonEncode({
          'afk.run.7': '{"state":"failed","issueNumber":7,"title":"A","retryCount":"lots"}',
        }),
      );
      final run = AfkStore(file: file).runFor(7)!;
      expect(run.state, 'failed');
      expect(run.retryCount, 0);
    });
  });

  group('the run row grows with the failure reason (spec #376, T6: the '
      'fresh-agent handoff\'s bootstrap lists why a run is retrying)', () {
    test(
      'updateRun persists lastFailureReason; runFor reads it back; a row '
      'without it (a T2/T3-era row) reads back null (tolerant decode)',
      () async {
        final store = AfkStore(file: file);
        await store.addRun(7, 'Add a README');
        await store.updateRun(
          const AfkRun(
            issueNumber: 7,
            title: 'Add a README',
            state: 'dispatched',
            retryCount: 1,
            lastFailureReason: 'model under load',
          ),
        );
        expect(
          AfkStore(file: file).runFor(7)!.lastFailureReason,
          'model under load',
        );

        // A row written before the field existed (no lastFailureReason key)
        // reads back null, never a throw.
        await file.writeAsString(
          jsonEncode({
            'afk.run.8': '{"state":"dispatched","issueNumber":8,"title":"B"}',
          }),
        );
        expect(AfkStore(file: file).runFor(8)!.lastFailureReason, isNull);
      },
    );

    test(
      'a wrong-typed lastFailureReason degrades to null (never a throw)',
      () async {
        await file.writeAsString(
          jsonEncode({
            'afk.run.7': '{"state":"dispatched","issueNumber":7,"title":"A","lastFailureReason":42}',
          }),
        );
        expect(AfkStore(file: file).runFor(7)!.lastFailureReason, isNull);
      },
    );

    test('copyWith clears lastFailureReason by an explicit null (the '
        'unset/cleared distinction)', () {
      const run = AfkRun(
        issueNumber: 7,
        title: 'Add a README',
        state: 'dispatched',
        lastFailureReason: 'model under load',
      );
      expect(run.copyWith().lastFailureReason, 'model under load');
      expect(run.copyWith(lastFailureReason: null).lastFailureReason, isNull);
    });
  });
}
