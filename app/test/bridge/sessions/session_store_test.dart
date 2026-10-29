import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/session_store.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-store');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  group('SessionStore', () {
    test('missing file loads as an empty store', () async {
      final store = await SessionStore.load(dir: dir);
      expect(store.ids(), isEmpty);
    });

    test('save + load round-trips the recorded ids', () async {
      final store = await SessionStore.load(dir: dir);
      store.add('ses_a');
      store.add('ses_b');
      await store.save();

      final reloaded = await SessionStore.load(dir: dir);
      expect(reloaded.ids(), {'ses_a', 'ses_b'});
      expect(reloaded.has('ses_a'), isTrue);
      expect(reloaded.has('ses_zzz'), isFalse);
    });

    test('the on-disk file is schema v1, keyed by session id', () async {
      final store = await SessionStore.load(dir: dir);
      store.add('ses_a');
      await store.save();

      final raw = jsonDecode(
        File('${dir.path}/${SessionStore.fileName}').readAsStringSync(),
      ) as Map<String, Object?>;
      expect(raw['version'], 1);
      expect((raw['sessions'] as Map).keys.toList(), ['ses_a']);
      expect((raw['sessions'] as Map)['ses_a'], <String, Object?>{});
    });

    test('save is atomic: no leftover temp files remain', () async {
      final store = await SessionStore.load(dir: dir);
      store.add('ses_a');
      await store.save();

      final leftovers = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
      expect(File('${dir.path}/${SessionStore.fileName}').existsSync(), isTrue);
    });

    test('a corrupt file loads as an empty store, not a crash', () async {
      await File('${dir.path}/${SessionStore.fileName}')
          .writeAsString('{definitely not json');
      final store = await SessionStore.load(dir: dir);
      expect(store.ids(), isEmpty);
    });

    test('a wrong-version file loads as an empty store', () async {
      await File('${dir.path}/${SessionStore.fileName}').writeAsString(
        jsonEncode({
          'version': 99,
          'sessions': {'ses_a': {}},
        }),
      );
      final store = await SessionStore.load(dir: dir);
      expect(store.ids(), isEmpty);
    });

    test('remove drops an id and persists', () async {
      final store = await SessionStore.load(dir: dir);
      store.add('ses_a');
      store.add('ses_b');
      await store.save();

      expect(store.remove('ses_a'), isTrue);
      expect(store.remove('ses_missing'), isFalse);
      await store.save();

      final reloaded = await SessionStore.load(dir: dir);
      expect(reloaded.ids(), {'ses_b'});
    });

    test('save creates the directory when it does not exist yet', () async {
      final nested = Directory('${dir.path}/deep/nested');
      final store = await SessionStore.load(dir: nested);
      store.add('ses_a');
      await store.save();
      expect(nested.existsSync(), isTrue);
      expect(await SessionStore.load(dir: nested).then((s) => s.ids()), {
        'ses_a',
      });
    });
  });
}
