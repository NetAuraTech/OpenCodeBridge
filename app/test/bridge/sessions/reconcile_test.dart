import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/reconcile.dart';
import 'package:opencodebridge/bridge/sessions/session_store.dart';

void main() {
  late Directory dir;

  Future<void> seed(List<String> ids) async {
    final store = await SessionStore.load(dir: dir);
    for (final id in ids) {
      store.add(id);
    }
    await store.save();
  }

  String fileBytes() =>
      File('${dir.path}/${SessionStore.fileName}').readAsStringSync();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-reconcile');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  group('reconcileOrphans', () {
    test(
      'no orphans -> nothing dropped, file byte-for-byte unchanged',
      () async {
        await seed(['ses_a', 'ses_b']);
        final before = fileBytes();

        final dropped = await reconcileOrphans(
          await SessionStore.load(dir: dir),
          {'ses_a', 'ses_b', 'ses_c'},
        );

        expect(dropped, isEmpty);
        expect(fileBytes(), before);
      },
    );

    test('orphans are dropped and the file is rewritten', () async {
      await seed(['ses_a', 'ses_orphan', 'ses_b']);

      final dropped = await reconcileOrphans(
        await SessionStore.load(dir: dir),
        {'ses_a', 'ses_b'}, // ses_orphan is no longer on the service
      );

      expect(dropped, ['ses_orphan']);
      final reloaded = await SessionStore.load(dir: dir);
      expect(reloaded.ids(), {'ses_a', 'ses_b'});
    });

    test('every record an orphan -> all dropped, store empty', () async {
      await seed(['ses_a', 'ses_b']);
      final dropped = await reconcileOrphans(
        await SessionStore.load(dir: dir),
        const <String>{},
      );
      expect(dropped.toSet(), {'ses_a', 'ses_b'});
      expect((await SessionStore.load(dir: dir)).ids(), isEmpty);
    });
  });
}
