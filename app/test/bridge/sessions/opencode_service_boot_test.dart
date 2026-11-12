import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/opencode_binary.dart';
import 'package:opencodebridge/bridge/sessions/opencode_cli.dart';
import 'package:opencodebridge/bridge/sessions/opencode_http_service.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service_boot.dart';
import 'package:opencodebridge/bridge/tunnel/port_holder.dart';

/// A fake opencode child (the `opencode serve` process): controllable
/// stdout/stderr (the `server listening on …` / `server password …` lines),
/// a settable liveness, and a kill that records the SIGTERM. A
/// `diesOnKill: false` child ignores the SIGTERM so the SIGKILL escalation
/// is observable.
class FakeOpencodeChild implements OpencodeChild {
  FakeOpencodeChild({this.pid = 424242, this.diesOnKill = true});

  @override
  final int pid;

  final bool diesOnKill;

  final _stdout = StreamController<List<int>>.broadcast();
  final _stderr = StreamController<List<int>>.broadcast();
  final _exited = Completer<int>();

  final List<ProcessSignal> kills = [];

  /// Whether the process is still alive (a false liveness is the boot's
  /// early-exit path).
  bool alive = true;

  bool get killed => kills.isNotEmpty;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode {
    if (!alive && !_exited.isCompleted) _exited.complete(0);
    return _exited.future;
  }

  @override
  bool kill() {
    if (alive) kills.add(ProcessSignal.sigterm);
    if (diesOnKill) die(0);
    return alive;
  }

  void die(int code) {
    alive = false;
    if (!_exited.isCompleted) _exited.complete(code);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  void emitListening(String url) => emitLine('server listening on $url');

  void emitPassword(String pw) => emitLine('server password $pw');

  /// Emits one of the child's stdout lines (the ready handshake).
  void emitLine(String line) => _stdout.add(utf8.encode('$line\n'));
}

/// The fake host around [OpencodeServiceBooter]: records every spawn and
/// signal and answers the port-holder / pid-alive / port-free / service
/// probes. The marker and descriptor live in [dir].
class FakeHost {
  FakeHost(this.dir);

  final Directory dir;

  final List<List<String>> argvs = [];
  final List<FakeOpencodeChild> spawned = [];

  /// The pids signalled, with the signal.
  final List<(int, ProcessSignal)> signals = [];

  /// Who holds the port of a re-attached (case-2) service, per probe.
  PortHolder? portHolder;

  /// Whether the holder dies on the SIGTERM (before the SIGKILL is needed).
  bool holderDiesOnTerm = true;

  final Set<int> deadPids = {};

  /// The opencode CLI path (the `OPENCODE_CLI`/PATH/app-managed resolution is
  /// stubbed to this).
  String? cli;

  /// Whether the service at the resolved url answers (the Basic-auth
  /// `GET /api/session` probe).
  bool serviceAnswers = false;

  /// Whether the base port is free (`true` → the base port is used).
  bool basePortFree = true;

  /// When set, the default spawner makes the spawned child report ready (the
  /// `server listening on …` + `server password …` lines) and the service
  /// answer, on spawn.
  bool emitReadyOnSpawn = false;

  /// The url a ready child reports.
  String readyUrl = 'http://127.0.0.1:4096';

  /// A custom spawner (the boot's early-exit / never-ready children); `null`
  /// uses the default spawn.
  Future<OpencodeChild> Function(List<String> argv)? spawner;

  String get markerPath => '${dir.path}/opencodebridge-child.json';

  String get descriptorPath => '${dir.path}/service.json';

  File get markerFile => File(markerPath);

  File get descriptorFile => File(descriptorPath);

  OpencodeServiceBooter booter({
    Duration startTimeout = const Duration(seconds: 20),
    Duration killGrace = const Duration(milliseconds: 50),
    int portBase = 4096,
  }) {
    return OpencodeServiceBooter(
      cli: () async => cli,
      spawner: (List<String> argv) async =>
          (spawner ?? _defaultSpawn).call(argv),
      kill: (int pid, ProcessSignal signal) async {
        signals.add((pid, signal));
        if (signal == ProcessSignal.sigkill) deadPids.add(pid);
        if (holderDiesOnTerm && signal == ProcessSignal.sigterm) {
          deadPids.add(pid);
        }
        return true;
      },
      pidAlive: (int pid) {
        if (deadPids.contains(pid)) return false;
        // A spawned child that has died on its own (not via a host signal)
        // is not alive either.
        for (final child in spawned) {
          if (child.pid == pid && !child.alive) return false;
        }
        return true;
      },
      portHolder: (int port) async => portHolder,
      isPortFree: (int port) async => port == portBase ? basePortFree : true,
      serviceProbe: (Uri url, String password) async => serviceAnswers,
      startTimeout: startTimeout,
      killGrace: killGrace,
      portBase: portBase,
      marker: markerFile,
      descriptor: descriptorFile,
    );
  }

  Future<OpencodeChild> _defaultSpawn(List<String> argv) async {
    argvs.add(argv);
    final child = FakeOpencodeChild();
    spawned.add(child);
    if (emitReadyOnSpawn) {
      serviceAnswers = true;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 10)).then((_) {
          child.emitListening(readyUrl);
          child.emitPassword('pw');
        }),
      );
    }
    return child;
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-boot');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('resolution order', () {
    test('no service: the app spawns its own (case 4) and owns it', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      host.emitReadyOnSpawn = true;
      final booter = host.booter();

      final result = await booter.start();

      expect(result.succeeded, isTrue);
      expect(result.owned, isTrue, reason: 'a spawned service is the app’s');
      expect(result.url, 'http://127.0.0.1:4096');
      expect(result.password, 'pw');
      expect(host.argvs, [
        ['/bin/opencode', 'serve', '--hostname', '127.0.0.1', '--port', '4096'],
      ]);
      // The descriptor (the bridge reads it) and the marker (the app’s
      // ownership) are both written.
      expect(host.descriptorFile.existsSync(), isTrue);
      expect(host.markerFile.existsSync(), isTrue);
      final descriptor = jsonDecode(
        host.descriptorFile.readAsStringSync(),
      ) as Map<String, Object?>;
      expect(descriptor, {'url': 'http://127.0.0.1:4096', 'password': 'pw'});
      expect(host.spawned.single.alive, isTrue, reason: 'the child is left up');
    });

    test(
      'case 2: a previous instance’s child still alive → attach, owned',
      () async {
        final host = FakeHost(dir);
        host.cli = '/bin/opencode';
        host.serviceAnswers = true;
        await host.markerFile.writeAsString(
          '{"url":"http://127.0.0.1:4100","password":"old"}',
        );
        final booter = host.booter();

        final result = await booter.start();

        expect(result.succeeded, isTrue);
        expect(
          result.owned,
          isTrue,
          reason: 'a re-attached child is the app’s',
        );
        expect(result.url, 'http://127.0.0.1:4100');
        expect(result.password, 'old');
        expect(host.argvs, isEmpty, reason: 'never spawn a second service');
      },
    );

    test('case 2: a stale marker (previous child gone) is removed and '
        'resolution continues to the spawn', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      // The marker is present but the service does not answer (dead child).
      host.serviceAnswers = false;
      await host.markerFile.writeAsString(
        '{"url":"http://127.0.0.1:4100","password":"old"}',
      );
      host.emitReadyOnSpawn = true;
      final booter = host.booter();

      final result = await booter.start();

      expect(result.succeeded, isTrue);
      expect(result.owned, isTrue);
      expect(result.url, 'http://127.0.0.1:4096');
      // A fresh spawn happened (the stale marker was removed and replaced).
      expect(host.argvs, hasLength(1));
      expect(host.markerFile.existsSync(), isTrue);
      final marker = jsonDecode(
        host.markerFile.readAsStringSync(),
      ) as Map<String, Object?>;
      expect(marker['url'], 'http://127.0.0.1:4096');
    });

    test(
      'case 3: a live service.json that answers → attach, never owned',
      () async {
        final host = FakeHost(dir);
        host.cli = '/bin/opencode';
        host.serviceAnswers = true;
        await host.descriptorFile.writeAsString(
          '{"url":"http://127.0.0.1:4200","password":"user"}',
        );
        final booter = host.booter();

        final result = await booter.start();

        expect(result.succeeded, isTrue);
        expect(
          result.owned,
          isFalse,
          reason: 'a user/TUI service is never the app’s (never stopped)',
        );
        expect(result.url, 'http://127.0.0.1:4200');
        expect(host.argvs, isEmpty, reason: 'never spawn over a live service');
      },
    );

    test('a stale service.json (service dead) does not attach; the app '
        'spawns', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      host.serviceAnswers = false;
      await host.descriptorFile.writeAsString(
        '{"url":"http://127.0.0.1:4200","password":"user"}',
      );
      host.emitReadyOnSpawn = true;
      final booter = host.booter();

      final result = await booter.start();

      expect(result.succeeded, isTrue);
      expect(result.owned, isTrue);
      expect(host.argvs, hasLength(1));
    });

    test(
      'start is idempotent: a second call reuses the instance’s service',
      () async {
        final host = FakeHost(dir);
        host.cli = '/bin/opencode';
        host.emitReadyOnSpawn = true;
        final booter = host.booter();

        final first = await booter.start();
        final second = await booter.start();

        expect(identical(first, second), isTrue);
        expect(host.argvs, hasLength(1), reason: 'never spawn twice');
      },
    );
  });

  group('spawn', () {
    test('a missing CLI fails the boot and the bridge stays up', () async {
      final host = FakeHost(dir);
      host.cli = null; // No OPENCODE_CLI, no PATH, no app-managed install.
      final booter = host.booter();

      final result = await booter.start();

      expect(result.succeeded, isFalse);
      expect(result.owned, isFalse);
      expect(result.error, isNotNull);
      expect(result.error, contains('no opencode CLI'));
      expect(host.argvs, isEmpty, reason: 'nothing to spawn');
      expect(host.markerFile.existsSync(), isFalse);
      expect(host.descriptorFile.existsSync(), isFalse);
    });

    test('a boot timeout stops the child and leaves no descriptor', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      host.serviceAnswers = false; // The service never answers.
      final booter = host.booter(
        startTimeout: const Duration(milliseconds: 200),
      );
      // Spawn a child that never reports ready.
      host.spawner = (List<String> argv) async {
        host.argvs.add(argv);
        final child = FakeOpencodeChild();
        host.spawned.add(child);
        child.emitLine('starting…');
        return child;
      };

      final result = await booter.start();

      expect(result.succeeded, isFalse);
      expect(result.error, contains('did not answer within'));
      expect(
        host.spawned.single.killed,
        isTrue,
        reason: 'the child is stopped',
      );
      expect(host.markerFile.existsSync(), isFalse);
      expect(host.descriptorFile.existsSync(), isFalse);
    });

    test('a child that exits during boot fails and is cleaned up', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      final booter = host.booter(startTimeout: const Duration(seconds: 5));
      host.spawner = (List<String> argv) async {
        host.argvs.add(argv);
        final child = FakeOpencodeChild();
        host.spawned.add(child);
        child.emitLine('boom');
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 10))
              .then((_) => child.die(1)),
        );
        return child;
      };

      final result = await booter.start();

      expect(result.succeeded, isFalse);
      expect(result.error, contains('exited during boot'));
      expect(host.markerFile.existsSync(), isFalse);
      expect(host.descriptorFile.existsSync(), isFalse);
    });

    test('a taken base port uses the bounded increment', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      host.basePortFree = false; // Port 4096 is taken → 4097.
      host.emitReadyOnSpawn = true;
      host.readyUrl = 'http://127.0.0.1:4097';
      final booter = host.booter();

      final result = await booter.start();

      expect(result.succeeded, isTrue);
      expect(host.argvs, [
        ['/bin/opencode', 'serve', '--hostname', '127.0.0.1', '--port', '4097'],
      ]);
      expect(result.url, 'http://127.0.0.1:4097');
    });

    test('the spawn is on loopback with an explicit port', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      host.emitReadyOnSpawn = true;
      final booter = host.booter();

      await booter.start();

      expect(host.argvs.single.first, '/bin/opencode');
      expect(host.argvs.single, contains('serve'));
      expect(host.argvs.single, contains('--hostname'));
      expect(host.argvs.single, contains('127.0.0.1'));
      expect(host.argvs.single, contains('--port'));
    });
  });

  group('stop (ownership)', () {
    test(
      'a spawned (case-4) child is SIGTERM’d and the files are removed',
      () async {
        final host = FakeHost(dir);
        host.cli = '/bin/opencode';
        host.emitReadyOnSpawn = true;
        final booter = host.booter(killGrace: const Duration(milliseconds: 50));
        await booter.start();

        await booter.stop();

        final child = host.spawned.single;
        expect(child.kills, isNotEmpty, reason: 'a SIGTERM was sent');
        expect(child.kills.first, ProcessSignal.sigterm);
        expect(host.markerFile.existsSync(), isFalse);
        expect(host.descriptorFile.existsSync(), isFalse);
        expect(child.alive, isFalse, reason: 'the child exited on the SIGTERM');
      },
    );

    test('a child that ignores the SIGTERM is escalated to SIGKILL', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      final booter = host.booter(killGrace: const Duration(milliseconds: 50));
      host.spawner = (List<String> argv) async {
        host.argvs.add(argv);
        final child = FakeOpencodeChild(diesOnKill: false);
        host.spawned.add(child);
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 10)).then((_) {
            child.emitListening('http://127.0.0.1:4096');
            child.emitPassword('pw');
          }),
        );
        host.serviceAnswers = true;
        return child;
      };
      await booter.start();

      await booter.stop();

      final child = host.spawned.single;
      expect(
        child.kills,
        contains(ProcessSignal.sigterm),
        reason: 'the SIGTERM comes first',
      );
      expect(
        host.signals,
        anyElement((s) => s.$1 == child.pid && s.$2 == ProcessSignal.sigkill),
        reason: 'escalation to SIGKILL after the grace',
      );
    });

    test('a re-attached (case-2) service is stopped by port, and the '
        'descriptor that is the app’s is removed', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      host.serviceAnswers = true;
      host.portHolder = const PortHolder(pid: 777, isCloudflared: false);
      await host.markerFile.writeAsString(
        '{"url":"http://127.0.0.1:4100","password":"old"}',
      );
      await host.descriptorFile.writeAsString(
        '{"url":"http://127.0.0.1:4100","password":"old"}',
      );
      final booter = host.booter();
      await booter.start();

      await booter.stop();

      expect(
        host.signals,
        anyElement((s) => s.$1 == 777 && s.$2 == ProcessSignal.sigterm),
        reason: 'the re-attached service’s pid is stopped by port',
      );
      expect(host.argvs, isEmpty, reason: 'nothing was spawned this run');
      expect(host.markerFile.existsSync(), isFalse);
      expect(host.descriptorFile.existsSync(), isFalse);
    });

    test(
      'a re-attached (case-2) service whose descriptor belongs to '
      'someone else is stopped, but the foreign descriptor is kept',
      () async {
        final host = FakeHost(dir);
        host.cli = '/bin/opencode';
        host.serviceAnswers = true;
        host.portHolder = const PortHolder(pid: 777, isCloudflared: false);
        await host.markerFile.writeAsString(
          '{"url":"http://127.0.0.1:4100","password":"old"}',
        );
        // A foreign descriptor (a different url) must not be deleted.
        await host.descriptorFile.writeAsString(
          '{"url":"http://127.0.0.1:9999","password":"foreign"}',
        );
        final booter = host.booter();
        await booter.start();

        await booter.stop();

        expect(host.markerFile.existsSync(), isFalse);
        expect(host.descriptorFile.existsSync(), isTrue);
      },
    );

    test('an attached (case-3) service is never stopped', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      host.serviceAnswers = true;
      await host.descriptorFile.writeAsString(
        '{"url":"http://127.0.0.1:4200","password":"user"}',
      );
      final booter = host.booter();
      await booter.start();

      await booter.stop();

      expect(host.signals, isEmpty, reason: 'never touch a user/TUI service');
      expect(host.argvs, isEmpty);
      expect(host.descriptorFile.existsSync(), isTrue);
    });
  });

  group('boot log (the log surface)', () {
    test('the child’s stdout lines are kept and forwarded to emit', () async {
      final host = FakeHost(dir);
      host.cli = '/bin/opencode';
      host.emitReadyOnSpawn = true;
      final booter = host.booter();
      final lines = <String>[];
      booter.emit = lines.add;

      await booter.start();

      expect(
        booter.bootLog,
        containsAll([
          'server listening on http://127.0.0.1:4096',
          'server password pw',
        ]),
      );
      expect(lines, contains('server password pw'));
    });
  });

  group('descriptor compatibility', () {
    test(
      'the descriptor the booter writes is readable by the bridge',
      () async {
        // The whole point of the app writing `service.json` (a directly-invoked
        // `opencode serve` writes none — issue #83): the bridge's
        // [OpencodeHttpService.fromHost] must read exactly what the booter
        // writes.
        final host = FakeHost(dir);
        host.cli = '/bin/opencode';
        host.emitReadyOnSpawn = true;
        final booter = host.booter();
        await booter.start();

        final service = await OpencodeHttpService.fromHost(
          statePath: host.descriptorPath,
        );
        // The descriptor's url/password round-trip into a usable client (the
        // base URL is where the service was reported listening).
        expect(service, isA<OpencodeHttpService>());
      },
    );
  });

  group('real end-to-end (the host opencode binary)', () {
    // Boots the actual `opencode serve` in an isolated HOME and proves the
    // full case-4 loop: spawn → descriptor + marker → the service answers →
    // the bridge's client reads the descriptor → stop tears it all down.
    // Skips when the host has no opencode CLI (CI may not ship one).
    test('spawns the real service, writes a readable descriptor, and '
        'stops it cleanly', () async {
      final binary = findHostOpencode();
      if (binary == null) {
        markTestSkipped('no opencode CLI on the host PATH');
        return;
      }
      final isolatedHome = await Directory.systemTemp.createTemp(
        'opencode-e2e-home',
      );
      final stateDir = await Directory.systemTemp.createTemp(
        'opencode-e2e-state',
      );
      final marker = File('${stateDir.path}/opencodebridge-child.json');
      final descriptor = File('${stateDir.path}/service.json');
      try {
        const portBase = 43777;
        final booter = OpencodeServiceBooter(
          cli: () async => binary,
          spawner: (List<String> argv) async {
            // An isolated HOME: opencode's own state is thrown away, and the
            // no-`--service` form writes no descriptor (issue #83) — the
            // booter is the one that writes it.
            final process = await Process.start(
              argv.first,
              argv.sublist(1),
              environment: {...Platform.environment, 'HOME': isolatedHome.path},
            );
            return ioProcessAdapter(process);
          },
          // The real host seams: free-port check, liveness, signals, and the
          // authenticated `GET /api/session` probe.
          isPortFree: hostPortFree,
          pidAlive: hostOpencodePidAlive,
          kill: hostKillOpencode,
          serviceProbe: probeOpencodeService,
          startTimeout: const Duration(seconds: 60),
          killGrace: const Duration(seconds: 10),
          portBase: portBase,
          marker: marker,
          descriptor: descriptor,
        );

        final result = await booter.start();
        expect(result.succeeded, isTrue, reason: result.error);
        expect(result.owned, isTrue);
        expect(result.url, 'http://127.0.0.1:$portBase');
        expect(result.password, isNotEmpty);

        // The descriptor and marker are written …
        expect(descriptor.existsSync(), isTrue);
        expect(marker.existsSync(), isTrue);
        // … and the bridge's client reads them back.
        final service = await OpencodeHttpService.fromHost(
          statePath: descriptor.path,
        );
        // … and the service answers an authenticated request (a fresh
        // isolated host has no sessions, but the list endpoint answers).
        final sessions = await service.listSessions();
        expect(sessions, isEmpty);

        // Stop: SIGTERM the real child, then tear down the app's files.
        await booter.stop();
        expect(marker.existsSync(), isFalse);
        expect(descriptor.existsSync(), isFalse);
      } finally {
        for (final tmp in [isolatedHome, stateDir]) {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        }
      }
    });
  });

  group('CLI resolution', () {
    test('OPENCODE_CLI wins', () async {
      final resolved = await resolveHostOpencodeCli(
        environment: {'OPENCODE_CLI': '/custom/opencode'},
        appManaged: () async => throw StateError('must not be reached'),
      );
      expect(resolved, '/custom/opencode');
    });

    test('else opencode on the PATH', () async {
      final bin = await Directory.systemTemp.createTemp('cli-path');
      try {
        final opencode = File('${bin.path}/opencode');
        await opencode.writeAsString('#!/bin/sh\n');
        // The PATH scan requires an exec bit.
        await Process.run('chmod', ['755', opencode.path]);
        final resolved = await resolveHostOpencodeCli(
          environment: {'PATH': bin.path},
          appManaged: () async => throw StateError('must not be reached'),
        );
        expect(resolved, opencode.path);
      } finally {
        bin.deleteSync(recursive: true);
      }
    });

    test('else the app-managed pinned install', () async {
      final dir2 = await Directory.systemTemp.createTemp('cli-managed');
      try {
        final binary = File('${dir2.path}/opencode');
        await binary.writeAsString('the app-managed binary');
        final resolved = await resolveHostOpencodeCli(
          environment: {'PATH': '/nonexistent-path-for-test'},
          appManaged: () async => binary,
        );
        expect(resolved, binary.path);
      } finally {
        dir2.deleteSync(recursive: true);
      }
    });

    test('none available → null', () async {
      final resolved = await resolveHostOpencodeCli(
        environment: {'PATH': '/nonexistent-path-for-test'},
        appManaged: () async => throw OpencodeBinaryError('no network'),
      );
      expect(resolved, isNull);
    });
  });
}
