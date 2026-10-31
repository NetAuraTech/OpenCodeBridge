import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_binary.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_cli.dart';

const int _kPid = 991;

/// A fake CLI child: exits with a fixed code, carries fixed output, and
/// records kills (a timed-out child is killed).
class FakeCliProcess implements CliProcess {
  FakeCliProcess({
    this.code = 0,
    this.out = '',
    this.err = '',
    this.alive = true,
  });

  final int code;
  final String out;
  final String err;
  final bool alive;

  final Completer<int> _exited = Completer<int>();

  bool killed = false;

  @override
  int get pid => _kPid;

  @override
  Future<int> get exitCode {
    if (alive) {
      Future<void>.delayed(const Duration(milliseconds: 1))
          .then((_) => _exited.complete(code));
    }
    return _exited.future;
  }

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(out));

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(err));

  @override
  bool kill() {
    killed = true;
    if (!_exited.isCompleted) _exited.complete(-15);
    return true;
  }
}

void main() {
  late Directory dir;
  late CloudflaredBinary binary;
  late List<List<String>> argvs;

  setUp(() async {
    argvs = [];
    dir = await Directory.systemTemp.createTemp('opencodebridge-tunnel-cli');
    await File('${dir.path}/cloudflared').writeAsString('the binary');
    await File('${dir.path}/version')
        .writeAsString(CloudflaredBinary.pinnedVersion);
    binary = CloudflaredBinary(
      dir: Directory(dir.path),
      resolveArch: () async => 'amd64',
      downloader: (Uri url, File target) async {},
    );
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  TunnelCli cliWith({
    required List<FakeCliProcess> spawned,
    Duration timeout = const Duration(milliseconds: 10),
  }) {
    return TunnelCli(
      binary: binary,
      spawner: (List<String> argv) async {
        argvs.add(argv);
        final child = spawned.isEmpty ? FakeCliProcess() : spawned.first;
        spawned.removeAt(0);
        return child;
      },
      timeout: timeout,
    );
  }

  test('login runs tunnel login with the app-managed binary', () async {
    final spawned = [FakeCliProcess(out: 'Browser auth succeeded for a@b.c')];
    final run = await cliWith(spawned: spawned).login();

    expect(argvs, [
      ['${dir.path}/cloudflared', 'tunnel', 'login'],
    ]);
    expect(run.success, isTrue);
    expect(run.stdout, 'Browser auth succeeded for a@b.c');
  });

  test('createTunnel runs tunnel create with the name', () async {
    final spawned = [FakeCliProcess(out: 'Created tunnel my-tunnel')];
    final run = await cliWith(spawned: spawned).createTunnel('my-tunnel');

    expect(argvs, [
      ['${dir.path}/cloudflared', 'tunnel', 'create', 'my-tunnel'],
    ]);
    expect(run.success, isTrue);
  });

  test('a non-zero exit is a failed run with the output line', () async {
    final spawned = [
      FakeCliProcess(
        code: 1,
        err: 'Error: no tunnel named "my-tunnel" exists in account',
      ),
    ];
    final run = await cliWith(spawned: spawned).createTunnel('my-tunnel');

    expect(run.success, isFalse);
    expect(run.firstOutputLine, contains('no tunnel named'));
  });

  test('a timed-out invocation kills the child and throws', () async {
    final child = FakeCliProcess(alive: false);
    final spawned = [child];

    await expectLater(
      cliWith(spawned: spawned).login(),
      throwsA(
        isA<CloudflaredCliError>().having(
          (e) => e.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
    expect(child.killed, isTrue);
  });
}
