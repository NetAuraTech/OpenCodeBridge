// The live orb upstreams (issue #274, spec §7.1/§7.2/§7.3): the per-orb
// service descriptor and its reachability gate — the single predicate
// across the state × url × password matrix, the live set with credentials,
// the per-orb verdict (reachable / unroutable / gone / unknown), and the
// degradation (docker down → host-only, inconclusive, no throw escapes) —
// each driven against the full case set.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_build_context.dart';
import 'package:opencodebridge/bridge/orb/orb_image_builder.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/orb/orb_upstreams.dart';
import 'package:opencodebridge/model/orb.dart';

const _url = 'http://127.0.0.1:49153';
const _pw = 'pwa';

/// The full gate matrix (spec §7.1): the state set crossed with the url and
/// password facts — one row per case, the in-gate row and every out-gate
/// row named.
const _matrix = <(String, String?, String?, bool)>[
  // The in-gate row: running, a non-empty url, a password line in the log.
  ('running', _url, _pw, true),
  // Running, but the boot's password line has not landed yet.
  ('running', _url, null, false),
  ('running', _url, '', false),
  // Running, but no ephemeral url on the record (the port mapping is not
  // there yet).
  ('running', null, _pw, false),
  ('running', '', _pw, false),
  // Not running — the state alone refuses, whatever else the record
  // carries (spec §2.2's full composed state set).
  ('stopped', _url, _pw, false),
  ('preparing', _url, _pw, false),
  ('preparing:clone', _url, _pw, false),
  ('cleanup_pending:uncommitted work', _url, _pw, false),
  ('broken:workspace', _url, _pw, false),
  ('broken:state', _url, _pw, false),
  ('broken:shell', _url, _pw, false),
  ('orphan', _url, _pw, false),
  ('something:else', _url, _pw, false),
  ('', _url, _pw, false),
];

OrbRecord record(String id, String state, {String? url}) => OrbRecord(
  id: id,
  name: id,
  project: 'proj',
  branch: 'orb/$id',
  state: state,
  created: '2026-01-01T00:00:00.000Z',
  url: url,
);

/// A bare [OrbService] the concrete implementation can hold onto; the
/// fake-seam groups inject both seams, so this instance is never driven.
OrbService bareService(Directory tmp) => OrbService(
  imageBuilder: OrbImageBuilder(
    context: OrbBuildContext(dir: tmp),
    run: _neverRun,
    spawn: _neverSpawn,
  ),
  run: _neverRun,
  spawn: _neverSpawn,
  git: (argv, {workingDirectory}) async =>
      const GitCliResult(exitCode: 0, stdout: '', stderr: ''),
  home: tmp.path,
  stateRoot: tmp,
  bridgePort: 1,
);

/// The concrete implementation's seams over a scripted list + passwords
/// (the module is tested without docker, the way the marker store is):
/// [listError] plays docker down.
LiveOrbUpstreams fakeSource({
  List<OrbRecord> records = const [],
  Map<String, String?> passwords = const {},
  Object? listError,
  required Directory tmp,
}) => LiveOrbUpstreams(
  orbService: bareService(tmp),
  orbList: () =>
      listError == null ? Future.value(records) : Future.error(listError),
  orbPassword: (id) => Future.value(passwords[id]),
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ocb-orb-upstreams-test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the single gate — OrbUpstream.reachable across state × url × '
      'password', () {
    test('the full matrix: one in-gate row, every other row out', () {
      for (final (state, url, password, inGate) in _matrix) {
        final upstream = OrbUpstream.reachable(
          id: 'a',
          state: state,
          url: url,
          password: password,
        );
        if (inGate) {
          expect(upstream, isA<OrbUpstream>(), reason: '$state/$url/$password');
        } else {
          expect(upstream, isNull, reason: '$state/$url/$password');
        }
      }
    });

    test('a gate-passing record yields the descriptor with its fields', () {
      final upstream = OrbUpstream.reachable(
        id: 'a',
        state: 'running',
        url: _url,
        password: _pw,
      );
      expect(upstream, isNotNull);
      expect(upstream!.id, 'a');
      expect(upstream.url, _url);
      expect(upstream.password, _pw);
    });

    test('the key is the composites reconciliation key (url|password)', () {
      final upstream = OrbUpstream.reachable(
        id: 'a',
        state: 'running',
        url: _url,
        password: _pw,
      )!;
      // Exactly the string the sessions and events composites reconcile on
      // today (spec §7.2/§7.3) — the contract phases read it off the value,
      // not off their own derivation.
      expect(upstream.key, '$_url|$_pw');
    });

    test('equality is id + url + password: a respawn changes the value', () {
      final a = OrbUpstream.reachable(
        id: 'a',
        state: 'running',
        url: _url,
        password: _pw,
      )!;
      expect(
        a,
        OrbUpstream.reachable(
          id: 'a',
          state: 'running',
          url: _url,
          password: _pw,
        ),
      );
      // A respawn mints a new port and a new password (spec §7.1): a new
      // key, a new value — that is what replaces a stale upstream client.
      expect(
        OrbUpstream.reachable(
          id: 'a',
          state: 'running',
          url: 'http://127.0.0.1:49154',
          password: _pw,
        ),
        isNot(equals(a)),
      );
      expect(
        OrbUpstream.reachable(
          id: 'a',
          state: 'running',
          url: _url,
          password: 'pwb',
        ),
        isNot(equals(a)),
      );
    });
  });

  group('live() — the live upstream set with credentials', () {
    test(
      'exactly the gate-passing orbs, in list order, with their keys',
      () async {
        final source = fakeSource(
          tmp: tmp,
          records: [
            record('a', 'running', url: _url), // In: url + password.
            record('b', 'running', url: _url), // Out: still booting (no line).
            record('c', 'stopped'), // Out: not running (no url either).
            record('d', 'running'), // Out: no url.
            record('e', 'orphan'), // Out: no container.
          ],
          passwords: {'a': _pw, 'd': 'pwe'},
        );
        final live = await source.live();
        expect([for (final u in live) u.id], equals(const ['a']));
        // The descriptor carries its credentials and its reconciliation key;
        // the out-gate rows carry no value at all — there is no "upstream
        // without a password" form.
        expect(live.single.url, _url);
        expect(live.single.password, _pw);
        expect(live.single.key, '$_url|$_pw');
      },
    );

    test('two gate-passing orbs keep the list order', () async {
      final source = fakeSource(
        tmp: tmp,
        records: [
          record('a', 'running', url: _url),
          record('f', 'running', url: 'http://127.0.0.1:49160'),
          record('c', 'stopped'),
        ],
        passwords: {'a': _pw, 'f': 'pwf'},
      );
      final live = await source.live();
      expect(
        [for (final u in live) (u.id, u.key)],
        equals(const [
          ('a', '$_url|$_pw'),
          ('f', 'http://127.0.0.1:49160|pwf'),
        ]),
      );
    });

    test('an empty list is an empty set', () async {
      final source = fakeSource(tmp: tmp);
      expect(await source.live(), isEmpty);
    });
  });

  group('verdict() — the per-orb conclusiveness fact, the same gate', () {
    List<OrbRecord> records() => [
      record('a', 'running', url: _url), // Reachable.
      record('b', 'running', url: _url), // Unroutable: still booting.
      record('c', 'stopped'), // Unroutable: stopped.
      record('d', 'running'), // Unroutable: no url.
      record('g', 'preparing:clone', url: _url), // Unroutable: booting.
    ];

    test('reachable: a gate-passing orb in a readable list', () async {
      final source = fakeSource(
        tmp: tmp,
        records: records(),
        passwords: {'a': _pw},
      );
      expect(await source.verdict('a'), UpstreamVerdict.reachable);
    });

    test('unroutable: in the readable list, but no upstream — booting, '
        'stopped, or url-less', () async {
      final source = fakeSource(
        tmp: tmp,
        records: records(),
        passwords: {'a': _pw, 'd': 'pwe'},
      );
      // The booting orb's password is still absent (the 404 is the host
      // fallback, not "gone").
      expect(await source.verdict('b'), UpstreamVerdict.unroutable);
      expect(await source.verdict('c'), UpstreamVerdict.unroutable);
      // A password without a url is still no upstream.
      expect(await source.verdict('d'), UpstreamVerdict.unroutable);
      // The preparing state refuses on the state alone.
      expect(await source.verdict('g'), UpstreamVerdict.unroutable);
    });

    test('gone: absent from a readable list — its sessions are lost with '
        'it', () async {
      final source = fakeSource(
        tmp: tmp,
        records: records(),
        passwords: {'a': _pw},
      );
      expect(await source.verdict('deleted'), UpstreamVerdict.gone);
    });

    test('the per-orb fact and the set agree on every row: the set is '
        'exactly the reachable verdicts', () async {
      final source = fakeSource(
        tmp: tmp,
        records: records(),
        passwords: {'a': _pw, 'd': 'pwe'},
      );
      final live = await source.live();
      final reachableIds = {for (final u in live) u.id};
      for (final r in records()) {
        final expected = reachableIds.contains(r.id)
            ? UpstreamVerdict.reachable
            : UpstreamVerdict.unroutable;
        expect(await source.verdict(r.id), expected, reason: r.id);
      }
    });
  });

  group('records() — the raw running-orb list, un-gated', () {
    test('the readable list, exactly as given (gated or not)', () async {
      final source = fakeSource(
        tmp: tmp,
        records: [
          record('a', 'running', url: _url), // Reachable.
          record('b', 'running', url: _url), // Unroutable: still booting.
          record('c', 'stopped'), // Unroutable: stopped.
        ],
        passwords: {'a': _pw},
      );
      final records = await source.records();
      expect(
        [for (final r in records!) r.id],
        equals(const ['a', 'b', 'c']),
      );
      // The raw records are the list's own values (labels; `url` only for a
      // running orb) — the module adds nothing and filters nothing: the
      // boot-retry check reads the list itself, not the gate's answer.
      expect(records.first.url, _url);
      expect(records.last.url, isNull);
    });

    test('an unreadable list is null (docker down) — a value, not a throw',
        () async {
      final source = fakeSource(
        tmp: tmp,
        records: [record('a', 'running', url: _url)],
        passwords: {'a': _pw},
        listError: const DockerUnavailableError('docker is down'),
      );
      expect(await source.records(), isNull);
    });
  });

  group('degradation — docker down (the list cannot be read)', () {
    test('live() is empty (host-only) — no throw escapes', () async {
      final source = fakeSource(
        tmp: tmp,
        records: [record('a', 'running', url: _url)],
        passwords: {'a': _pw},
        listError: const DockerUnavailableError('docker is down'),
      );
      expect(await source.live(), isEmpty);
    });

    test('every verdict is unknown — a degraded read never claims an '
        'upstream exists nor a session is gone', () async {
      final source = fakeSource(
        tmp: tmp,
        records: [record('a', 'running', url: _url)],
        passwords: {'a': _pw},
        listError: const DockerUnavailableError('docker is down'),
      );
      // The would-be-reachable orb: no upstream claim…
      expect(await source.verdict('a'), UpstreamVerdict.unknown);
      // …and no "gone" claim either (the task service must not settle a
      // mid-flight task failed on a degraded read — issue #211/#276).
      expect(await source.verdict('deleted'), UpstreamVerdict.unknown);
    });
  });

  group('LiveOrbUpstreams — the concrete host implementation (a real '
      'OrbService over a fake docker CLI)', () {
    const labelsA =
        '{"ocb.id":"a","ocb.name":"A","ocb.project":"proj",'
        '"ocb.branch":"orb/a","ocb.created":"2026-01-01T00:00:00.000Z"}';
    const labelsB =
        '{"ocb.id":"b","ocb.name":"B","ocb.project":"proj",'
        '"ocb.branch":"orb/b","ocb.created":"2026-01-01T00:00:00.000Z"}';
    const portsA = '{"4096/tcp":[{"HostIp":"0.0.0.0","HostPort":"49153"}]}';

    DockerRunner docker({required bool up}) =>
        (argv, {workingDirectory}) async {
          if (!up) {
            return const DockerCliResult(
              exitCode: 1,
              stdout: '',
              stderr: 'docker is down',
            );
          }
          DockerCliResult out(String stdout) =>
              DockerCliResult(exitCode: 0, stdout: stdout, stderr: '');
          if (argv[0] == 'ps') return out('orb-a\norb-b\n');
          if (argv[0] == 'inspect') {
            if (argv.contains('{{json .Config.Labels}}')) {
              return out('$labelsA\n$labelsB');
            }
            if (argv.contains('{{.State.Status}}')) {
              return out('running\nexited\n');
            }
            if (argv.contains('{{json .NetworkSettings.Ports}}')) {
              return out('$portsA\n{}');
            }
          }
          if (argv[0] == 'volume' && argv[1] == 'ls') {
            return out('orb-b-workspace\n');
          }
          if (argv[0] == 'volume' && argv[1] == 'inspect') {
            return out('{"ocb.id":"b"}\n');
          }
          if (argv[0] == 'logs') {
            switch (argv[1]) {
              case 'orb-a':
                return out('boot line\nserver password pwa\nmore\n');
              case 'orb-b':
                return out('boot line\nserver password pwb\n');
              default:
                return const DockerCliResult(
                  exitCode: 1,
                  stdout: '',
                  stderr: 'no such container',
                );
            }
          }
          throw StateError('unexpected docker argv: $argv');
        };

    OrbService service({required bool up}) => OrbService(
      imageBuilder: OrbImageBuilder(
        context: OrbBuildContext(dir: tmp),
        run: docker(up: up),
        spawn: _neverSpawn,
      ),
      run: docker(up: up),
      spawn: _neverSpawn,
      git: (argv, {workingDirectory}) async =>
          const GitCliResult(exitCode: 0, stdout: '', stderr: ''),
      home: tmp.path,
      stateRoot: tmp,
      bridgePort: 1,
    );

    test('the default seams read the orb service: the url is the record '
        'port mapping, the password the last log line', () async {
      // The stopped orb's state dir (its broken checks read the host).
      Directory('${tmp.path}/b').createSync(recursive: true);
      final source = LiveOrbUpstreams(orbService: service(up: true));
      final live = await source.live();
      expect(live, hasLength(1));
      expect(live.single.id, 'a');
      // The url is the list's port-mapping derivation read off the record
      // (spec §2.9/§7.1) — not re-derived here.
      expect(live.single.url, 'http://127.0.0.1:49153');
      // The password is the container log's last `server password` line
      // (spec §7.1), through the orb service's own parser.
      expect(live.single.password, 'pwa');
      expect(live.single.key, 'http://127.0.0.1:49153|pwa');
      // The stopped orb: no upstream, even though its log carries a
      // password — the state alone refuses.
      expect(await source.verdict('a'), UpstreamVerdict.reachable);
      expect(await source.verdict('b'), UpstreamVerdict.unroutable);
      expect(await source.verdict('deleted'), UpstreamVerdict.gone);
    });

    test('docker down through the real list: host-only and inconclusive, '
        'no throw escapes', () async {
      final source = LiveOrbUpstreams(orbService: service(up: false));
      expect(await source.live(), isEmpty);
      expect(await source.verdict('a'), UpstreamVerdict.unknown);
      expect(await source.verdict('deleted'), UpstreamVerdict.unknown);
    });

    test('no orb service at all: the host-only degradation (the bridge '
        'wires the module on a machine without orbs)', () async {
      final source = LiveOrbUpstreams();
      expect(await source.records(), isEmpty);
      expect(await source.live(), isEmpty);
      expect(await source.verdict('a'), UpstreamVerdict.gone);
    });
  });
}

/// A docker runner that must never run: any drive of the real path is a
/// test bug (the seams stand in for the orb service).
Future<DockerCliResult> _neverRun(
  List<String> argv, {
  String? workingDirectory,
}) => throw StateError('the seams stand in for the orb service');

/// A docker spawner that must never run (the boot stream is never started).
Future<DockerProcess> _neverSpawn(
  List<String> argv, {
  String? workingDirectory,
}) => throw StateError('the seams stand in for the orb service');
