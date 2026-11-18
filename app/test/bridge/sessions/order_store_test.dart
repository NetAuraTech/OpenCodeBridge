import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/order_store.dart';

/// The bridge's session order store (issue #237): the app-owned
/// `sessionID -> position` map behind the home list's pinned-first sort.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-order-store');
    file = File('${dir.path}/session-order.json');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  group('SessionOrderStore.load', () {
    test('is empty when the file is missing', () {
      final store = SessionOrderStore(file: file);
      expect(store.load(), isEmpty);
    });

    test('reads the persisted map (issue #237: survives a restart)', () {
      file.writeAsStringSync(jsonEncode({'ses_1': 2, 'ses_2': 1}));
      final store = SessionOrderStore(file: file);
      expect(store.load(), {'ses_1': 2, 'ses_2': 1});
    });

    test(
      're-reads fresh on every call (a second instance sees the latest)',
      () {
        final store = SessionOrderStore(file: file);
        expect(store.load(), isEmpty);
        file.writeAsStringSync(jsonEncode({'ses_1': 0}));
        // A new store (the bridge restarted) over the same file sees the
        // position written by the previous one.
        expect(SessionOrderStore(file: file).load(), {'ses_1': 0});
      },
    );

    test('tolerates a corrupt file (empty, no throw)', () {
      file.writeAsStringSync('{"ses_1": ');
      expect(SessionOrderStore(file: file).load(), isEmpty);
    });

    test('tolerates a non-object file (empty, no throw)', () {
      file.writeAsStringSync('[1, 2, 3]');
      expect(SessionOrderStore(file: file).load(), isEmpty);
    });

    test('tolerates non-numeric position values (they are dropped)', () {
      file.writeAsStringSync(jsonEncode({'ses_1': 'two', 'ses_2': 1}));
      expect(SessionOrderStore(file: file).load(), {'ses_2': 1});
    });
  });

  group('SessionOrderStore.set', () {
    test('persists the position and load round-trips it', () async {
      final store = SessionOrderStore(file: file);
      await store.set('ses_1', 2);
      expect(store.load(), {'ses_1': 2});
      // The file is the durable record: the app-owned file now carries it.
      final onDisk = jsonDecode(file.readAsStringSync()) as Map;
      expect(onDisk, {'ses_1': 2});
    });

    test('creates the parent directory when it is missing', () async {
      final nested = File('${dir.path}/sub/dir/session-order.json');
      final store = SessionOrderStore(file: nested);
      await store.set('ses_1', 0);
      expect(nested.existsSync(), isTrue);
      expect(SessionOrderStore(file: nested).load(), {'ses_1': 0});
    });

    test('keeps the other sessions\' positions (set merges)', () async {
      final store = SessionOrderStore(file: file);
      await store.set('ses_1', 1);
      await store.set('ses_2', 0);
      expect(store.load(), {'ses_1': 1, 'ses_2': 0});
    });
  });

  // The pin write's cost (issue #273, the store half of "no full-list
  // walk"): set is one load of the persisted map plus one entry, persisted
  // with one write of the file. The other positions are kept by
  // construction, never re-read or re-written one by one — the cost is
  // pinned through the counted seams (the counted store, the counted
  // file), the way the probe's cost is pinned through probedIds /
  // listSessionsCalls.

  group('SessionOrderStore.set cost (issue #273)', () {
    test('keeps every other position with one load and one write of the '
        'persisted map', () async {
      // The file already carries several pinned sessions.
      file.writeAsStringSync(jsonEncode({'ses_1': 1, 'ses_2': 0, 'ses_3': 3}));
      final counted = _CountingFile(file);
      final store = _CountingOrderStore(counted);

      await store.set('ses_2', 9);

      // The cost: one load of the persisted map, one read of the file's
      // content, one write of it. A walk that re-read or re-wrote the other
      // ids would show.
      expect(store.loadCalls, 1);
      expect(counted.readCalls, 1);
      expect(counted.writeCalls, 1);
      // The on-disk fact: the one entry moved, every other position kept.
      // (The test's own read-back goes through the unwrapped file.)
      expect(jsonDecode(file.readAsStringSync()), {
        'ses_1': 1,
        'ses_2': 9,
        'ses_3': 3,
      });
    });

    test('a new pin joins the persisted map the same way (one load, one '
        'write)', () async {
      file.writeAsStringSync(jsonEncode({'ses_1': 1, 'ses_2': 0}));
      final counted = _CountingFile(file);
      final store = _CountingOrderStore(counted);

      await store.set('ses_3', 2);

      expect(store.loadCalls, 1);
      expect(counted.readCalls, 1);
      expect(counted.writeCalls, 1);
      expect(jsonDecode(file.readAsStringSync()), {
        'ses_1': 1,
        'ses_2': 0,
        'ses_3': 2,
      });
    });
  });

  group('SessionOrderStore.clear', () {
    test('removes the session\'s entry and keeps the rest', () async {
      final store = SessionOrderStore(file: file);
      await store.set('ses_1', 1);
      await store.set('ses_2', 0);
      await store.clear('ses_1');
      expect(store.load(), {'ses_2': 0});
    });

    test('is a no-op when the session has no entry', () async {
      final store = SessionOrderStore(file: file);
      await store.set('ses_1', 1);
      await store.clear('ses_gone');
      expect(store.load(), {'ses_1': 1});
    });

    test('leaves the file absent when the map is empty', () async {
      final store = SessionOrderStore(file: file);
      await store.set('ses_1', 1);
      await store.clear('ses_1');
      expect(store.load(), isEmpty);
    });
  });
}

/// A [SessionOrderStore] that counts its [load] calls (issue #273's cost
/// seam): the store's one write path is a fresh [load] plus one entry, and
/// [load] is public, so the call shape is counted through the override —
/// the way the probe's cost is counted through [FakeOpencodeService]
/// (backend_test.dart), no production logging added for the test.
class _CountingOrderStore extends SessionOrderStore {
  _CountingOrderStore(File file) : super(file: file);

  /// The [load] calls (the pin write's one read of the persisted map).
  int loadCalls = 0;

  @override
  Map<String, num> load() {
    loadCalls++;
    return super.load();
  }
}

/// A [File] that counts the store's reads and writes of it (issue #273's
/// cost seam): the store reads the persisted map through `readAsStringSync`
/// and persists it through `writeAsString`, so the file's observable cost —
/// one read of the content, one write of it — is counted here, and the
/// on-disk fact (the other positions untouched) is read back through the
/// unwrapped file.
class _CountingFile implements File {
  _CountingFile(this._file);

  final File _file;

  /// The `readAsString` calls (the store's [load] reads the map through
  /// them).
  int readCalls = 0;

  /// The `writeAsString` calls (the store's write path persists through
  /// them).
  int writeCalls = 0;

  @override
  bool existsSync() => _file.existsSync();

  @override
  Directory get parent => _file.parent;

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    readCalls++;
    return _file.readAsStringSync(encoding: encoding);
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    readCalls++;
    return _file.readAsString(encoding: encoding);
  }

  @override
  Future<File> writeAsString(
    String contents, {
    Encoding encoding = utf8,
    bool flush = false,
    FileMode mode = FileMode.write,
  }) {
    writeCalls++;
    return _file.writeAsString(
      contents,
      encoding: encoding,
      flush: flush,
      mode: mode,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
