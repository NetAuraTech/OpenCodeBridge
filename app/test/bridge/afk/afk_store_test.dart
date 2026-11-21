import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';

/// The bridge's persisted AFK machine state (spec #407, T1): the app-owned
/// file, now keyed **per repo identity** — one AFK session id per repo
/// (`afk.session.<owner/repo>`) and one run row per (repo, issue)
/// (`afk.run.<owner/repo>.<issue>`, the row carrying `ownerRepo`). The
/// pre-scoping flat keys (`afk.sessionId`, `afk.run.<issue>`) are ignored on
/// read and never written back (no migration).
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

  group('AfkStore (per-repo session id)', () {
    test('reads empty when the file is missing (a fresh machine)', () {
      final store = AfkStore(file: file);
      expect(store.sessionIdFor('o/r'), isNull);
      expect(store.allRuns(), isEmpty);
      expect(store.load(), isEmpty);
    });

    test('degrades to empty on a corrupt or non-object file', () {
      file.writeAsStringSync('not json');
      expect(AfkStore(file: file).load(), isEmpty);
      file.writeAsStringSync(jsonEncode([1, 2, 3]));
      expect(AfkStore(file: file).load(), isEmpty);
    });

    test(
      'stores and re-reads a repo session id (survives a restart)',
      () async {
        final store = AfkStore(file: file);
        await store.setSessionId('o/r', 'ses_afk_1');
        expect(AfkStore(file: file).sessionIdFor('o/r'), 'ses_afk_1');
      },
    );

    test('two repos hold two independent session ids', () async {
      final store = AfkStore(file: file);
      await store.setSessionId('a/r', 'ses_a');
      await store.setSessionId('b/r', 'ses_b');
      final reloaded = AfkStore(file: file);
      expect(reloaded.sessionIdFor('a/r'), 'ses_a');
      expect(reloaded.sessionIdFor('b/r'), 'ses_b');
      // Clearing one repo leaves the other.
      await reloaded.setSessionId('a/r', null);
      final after = AfkStore(file: file);
      expect(after.sessionIdFor('a/r'), isNull);
      expect(after.sessionIdFor('b/r'), 'ses_b');
    });

    test('clearing the only session id removes the file (no cruft)', () async {
      await AfkStore(file: file).setSessionId('o/r', 'ses_afk_1');
      expect(file.existsSync(), isTrue);
      await AfkStore(file: file).setSessionId('o/r', null);
      expect(AfkStore(file: file).sessionIdFor('o/r'), isNull);
      expect(file.existsSync(), isFalse);
    });

    test('a repo session id coexists with run rows and other repos', () async {
      final store = AfkStore(file: file);
      await store.setSessionId('o/r', 'ses_afk_1');
      await store.addRun('o/r', 7, 'Add a README');
      await store.addRun('other/r', 7, 'A different issue 7');
      final reloaded = AfkStore(file: file);
      expect(reloaded.sessionIdFor('o/r'), 'ses_afk_1');
      expect(reloaded.runFor('o/r', 7)!.title, 'Add a README');
      expect(reloaded.runFor('other/r', 7)!.title, 'A different issue 7');
    });
  });

  group('run rows (keyed per repo, carrying ownerRepo)', () {
    test('addRun persists + runFor reads back (ownerRepo, state idle, number, '
        'title)', () async {
      final store = AfkStore(file: file);
      await store.addRun('o/r', 7, 'Add a README');
      final run = AfkStore(file: file).runFor('o/r', 7);
      expect(run, isNotNull);
      expect(run!.ownerRepo, 'o/r');
      expect(run.issueNumber, 7);
      expect(run.title, 'Add a README');
      expect(run.state, 'idle');
    });

    test('the same issue number in two repos is two distinct rows', () async {
      final store = AfkStore(file: file);
      await store.addRun('a/r', 7, 'A issue 7');
      await store.addRun('b/r', 7, 'B issue 7');
      final reloaded = AfkStore(file: file);
      expect(reloaded.runFor('a/r', 7)!.title, 'A issue 7');
      expect(reloaded.runFor('b/r', 7)!.title, 'B issue 7');
      expect(reloaded.allRuns(), hasLength(2));
    });

    test(
      'runsFor(repo) lists that repo rows, sorted by issue number',
      () async {
        final store = AfkStore(file: file);
        await store.addRun('o/r', 9, 'Nine');
        await store.addRun('o/r', 7, 'Seven');
        await store.addRun('other/r', 1, 'One');
        final reloaded = AfkStore(file: file);
        expect(reloaded.runsFor('o/r').map((r) => r.issueNumber).toList(), [
          7,
          9,
        ]);
        expect(reloaded.runsFor('other/r').map((r) => r.issueNumber).toList(), [
          1,
        ]);
        expect(
          reloaded.runsFor('a/repo'),
          isEmpty,
          reason: 'no rows for a repo with none',
        );
      },
    );

    test('allRuns() lists every repo row, sorted by issue number', () async {
      final store = AfkStore(file: file);
      await store.addRun('b/r', 7, 'B7');
      await store.addRun('a/r', 9, 'A9');
      await store.addRun('a/r', 7, 'A7');
      final rows = AfkStore(file: file).allRuns();
      expect(rows.map((r) => r.issueNumber).toList(), [7, 7, 9]);
    });

    test('addRun upserts: re-adding (repo, issue) updates its row', () async {
      final store = AfkStore(file: file);
      await store.addRun('o/r', 7, 'Old title');
      await store.addRun('o/r', 7, 'New title');
      expect(AfkStore(file: file).runFor('o/r', 7)!.title, 'New title');
      expect(AfkStore(file: file).allRuns(), hasLength(1));
    });

    test('a corrupt (repo, issue) row reads as absent', () async {
      await file.writeAsString(
        jsonEncode({
          'afk.run.o/r.7': 'not json',
          'afk.run.o/r.9': '{"ownerRepo":"o/r","state":"idle","issueNumber":9,"title":"Nine"}',
        }),
      );
      final store = AfkStore(file: file);
      expect(store.runFor('o/r', 7), isNull);
      expect(store.runFor('o/r', 8), isNull);
      expect(store.allRuns().map((r) => r.issueNumber).toList(), [9]);
    });
  });

  group('the run row carries ownerRepo (the run-state fields round-trip)', () {
    test(
      'updateRun persists the full per-repo row; runFor reads every field back',
      () async {
        final store = AfkStore(file: file);
        await store.addRun('o/r', 7, 'Add a README');
        await store.updateRun(
          const AfkRun(
            ownerRepo: 'o/r',
            issueNumber: 7,
            title: 'Add a README',
            state: 'pr-open',
            prNumber: 41,
            prUrl: 'https://github.com/org/repo/pull/41',
            narrationId: 'IC_1',
          ),
        );
        final run = AfkStore(file: file).runFor('o/r', 7)!;
        expect(run.ownerRepo, 'o/r');
        expect(run.state, 'pr-open');
        expect(run.retryCount, 0);
        expect(run.prNumber, 41);
        expect(run.prUrl, 'https://github.com/org/repo/pull/41');
        expect(run.closedUnmerged, isFalse);
        expect(run.retryAt, isNull);
        expect(run.narrationId, 'IC_1');
      },
    );

    test('updateRun keys the row by the run own ownerRepo (a repo mismatch in '
        'the key and the row would be a bug)', () async {
      final store = AfkStore(file: file);
      await store.addRun('o/r', 7, 'Add a README');
      await store.updateRun(
        const AfkRun(
          ownerRepo: 'o/r',
          issueNumber: 7,
          title: 'Add a README',
          state: 'failed',
          retryCount: 3,
          lastFailureReason: 'model under load',
        ),
      );
      final run = AfkStore(file: file).runFor('o/r', 7)!;
      expect(run.state, 'failed');
      expect(run.retryCount, 3);
      expect(run.lastFailureReason, 'model under load');
    });

    test('copyWith replaces state fields but not the identity', () {
      const run = AfkRun(
        ownerRepo: 'o/r',
        issueNumber: 7,
        title: 'T',
        state: 'idle',
      );
      final next = run.copyWith(state: 'dispatched');
      expect(next.ownerRepo, 'o/r');
      expect(next.issueNumber, 7);
      expect(next.title, 'T');
      expect(next.state, 'dispatched');
    });
  });

  group('no migration (the legacy flat keys are ignored, never written back)', () {
    test(
      'a legacy flat file (afk.sessionId + afk.run.<n>) reads as empty',
      () async {
        await file.writeAsString(
          jsonEncode({
            'afk.sessionId': 'ses_legacy',
            'afk.run.7': '{"state":"idle","issueNumber":7,"title":"Legacy"}',
          }),
        );
        final store = AfkStore(file: file);
        // The per-repo accessors never see the legacy flat keys.
        expect(store.sessionIdFor('o/r'), isNull);
        expect(store.sessionIdFor('NetAuraTech/OpenCodeBridge'), isNull);
        expect(store.runFor('o/r', 7), isNull);
        expect(store.allRuns(), isEmpty);
      },
    );

    test(
      'a write drops the legacy flat keys (they are not written back)',
      () async {
        // A pre-scoping file with the legacy keys.
        await file.writeAsString(
          jsonEncode({
            'afk.sessionId': 'ses_legacy',
            'afk.run.7': '{"state":"idle","issueNumber":7,"title":"Legacy"}',
          }),
        );
        // Any per-repo write loads the legacy map and must drop the flat keys.
        await AfkStore(file: file).addRun('o/r', 9, 'Nine');
        final reloaded = AfkStore(file: file);
        final map = reloaded.load();
        expect(map.containsKey('afk.sessionId'), isFalse);
        expect(map.containsKey('afk.run.7'), isFalse);
        // The new per-repo row is present.
        expect(map.containsKey('afk.run.o/r.9'), isTrue);
        expect(reloaded.runFor('o/r', 9)!.title, 'Nine');
        expect(reloaded.allRuns(), hasLength(1));
      },
    );

    test(
      'the legacy flat keys never appear on any read after a fresh write',
      () async {
        final store = AfkStore(file: file);
        await store.setSessionId('o/r', 'ses_1');
        await store.addRun('o/r', 7, 'A README');
        final reloaded = AfkStore(file: file);
        final map = reloaded.load();
        expect(map.containsKey('afk.sessionId'), isFalse);
        expect(map.containsKey('afk.run.7'), isFalse);
        expect(map.containsKey('afk.session.o/r'), isTrue);
        expect(map.containsKey('afk.run.o/r.7'), isTrue);
      },
    );
  });
}
