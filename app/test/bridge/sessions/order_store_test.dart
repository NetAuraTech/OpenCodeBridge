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
