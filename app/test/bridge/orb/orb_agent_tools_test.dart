// The spawn surface's global agent tools (issue #99, spec §8.1): the
// embedded opencode v2 plugin registering orb_spawn/orb_wait, materialized
// into the global opencode plugins dir (a stale untouched copy refreshed at
// startup, a user-tuned copy left alone — issue #141).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/orb/orb_agent_tools.dart';

import 'stale_plugin_v1_fixture.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('orb-agent-tools');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('materialize writes the plugin into the plugins dir', () async {
    await OrbAgentTools.materialize(into: temp);

    final file = File('${temp.path}/opencodebridge_orbs.ts');
    expect(file.existsSync(), isTrue);
    final source = file.readAsStringSync();
    // opencode v2's plugin shape: a default export with an id and setup,
    // registering the tools through ctx.tool.transform (a v1 `tool()` file
    // in tools/ is not loaded by a v2 server).
    expect(source, contains('export default {'));
    expect(source, contains('id: "opencodebridge.spawn"'));
    expect(source, contains('ctx.tool.transform'));
    expect(source, contains('editor.add'));
    // The plugin is dependency-free: no import outside node builtins (an
    // unresolvable import fails the whole plugin load).
    expect(source, isNot(contains('@opencode-ai/plugin')));
    expect(source, contains('from "fs"'));
    // The spawn surface's tools, calling only the bridge HTTP API (§8.1).
    expect(source, contains('name: "orb_spawn"'));
    expect(source, contains('name: "orb_wait"'));
    expect(source, contains('/api/orb/spawn'));
    expect(source, contains('/api/orb/wait'));
    // The issue #100 contract: the targeting/seed arguments and the
    // spawn-tree-scoped controls (spec §8.2/§3.3/§8.4).
    expect(source, contains('orb: args.orb'));
    expect(source, contains('seed: args.seed'));
    expect(source, contains('name: "orb_stop"'));
    expect(source, contains('name: "orb_delete"'));
    expect(source, contains('name: "orb_export"'));
    expect(source, contains('/api/orb/stop'));
    expect(source, contains('/api/orb/delete'));
    expect(source, contains('/api/orb/export'));
    expect(source, isNot(contains('docker')));
    expect(OrbAgentTools.files.keys, ['opencodebridge_orbs.ts']);
  });

  test(
    'a failed spawn fetch asks the recent tasks before answering (issue #143)',
    () async {
      await OrbAgentTools.materialize(into: temp);
      final source = File('${temp.path}/opencodebridge_orbs.ts')
          .readAsStringSync();
      // The timeout-aware path: the spawn catch asks the bridge's recent
      // tasks (by the tool's directory), and a non-empty answer points at
      // the dispatched task instead of the blind "unreachable" error.
      expect(source, contains('/api/orb/tasks'));
      // The read is scoped to this session's own dispatches (issue #147).
      expect(
        source,
        contains('recentTasks(context?.directory, context?.sessionID)'),
      );
      expect(source, contains('orb_wait with the matching task_id'));
    },
  );

  test('the dispatched text is the caller task plus the return contract '
      '(issue #147)', () async {
    await OrbAgentTools.materialize(into: temp);
    final source = File('${temp.path}/opencodebridge_orbs.ts')
        .readAsStringSync();
    // The bridge prompts the orb with exactly what the tool sends, so the
    // commit/push and PR contract travels in the tool's own text — not
    // glued on by the bridge.
    expect(source, contains('task: fullySpecified(args.task)'));
    expect(source, contains('function fullySpecified(task)'));
    expect(source, contains('post-commit hook pushes them'));
    expect(source, contains('gh pr create'));
    expect(source, contains('One PR per orb'));
  });

  test(
    'a shell-less orb is refused with its boot reason (issue #149)',
    () async {
      await OrbAgentTools.materialize(into: temp);
      final source = File('${temp.path}/opencodebridge_orbs.ts')
          .readAsStringSync();
      // The spawn surface answers the bridge's no_shell refusal by naming the
      // boot's reason and dispatching nothing — never by falling through to
      // the generic "failed" text.
      expect(source, contains('code === "no_shell"'));
      expect(source, contains('no task was dispatched'));
      expect(source, contains('row.details || "no usable shell"'));
      expect(source, contains('cannot commit, push or open the PR'));
      // And orb_wait surfaces the refused task as such: the summary it carries
      // is the boot's reason.
      expect(source, contains('row.status === "refused"'));
      expect(source, contains('this orb cannot run commands'));
    },
  );

  test(
    'the spawn answers async by default and the wait is bounded (issue #169)',
    () async {
      await OrbAgentTools.materialize(into: temp);
      final source = File('${temp.path}/opencodebridge_orbs.ts')
          .readAsStringSync();
      // The dispatch returns as soon as it lands: the completion injection
      // (spec §8.3) wakes the caller, so no tool call is ever held past the
      // agent runtime's own fetch timeout.
      expect(source, contains('wait: args.wait ?? false'));
      // The caller is told not to poll, and a running orb_wait answer is a
      // state, not a broken bridge.
      expect(source, contains('do not poll'));
      expect(source, contains('not that the bridge is down'));
      // The running answer points at the same-turn check, not a blind retry.
      expect(source, contains('no need to poll'));
    },
  );

  test('materialize never overwrites an edited copy (on-disk wins)', () async {
    final file = File('${temp.path}/opencodebridge_orbs.ts')
      ..writeAsStringSync('// tuned by hand');
    await OrbAgentTools.materialize(into: temp);
    expect(file.readAsStringSync(), '// tuned by hand');
  });

  // Issue #141: opencode v2's tool registry defaults every registered tool
  // into Code Mode unless the registration opts out, so the plain names the
  // model sees were guaranteed to fail their first direct call. The five orb
  // tools must each carry the opt-out.
  test('the five orb tools register as direct tools, outside Code Mode '
      '(issue #141)', () async {
    await OrbAgentTools.materialize(into: temp);
    final source = File('${temp.path}/opencodebridge_orbs.ts')
        .readAsStringSync();
    // opencode v2's plugin tool API: `options: { codemode: false }` is
    // what keeps a registered tool a plain callable tool instead of
    // Code-Mode-only.
    expect(
      RegExp(r'options:\s*\{\s*codemode:\s*false\s*\}').allMatches(source),
      hasLength(5),
      reason:
          'one opt-out per orb_spawn / orb_wait / orb_stop / '
          'orb_delete / orb_export registration',
    );
    // Each opt-out belongs to a tool registration: every `editor.add` of
    // an orb tool carries one (each add block holds both strings).
    for (final name in const [
      'orb_spawn',
      'orb_wait',
      'orb_stop',
      'orb_delete',
      'orb_export',
    ]) {
      final block = RegExp(
        'editor\\.add\\(\\{\\s*name: "$name"[\\s\\S]*?\\n      \\}\\)',
      ).firstMatch(source);
      expect(block, isNotNull, reason: 'the $name registration');
      expect(block!.group(0), contains('codemode: false'));
    }
  });

  // Issue #141: the create-if-missing contract froze the fix out of every
  // existing install — a machine holding the stale plugin file never
  // received it. Startup refreshes a copy still byte-identical to a
  // previous materialization.
  test(
    'materialize refreshes a stale untouched copy in place (issue #141)',
    () async {
      // A previous bridge materialized exactly these bytes; the user never
      // touched the file.
      final file = File('${temp.path}/opencodebridge_orbs.ts')
        ..writeAsStringSync(stalePluginV1);
      await OrbAgentTools.materialize(into: temp);
      expect(
        file.readAsStringSync(),
        OrbAgentTools.files['opencodebridge_orbs.ts'],
      );
    },
  );

  test('materialize keeps the current copy byte-identical, without rewriting '
      'it (issue #141)', () async {
    final file = File('${temp.path}/opencodebridge_orbs.ts')
      ..writeAsStringSync(OrbAgentTools.files['opencodebridge_orbs.ts']!)
      ..setLastModifiedSync(DateTime(2026, 1, 1));
    await OrbAgentTools.materialize(into: temp);
    expect(file.readAsStringSync(), isNot(stalePluginV1));
    expect(
      file.statSync().modified,
      DateTime(2026, 1, 1), // No touch: the write is a no-op when the
      // on-disk bytes already are the embedded ones.
    );
  });

  test('materialize leaves a copy edited from an old materialization alone '
      '(issue #141)', () async {
    // User-tuned: a previous materialization plus the user's own line.
    // Refreshing it would overwrite the tuning — the on-disk copy wins.
    final tuned = '$stalePluginV1// my tweak\n';
    final file = File('${temp.path}/opencodebridge_orbs.ts')
      ..writeAsStringSync(tuned);
    await OrbAgentTools.materialize(into: temp);
    expect(file.readAsStringSync(), tuned);
  });

  test(
    'the spawn tool resolves the bridge URL from the copied config',
    () async {
      await OrbAgentTools.materialize(into: temp);
      final source = File('${temp.path}/opencodebridge_orbs.ts')
          .readAsStringSync();
      // Inside an orb the bridge is reached through the config key the bridge
      // writes at every copy (host.docker.internal), not localhost (§8.5).
      expect(source, contains('"bridgeUrl"'));
      expect(source, contains('OPENCODEBRIDGE_URL'));
      expect(source, contains('127.0.0.1:48201'));
    },
  );

  test('the host dir is the global opencode plugins dir', () {
    final home = Platform.environment['HOME'] ?? '/';
    final path = OrbAgentTools.hostDir().path;
    expect(path, endsWith('/.config/opencode/plugins'));
    expect(path, startsWith(home));
  });
}
