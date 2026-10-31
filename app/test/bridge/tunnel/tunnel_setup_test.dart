import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_binary.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_config.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_cli.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_preconditions.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_setup.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_supervisor.dart';
import 'package:opencodebridge/model/tunnel_setup.dart';

const String _kCredentialsUuid = '11111111-2222-3333-4444-555555555555';
const String _kCreatedUuid = '99999999-8888-7777-6666-555555555555';
const int _kChildPid = 4242;
const String _kCredentialsJson =
    '{\n'
    '  "OwnerID": "owner",\n'
    '  "TunnelID": "$_kCredentialsUuid",\n'
    '  "APIKey": "secret",\n'
    '  "OwnerEmail": "user@example.com"\n'
    '}';

/// The credentials file the app-driven `tunnel create` writes (the CLI
/// owns it, verbatim).
const String _kCreatedJson =
    '{\n'
    '  "OwnerID": "owner",\n'
    '  "TunnelID": "$_kCreatedUuid",\n'
    '  "APIKey": "created-secret",\n'
    '  "OwnerEmail": "user@example.com"\n'
    '}';

/// A fake supervised child: records kill(), completes its exit code when
/// killed (a live child never reports an exit on its own).
class FakeTunnelProcess implements TunnelProcess {
  FakeTunnelProcess({this.pid = _kChildPid});

  @override
  final int pid;

  final Completer<int> _exited = Completer<int>();

  bool killed = false;

  @override
  Future<int> get exitCode => _exited.future;

  @override
  bool kill() {
    killed = true;
    if (!_exited.isCompleted) _exited.complete(0);
    return true;
  }
}

/// A fake CLI child for the app-driven create (issue #37): the real
/// `tunnel create` writes the credentials file; here the spawner's
/// [cliEffect] does it.
class FakeCliProcess implements CliProcess {
  FakeCliProcess({this.code = 0, this.err = ''});

  final int code;
  final String err;
  final Completer<int> _exited = Completer<int>();

  @override
  int get pid => 9001;

  @override
  Future<int> get exitCode {
    Future<void>.delayed(const Duration(milliseconds: 1))
        .then((_) => _exited.complete(code));
    return _exited.future;
  }

  @override
  Stream<List<int>> get stdout => Stream.value(const <int>[]);

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(err));

  @override
  bool kill() {
    if (!_exited.isCompleted) _exited.complete(code);
    return true;
  }
}

class FakeHost {
  FakeHost(this.dir);

  final Directory dir;

  final List<List<String>> argvs = [];
  final List<FakeTunnelProcess> spawned = [];

  late final CloudflaredConfigFile config;
  late final CloudflaredBinary binary;

  Future<void> setup() async {
    await File('${dir.path}/cloudflared').writeAsString('the binary');
    await File('${dir.path}/version')
        .writeAsString(CloudflaredBinary.pinnedVersion);
    config = CloudflaredConfigFile(file: File('${dir.path}/cloudflared.yml'));
    binary = CloudflaredBinary(
      dir: Directory(dir.path),
      resolveArch: () async => 'amd64',
      downloader: (Uri url, File target) async {},
    );
  }

  TunnelSupervisor supervisor(TunnelPreconditionChecker preconditions) =>
      TunnelSupervisor(
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
        scrape: (int port) async => 3,
        portHolder: (int port) async => null,
        killGrace: const Duration(milliseconds: 50),
        connectTimeout: const Duration(milliseconds: 10),
      );
}

void main() {
  late Directory dir;
  late FakeHost host;
  late TunnelSetup setup;
  late List<List<String>> cliArgvs;

  Future<void> build({
    required Directory credentialsDir,
    int cliCode = 0,
    String cliErr = '',
    Future<void> Function(List<String> argv)? cliEffect,
  }) async {
    cliArgvs = [];
    await host.setup();
    final preconditions = TunnelPreconditionChecker(
      binary: host.binary,
      configFile: host.config,
      bridgePort: 48201,
      dnsResolves: (String host) async => true,
      accessProbe: (String host) async => AccessVerdict.enforcing,
    );
    final cli = TunnelCli(
      binary: host.binary,
      spawner: (List<String> argv) async {
        cliArgvs.add(argv);
        await cliEffect?.call(argv);
        return FakeCliProcess(code: cliCode, err: cliErr);
      },
      timeout: const Duration(milliseconds: 100),
    );
    setup = TunnelSetup(
      supervisor: host.supervisor(preconditions),
      bridgePort: 48201,
      cli: cli,
      credentialsDir: credentialsDir,
      configFile: host.config,
    );
  }

  String payload({
    String tunnel = 'my-tunnel',
    String hostname = 'bridge.example.com',
    String? credentials,
    bool includeCredentials = true,
  }) =>
      '{'
      '"tunnel": "$tunnel",'
      '"hostname": "$hostname"'
      '${includeCredentials ? ', "credentials": ${jsonEncode(credentials ?? _kCredentialsJson)}' : ''}'
      '}';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-tunnel-setup');
    host = FakeHost(dir);
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test(
    'apply writes the credentials verbatim and the generated config',
    () async {
      await build(credentialsDir: Directory('${dir.path}/.cloudflared'));

      await setup.apply(payload());

      final credentialsFile = File(
        '${dir.path}/.cloudflared/$_kCredentialsUuid.json',
      );
      expect(credentialsFile.readAsStringSync(), _kCredentialsJson);
      expect(
        host.config.file.readAsStringSync(),
        'tunnel: my-tunnel\n'
        'credentials-file: ${dir.path}/.cloudflared/$_kCredentialsUuid.json\n'
        'ingress:\n'
        '  - hostname: bridge.example.com\n'
        '    service: http://127.0.0.1:48201\n'
        '  - service: http_status:404\n',
      );
    },
  );

  test('apply (re)starts the tunnel child when every step is met', () async {
    await build(credentialsDir: Directory('${dir.path}/.cloudflared'));

    await setup.apply(payload());

    expect(host.argvs, hasLength(1));
    // `cloudflared tunnel [tunnel command options] run [TUNNEL]`: the
    // command options go before `run`, the tunnel name is the last
    // argument.
    expect(host.argvs.single, [
      '${dir.path}/cloudflared',
      'tunnel',
      '--config',
      '${dir.path}/cloudflared.yml',
      '--no-autoupdate',
      '--metrics',
      '127.0.0.1:20241',
      'run',
      'my-tunnel',
    ]);
  });

  test('apply is idempotent: the same files, the child (re)started', () async {
    await build(credentialsDir: Directory('${dir.path}/.cloudflared'));

    await setup.apply(payload());
    final first = host.config.file.readAsStringSync();
    await setup.apply(payload());

    expect(host.config.file.readAsStringSync(), first);
    expect(
      File('${dir.path}/.cloudflared/$_kCredentialsUuid.json')
          .readAsStringSync(),
      _kCredentialsJson,
    );
    expect(host.argvs, hasLength(2));
    expect(host.spawned.first.killed, isTrue);
  });

  test('an invalid payload throws and leaves no files behind', () async {
    await build(credentialsDir: Directory('${dir.path}/.cloudflared'));

    for (final body in [
      payload(credentials: '{nope'),
      payload(tunnel: 'my tunnel'),
      payload(hostname: 'no dot'),
      '{not json}',
    ]) {
      await expectLater(setup.apply(body), throwsA(isA<TunnelSetupError>()));
    }

    expect(host.config.file.existsSync(), isFalse);
    final credentialsDir = Directory('${dir.path}/.cloudflared');
    expect(
      !credentialsDir.existsSync() || credentialsDir.listSync().isEmpty,
      isTrue,
    );
    expect(host.spawned, isEmpty);
  });

  test('unwriteable files are a TunnelSetupWriteError', () async {
    // A regular file where the credentials directory must go.
    await File('${dir.path}/.cloudflared').writeAsString('a file');
    await build(credentialsDir: Directory('${dir.path}/.cloudflared'));

    await expectLater(
      setup.apply(payload()),
      throwsA(isA<TunnelSetupWriteError>()),
    );
    expect(host.spawned, isEmpty);
  });

  test('apply without pasted credentials drives the CLI create', () async {
    await build(
      credentialsDir: Directory('${dir.path}/.cloudflared'),
      cliEffect: (List<String> argv) async {
        // The real `tunnel create` writes the credentials file itself.
        await Directory('${dir.path}/.cloudflared').create(recursive: true);
        await File('${dir.path}/.cloudflared/$_kCreatedUuid.json')
            .writeAsString(_kCreatedJson);
      },
    );

    await setup.apply(payload(includeCredentials: false));

    expect(cliArgvs, [
      ['${dir.path}/cloudflared', 'tunnel', 'create', 'my-tunnel'],
    ]);
    expect(
      File('${dir.path}/.cloudflared/$_kCreatedUuid.json').readAsStringSync(),
      _kCreatedJson,
    );
    expect(
      host.config.file.readAsStringSync(),
      'tunnel: my-tunnel\n'
      'credentials-file: ${dir.path}/.cloudflared/$_kCreatedUuid.json\n'
      'ingress:\n'
      '  - hostname: bridge.example.com\n'
      '    service: http://127.0.0.1:48201\n'
      '  - service: http_status:404\n',
    );
    expect(host.argvs, hasLength(1));
  });

  test('a failed create throws and writes nothing', () async {
    await build(
      credentialsDir: Directory('${dir.path}/.cloudflared'),
      cliCode: 1,
      cliErr: 'Error: not logged in',
    );

    await expectLater(
      setup.apply(payload(includeCredentials: false)),
      throwsA(
        isA<TunnelSetupCreateError>().having(
          (e) => e.message,
          'message',
          contains('not logged in'),
        ),
      ),
    );
    expect(cliArgvs, hasLength(1));
    expect(host.config.file.existsSync(), isFalse);
    expect(host.spawned, isEmpty);
  });

  test('a create that writes no credentials file throws', () async {
    await build(credentialsDir: Directory('${dir.path}/.cloudflared'));

    await expectLater(
      setup.apply(payload(includeCredentials: false)),
      throwsA(isA<TunnelSetupCreateError>()),
    );
    expect(host.config.file.existsSync(), isFalse);
    expect(host.spawned, isEmpty);
  });

  test('renderConfig renders the app-owned config', () {
    expect(
      TunnelSetup.renderConfig(
        tunnel: 'my-tunnel',
        credentialsFile: '~/.cloudflared/$_kCredentialsUuid.json',
        hostname: 'bridge.example.com',
        bridgePort: 48201,
      ),
      'tunnel: my-tunnel\n'
      'credentials-file: ~/.cloudflared/$_kCredentialsUuid.json\n'
      'ingress:\n'
      '  - hostname: bridge.example.com\n'
      '    service: http://127.0.0.1:48201\n'
      '  - service: http_status:404\n',
    );
  });
}
