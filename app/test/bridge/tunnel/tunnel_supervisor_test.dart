import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_binary.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_config.dart';
import 'package:opencodebridge/bridge/tunnel/port_holder.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_preconditions.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_supervisor.dart';
import 'package:opencodebridge/model/tunnel_report.dart';

const String _kCredentialsUuid = '11111111-2222-3333-4444-555555555555';
const int _kChildPid = 4242;

/// A fake supervised child: records kill(), completes its exit code when
/// told (a child with `diesOnKill: false` ignores the SIGTERM).
class FakeTunnelProcess implements TunnelProcess {
  FakeTunnelProcess({this.pid = _kChildPid, this.diesOnKill = true});

  @override
  final int pid;

  final bool diesOnKill;

  final Completer<int> _exited = Completer<int>();

  bool killed = false;

  void exit(int code) {
    if (!_exited.isCompleted) _exited.complete(code);
  }

  @override
  Future<int> get exitCode => _exited.future;

  @override
  bool kill() {
    killed = true;
    if (diesOnKill) exit(0);
    return true;
  }
}

/// The fake host around [TunnelSupervisor]: records every spawn and every
/// signal, and answers the port-holder / pid / scrape probes.
class FakeHost {
  FakeHost(this.dir);

  final Directory dir;

  final List<List<String>> argvs = [];
  final List<FakeTunnelProcess> spawned = [];
  final List<(int, ProcessSignal)> signals = [];
  final Set<int> deadPids = {};

  /// Who holds the primary metrics port, per probe.
  PortHolder? portHolder;

  /// The registered connections the scrape returns.
  int connections = 0;

  /// Whether a freshly spawned child dies on the SIGTERM of [FakeTunnelProcess.kill].
  bool diesOnKill = true;

  /// Whether the orphan dies on the SIGTERM (before the SIGKILL is needed).
  bool orphanDiesOnTerm = true;

  late final File configFile;
  late final CloudflaredConfigFile config;
  late final CloudflaredBinary binary;
  late final TunnelPreconditionChecker preconditions;

  Future<void> setup({bool withConfig = true}) async {
    await File('${dir.path}/cloudflared').writeAsString('the binary');
    await File('${dir.path}/version')
        .writeAsString(CloudflaredBinary.pinnedVersion);
    configFile = File('${dir.path}/cloudflared.yml');
    if (withConfig) {
      await configFile.writeAsString(
        'tunnel: my-tunnel\n'
        'credentials-file: ${dir.path}/$_kCredentialsUuid.json\n'
        'ingress:\n'
        '  - hostname: bridge.example.com\n'
        '    service: http://127.0.0.1:48201\n',
      );
    }
    await File('${dir.path}/$_kCredentialsUuid.json')
        .writeAsString('{"TunnelID": "$_kCredentialsUuid"}');
    config = CloudflaredConfigFile(file: configFile);
    binary = CloudflaredBinary(
      dir: Directory(dir.path),
      resolveArch: () async => 'amd64',
      downloader: (Uri url, File target) async {},
    );
    preconditions = TunnelPreconditionChecker(
      binary: binary,
      configFile: config,
      bridgePort: 48201,
      dnsResolves: (String host) async => true,
      accessProbe: (String host) async => AccessVerdict.enforcing,
    );
  }

  TunnelSupervisor supervisor() => TunnelSupervisor(
    binary: binary,
    configFile: config,
    preconditions: preconditions,
    spawner: (List<String> argv) async {
      argvs.add(argv);
      final child = FakeTunnelProcess(diesOnKill: diesOnKill);
      spawned.add(child);
      return child;
    },
    kill: (int pid, ProcessSignal signal) async {
      signals.add((pid, signal));
      if (signal == ProcessSignal.sigkill) deadPids.add(pid);
      if (orphanDiesOnTerm &&
          signal == ProcessSignal.sigterm &&
          pid != _kChildPid) {
        deadPids.add(pid);
      }
      return true;
    },
    pidAlive: (int pid) => pid == _kChildPid || !deadPids.contains(pid),
    scrape: (int port) async => connections,
    portHolder: (int port) async => portHolder,
    killGrace: const Duration(milliseconds: 50),
  );

  FakeTunnelProcess? get lastChild => spawned.isEmpty ? null : spawned.last;
}

void main() {
  late Directory dir;
  late FakeHost host;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-supervisor');
    host = FakeHost(dir);
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 10));

  Future<TunnelSupervisor> started() async {
    await host.setup();
    final supervisor = host.supervisor();
    await supervisor.start();
    await pump();
    return supervisor;
  }

  group('TunnelSupervisor.start', () {
    test(
      'spawns cloudflared with the pinned argv on the primary port',
      () async {
        final supervisor = await started();
        addTearDown(() => supervisor.stop());

        expect(host.argvs, [
          [
            '${dir.path}/cloudflared',
            'tunnel',
            'run',
            'my-tunnel',
            '--config',
            '${dir.path}/cloudflared.yml',
            '--no-autoupdate',
            '--metrics',
            '127.0.0.1:$kPrimaryMetricsPort',
          ],
        ]);
        expect(supervisor.metricsPort, kPrimaryMetricsPort);
      },
    );

    test('does not spawn while a precondition is missing', () async {
      await host.setup(withConfig: false);
      final supervisor = host.supervisor();
      await supervisor.start();
      await pump();

      expect(host.spawned, isEmpty);
      final report = await supervisor.report();
      expect(report.status, TunnelStatus.down);
      expect(report.missing, [TunnelSetupStep.config]);
      await supervisor.stop();
    });
  });

  group('TunnelSupervisor orphan handling', () {
    test('terminates a cloudflared orphan holding the primary port', () async {
      host.portHolder = const PortHolder(pid: 999, isCloudflared: true);
      final supervisor = await started();
      addTearDown(() => supervisor.stop());

      expect(host.signals, [(999, ProcessSignal.sigterm)]);
      expect(host.argvs.single.last, '127.0.0.1:$kPrimaryMetricsPort');
    });

    test('falls back to the fallback port for a foreign holder', () async {
      host.portHolder = const PortHolder(pid: 999, isCloudflared: false);
      final supervisor = await started();
      addTearDown(() => supervisor.stop());

      expect(host.signals, isEmpty);
      expect(host.argvs.single.last, '127.0.0.1:$kFallbackMetricsPort');
    });
  });

  group('TunnelSupervisor respawning', () {
    test('respawns a child that exits', () async {
      final supervisor = await started();
      addTearDown(() => supervisor.stop());

      host.lastChild!.exit(1);
      await pump();

      expect(host.spawned.length, 2);
    });

    test('stops respawning after the cap, and restart() respawns', () async {
      final supervisor = await started();
      addTearDown(() => supervisor.stop());

      // Initial child + 3 auto-respawns fill the cap of 3.
      for (var i = 0; i < 3; i++) {
        host.lastChild!.exit(1);
        await pump();
      }
      expect(host.spawned.length, 4);
      // The 4th child's exit hits the cap: no 5th spawn.
      host.lastChild!.exit(1);
      await pump();
      expect(host.spawned.length, 4);
      expect(supervisor.respawnCapExhausted, isTrue);

      await supervisor.restart();
      await pump();
      expect(host.spawned.length, 5);
    });
  });

  group('TunnelSupervisor.stop', () {
    test('SIGTERMs a well-behaved child and waits for its exit', () async {
      final supervisor = await started();
      await supervisor.stop();

      expect(host.lastChild!.killed, isTrue);
      expect(
        host.signals,
        isEmpty, // No SIGKILL needed.
      );
    });

    test('escalates to SIGKILL after the grace period', () async {
      host.diesOnKill = false;
      final supervisor = await started();
      await supervisor.stop();

      expect(host.signals, [(_kChildPid, ProcessSignal.sigkill)]);
    });
  });

  group('TunnelSupervisor.report', () {
    test('is up when the child runs and holds connections', () async {
      host.connections = 3;
      final supervisor = await started();
      addTearDown(() => supervisor.stop());

      final report = await supervisor.report();
      expect(report.status, TunnelStatus.up);
      expect(report.running, isTrue);
      expect(report.registeredConnections, 3);
      expect(report.metricsPort, kPrimaryMetricsPort);
      expect(report.hostname, 'bridge.example.com');
      expect(report.missing, isEmpty);
    });

    test('is down when the child runs without edge connections', () async {
      final supervisor = await started();
      addTearDown(() => supervisor.stop());

      final report = await supervisor.report();
      expect(report.status, TunnelStatus.down);
      expect(report.running, isTrue);
      expect(report.registeredConnections, 0);
    });
  });
}
