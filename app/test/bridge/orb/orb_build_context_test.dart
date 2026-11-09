import 'dart:convert';
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

    test(
      'the materialized boot script starts at the shebang (issue #145)',
      () async {
        // The bridge builds the image from this dir. A leading newline (or a
        // BOM) before `#!/bin/sh` runs the script fine but the image's
        // `docker exec`/`exec` form fatals with `exec format error` — the
        // failure a hand-written context hit. The embedded value must start at
        // byte 0 with the shebang.
        const key = 'orb-entrypoint.sh';
        final context = OrbBuildContext(dir: dir);
        await context.materialize();
        final written = File('${dir.path}/$key').readAsBytesSync();
        expect(written.sublist(0, 10), ascii.encode('#!/bin/sh\n'));
        expect(written, utf8.encode(OrbEmbedded.files[key]!));
      },
    );

    test('never overwrites an existing file (the on-disk copy is the source '
        'of truth)', () async {
      final context = OrbBuildContext(dir: dir);
      await context.materialize();
      final file = File('${dir.path}/Dockerfile');
      await file.writeAsString('ARG OPENCODE_VERSION=9.9.9\n');
      await context.materialize();
      expect(file.readAsStringSync(), 'ARG OPENCODE_VERSION=9.9.9\n');
    });

    test('a stale boot script is replaced on the next startup, its user pins '
        'kept (issue #145)', () async {
      // The defect: the app's own code (the entrypoint) was written
      // create-if-missing like the user's Dockerfile, so an install created
      // at 2026-11-05 froze a 60-line entrypoint forever — #94's services,
      // #120's GH_CONFIG_DIR export and #149's shell probe never reached any
      // orb, and the image tag stayed in sync with that frozen file by
      // construction. The app's code must follow the app; the pins are the
      // user's.
      final stale =
          '#!/bin/sh\n'
          '# Orb container entrypoint (issue #93),\n'
          'exec opencode serve --hostname 0.0.0.0 --port 4096\n';
      File('${dir.path}/orb-entrypoint.sh').writeAsStringSync(stale);
      final pin = 'ARG OPENCODE_VERSION=9.9.9\n';
      File('${dir.path}/Dockerfile').writeAsStringSync(pin);

      final context = OrbBuildContext(dir: dir);
      await context.materialize();

      // The app's code follows the app...
      expect(
        File('${dir.path}/orb-entrypoint.sh').readAsStringSync(),
        OrbEmbedded.files['orb-entrypoint.sh'],
        reason: 'a stale entrypoint must be upgraded, not frozen',
      );
      // ... and it is NOT the stale bytes (the anti-tautology half).
      expect(
        File('${dir.path}/orb-entrypoint.sh').readAsStringSync(),
        isNot(stale),
      );
      expect(
        File('${dir.path}/orb-entrypoint.sh').readAsStringSync(),
        contains('GH_CONFIG_DIR'),
      );
      expect(
        File('${dir.path}/orb-entrypoint.sh').readAsStringSync(),
        contains('stage: shell'),
      );
      // ... the user's pins stay theirs.
      expect(File('${dir.path}/Dockerfile').readAsStringSync(), pin);
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
        'TYPESENSE_VERSION=28.0',
        'MAILHOG_VERSION=1.0.1',
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

    test('the typesense source is the official dl.typesense.org release with '
        'the pinned md5 verified (the former download.typesense.org domain '
        'is dead — the image must still build)', () {
      final dockerfile = OrbEmbedded.files['Dockerfile']!;
      expect(
        dockerfile,
        contains(r'dl.typesense.org/releases/${TYPESENSE_VERSION}/'),
      );
      expect(dockerfile, isNot(contains('download.typesense.org')));
      expect(dockerfile, contains('typesense-server.md5.txt'));
      expect(dockerfile, contains('md5sum'));
    });

    test('the entrypoint does the full boot prep and then serves opencode '
        '(issue #94)', () {
      final entrypoint = OrbEmbedded.files['orb-entrypoint.sh'];
      // The installers (spec §6.3).
      expect(entrypoint, contains('npm ci'));
      expect(entrypoint, contains('npm install'));
      expect(entrypoint, contains('composer install'));
      expect(entrypoint, contains('flutter pub get'));
      // The local services (spec §6.4), bound to loopback in-container.
      expect(entrypoint, contains('pg_ctl'));
      expect(
        entrypoint,
        contains('redis-server --daemonize yes --bind 127.0.0.1'),
      );
      expect(entrypoint, contains('typesense-server'));
      expect(entrypoint, contains('mailhog'));
      // The health gate (spec §6.5) as a named constant.
      expect(entrypoint, contains('SERVICE_HEALTH_TIMEOUT_SECONDS=30'));
      // The boot stages (spec §9.3/§9.4).
      expect(entrypoint, contains('[orb] stage:'));
      // Serve opencode on the fixed in-container port (spec §2.9).
      expect(entrypoint, contains('exec opencode serve'));
    });
  });
}
