import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_component.dart';
import 'package:opencodebridge/bridge/afk/afk_session_manager.dart';
import 'package:opencodebridge/bridge/afk/afk_settings.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/order_store.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/model/command.dart';

/// A scripted [OpencodeService] for the AFK tests: it records create
/// arguments and answers create/probe/projects from scripted state. The rest
/// is never called (the AFK code paths use only create, probe, and projects).
class _FakeService extends OpencodeService {
  int createdCount = 0;
  String? createDirectory;
  ModelRef? createModel;
  String? createAgent;

  /// The project list (the main-checkout resolution reads it).
  List<OpencodeProject> projectList = const [];

  /// The ids the service has (probe answers present for these).
  final Set<String> present = {};

  @override
  Future<List<OpencodeProject>> projects() async => projectList;

  @override
  Future<OpencodeSession> createSessionInDirectory(
    String directory, {
    ModelRef? model,
    String? agent,
  }) async {
    createdCount++;
    createDirectory = directory;
    createModel = model;
    createAgent = agent;
    final id = 'ses_afk_$createdCount';
    present.add(id);
    return OpencodeSession(
      id: id,
      title: 'AFK',
      projectId: 'proj',
      created: createdCount,
      location: directory,
    );
  }

  @override
  Future<OpencodeSession> probe(String id) async {
    if (!present.contains(id)) {
      throw const OpencodeServiceError(404, 'no such session');
    }
    return OpencodeSession(
      id: id,
      title: 'AFK',
      projectId: 'proj',
      created: 0,
      location: '/main',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An in-memory [SessionOrderStore] (the backend needs one; the AFK code
/// paths never touch it).
class _InMemoryOrderStore implements SessionOrderStore {
  final Map<String, num> _map = {};

  @override
  File get file => throw UnimplementedError('in-memory');

  @override
  Map<String, num> load() => Map.of(_map);

  @override
  Future<void> set(String id, num position) async {
    _map[id] = position;
  }

  @override
  Future<void> clear(String id) async {
    _map.remove(id);
  }
}

void main() {
  late Directory dir;
  late File storeFile;
  late _FakeService service;
  late SessionsBackend backend;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-afk-component');
    storeFile = File('${dir.path}/afk.json');
    service = _FakeService();
    backend = SessionsBackend(
      service: service,
      orderStore: _InMemoryOrderStore(),
    );
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  /// A component over the backend with the repo's checkout directory injected
  /// (so the component does not need a real project list). [repos] is the set
  /// of armed repo identities; the injected directory answers the given
  /// [directory] for every repo. `repos` empty (or `null`) disarms.
  AfkComponent mkComponent({
    Set<String>? repos,
    String model = '',
    String directory = '/main-checkout',
  }) {
    final component = AfkComponent(
      backend: backend,
      store: AfkStore(file: storeFile),
      directoryOf: (_, _) async => directory,
    );
    component.updateSettings(
      AfkSettings(armedRepos: repos ?? const {}, parallelOrbs: 5, model: model),
    );
    return component;
  }

  group('AfkSessionManager', () {
    test('creates the session in the directory with agent afk', () async {
      final manager = AfkSessionManager(
        sessions: service,
        directory: () async => '/main-checkout',
      );
      final id = await manager.ensureSession();
      expect(service.createdCount, 1);
      expect(service.createDirectory, '/main-checkout');
      expect(service.createAgent, 'afk');
      expect(id, 'ses_afk_1');
      expect(manager.sessionId, 'ses_afk_1');
    });

    test('an empty model is created with no model pin (inherit)', () async {
      final manager = AfkSessionManager(
        sessions: service,
        directory: () async => '/main-checkout',
      );
      await manager.ensureSession(model: '');
      expect(service.createModel, isNull);
    });

    test('a pinned model is created with the model ref', () async {
      final manager = AfkSessionManager(
        sessions: service,
        directory: () async => '/main-checkout',
      );
      await manager.ensureSession(model: 'zhipu/glm-4.7');
      expect(
        service.createModel,
        const ModelRef(providerId: 'zhipu', id: 'glm-4.7'),
      );
    });

    test(
      'a second ensure reuses the existing session (no duplicate)',
      () async {
        final manager = AfkSessionManager(
          sessions: service,
          directory: () async => '/main-checkout',
        );
        final first = await manager.ensureSession();
        final second = await manager.ensureSession();
        expect(second, first);
        expect(service.createdCount, 1);
      },
    );

    test(
      'a stored id the service lost is re-created (fresh agent handoff)',
      () async {
        final manager = AfkSessionManager(
          sessions: service,
          directory: () async => '/main-checkout',
          initialSessionId: 'ses_gone',
        );
        final id = await manager.ensureSession();
        expect(id, 'ses_afk_1');
        expect(service.createdCount, 1);
      },
    );
  });

  group('AfkComponent', () {
    test(
      'arming a repo creates exactly one session and stores its id',
      () async {
        final component = mkComponent(repos: {'o/r'});
        expect(component.sessionIdFor('o/r'), isNull);
        final id = await component.ensureSession('o/r');
        expect(id, 'ses_afk_1');
        expect(component.sessionIdFor('o/r'), 'ses_afk_1');
        expect(service.createdCount, 1);
        // The id is persisted in the store (the bridge's own fact), under the
        // repo.
        expect(AfkStore(file: storeFile).sessionIdFor('o/r'), 'ses_afk_1');
      },
    );

    test('arming a second repo creates a second, independent session (two '
        'independent sessions, spec #407)', () async {
      final component = mkComponent(repos: {'o/a', 'o/b'});
      final a = await component.ensureSession('o/a');
      final b = await component.ensureSession('o/b');
      expect(a, 'ses_afk_1');
      expect(b, 'ses_afk_2');
      expect(service.createdCount, 2);
      // Two independent stored ids, one per repo.
      expect(AfkStore(file: storeFile).sessionIdFor('o/a'), 'ses_afk_1');
      expect(AfkStore(file: storeFile).sessionIdFor('o/b'), 'ses_afk_2');
    });

    test('a re-arm reuses the existing session (no duplicate) — the session '
        'outlives a disarm', () async {
      final component = mkComponent(repos: {'o/r'});
      final first = await component.ensureSession('o/r');
      expect(first, 'ses_afk_1');

      // A disarm (the repo leaves armedRepos) holds everything: the session
      // and its stored id stay. A re-arm reuses the live session through the
      // stored id — no duplicate.
      component.updateSettings(const AfkSettings(armedRepos: {}));
      expect(component.isArmed('o/r'), isFalse);
      expect(
        component.sessionIdFor('o/r'),
        'ses_afk_1',
        reason: 'the stored id outlives the disarm',
      );
      component.updateSettings(const AfkSettings(armedRepos: {'o/r'}));
      final second = await component.ensureSession('o/r');
      expect(second, first);
      expect(service.createdCount, 1);
    });

    test(
      'a restarted bridge (fresh component) reuses the persisted session',
      () async {
        final component = mkComponent(repos: {'o/r'});
        await component.ensureSession(
          'o/r',
        ); // Persists ses_afk_1 in the store.

        // A fresh component over the same store (a bridge restart) is seeded
        // with the persisted id and reuses it — no second create.
        final restarted = mkComponent(repos: {'o/r'});
        final id = await restarted.ensureSession('o/r');
        expect(id, 'ses_afk_1');
        expect(service.createdCount, 1);
      },
    );

    test(
      'a changed model is effective from the next session creation',
      () async {
        final component = mkComponent(repos: {'o/r'});
        await component.ensureSession('o/r'); // No model (empty default).
        expect(service.createModel, isNull);

        // The session was lost (a restart that dropped it): the next creation
        // uses the newly-pinned model.
        service.present.clear();
        component.updateSettings(
          const AfkSettings(
            armedRepos: {'o/r'},
            parallelOrbs: 5,
            model: 'a/b#v',
          ),
        );
        await component.ensureSession('o/r');
        expect(
          service.createModel,
          const ModelRef(providerId: 'a', id: 'b', variant: 'v'),
        );
      },
    );

    test('the live cap is exposed for the spawn boundary to read; isArmed is '
        'per repo (reads armedRepos live)', () {
      final component = mkComponent(repos: {'o/r'});
      component.updateSettings(
        const AfkSettings(armedRepos: {'o/r'}, parallelOrbs: 7, model: ''),
      );
      expect(component.settings.parallelOrbs, 7);
      expect(component.isArmed('o/r'), isTrue);
      expect(component.isArmed('o/other'), isFalse);
      // A disarm of the repo is picked up live (no restart).
      component.updateSettings(const AfkSettings(armedRepos: {}));
      expect(component.isArmed('o/r'), isFalse);
    });

    test(
      'spawnGate is null with no armed repo (no AFK session, cap disengaged)',
      () {
        final component = mkComponent(repos: {});
        expect(component.spawnGate(), isNull);
      },
    );

    test('spawnGate is null when no repo is armed (the cap never applies)', () {
      final component = mkComponent(repos: {});
      expect(component.spawnGate(), isNull);
    });

    test('spawnGate is null when an armed repo has no stored AFK session', () {
      final component = mkComponent(repos: {'o/r'});
      expect(component.spawnGate(), isNull);
    });

    test('spawnGate carries the set of AFK session ids (the attribution set) '
        'and the live cap, read fresh on every call', () async {
      final component = mkComponent(repos: {'o/r'});
      await component.ensureSession('o/r'); // Persists the AFK session id.

      final gate = component.spawnGate();
      expect(gate, isNotNull);
      expect(gate!.sessionIds, {'ses_afk_1'});
      expect(gate.cap, 5);
      // The attribution fact: a spawn is AFK when its caller session is
      // any armed repo's AFK session.
      expect(gate.isAfk('ses_afk_1'), isTrue);
      expect(gate.isAfk('ses_other'), isFalse);
      expect(gate.isAfk(null), isFalse);

      // A changed cap is effective from the next read (the next spawn): the
      // gate re-reads the live settings, no restart.
      component.updateSettings(
        const AfkSettings(armedRepos: {'o/r'}, parallelOrbs: 2, model: ''),
      );
      expect(component.spawnGate()!.cap, 2);
    });

    test('two armed repos: the gate carries both stored session ids; a repo '
        'without a stored id drops out; disarming everything disengages the '
        'cap (null gate)', () async {
      final component = mkComponent(repos: {'o/r'});
      await component.ensureSession('o/r'); // ses_afk_1 under o/r.
      component.updateSettings(
        const AfkSettings(
          armedRepos: {'o/r', 'o/r2'},
          parallelOrbs: 5,
          model: '',
        ),
      );
      final gate = component.spawnGate();
      expect(gate, isNotNull);
      // o/r2 has no stored session yet (T3 creates it): it drops out of
      // the set, o/r's id stays.
      expect(gate!.sessionIds, {'ses_afk_1'});
      expect(gate.isAfk('ses_afk_1'), isTrue);

      // A second repo with its own stored session: the set carries both —
      // either AFK session's spawns are AFK-attributed.
      await AfkStore(file: storeFile).setSessionId('o/r2', 'ses_afk_r2');
      final both = component.spawnGate()!;
      expect(both.sessionIds, {'ses_afk_1', 'ses_afk_r2'});
      expect(both.isAfk('ses_afk_1'), isTrue);
      expect(both.isAfk('ses_afk_r2'), isTrue);
      expect(both.isAfk('ses_other'), isFalse);

      // Disarming everything holds the stored ids but disengages the cap:
      // no armed repo, no AFK session at the spawn boundary.
      component.updateSettings(const AfkSettings());
      expect(component.spawnGate(), isNull);
    });

    test('disarming one repo while its orb is in flight: its session id '
        'stays in the set (the in-flight fact is the creating task\'s '
        'caller, not the current arming)', () async {
      // Two repos armed, each with its own stored session.
      final component = mkComponent(repos: {'o/r'});
      await component.ensureSession('o/r'); // ses_afk_1 under o/r.
      await AfkStore(file: storeFile).setSessionId('o/r2', 'ses_afk_r2');
      component.updateSettings(
        const AfkSettings(
          armedRepos: {'o/r', 'o/r2'},
          parallelOrbs: 5,
          model: '',
        ),
      );
      expect(component.spawnGate()!.sessionIds, {'ses_afk_1', 'ses_afk_r2'});

      // Disarm o/r while its orb is in flight: the disarm never deletes the
      // stored session id (the session outlives a disarm), so its id stays in
      // the set until the orb settles. Only o/r2 is armed now.
      component.updateSettings(
        const AfkSettings(armedRepos: {'o/r2'}, parallelOrbs: 5, model: ''),
      );
      final gate = component.spawnGate();
      expect(gate, isNotNull);
      expect(gate!.sessionIds, {'ses_afk_1', 'ses_afk_r2'});
      expect(gate.isAfk('ses_afk_1'), isTrue);
      expect(gate.isAfk('ses_afk_r2'), isTrue);
    });

    test(
      'no backend: no AFK session can be created (degrades to null)',
      () async {
        final component = AfkComponent(
          backend: null,
          store: AfkStore(file: storeFile),
          directoryOf: (_, _) async => '/main-checkout',
        );
        // Armed, but with no backend there is no host to create the session on.
        component.updateSettings(const AfkSettings(armedRepos: {'o/r'}));
        expect(await component.ensureSession('o/r'), isNull);
        expect(component.sessionIdFor('o/r'), isNull);
      },
    );

    test('the default directoryOf resolves the first list-order project whose '
        'repo identity equals the armed repo (the session lands in that '
        'checkout, spec #407)', () async {
      // Two checkouts of two repos (real temp git dirs, so repoIdentityOf
      // resolves them), in list order o/a then o/b.
      final checkoutA = await _checkoutWithOrigin(
        dir,
        'https://github.com/o/a',
      );
      final checkoutB = await _checkoutWithOrigin(
        dir,
        'https://github.com/o/b',
      );
      service.projectList = [
        OpencodeProject(id: 'p1', name: 'a', canonical: checkoutA.path),
        OpencodeProject(id: 'p2', name: 'b', canonical: checkoutB.path),
      ];
      final component = AfkComponent(
        backend: backend,
        store: AfkStore(file: storeFile),
      );
      component.updateSettings(const AfkSettings(armedRepos: {'o/b'}));
      // The session lands in o/b's checkout (the second project in list
      // order — the first one does not carry the identity o/b).
      await component.ensureSession('o/b');
      expect(service.createDirectory, checkoutB.path);
    });

    test('two checkouts of the same repo share one session, in the first '
        'list-order checkout (spec #407, AC4)', () async {
      // Two checkouts of the same repo, in list order (both resolve to
      // o/r), plus a different repo's checkout last.
      final firstCheckout = await _checkoutWithOrigin(
        dir,
        'https://github.com/o/r',
      );
      final secondCheckout = await _checkoutWithOrigin(
        dir,
        'git@github.com:o/r.git',
      );
      final otherCheckout = await _checkoutWithOrigin(
        dir,
        'https://github.com/o/other',
      );
      service.projectList = [
        OpencodeProject(id: 'p1', name: 'first', canonical: firstCheckout.path),
        OpencodeProject(
          id: 'p2',
          name: 'second',
          canonical: secondCheckout.path,
        ),
        OpencodeProject(id: 'p3', name: 'other', canonical: otherCheckout.path),
      ];
      final component = AfkComponent(
        backend: backend,
        store: AfkStore(file: storeFile),
      );
      component.updateSettings(const AfkSettings(armedRepos: {'o/r'}));
      // One session for the shared identity, in the first list-order
      // checkout carrying it.
      final id = await component.ensureSession('o/r');
      expect(id, 'ses_afk_1');
      expect(service.createdCount, 1);
      expect(service.createDirectory, firstCheckout.path);
    });
  });
}

/// A temp git checkout tracking [remoteUrl] on its `origin` (so T1's
/// [repoIdentityOf] resolves it): `git init` + `git remote add origin` in a
/// temp dir under [parent]. The dir is cleaned up with [parent].
Future<Directory> _checkoutWithOrigin(
  Directory parent,
  String remoteUrl,
) async {
  final checkout = await Directory(
    '${parent.path}/checkout-${remoteUrl.hashCode.abs()}-${DateTime.now().microsecondsSinceEpoch}',
  ).create(recursive: true);
  Future<void> git(List<String> args) async {
    final result = await Process.run(
      'git',
      ['-C', checkout.path, ...args],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  await git(['init', '-q']);
  await git(['remote', 'add', 'origin', remoteUrl]);
  return checkout;
}
