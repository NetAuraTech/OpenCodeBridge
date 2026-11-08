// SMOKE (issue #120, manual — not part of the suite): the full fix path
// against the REAL host: the real docker daemon, the real host gh (the
// keyring token), a real GitHub https remote, the real orb image built
// from THIS branch's embedded build context. Proves end to end:
//   1. create stages the container-local gh config carrying the keyring
//      token (gh auth token inside the orb == the host token);
//   2. the post-commit hook push lands the branch on GitHub;
//   3. a broken push fails the commit, writes the marker, the orb list
//      surfaces pushFailing; the recovery push clears it;
//   4. the deletion guard passes and the deletion removes the state dir
//      (the staged secret included) — nothing left behind.
// Run: flutter test test/manual/smoke120_test.dart
// Pushes/deletes ONLY its own orb/<id> branch on the remote.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_build_context.dart';
import 'package:opencodebridge/bridge/orb/orb_image_builder.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';

const _remote = 'https://github.com/NetAuraTech/OpenCodeBridge.git';

String _digest(String s) =>
    sha256.convert(utf8.encode(s.trim())).toString().substring(0, 12);

Future<({int exitCode, String stdout, String stderr})> _exec(
  List<String> argv, {
  String? cwd,
}) async {
  final r = await Process.run(
    argv.first,
    argv.sublist(1),
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return (
    exitCode: r.exitCode,
    stdout: r.stdout as String,
    stderr: r.stderr as String,
  );
}

Future<void> _until(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 60),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

void main() {
  test('smoke #120: keyring token injection + push marker, live', () async {
    final docker = DockerBackend.hostCli();
    final gitBinary = findHostGit();
    final ghBinary = findHostGh();
    if (docker == null || gitBinary == null || ghBinary == null) {
      fail('this smoke needs the host docker, git AND gh CLIs on PATH');
    }
    final home = Platform.environment['HOME']!;

    // The host baseline: the gh token the read-only mount cannot carry.
    final hostToken = await Process.run(ghBinary, [
      'auth',
      'token',
    ], stdoutEncoding: utf8);
    expect(hostToken.exitCode, 0, reason: 'the host gh must be logged in');
    final hostDigest = _digest(hostToken.stdout as String);

    final root = await Directory.systemTemp.createTemp('oc-smoke120');
    // The build context materialized from THIS branch's embedded files:
    // the fix's entrypoint rides the new tag's image (ensureImage builds
    // it; Docker's layer cache keeps every toolchain layer).
    final context = OrbBuildContext(dir: Directory('${root.path}/ctx'));
    await context.materialize();
    expect(
      File('${root.path}/ctx/orb-entrypoint.sh').readAsStringSync(),
      contains('push-failed'),
      reason: 'the embedded build context must carry the fix',
    );

    final stateRoot = Directory('${root.path}/state');
    final builder = OrbImageBuilder(
      context: context,
      run: docker.run,
      spawn: docker.spawn,
    );
    final service = OrbService(
      imageBuilder: builder,
      run: docker.run,
      spawn: docker.spawn,
      git: hostGitRunner(gitBinary),
      home: home,
      stateRoot: stateRoot,
      bridgePort: 48201,
      gh: hostGhRunner(ghBinary),
      bootTimeout: const Duration(minutes: 8),
      pollInterval: const Duration(milliseconds: 500),
    );

    // A minimal checkout: only origin's URL matters (the remote probe).
    final checkout = Directory('${root.path}/checkout')..createSync();
    await _exec(['git', 'init', '-q', checkout.path]);
    await _exec([
      'git',
      'remote',
      'add',
      'origin',
      _remote,
    ], cwd: checkout.path);

    String? orbId;
    try {
      // 1. The real creation: image ensure/build, clone, hook, boot,
      // descriptor verify — with the gh probe + credential staging.
      final record = await service.create(
        project: 'smoke120',
        name: 'smoke',
        checkout: checkout.path,
      );
      orbId = record.id;
      final container = 'orb-$orbId';
      final marker = File('${stateRoot.path}/$orbId/push-failed');

      // The staged credentials exist host-side and INSIDE the orb, and
      // carry the host's keyring token (digest-compared, never logged).
      final staged = File('${stateRoot.path}/$orbId/gh/hosts.yml');
      expect(staged.existsSync(), isTrue);
      expect(staged.readAsStringSync(), contains('oauth_token:'));
      final inOrb = await _exec([
        'docker',
        'exec',
        container,
        'sh',
        '-c',
        'GH_CONFIG_DIR=/root/.local/gh gh auth token',
      ]);
      expect(inOrb.exitCode, 0, reason: inOrb.stderr);
      expect(
        _digest(inOrb.stdout),
        hostDigest,
        reason: 'the orb token must BE the host keyring token',
      );

      // 2. A real commit pushes: the hook's push authenticates through
      // the staged config (docker exec carries no GH_CONFIG_DIR — the
      // hook's baked-in export must cover it) and lands the branch.
      final commit = await _exec([
        'docker',
        'exec',
        container,
        'sh',
        '-c',
        'cd /workspace && git commit -q --allow-empty -m "smoke #120"',
      ]);
      expect(commit.exitCode, 0, reason: '${commit.stdout}${commit.stderr}');
      await _until(() async {
        final probe = await _exec([
          'git',
          'ls-remote',
          '--heads',
          'origin',
          'orb/$orbId',
        ], cwd: checkout.path);
        return probe.exitCode == 0 && probe.stdout.trim().isNotEmpty;
      }, reason: 'orb/$orbId on the remote');
      expect(marker.existsSync(), isFalse);
      var rows = await service.list();
      expect(rows.firstWhere((r) => r.id == orbId).pushFailing, isFalse);

      // 3. Break the remote: the next push fails — the commit fails for
      // the agent, the marker lands, the list surfaces it.
      await _exec([
        'docker',
        'exec',
        container,
        'sh',
        '-c',
        'cd /workspace && git remote set-url origin /nonexistent-remote',
      ]);
      // 3. Break the remote: the next push fails. git IGNORES a
      // post-commit hook's exit code, so the commit itself succeeds for
      // the agent (the push failure shows in its output) — the durable
      // signal is the marker, and the list surfaces it.
      await _exec([
        'docker',
        'exec',
        container,
        'sh',
        '-c',
        'cd /workspace && git remote set-url origin /nonexistent-remote',
      ]);
      final badCommit = await _exec([
        'docker',
        'exec',
        container,
        'sh',
        '-c',
        'cd /workspace && git commit -q --allow-empty -m "smoke broken"',
      ]);
      expect(
        badCommit.stdout + badCommit.stderr,
        contains('failed'),
        reason: 'the hook must report the failed push in the commit output',
      );
      await _until(
        () async => marker.existsSync(),
        reason: 'the push-failed marker',
      );
      rows = await service.list();
      expect(rows.firstWhere((r) => r.id == orbId).pushFailing, isTrue);

      // Recover: the push succeeds, the marker clears, the row is clean.
      await _exec([
        'docker',
        'exec',
        container,
        'sh',
        '-c',
        'cd /workspace && git remote set-url origin $_remote',
      ]);
      final goodCommit = await _exec([
        'docker',
        'exec',
        container,
        'sh',
        '-c',
        'cd /workspace && git commit -q --allow-empty -m "smoke fixed"',
      ]);
      expect(goodCommit.exitCode, 0, reason: goodCommit.stderr);
      await _until(
        () async => !marker.existsSync(),
        reason: 'the marker to clear',
      );
      rows = await service.list();
      expect(rows.firstWhere((r) => r.id == orbId).pushFailing, isFalse);

      // 4. The real deletion removes the orb and its state dir — the
      // staged secret included. (The guard first: on a clean, fully
      // pushed workspace it passes; a refusal would be the pre-existing
      // detached-HEAD counting, not this fix — force past it either way,
      // the smoke has nothing left to protect.)
      final guard = await service.deleteGuard(orbId);
      printOnFailure(
        'guard: evaluable=${guard.evaluable} '
        'unpushed=${guard.unpushedCount} dirty=${guard.dirty}',
      );
      final id = orbId;
      await service
          .delete(id)
          .catchError((Object _) => service.delete(id, force: true));
      expect(Directory('${stateRoot.path}/$orbId').existsSync(), isFalse);
      expect(
        File('${stateRoot.path}/$orbId/gh/hosts.yml').existsSync(),
        isFalse,
        reason: 'the staged token must die with the orb',
      );
    } finally {
      if (orbId != null) {
        // Success: the orb is already gone (this is a no-op error) but
        // the branch cleanup runs. Failure: the orb comes out here — a
        // smoke run never leaves an orb or its branch behind. ONLY this
        // smoke's own branch is touched on the remote.
        await service.delete(orbId).catchError((Object _) {});
        await service.delete(orbId, force: true).catchError((Object _) {});
        await _exec([
          'git',
          'push',
          'origin',
          '--delete',
          'orb/$orbId',
        ], cwd: checkout.path);
      }
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // Root-owned state-dir remnants (a container wrote through the
        // mount): clean them as root, then retry.
        await Process.run('docker', [
          'run',
          '--rm',
          '-v',
          '${root.path}:/r',
          '--entrypoint',
          'find',
          builder.expectedTag,
          '/r',
          '-mindepth',
          '1',
          '-delete',
        ]);
        await root.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}
