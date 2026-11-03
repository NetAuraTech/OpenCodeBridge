import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/orb/orb_build_context.dart';
import 'package:opencodebridge/bridge/orb/orb_embedded.dart';

void main() {
  group('OrbBuildContext.materialize (issue #92)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('oc-orb-ctx');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('writes the embedded files when the dir is missing', () async {
      final context = OrbBuildContext(dir: dir);
      await context.materialize();
      for (final entry in OrbEmbedded.files.entries) {
        final file = File('${dir.path}/${entry.key}');
        expect(
          file.readAsStringSync(),
          entry.value,
          reason: 'the ${entry.key} comes from the embedded copy',
        );
      }
    });

    test('never overwrites an existing file (the on-disk copy is the source '
        'of truth)', () async {
      final context = OrbBuildContext(dir: dir);
      await context.materialize();
      final file = File('${dir.path}/Dockerfile');
      await file.writeAsString('ARG OPENCODE_VERSION=9.9.9\n');
      await context.materialize();
      expect(file.readAsStringSync(), 'ARG OPENCODE_VERSION=9.9.9\n');
    });

    test('is stable across startups: the tag does not change', () async {
      final context = OrbBuildContext(dir: dir);
      await context.materialize();
      final first = context.expectedTag();
      await context.materialize(); // The next app startup.
      expect(context.expectedTag(), first);
    });

    test('the tag is orb:<12 hex characters>', () async {
      final context = OrbBuildContext(dir: dir);
      await context.materialize();
      expect(context.expectedTag(), matches(RegExp(r'^orb:[0-9a-f]{12}$')));
    });

    test('an on-disk edit changes the tag (the new tag builds without '
        'touching the existing image)', () async {
      final context = OrbBuildContext(dir: dir);
      await context.materialize();
      final before = context.expectedTag();
      await File('${dir.path}/Dockerfile')
          .writeAsString('ARG OPENCODE_VERSION=2.1.5\n');
      expect(context.expectedTag(), isNot(before));
    });

    test('reset = delete the files: the next materialize restores the '
        'embedded copy and the original tag', () async {
      final context = OrbBuildContext(dir: dir);
      await context.materialize();
      final first = context.expectedTag();
      await dir.delete(recursive: true);
      await context.materialize();
      expect(context.expectedTag(), first);
      expect(
        File('${dir.path}/Dockerfile').readAsStringSync(),
        OrbEmbedded.files['Dockerfile'],
      );
    });
  });

  group('OrbEmbedded (issue #92)', () {
    test('the Dockerfile pins every toolchain as an ARG with a default', () {
      final dockerfile = OrbEmbedded.files['Dockerfile']!;
      for (final arg in [
        'BASE_IMAGE=ubuntu:24.04',
        'NODE_VERSION=22.14.0',
        'NPM_VERSION=10.9.2',
        'PHP_VERSION=8.3',
        'FLUTTER_VERSION=3.47.8',
        'REDIS_VERSION=7.4.0',
        'POSTGRES_VERSION=16',
        'TYPESENSE_VERSION=28.1',
        'MAILHOG_VERSION=1.2.0',
        'GIT_VERSION=2.43',
        'OPENCODE_VERSION=2.1.4',
      ]) {
        expect(dockerfile, contains('ARG $arg'), reason: 'missing pin: $arg');
      }
    });

    test('installs opencode v2 from @opencode/cli', () {
      final dockerfile = OrbEmbedded.files['Dockerfile']!;
      expect(dockerfile, contains(r'@opencode/cli@${OPENCODE_VERSION}'));
    });

    test('the entrypoint is a placeholder that starts opencode', () {
      expect(
        OrbEmbedded.files['orb-entrypoint.sh'],
        contains('exec opencode serve'),
      );
    });
  });
}
