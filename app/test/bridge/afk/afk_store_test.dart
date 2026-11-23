import 'dart:async';
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

    test(
      'allSessionIds enumerates the stored per-repo ids, ignoring the '
      'legacy flat key and the run rows (disarming-stable set, T5)',
      () async {
        final store = AfkStore(file: file);
        await store.setSessionId('a/r', 'ses_a');
        await store.setSessionId('b/r', 'ses_b');
        await store.addRun('a/r', 7, 'Add a README');
        // A legacy flat key a pre-scoping file still carries: ignored on read
        // (no migration), so it is not mistaken for a per-repo session id.
        final map = store.load();
        map['afk.sessionId'] = 'ses_legacy';
        file.writeAsStringSync(jsonEncode(map));

        final reloaded = AfkStore(file: file);
        expect(reloaded.allSessionIds(), {'ses_a', 'ses_b'});

        // A cleared id drops out of the set (the key is removed on write).
        await reloaded.setSessionId('a/r', null);
        expect(AfkStore(file: file).allSessionIds(), {'ses_b'});
      },
    );

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

  group('concurrent writers and readers (issue #418)', () {
    test(
      'overlapping writers cannot lose an earlier write (the map is captured '
      'inside the serialized write)',
      () async {
        final fake = _FakeFile('${dir.path}/afk.json');
        final store = AfkStore(file: fake);
        // Hold the first write in flight: it has not landed on disk yet.
        fake.holdNextWrite();
        final first = store.addRun('a/r', 1, 'A');
        // The second writer starts while the first is in flight. An
        // unserialized read-modify-write loads a map that does not carry the
        // first writer's row, and its write lands over it.
        final second = store.addRun('b/r', 2, 'B');
        fake.releaseHeldWrites();
        await Future.wait([first, second]);
        expect(
          store.runFor('a/r', 1),
          isNotNull,
          reason: 'the in-flight write must not be lost to the overlap',
        );
        expect(store.runFor('b/r', 2), isNotNull);
      },
    );

    test('a reader mid-write never sees a partial or missing file (the replace '
        'is atomic)', () async {
      final fake = _FakeFile('${dir.path}/afk.json');
      // The store's staging file, injected: the test holds the rename from it,
      // so the write is truly mid-flight — staged content written, target
      // still untouched.
      final staged = _FakeFile('${dir.path}/afk.json.afk-tmp.test');
      final store = AfkStore(file: fake, tempFile: (_) => staged);
      await store.updateRun(
        const AfkRun(
          ownerRepo: 'o/r',
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      staged.holdNextRename();
      final pending = store.updateRun(
        const AfkRun(
          ownerRepo: 'o/r',
          issueNumber: 7,
          title: 'Add a README',
          state: 'pr-open',
        ),
      );
      // Suspend until the rename itself is in flight. A truncate-then-write
      // store would have emptied or truncated the target by now; the atomic
      // replace leaves it holding the previous complete state.
      await staged.holdFired;
      final mid = AfkStore(file: fake).runFor('o/r', 7);
      expect(mid, isNotNull, reason: 'a mid-write read is never torn');
      expect(mid!.state, 'dispatched', reason: 'the replace is atomic');
      staged.releaseHeldWrites();
      await pending;
      expect(store.runFor('o/r', 7)!.state, 'pr-open');
    });
  });
}

/// The [File] seam for the store's concurrency tests (issue #418): delegates
/// to a real file on disk, but lets a test hold an operation in flight. Two
/// holds, each pinning one side of the atomic-write contract:
///
/// - [holdNextWrite] holds a direct `writeAsString` on the target (the
///   non-atomic truncate+write path), leaving the on-disk file truncated —
///   exactly what that path exposes mid-flight to a synchronous reader. Under
///   the atomic implementation the store never writes the target directly, so
///   the hold never fires.
/// - [holdNextRename] holds the staged replace: the sibling file already
///   carries the new content while the target still holds the old one.
/// [holdFired] completes when the next held operation has gone in flight, so
/// a test can read at a deterministic mid-write instant.
class _FakeFile implements File {
  _FakeFile(String path) : _real = File(path), path = path;

  final File _real;
  @override
  final String path;

  bool _holdNextWrite = false;
  bool _holdNextRename = false;
  final List<Completer<void>> _held = [];
  final Completer<void> _holdFired = Completer<void>();

  /// Hold the next [writeAsString] in flight (leaving the file truncated)
  /// until [releaseHeldWrites].
  void holdNextWrite() => _holdNextWrite = true;

  /// Hold the next [rename] in flight until [releaseHeldWrites].
  void holdNextRename() => _holdNextRename = true;

  /// Completes when the next held operation has gone in flight and is
  /// waiting for [releaseHeldWrites].
  Future<void> get holdFired => _holdFired.future;

  /// Land every held operation, in the order held.
  void releaseHeldWrites() {
    for (final held in _held) {
      held.complete();
    }
    _held.clear();
  }

  void _fireHold() {
    if (!_holdFired.isCompleted) _holdFired.complete();
  }

  @override
  bool existsSync() => _real.existsSync();

  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      _real.readAsStringSync(encoding: encoding);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (_holdNextWrite) {
      _holdNextWrite = false;
      // The truncated view: a real writeAsString empties the file before the
      // content lands, so a write held in flight is observed truncated.
      _real.writeAsStringSync('');
      final held = Completer<void>();
      _held.add(held);
      _fireHold();
      await held.future;
    }
    await _real.writeAsString(contents, encoding: encoding, flush: flush);
    return _real;
  }

  @override
  Future<File> rename(String newPath) async {
    if (_holdNextRename) {
      _holdNextRename = false;
      // The staged file already carries the new content; the target still
      // holds the old one until this rename lands.
      final held = Completer<void>();
      _held.add(held);
      _fireHold();
      await held.future;
    }
    return _real.rename(newPath);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  Directory get parent => _real.parent;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not faked: ${invocation.memberName}');
}
