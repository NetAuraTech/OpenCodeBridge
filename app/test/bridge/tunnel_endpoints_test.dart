import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_binary.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_config.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_preconditions.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_supervisor.dart';
import 'package:opencodebridge/model/tunnel_report.dart';

const String _kCredentialsUuid = '11111111-2222-3333-4444-555555555555';
const int _kChildPid = 4242;

/// A fake supervised child: kill() records and completes its exit code.
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

/// The fake host around the supervised child: records the spawns and
/// signals, and answers the probes.
class FakeHost {
  FakeHost(this.dir);

  final Directory dir;

  final List<List<String>> argvs = [];
  final List<FakeTunnelProcess> spawned = [];

  /// The registered edge connections the scrape returns.
  int connections = 3;

  late final File configFile;
  late final CloudflaredConfigFile config;
  late final CloudflaredBinary binary;
  late final TunnelPreconditionChecker preconditions;

  Future<void> setup() async {
    await File('${dir.path}/cloudflared').writeAsString('the binary');
    await File('${dir.path}/version')
        .writeAsString(CloudflaredBinary.pinnedVersion);
    configFile = File('${dir.path}/cloudflared.yml');
    await configFile.writeAsString(
      'tunnel: my-tunnel\n'
      'credentials-file: ${dir.path}/$_kCredentialsUuid.json\n'
      'ingress:\n'
      '  - hostname: bridge.example.com\n'
      '    service: http://127.0.0.1:48201\n',
    );
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
      final child = FakeTunnelProcess();
      spawned.add(child);
      return child;
    },
    kill: (int pid, ProcessSignal signal) async => true,
    pidAlive: (int pid) => pid == _kChildPid,
    scrape: (int port) async => connections,
    portHolder: (int port) async => null,
    killGrace: const Duration(milliseconds: 50),
  );

  FakeTunnelProcess? get lastChild => spawned.isEmpty ? null : spawned.last;
}

/// One bridge request: the status code and the decoded JSON body.
Future<(int, Map<String, Object?>)> request(
  Uri base,
  String method,
  String path,
) async {
  final client = HttpClient();
  try {
    final request = method == 'GET'
        ? await client.getUrl(base.replace(path: path))
        : await client.postUrl(base.replace(path: path));
    final response = await request.close();
    final raw = await response.transform(const Utf8Decoder()).join();
    return (response.statusCode, jsonDecode(raw) as Map<String, Object?>);
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('BridgeServer tunnel endpoints', () {
    late Directory dir;
    late FakeHost host;
    late BridgeServer server;
    late Uri base;
    late TunnelSupervisor tunnel;
    late FakeTunnelProcess initialChild;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp(
        'opencodebridge-tunnel-endpoints',
      );
      host = FakeHost(dir);
      await host.setup();
      tunnel = host.supervisor();
      server = await BridgeServer.start(port: 0, tunnel: tunnel);
      base = server.baseUri;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      initialChild = host.lastChild!;
    });

    tearDown(() async {
      await server.stop();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test(
      'BridgeServer.start supervises the tunnel (the child is spawned)',
      () async {
        expect(host.argvs, hasLength(1));
        expect(host.argvs.single.first, '${dir.path}/cloudflared');
        expect(host.argvs.single, contains('--no-autoupdate'));
        expect(host.argvs.single, contains('127.0.0.1:$kPrimaryMetricsPort'));
        expect(tunnel.active, isTrue);
      },
    );

    test('GET /api/tunnel answers the current report', () async {
      final (status, reported) = await request(base, 'GET', '/api/tunnel');
      expect(status, HttpStatus.ok);
      expect(reported, {
        'status': 'up',
        'running': true,
        'connections': 3,
        'port': kPrimaryMetricsPort,
        'hostname': 'bridge.example.com',
        'missing': <String>[],
        'details': <String>[],
      });
    });

    test('POST /api/tunnel/check re-runs the precondition pass', () async {
      await host.configFile.delete();
      final (status, reported) = await request(
        base,
        'POST',
        '/api/tunnel/check',
      );
      expect(status, HttpStatus.ok);
      // The child still runs and holds edge connections, so the tunnel is
      // still up; the recheck surfaces the now-missing config as a step.
      expect(reported['status'], 'up');
      expect(reported['missing'], [TunnelSetupStep.config]);
      expect((reported['details'] as List).first, contains('cloudflared.yml'));
    });

    test('POST /api/tunnel/start respawns the child', () async {
      final (status, _) = await request(base, 'POST', '/api/tunnel/start');
      expect(status, HttpStatus.ok);

      expect(host.argvs, hasLength(2));
      expect(initialChild.killed, isTrue);
      expect(host.lastChild, isNot(initialChild));
    });

    test('stop() terminates the tunnel child', () async {
      await server.stop();
      expect(initialChild.killed, isTrue);
      expect(tunnel.active, isFalse);
    });
  });

  group('BridgeServer without a tunnel', () {
    late BridgeServer server;
    late Uri base;

    setUp(() async {
      server = await BridgeServer.start(port: 0);
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test('GET /api/tunnel answers not_configured', () async {
      final (status, reported) = await request(base, 'GET', '/api/tunnel');
      expect(status, HttpStatus.ok);
      expect(reported, {
        'status': 'not_configured',
        'running': false,
        'connections': 0,
        'port': null,
        'hostname': null,
        'missing': <String>[],
        'details': <String>[],
      });
    });

    test(
      'the check and start actions answer 404 tunnel_not_configured',
      () async {
        for (final path in ['/api/tunnel/check', '/api/tunnel/start']) {
          final (status, reported) = await request(base, 'POST', path);
          expect(status, HttpStatus.notFound);
          expect(reported, {'error': 'tunnel_not_configured'});
        }
      },
    );
  });
}
