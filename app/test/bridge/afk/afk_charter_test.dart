import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_charter.dart';

/// The AFK agent's charter (spec #376, T1): the canonical markdown agent file
/// and its guarantee — "write if absent, never rewrite if present".
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-afk-charter');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('installs the canonical charter when absent (fresh machine)', () async {
    final file = await AfkCharter.install(agentsDir: dir);
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), AfkCharter.canonical);
  });

  test('leaves an existing (hand-edited) file byte-identical', () async {
    final file = File('${dir.path}/${AfkCharter.fileName}');
    const edited = '---\ndescription: my edit\n---\n\nmy own rules\n';
    file.writeAsStringSync(edited);

    await AfkCharter.install(agentsDir: dir);

    expect(file.readAsStringSync(), edited);
  });

  test('leaves an existing file byte-identical when it already equals the '
      'canonical copy (no churn)', () async {
    final file = File('${dir.path}/${AfkCharter.fileName}');
    file.writeAsStringSync(AfkCharter.canonical);

    final before = file.lastModifiedSync();
    await AfkCharter.install(agentsDir: dir);

    expect(file.readAsStringSync(), AfkCharter.canonical);
    // The file is not rewritten when it is already current.
    expect(file.lastModifiedSync(), before);
  });

  group('the canonical charter content', () {
    test('defines the `afk` primary agent (the session agent is `afk`)', () {
      expect(AfkCharter.agentId, 'afk');
      // The body is the agent's system prompt; the frontmatter names the id
      // and the mode. A markdown agent file's frontmatter carries `mode`.
      expect(AfkCharter.canonical, contains('mode: primary'));
    });

    test('denies force-push (the hard rule enforced as a permission)', () {
      expect(AfkCharter.canonical, contains('git push --force *'));
      expect(AfkCharter.canonical, contains('effect: deny'));
    });

    test('denies pushing the default branch', () {
      expect(AfkCharter.canonical, contains('git push origin main *'));
      expect(AfkCharter.canonical, contains('git push origin master *'));
    });

    test('carries no model (the bridge pins it at creation)', () {
      // The model is deliberately absent from the charter file: the bridge
      // pins it from the afkModel setting, and an empty pin inherits the
      // service default. A `model:` line in the frontmatter would freeze a
      // model into the file that the setting must own.
      final lines = AfkCharter.canonical.split('\n');
      expect(lines, isNot(contains(RegExp(r'^model:'))));
    });

    test('states the implement-spec discipline and the human boundary', () {
      expect(AfkCharter.canonical, contains('implement-spec'));
      expect(AfkCharter.canonical, contains('Never merge'));
      expect(AfkCharter.canonical, contains('Never force-push'));
      expect(AfkCharter.canonical, contains('default branch'));
    });
  });
}
