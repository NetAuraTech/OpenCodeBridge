import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/repo_identity.dart';

/// The repo identity (spec #407, T1): the one fact that pins both the AFK
/// session's home and the `gh` reader's cwd to the armed project's checkout.
/// [parseRepoIdentity] is the pure parser (exhaustive); [repoIdentityOf] is
/// the one git wrapper (tested against a real temp git dir, a git dir without
/// an `origin` remote, and a non-git dir).
void main() {
  group('parseRepoIdentity (pure)', () {
    test('parses an https remote URL', () {
      expect(
        parseRepoIdentity('https://github.com/NetAuraTech/OpenCodeBridge'),
        'NetAuraTech/OpenCodeBridge',
      );
    });

    test('parses an https remote URL with a trailing .git', () {
      expect(
        parseRepoIdentity('https://github.com/NetAuraTech/OpenCodeBridge.git'),
        'NetAuraTech/OpenCodeBridge',
      );
    });

    test('parses an ssh remote URL', () {
      expect(
        parseRepoIdentity('git@github.com:NetAuraTech/OpenCodeBridge'),
        'NetAuraTech/OpenCodeBridge',
      );
    });

    test('parses an ssh remote URL with a trailing .git', () {
      expect(
        parseRepoIdentity('git@github.com:NetAuraTech/OpenCodeBridge.git'),
        'NetAuraTech/OpenCodeBridge',
      );
    });

    test('parses an https remote on a non-github host', () {
      expect(parseRepoIdentity('https://gitlab.com/group/proj'), 'group/proj');
    });

    test('junk answers null', () {
      expect(parseRepoIdentity('not a url'), isNull);
      expect(parseRepoIdentity('hello world'), isNull);
      expect(parseRepoIdentity(':::///'), isNull);
    });

    test('empty and blank answer null', () {
      expect(parseRepoIdentity(''), isNull);
      expect(parseRepoIdentity('   '), isNull);
    });

    test('a value with no owner/repo split answers null', () {
      expect(parseRepoIdentity('https://github.com/owneronly'), isNull);
      expect(parseRepoIdentity('git@github.com:owneronly'), isNull);
    });

    test('an empty owner or repo part answers null', () {
      expect(parseRepoIdentity('https://github.com//repo'), isNull);
      expect(parseRepoIdentity('https://github.com/owner/'), isNull);
    });

    test('surrounding whitespace is trimmed before parsing', () {
      expect(parseRepoIdentity('  https://github.com/a/b  '), 'a/b');
    });
  });

  group('repoIdentityOf (the git wrapper)', () {
    late Directory dir;

    Future<void> git(List<String> args) async {
      final result = await Process.run(
        'git',
        ['-C', dir.path, ...args],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed: ${result.stderr}');
      }
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('oc-repo-identity');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('a git dir with an https origin answers the identity', () async {
      await git(['init', '-q']);
      await git([
        'remote',
        'add',
        'origin',
        'https://github.com/NetAuraTech/OpenCodeBridge',
      ]);
      expect(await repoIdentityOf(dir), 'NetAuraTech/OpenCodeBridge');
    });

    test('a git dir with an ssh origin answers the identity', () async {
      await git(['init', '-q']);
      await git([
        'remote',
        'add',
        'origin',
        'git@github.com:NetAuraTech/OpenCodeBridge.git',
      ]);
      expect(await repoIdentityOf(dir), 'NetAuraTech/OpenCodeBridge');
    });

    test('a git dir without an origin remote answers null', () async {
      await git(['init', '-q']);
      expect(await repoIdentityOf(dir), isNull);
    });

    test('a non-git directory answers null', () async {
      expect(await repoIdentityOf(dir), isNull);
    });
  });
}
