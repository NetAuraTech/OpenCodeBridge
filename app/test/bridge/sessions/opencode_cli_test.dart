import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/opencode_cli.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ocb-opencode-cli-test-');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  File fakeOpencode(Directory dir, {String? content}) {
    final file = File('${dir.path}/opencode')
      ..writeAsStringSync(
        content ??
            '#!/bin/sh\n'
                r'echo "argv: $*"'
                '\n'
                r'echo "PASSWORD: ${OPENCODE_PASSWORD:-<unset>}"'
                '\n',
      );
    Process.runSync('chmod', ['+x', file.path]);
    return file;
  }

  group('findHostOpencode', () {
    test('finds an executable on the given PATH', () {
      final bin = Directory('${tmp.path}/bin')..createSync();
      fakeOpencode(bin);
      final found = findHostOpencode(path: '${bin.path}:${tmp.path}/empty');
      expect(found, equals('${bin.path}/opencode'));
    });

    test('skips an entry without the exec bit', () {
      final bin = Directory('${tmp.path}/bin')..createSync();
      File('${bin.path}/opencode').writeAsStringSync('#!/bin/sh\n');
      // No chmod: the file is created without the exec bit.
      final found = findHostOpencode(path: bin.path);
      expect(found, isNull);
    });

    test('skips a directory entry named opencode', () {
      final dir = Directory('${tmp.path}/opencode')..createSync();
      final found = findHostOpencode(path: dir.parent.path);
      expect(found, isNull);
    });

    test('returns null when the PATH has no opencode', () {
      final found = findHostOpencode(path: '${tmp.path}/missing');
      expect(found, isNull);
    });
  });

  group('hostOpencodeRunner', () {
    test('runs the CLI and reports exit code, stdout, stderr', () async {
      final bin = Directory('${tmp.path}/bin')..createSync();
      final file = File('${bin.path}/opencode')
        ..writeAsStringSync(
          '#!/bin/sh\necho out-line\necho err-line >&2\nexit 3\n',
        );
      Process.runSync('chmod', ['+x', file.path]);
      final runner = hostOpencodeRunner(file.path);
      final result = await runner(['session', 'export', 'abc123']);
      expect(result.exitCode, 3);
      expect(result.stdout, 'out-line\n');
      expect(result.stderr, 'err-line\n');
    });

    test(
      'overlays env on the parent environment (not a replacement)',
      () async {
        // The parent environment must survive the overlay: HOME is the
        // bridge's own (this test process') environment, plus the overlay key.
        final bin = Directory('${tmp.path}/bin')..createSync();
        final file = File('${bin.path}/opencode')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            r'echo "PASSWORD: ${OPENCODE_PASSWORD:-<unset>}"'
            '\n'
            r'echo "HOME: ${HOME:-<unset>}"'
            '\n',
          );
        Process.runSync('chmod', ['+x', file.path]);
        final runner = hostOpencodeRunner(file.path);
        final result = await runner(
          ['session', 'export', 'abc123'],
          env: {'OPENCODE_PASSWORD': 's3cret'},
        );
        expect(result.stdout, contains('PASSWORD: s3cret'));
        expect(
          result.stdout,
          contains('HOME: ${Platform.environment['HOME']}'),
        );
      },
    );

    test(
      'inherits the parent environment untouched when env is null',
      () async {
        final bin = Directory('${tmp.path}/bin')..createSync();
        final file = File('${bin.path}/opencode')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            r'echo "HOME: ${HOME:-<unset>}"'
            '\n',
          );
        Process.runSync('chmod', ['+x', file.path]);
        final runner = hostOpencodeRunner(file.path);
        final result = await runner(['session', 'import', 'x.json']);
        expect(
          result.stdout,
          contains('HOME: ${Platform.environment['HOME']}'),
        );
      },
    );
  });
}
