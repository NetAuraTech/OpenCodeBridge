// The spawn surface's global agent tools (issue #99, spec §8.1): the
// embedded opencode v2 plugin registering orb_spawn/orb_wait, materialized
// create-if-missing into the global opencode plugins dir.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/orb/orb_agent_tools.dart';

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
      final source = File(
        '${temp.path}/opencodebridge_orbs.ts',
      ).readAsStringSync();
      // The timeout-aware path: the spawn catch asks the bridge's recent
      // tasks (by the tool's directory), and a non-empty answer points at
      // the dispatched task instead of the blind "unreachable" error.
      expect(source, contains('/api/orb/tasks'));
      expect(source, contains('recentTasks(context?.directory)'));
      expect(source, contains('orb_wait with the matching task_id'));
    },
  );

  test('materialize never overwrites an edited copy (on-disk wins)', () async {
    final file = File('${temp.path}/opencodebridge_orbs.ts')
      ..writeAsStringSync('// tuned by hand');
    await OrbAgentTools.materialize(into: temp);
    expect(file.readAsStringSync(), '// tuned by hand');
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
