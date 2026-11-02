import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/fs/fs_service.dart';
import 'package:opencodebridge/bridge/fs/linux_fs_service.dart';

void main() {
  group('LinuxFsService', () {
    late Directory tmp;
    late File mountsFile;
    late LinuxFsService service;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fs-service');
      mountsFile = File('${tmp.path}/mounts');
      service = LinuxFsService(mountsPath: mountsFile.path);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test(
      'drives keeps the real mounts, drops pseudo fstypes and unmounted',
      () async {
        final a = Directory('${tmp.path}/a')..createSync();
        final b = Directory('${tmp.path}/b')..createSync();
        final gone = Directory('${tmp.path}/gone');
        final mem = Directory('${tmp.path}/mem')..createSync();
        mountsFile.writeAsStringSync(
          [
            '/\t${tmp.path}\text4\trw 0 0',
            '/dev/loop0\t${a.path}\text4\trw,relatime 0 0',
            '/dev/loop1\t${b.path}\txfs\trw 0 0',
            '/dev/loop2\t${gone.path}\text4\trw 0 0',
            'tmpfs\t${mem.path}\ttmpfs\trw,relatime 0 0',
          ].join('\n'),
        );
        expect(await service.drives(), [tmp.path, a.path, b.path]);
      },
    );

    test(
      'drives returns an empty list when the mount table is unreadable',
      () async {
        expect(await service.drives(), isEmpty);
      },
    );

    test(
      'subdirectories lists subdirectories only, full paths, sorted',
      () async {
        Directory('${tmp.path}/b').createSync();
        Directory('${tmp.path}/a').createSync();
        File('${tmp.path}/note.txt').createSync();
        Directory('${tmp.path}/B').createSync();
        expect(await service.subdirectories(tmp.path), [
          '${tmp.path}/B',
          '${tmp.path}/a',
          '${tmp.path}/b',
        ]);
      },
    );

    test('subdirectories rejects a non-absolute path with badPath', () async {
      final error = await capture(() => service.subdirectories('relative/dir'));
      expect(error, isA<FsError>());
      expect(error!.kind, FsErrorKind.badPath);
    });

    test('subdirectories maps a missing directory to notFound', () async {
      final error = await capture(
        () => service.subdirectories('${tmp.path}/nope'),
      );
      expect(error, isA<FsError>());
      expect(error!.kind, FsErrorKind.notFound);
    });

    test('subdirectories maps a path that is a file to notFound', () async {
      final file = File('${tmp.path}/note.txt')..createSync();
      final error = await capture(() => service.subdirectories(file.path));
      expect(error, isA<FsError>());
      expect(error!.kind, FsErrorKind.notFound);
    });

    test(
      'subdirectories maps a permission denial to permissionDenied',
      () async {
        if (_runningAsRoot()) {
          markTestSkipped('permission denial cannot be exercised as root');
        }
        final locked = Directory('${tmp.path}/locked')..createSync();
        Process.runSync('chmod', ['0', locked.path]);
        try {
          final error = await capture(
            () => service.subdirectories(locked.path),
          );
          expect(error, isA<FsError>());
          expect(error!.kind, FsErrorKind.permissionDenied);
        } finally {
          // Restored so tearDown can delete the tree.
          Process.runSync('chmod', ['755', locked.path]);
        }
      },
    );
  });
}

Future<FsError?> capture(Future<List<String>> Function() call) async {
  try {
    await call();
    return null;
  } on FsError catch (e) {
    return e;
  }
}

/// Whether the test runs as root, under which a mode-000 directory is still
/// listable and the permission denial cannot be exercised.
bool _runningAsRoot() {
  try {
    final out = Process.runSync('id', ['-u'], runInShell: true);
    return out.exitCode == 0 && out.stdout.toString().trim() == '0';
  } on Object {
    return false;
  }
}
