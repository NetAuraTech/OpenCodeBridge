import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/orb/orb_embedded.dart';

/// One run of the entrypoint against the fake toolchain (see [_Harness]).
class _Run {
  _Run(this.exitCode, this.output, this.calls);

  /// The entrypoint's exit code.
  final int exitCode;

  /// The entrypoint's stdout + stderr lines (the boot log the bridge
  /// streams as `orb.boot` events).
  final List<String> output;

  /// The fake toolchain's call log (one line per tool invocation, in call
  /// order — the harness is fresh per test, so this is this run's calls).
  final List<String> calls;

  /// The entrypoint's output as a single string (for `contains`).
  String get stdout => output.join('\n');

  /// The call log lines starting with [prefix] (in call order).
  List<String> callsTo(String prefix) =>
      calls.where((c) => c.startsWith(prefix)).toList();

  /// Whether any call starts with [prefix].
  bool called(String prefix) => callsTo(prefix).isNotEmpty;

  /// The last call starting with [prefix], or `null`.
  String? lastCallTo(String prefix) {
    final matching = callsTo(prefix);
    return matching.isEmpty ? null : matching.last;
  }

  /// The boot-stage words, in the order they streamed (spec §9.4: the
  /// preparing state shows the stage word).
  List<String> get stages => [
    for (final line in output)
      if (line.startsWith('[orb] stage: '))
        line.substring('[orb] stage: '.length),
  ];
}

/// Runs the EMBEDDED entrypoint (exactly the bytes the image bakes, spec
/// §6.6) under /bin/sh against a scripted fake toolchain: the PATH is
/// seeded with stand-ins for opencode, git, ssh-keyscan, the installers,
/// the service binaries, curl, chown and the user switch. Every fake
/// records its invocation in a call log and simulates the bits of state
/// the entrypoint polls (the health checks). The container paths are
/// pointed at temp dirs through the script's `ORB_*` env overrides.
///
/// A run models one container start: the in-container services are dead
/// (the fake health state resets), the data volume ([data]) and the
/// workspace persist (they are Docker volumes), and the call log
/// accumulates across the runs of one harness (one orb's life).
class _Harness {
  _Harness() : root = Directory.systemTemp.createTempSync('oc-orb-entry-') {
    for (final name in const [
      'bin',
      'workspace',
      'data',
      'home',
      'ssh',
      'state',
      'pgbin',
      'fake-state',
    ]) {
      Directory('${root.path}/$name').createSync();
    }
    _writeFakes();
  }

  final Directory root;
  Directory get bin => Directory('${root.path}/bin');
  Directory get workspace => Directory('${root.path}/workspace');
  Directory get data => Directory('${root.path}/data');
  Directory get ssh => Directory('${root.path}/ssh');
  Directory get state => Directory('${root.path}/state');
  Directory get pgbin => Directory('${root.path}/pgbin');
  Directory get fakeState => Directory('${root.path}/fake-state');
  File get callLog => File('${root.path}/call.log');

  /// Runs one container start. [workspaceFiles] are the files present in
  /// the workspace (the clone's content plus the bridge-injected `.env*`);
  /// [firstStart] leaves the workspace without `.git` so the entrypoint's
  /// first-start clone path runs; [script] overrides the embedded
  /// entrypoint (the gate-timeout tests shorten the named constant);
  /// [stateFiles] pre-seed the fake health state (services already up);
  /// [env] adds env for the fakes (e.g. `FAKE_NPM_EXIT`).
  Future<_Run> run({
    Map<String, String> workspaceFiles = const {},
    bool firstStart = false,
    bool knownHosts = true,
    String? script,
    Map<String, String> stateFiles = const {},
    Map<String, String> env = const {},
  }) async {
    for (final entry in workspaceFiles.entries) {
      File('${workspace.path}/${entry.key}').writeAsStringSync(entry.value);
    }
    if (firstStart) {
      final git = Directory('${workspace.path}/.git');
      if (git.existsSync()) git.deleteSync(recursive: true);
    } else {
      Directory('${workspace.path}/.git').createSync(recursive: true);
    }
    final knownHostsFile = File('${ssh.path}/known_hosts');
    if (knownHosts) {
      knownHostsFile.writeAsStringSync('github.com ssh-rsa FAKE\n');
    } else {
      if (knownHostsFile.existsSync()) knownHostsFile.deleteSync();
    }
    // A new container start: the in-container services are dead — reset
    // the fake health state (the data volume persists).
    for (final file in fakeState.listSync()) {
      file.deleteSync();
    }
    for (final entry in stateFiles.entries) {
      File('${fakeState.path}/${entry.key}').writeAsStringSync(entry.value);
    }

    final entrypoint = File('${root.path}/entrypoint.sh')
      ..writeAsStringSync(script ?? OrbEmbedded.files['orb-entrypoint.sh']!);
    final environment = <String, String>{
      'PATH': '${bin.path}:${Platform.environment['PATH']!}',
      'HOME': '${root.path}/home',
      'ORB_WORKSPACE': workspace.path,
      'ORB_DATA_DIR': data.path,
      'ORB_SSH_DIR': ssh.path,
      'ORB_STATE_DIR': state.path,
      'FAKE_LOG': callLog.path,
      'FAKE_STATE': fakeState.path,
      'FAKE_PG_BINDIR': pgbin.path,
      'ORB_ID': 'testorb1',
      'ORB_REPO_URL': 'git@github.com:acme/project.git',
      'ORB_GIT_NAME': 'Orb Test',
      'ORB_GIT_EMAIL': 'orb@test.local',
      ...env,
    };
    final process = await Process.start('/bin/sh', [
      entrypoint.path,
    ], environment: environment);
    final out = <String>[];
    final err = <String>[];
    final outDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(out.add)
        .asFuture<void>();
    final errDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(err.add)
        .asFuture<void>();
    final code = await process.exitCode;
    await outDone;
    await errDone;
    // The backgrounded fake services (nohup) may still be appending to the
    // call log; let them settle before reading it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final calls = callLog.existsSync()
        ? callLog
              .readAsStringSync()
              .split('\n')
              .where((l) => l.isNotEmpty)
              .toList()
        : <String>[];
    return _Run(code, [...out, ...err], calls);
  }

  /// The cumulative call count (across this harness's runs) of calls
  /// starting with [prefix].
  int callCount(String prefix) {
    if (!callLog.existsSync()) return 0;
    return callLog
        .readAsStringSync()
        .split('\n')
        .where((l) => l.startsWith(prefix))
        .length;
  }

  /// The SQL captured by the fake psql (the postgres provisioning).
  String psqlSql() => File('${fakeState.path}/psql-sql').existsSync()
      ? File('${fakeState.path}/psql-sql').readAsStringSync()
      : '';

  void dispose() {
    root.deleteSync(recursive: true);
  }

  // ------------------------------------------------------------------------
  // The fake toolchain.

  void _writeFakes() {
    const fakes = <String, String>{
      'opencode': r'''
echo "opencode $* ghconfig=${GH_CONFIG_DIR:-unset}" >> "$FAKE_LOG"
exit 0
''',
      'git': r'''
echo "git $*" >> "$FAKE_LOG"
if [ "$1" = "init" ]; then
    mkdir -p "$2/.git/hooks"
    exit 0
fi
for a in "$@"; do
    if [ "$a" = "push" ]; then
        exit "${FAKE_GIT_PUSH_EXIT:-0}"
    fi
    if [ "$a" = "symbolic-ref" ]; then
        echo "origin/main"
        exit 0
    fi
done
exit 0
''',
      'ssh-keyscan': r'''
echo "ssh-keyscan $*" >> "$FAKE_LOG"
echo "github.com ssh-rsa FAKE"
exit 0
''',
      'npm': r'''
echo "npm $*" >> "$FAKE_LOG"
exit "${FAKE_NPM_EXIT:-0}"
''',
      'composer': r'''
echo "composer $*" >> "$FAKE_LOG"
exit 0
''',
      'flutter': r'''
echo "flutter $*" >> "$FAKE_LOG"
exit 0
''',
      'chown': r'''
echo "chown $*" >> "$FAKE_LOG"
exit 0
''',
      'runuser': r'''
echo "runuser $*" >> "$FAKE_LOG"
[ "$1" = "-u" ] || exit 1
shift
shift
[ "$1" = "--" ] || exit 1
shift
exec "$@"
''',
      'pg_config': r'''
case "$1" in
    --bindir)
        echo "$FAKE_PG_BINDIR"
        ;;
    --version)
        echo "PostgreSQL 16.0 (fake)"
        ;;
esac
exit 0
''',
      'redis-server': r'''
echo "redis-server $*" >> "$FAKE_LOG"
touch "$FAKE_STATE/redis-up"
exit 0
''',
      'redis-cli': r'''
echo "redis-cli $*" >> "$FAKE_LOG"
# The command is the first non-option argument (-h/-p take a value; the real
# redis-cli parses them only before the command, so the entrypoint uses that
# form).
cmd=""
skip=0
for a in "$@"; do
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    case "$a" in
        -h | -p) skip=1 ;;
        -*) ;;
        *) cmd="$a"; break ;;
    esac
done
if [ "$cmd" = "ping" ] && [ -f "$FAKE_STATE/redis-up" ]; then
    echo "PONG"
    exit 0
fi
exit 1
''',
      'typesense-server': r'''
echo "typesense-server $*" >> "$FAKE_LOG"
touch "$FAKE_STATE/typesense-up"
exit 0
''',
      'mailhog': r'''
echo "mailhog $*" >> "$FAKE_LOG"
touch "$FAKE_STATE/mailhog-up"
exit 0
''',
      'curl': r'''
echo "curl $*" >> "$FAKE_LOG"
url=""
for a in "$@"; do
    case "$a" in
        -*) ;;
        *) url="$a"; break ;;
    esac
done
case "$url" in
    */health)
        [ -f "$FAKE_STATE/typesense-up" ] && exit 0 || exit 1
        ;;
    */api/v2/messages)
        [ -f "$FAKE_STATE/mailhog-up" ] && exit 0 || exit 1
        ;;
esac
exit 0
''',
    };
    const pgTools = <String, String>{
      // The fake pg_isready becomes healthy after FAKE_PG_HEALTHY_AFTER
      // probes (default 2 — one poll of the gate), or never when the
      // postgres-never marker is present.
      'pg_isready': r'''
echo "pg_isready $*" >> "$FAKE_LOG"
if [ -f "$FAKE_STATE/postgres-never" ]; then
    exit 2
fi
n=0
if [ -f "$FAKE_STATE/pg-probes" ]; then
    n=$(cat "$FAKE_STATE/pg-probes")
fi
n=$((n + 1))
echo "$n" > "$FAKE_STATE/pg-probes"
if [ "$n" -ge "${FAKE_PG_HEALTHY_AFTER:-2}" ]; then
    exit 0
fi
exit 2
''',
      'initdb': r'''
echo "initdb $*" >> "$FAKE_LOG"
dir=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-D" ]; then dir="$a"; fi
    prev="$a"
done
if [ -n "$dir" ]; then
    echo "16" > "$dir/PG_VERSION"
fi
exit 0
''',
      'pg_ctl': r'''
echo "pg_ctl $*" >> "$FAKE_LOG"
exit 0
''',
      'psql': r'''
echo "psql $*" >> "$FAKE_LOG"
cat >> "$FAKE_STATE/psql-sql"
exit 0
''',
    };
    fakes.forEach((name, body) => _writeExecutable(bin.path, name, body));
    pgTools.forEach((name, body) => _writeExecutable(pgbin.path, name, body));
  }

  void _writeExecutable(String dir, String name, String body) {
    final file = File('$dir/$name')..writeAsStringSync('#!/bin/sh\n$body');
    Process.runSync('chmod', ['+x', file.path]);
  }
}

void main() {
  late _Harness h;

  setUp(() {
    h = _Harness();
  });

  tearDown(() {
    h.dispose();
  });

  group('the installers (issue #94, spec §6.3)', () {
    test('npm ci when package-lock.json is present (first start)', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'package.json': '{}', 'package-lock.json': '{}'},
      );
      expect(r.exitCode, 0);
      expect(r.called('npm ci'), isTrue);
      expect(r.called('npm install'), isFalse);
    });

    test('npm install when there is no lockfile', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'package.json': '{}'},
      );
      expect(r.exitCode, 0);
      expect(r.called('npm ci'), isFalse);
      expect(r.called('npm install'), isTrue);
    });

    test('no package.json: no npm', () async {
      final r = await h.run(firstStart: true);
      expect(r.exitCode, 0);
      expect(r.called('npm'), isFalse);
    });

    test('composer install when composer.json is present', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'composer.json': '{}'},
      );
      expect(r.exitCode, 0);
      expect(r.called('composer install'), isTrue);
    });

    test('flutter pub get when pubspec.yaml is present', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'pubspec.yaml': 'name: x'},
      );
      expect(r.exitCode, 0);
      expect(r.called('flutter pub get'), isTrue);
    });

    test('an installer failure is non-fatal: log and continue', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'package.json': '{}', 'package-lock.json': '{}'},
        env: {'FAKE_NPM_EXIT': '1'},
      );
      expect(r.exitCode, 0, reason: 'a missing dep does not brick the orb');
      expect(r.stdout, contains('npm ci failed'));
      expect(r.called('opencode'), isTrue, reason: 'opencode still starts');
    });

    test(
      'the installers run once, at create: a wake does not re-run them',
      () async {
        final r = await h.run(
          firstStart: false,
          workspaceFiles: {'package.json': '{}', 'package-lock.json': '{}'},
        );
        expect(r.exitCode, 0);
        expect(r.called('npm'), isFalse);
        expect(r.called('composer'), isFalse);
        expect(r.called('flutter'), isFalse);
      },
    );
  });

  group('the local services (issue #94, spec §6.4)', () {
    test(
      'a declared local service starts on every start (create AND wake)',
      () async {
        final create = await h.run(
          firstStart: true,
          workspaceFiles: {'.env': 'PG_HOST=127.0.0.1\n'},
        );
        expect(create.exitCode, 0);
        expect(
          create.called('pg_ctl'),
          isTrue,
          reason: 'postgres starts at create',
        );

        // The wake: the container restarts, the services are dead again, the
        // data volume persists.
        final wake = await h.run();
        expect(wake.exitCode, 0);
        expect(
          wake.called('pg_ctl'),
          isTrue,
          reason: 'postgres starts again on wake',
        );
        expect(
          h.callCount('initdb'),
          1,
          reason: 'initdb runs once: the data volume persists across starts',
        );
      },
    );

    test('the service binds to 127.0.0.1 on the port the .env names', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {
          '.env': 'PG_HOST=localhost\nPG_PORT=5543\nREDIS_HOST=127.0.0.1\nREDIS_PORT=6380\n',
        },
      );
      expect(r.exitCode, 0);
      expect(r.lastCallTo('pg_ctl'), contains("-p 5543"));
      expect(r.lastCallTo('pg_ctl'), contains("listen_addresses='127.0.0.1'"));
      expect(r.lastCallTo('redis-server'), contains('--port 6380'));
      expect(r.lastCallTo('redis-server'), contains('--bind 127.0.0.1'));
    });

    test('the conventional default port when the .env names none', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {
          '.env': 'PG_HOST=127.0.0.1\nREDIS_HOST=::1\nTYPESENSE_HOST=localhost\nMAILHOG_HOST=127.0.0.1\n',
        },
      );
      expect(r.exitCode, 0);
      expect(r.lastCallTo('pg_ctl'), contains('-p 5432'));
      expect(r.lastCallTo('redis-server'), contains('--port 6379'));
      expect(r.lastCallTo('typesense-server'), contains('--api-port=8108'));
      expect(
        r.lastCallTo('typesense-server'),
        contains('--api-address=127.0.0.1'),
      );
      expect(
        r.lastCallTo('mailhog'),
        contains('--api-bind-addr 127.0.0.1:8025'),
      );
      expect(
        r.lastCallTo('mailhog'),
        contains('--ui-bind-addr 127.0.0.1:8025'),
      );
      expect(
        r.lastCallTo('mailhog'),
        contains('--smtp-bind-addr 127.0.0.1:1025'),
      );
    });

    test('a non-local host is logged and ignored', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'.env': 'PG_HOST=db.internal.example.com\n'},
      );
      expect(r.exitCode, 0);
      expect(r.called('pg_ctl'), isFalse);
      expect(r.called('initdb'), isFalse);
      expect(r.stdout, contains('postgres: host'));
      expect(r.stdout, contains('not local'));
      expect(r.called('opencode'), isTrue, reason: 'the orb still boots');
    });

    test('an undeclared service is not started', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'.env': 'PG_HOST=127.0.0.1\n'},
      );
      expect(r.called('redis-server'), isFalse);
      expect(r.called('typesense-server'), isFalse);
      expect(r.called('mailhog'), isFalse);
    });

    test('.env.example files are never a declaration', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {
          '.env.example': 'PG_HOST=127.0.0.1\nREDIS_HOST=localhost\n',
        },
      );
      expect(r.exitCode, 0);
      expect(r.called('pg_ctl'), isFalse);
      expect(r.called('redis-server'), isFalse);
      expect(r.stdout, isNot(contains('stage: health')));
    });

    test('a later .env file overrides an earlier one', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {
          '.env': 'PG_HOST=127.0.0.1\n',
          '.env.local': 'PG_HOST=remote.example.com\n',
        },
      );
      expect(
        r.called('pg_ctl'),
        isFalse,
        reason: '.env.local wins: the host is not local',
      );
      expect(r.stdout, contains('not local'));
    });

    test('service data lives on the data volume, not the workspace', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'.env': 'PG_HOST=127.0.0.1\nREDIS_HOST=localhost\n'},
      );
      expect(r.lastCallTo('initdb'), contains('-D ${h.data.path}/postgres'));
      expect(r.lastCallTo('pg_ctl'), contains('-D ${h.data.path}/postgres'));
      expect(
        r.lastCallTo('redis-server'),
        contains('--dir ${h.data.path}/redis'),
      );
    });

    test('postgres is provisioned from the .env (role + database)', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {
          '.env': 'PG_HOST=127.0.0.1\nPG_USER=appuser\nPG_PASSWORD=apppass\nPG_DB_NAME=appdb\n',
        },
      );
      expect(r.exitCode, 0);
      expect(r.called('psql'), isTrue);
      expect(h.psqlSql(), contains('CREATE ROLE "appuser" LOGIN'));
      expect(h.psqlSql(), contains("PASSWORD 'apppass'"));
      expect(h.psqlSql(), contains('CREATE DATABASE "appdb" OWNER "appuser"'));
    });

    test('no PG_USER / PG_DB_NAME: no provisioning', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'.env': 'PG_HOST=127.0.0.1\n'},
      );
      expect(r.called('psql'), isFalse);
    });

    test('typesense is provisioned with the .env API key', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {
          '.env': 'TYPESENSE_HOST=127.0.0.1\nTYPESENSE_API_KEY=tskey\n',
        },
      );
      expect(r.exitCode, 0);
      expect(r.lastCallTo('typesense-server'), contains('--api-key=tskey'));
      expect(
        r.lastCallTo('typesense-server'),
        contains('--data-dir=${h.data.path}/typesense'),
      );
    });

    test('an already-healthy service is not (re)started '
        '(health-check before start)', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'.env': 'PG_HOST=127.0.0.1\nREDIS_HOST=localhost\n'},
        env: {'FAKE_PG_HEALTHY_AFTER': '1'},
        stateFiles: {'redis-up': ''},
      );
      expect(r.exitCode, 0);
      expect(
        r.called('pg_ctl'),
        isFalse,
        reason: 'postgres was already healthy',
      );
      expect(r.called('initdb'), isFalse);
      expect(
        r.called('redis-server'),
        isFalse,
        reason: 'redis was already healthy',
      );
      expect(r.stdout, contains('postgres: already healthy'));
      expect(r.stdout, contains('redis: already healthy'));
    });
  });

  group('the health gate (issue #94, spec §6.5)', () {
    test(
      'opencode starts only after every declared service is healthy',
      () async {
        final r = await h.run(
          firstStart: true,
          workspaceFiles: {
            '.env':
                'PG_HOST=127.0.0.1\nPG_PORT=5543\nPG_USER=u\nPG_PASSWORD=p\nPG_DB_NAME=d\n'
                'REDIS_HOST=localhost\nREDIS_PORT=6380\n'
                'TYPESENSE_HOST=::1\nTYPESENSE_API_KEY=tskey\n'
                'MAILHOG_HOST=127.0.0.1\n',
          },
        );
        expect(r.exitCode, 0);
        // The gate waited for every declared service...
        for (final service in ['postgres', 'redis', 'typesense', 'mailhog']) {
          expect(r.stdout, contains('$service: healthy'));
        }
        // ...and only then opencode started (after every service start).
        final opencodeAt = r.calls.indexOf(
          r.calls.firstWhere((c) => c.startsWith('opencode')),
        );
        for (final prefix in [
          'pg_ctl',
          'redis-server',
          'typesense-server',
          'mailhog',
        ]) {
          final at = r.calls.indexOf(
            r.calls.firstWhere((c) => c.startsWith(prefix)),
          );
          expect(
            at,
            lessThan(opencodeAt),
            reason: '$prefix must precede opencode',
          );
        }
        expect(r.lastCallTo('opencode'), contains('--port 4096'));
        expect(r.stdout, contains('[orb] stage: ready'));
      },
    );

    test(
      'a declared service that never becomes healthy fails the boot',
      () async {
        // The gate timeout is a named constant in the boot script (spec
        // §6.5); the test-local copy shortens it (the embedded file keeps
        // the ~30 s default).
        final script = OrbEmbedded.files['orb-entrypoint.sh']!.replaceFirst(
          'SERVICE_HEALTH_TIMEOUT_SECONDS=30',
          'SERVICE_HEALTH_TIMEOUT_SECONDS=1',
        );
        expect(script, contains('SERVICE_HEALTH_TIMEOUT_SECONDS=1'));
        final r = await h.run(
          firstStart: true,
          script: script,
          workspaceFiles: {'.env': 'PG_HOST=127.0.0.1\n'},
          stateFiles: {'postgres-never': ''},
        );
        expect(
          r.exitCode,
          isNot(0),
          reason: 'the entrypoint exits non-zero: the boot fails',
        );
        expect(r.called('pg_ctl'), isTrue, reason: 'the start was attempted');
        expect(
          r.called('opencode'),
          isFalse,
          reason: 'opencode never starts behind an unhealthy service',
        );
        expect(r.stdout, contains('FATAL'));
        expect(r.stdout, contains('postgres'));
      },
    );

    test(
      'no declared services: no gate, opencode starts immediately',
      () async {
        final r = await h.run(
          firstStart: true,
          workspaceFiles: {'.env': 'APP_DEBUG=1\n'},
        );
        expect(r.exitCode, 0);
        expect(r.stdout, isNot(contains('stage: health')));
        expect(r.called('pg_isready'), isFalse);
        expect(r.called('opencode'), isTrue);
      },
    );
  });

  group('the boot stages (issue #94, spec §9.3/§9.4)', () {
    test('a first start streams the stages in order', () async {
      final r = await h.run(
        firstStart: true,
        workspaceFiles: {'package.json': '{}', '.env': 'PG_HOST=127.0.0.1\n'},
      );
      expect(r.stages, [
        'cloning',
        'installing',
        'services',
        'health',
        'ready',
      ]);
    });

    test('a wake streams no clone/install stages', () async {
      final r = await h.run(
        firstStart: false,
        workspaceFiles: {'.env': 'PG_HOST=127.0.0.1\n'},
      );
      expect(r.stages, ['services', 'health', 'ready']);
    });

    test('a wake with no declared services skips the health stage', () async {
      final r = await h.run(firstStart: false);
      expect(r.stages, ['services', 'ready']);
    });
  });

  group('the first-start path (issue #93, kept intact)', () {
    test('a first start clones, installs the hook, then boots', () async {
      final r = await h.run(firstStart: true);
      expect(r.exitCode, 0);
      expect(r.callsTo('git init').first, endsWith(h.workspace.path));
      final hook = File('${h.workspace.path}/.git/hooks/post-commit');
      expect(hook.readAsStringSync(), contains('orb/testorb1'));
      expect(r.called('opencode'), isTrue);
    });

    test(
      'a first start without a base checks out the remote default',
      () async {
        // The fake git answers `symbolic-ref` with `origin/main` (the fake
        // default branch).
        final r = await h.run(firstStart: true);
        expect(r.exitCode, 0);
        expect(
          r.lastCallTo('git -C ${h.workspace.path} checkout'),
          contains('origin/main'),
        );
      },
    );

    test(
      'a seeded first start checks out the seed branch (ORB_BASE_BRANCH)',
      () async {
        // The seed (spec §3.3): the bridge passes the seed's branch; the
        // clone checks out the remote's branch tip, never the default.
        final r = await h.run(
          firstStart: true,
          env: {'ORB_BASE_BRANCH': 'orb/seedid'},
        );
        expect(r.exitCode, 0);
        expect(
          r.lastCallTo('git -C ${h.workspace.path} checkout'),
          contains('origin/orb/seedid'),
        );
      },
    );

    test('the ssh known-hosts fallback seeds a container-local copy', () async {
      final r = await h.run(firstStart: false, knownHosts: false);
      expect(r.exitCode, 0);
      expect(r.called('ssh-keyscan'), isTrue);
      expect(
        File('${h.state.path}/orb-ssh/known_hosts').readAsStringSync(),
        contains('github.com'),
      );
    });
  });

  group('the staged gh credentials (issue #120)', () {
    test('a staged gh config redirects gh: GH_CONFIG_DIR is exported and '
        'baked into the hook', () async {
      // The bridge staged the container-local gh credentials before the
      // start (the state dir mount carries them, host-authoritative).
      Directory('${h.state.path}/gh').createSync(recursive: true);
      File('${h.state.path}/gh/hosts.yml').writeAsStringSync(
        'github.com:\n    users:\n        u:\n            oauth_token: t\n'
        '    user: u\n',
      );
      final r = await h.run(firstStart: true);
      expect(r.exitCode, 0);
      // opencode (and every shell it spawns — the hook, the agent's gh)
      // inherits the config dir pointing at the staged credentials.
      expect(r.lastCallTo('opencode'), contains('ghconfig=${h.state.path}/gh'));
      // The hook carries it too: a hook run outside opencode's shell
      // still finds the credentials.
      final hook = File('${h.workspace.path}/.git/hooks/post-commit');
      expect(hook.readAsStringSync(), contains('GH_CONFIG_DIR'));
      expect(hook.readAsStringSync(), contains('${h.state.path}/gh'));
    });

    test(
      'no staged gh config: gh keeps the default (mounted) config',
      () async {
        // A host whose gh config is self-sufficient (or has no token at
        // all): nothing is staged, nothing is redirected — the §4 mount
        // stays the surface.
        final r = await h.run(firstStart: true);
        expect(r.exitCode, 0);
        expect(r.lastCallTo('opencode'), contains('ghconfig=unset'));
        final hook = File('${h.workspace.path}/.git/hooks/post-commit');
        expect(hook.readAsStringSync(), isNot(contains('GH_CONFIG_DIR')));
      },
    );
  });

  group('the post-commit push marker (issue #120)', () {
    /// Runs the installed hook the way git would: `sh <hook>` with the
    /// fake toolchain on PATH. [pushExit] scripts the fake `git push`.
    Future<int> runHook(_Harness h, {String pushExit = '0'}) async {
      final result = await Process.run(
        '/bin/sh',
        ['${h.workspace.path}/.git/hooks/post-commit'],
        environment: {
          'PATH': '${h.bin.path}:${Platform.environment['PATH']!}',
          'HOME': '${h.root.path}/home',
          'FAKE_LOG': h.callLog.path,
          'FAKE_GIT_PUSH_EXIT': pushExit,
        },
      );
      return result.exitCode;
    }

    test(
      'a failed push marks the state dir and still fails the hook',
      () async {
        final r = await h.run(firstStart: true);
        expect(r.exitCode, 0);
        final marker = File('${h.state.path}/push-failed');
        expect(marker.existsSync(), isFalse);

        final exit = await runHook(h, pushExit: '1');
        // The hook still reports the failure to the committing agent.
        expect(exit, isNot(0));
        // And the bridge-readable marker names the branch.
        expect(marker.existsSync(), isTrue);
        expect(marker.readAsStringSync(), contains('orb/testorb1'));
      },
    );

    test('a successful push after a failure clears the marker', () async {
      final r = await h.run(firstStart: true);
      expect(r.exitCode, 0);
      final marker = File('${h.state.path}/push-failed');
      await runHook(h, pushExit: '1');
      expect(marker.existsSync(), isTrue);

      expect(await runHook(h, pushExit: '0'), 0);
      expect(marker.existsSync(), isFalse);
    });
  });
}
