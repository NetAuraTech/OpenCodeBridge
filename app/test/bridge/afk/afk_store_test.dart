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
}
