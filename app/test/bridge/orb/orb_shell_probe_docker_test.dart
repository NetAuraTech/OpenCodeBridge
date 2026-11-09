@Tags(['docker'])
library;

// The shell probe's ground truth (issue #149, spec §6.8): not the agent's
// prose, not a fake of the container — the EMBEDDED entrypoint booted in a REAL
// container derived from the pinned orb base image, asked to run the smoke
// command.
//
// Opt-in: `flutter test --tags docker`. Skipped when this host has no daemon or
// no `orb:<hash>` base image. The orb image is the base image plus the
// entrypoint (spec §5.2), so the derived image swaps only the entrypoint — the
// rest (sh, git, gh, node, opencode) is exactly the orb's.
//
// The clone source is a bare repo bind-mounted read-only and copied inside the
// container, so the clone is a plain local one: no network, no host uid.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/orb/orb_embedded.dart';

const _derived = 'orb-shell-probe:test';

Future<(int, String, String)> _docker(List<String> argv) async {
  final result = await Process.run('docker', argv);
  return (result.exitCode, result.stdout as String, result.stderr as String);
}

void main() {
  late Directory root;
  late String? base;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('oc-orb-shell-149-');
    final (info, _, _) = await _docker([
      'info',
      '--format',
      '{{.ServerVersion}}',
    ]);
    if (info != 0) {
      base = null;
      return;
    }
    final (_, images, _) = await _docker([
      'images',
      '--format',
      '{{.Repository}}:{{.Tag}}',
    ]);
    base = const LineSplitter()
        .convert(images)
        .where((line) => line.startsWith('orb:'))
        .firstOrNull;
    if (base == null) return;

    // The seed: a tiny committed repo, so the first-start clone finds a
    // branch to check out.
    final seed = Directory('${root.path}/seed')..createSync();
    await Process.run('git', [
      'init',
      '-q',
      '-b',
      'main',
    ], workingDirectory: seed.path);
    File('${seed.path}/README.md').writeAsStringSync('seed\n');
    await Process.run('git', ['add', '.'], workingDirectory: seed.path);
    await Process.run('git', [
      '-c',
      'user.name=Seed',
      '-c',
      'user.email=seed@test.local',
      'commit',
      '-qm',
      'seed',
    ], workingDirectory: seed.path);

    final ctx = Directory('${root.path}/ctx')..createSync();
    File('${ctx.path}/orb-entrypoint.sh')
        .writeAsStringSync(OrbEmbedded.files['orb-entrypoint.sh']!);
    File('${ctx.path}/Dockerfile').writeAsStringSync(
      'FROM $base\n'
      'COPY orb-entrypoint.sh /usr/local/bin/orb-entrypoint\n'
      'RUN chmod +x /usr/local/bin/orb-entrypoint\n',
    );
    final (build, bout, berr) = await _docker([
      'build',
      '-q',
      '-t',
      _derived,
      ctx.path,
    ]);
    expect(build, 0, reason: '$bout$berr');
  });

  tearDownAll(() async {
    await _docker(['rm', '-f', 'orb-shell-probe-149']);
    await _docker(['rm', '-f', 'orb-shell-probe-149-broken']);
    await _docker(['rmi', '-f', _derived]);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a freshly prepared orb can run a command from its agent', () async {
    if (base == null) {
      markTestSkipped('no docker daemon, or no orb:<hash> base image');
      return;
    }
    final (run, out, err) = await _docker([
      'run',
      '-d',
      '--name',
      'orb-shell-probe-149',
      '-p',
      '127.0.0.1:0:4096',
      '-v',
      '${root.path}/seed:/seed:ro',
      '-e',
      'ORB_ID=shell149',
      '-e',
      'ORB_GIT_NAME=Orb Test',
      '-e',
      'ORB_GIT_EMAIL=orb@test.local',
      '--entrypoint',
      '/bin/sh',
      _derived,
      '-c',
      'cp -a /seed /opt/seed && chown -R root:root /opt/seed && '
          'git config --global --add safe.directory /opt/seed; '
          'ORB_REPO_URL=/opt/seed '
          'exec /usr/local/bin/orb-entrypoint',
    ]);
    expect(run, 0, reason: '$out$err');

    String log = '';
    for (var i = 0; i < 200; i++) {
      final (_, current, _) = await _docker(['logs', 'orb-shell-probe-149']);
      log = current;
      if (log.contains('[orb] stage: ready')) break;
      final (_, status, _) = await _docker([
        'inspect',
        '--format',
        '{{.State.Status}}',
        'orb-shell-probe-149',
      ]);
      if (status.trim() == 'exited') break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    // The probe ran on the agent's own shell and passed before the serve.
    expect(log, contains('[orb] stage: shell'), reason: log);
    expect(
      log,
      contains('[orb] shell: usable (sh -c \'printf ok\')'),
      reason: log,
    );
    // The stage order is the contract: cloned, then probed, then ready (the
    // password line's position is the service's own buffering, not ours).
    final stages = const LineSplitter()
        .convert(log)
        .where((line) => line.startsWith('[orb] stage: '))
        .map((line) => line.substring('[orb] stage: '.length))
        .toList();
    expect(
      stages,
      containsAllInOrder(['cloning', 'shell', 'ready']),
      reason: log,
    );

    // The acceptance criterion, executed: `printf ok` from the orb's own
    // shell, plus the binaries the spawn prompt tells the agent to run.
    final (smoke, smokeOut, smokeErr) = await _docker([
      'exec',
      'orb-shell-probe-149',
      'sh',
      '-c',
      'printf ok',
    ]);
    expect(smoke, 0, reason: '$smokeOut$smokeErr');
    expect(smokeOut.trim(), 'ok');
    for (final binary in ['git', 'gh', 'node', 'opencode']) {
      final (which) = await _docker([
        'exec',
        'orb-shell-probe-149',
        'sh',
        '-c',
        'command -v $binary',
      ]);
      expect(which.$1, 0, reason: '$binary is not in the orb image');
    }
  });

  test('an orb whose agent cannot execute never reaches ready', () async {
    if (base == null) {
      markTestSkipped('no docker daemon, or no orb:<hash> base image');
      return;
    }
    final (run, out, err) = await _docker([
      'run',
      '-d',
      '--name',
      'orb-shell-probe-149-broken',
      '-v',
      '${root.path}/seed:/seed:ro',
      '-e',
      'ORB_PROBE_SHELL=/bin/nosuchshell',
      '-e',
      'ORB_ID=broken149',
      '-e',
      'ORB_GIT_NAME=Orb Test',
      '-e',
      'ORB_GIT_EMAIL=orb@test.local',
      '--entrypoint',
      '/bin/sh',
      _derived,
      '-c',
      'cp -a /seed /opt/seed && chown -R root:root /opt/seed && '
          'git config --global --add safe.directory /opt/seed; '
          'ORB_REPO_URL=/opt/seed '
          'exec /usr/local/bin/orb-entrypoint',
    ]);
    expect(run, 0, reason: '$out$err');

    for (var i = 0; i < 120; i++) {
      final (_, status, _) = await _docker([
        'inspect',
        '--format',
        '{{.State.Status}}',
        'orb-shell-probe-149-broken',
      ]);
      if (status.trim() == 'exited') break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final (_, state, _) = await _docker([
      'inspect',
      '--format',
      '{{.State.ExitCode}}',
      'orb-shell-probe-149-broken',
    ]);
    expect(state.trim(), isNot('0'), reason: 'the boot must fail');
    final (_, log, _) = await _docker(['logs', 'orb-shell-probe-149-broken']);
    expect(log, contains('[orb] FATAL: no usable shell'));
    expect(log, isNot(contains('[orb] stage: ready')), reason: log);
    expect(log, isNot(contains('server listening')), reason: log);
  });
}
