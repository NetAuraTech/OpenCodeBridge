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

  /// A component over the backend with the main checkout injected (so the
  /// component does not need a real project list). [armed] sets the arming
  /// toggle as the Settings tab would persist it.
  AfkComponent mkComponent({bool armed = false, String model = ''}) {
    final component = AfkComponent(
      backend: backend,
      store: AfkStore(file: storeFile),
      directoryOf: (_) async => '/main-checkout',
    );
    component.updateSettings(
      AfkSettings(enabled: armed, parallelOrbs: 5, model: model),
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
    test('arming creates exactly one session and stores its id', () async {
      final component = mkComponent(armed: true);
      expect(component.sessionId, isNull);
      final id = await component.ensureSession();
      expect(id, 'ses_afk_1');
      expect(component.sessionId, 'ses_afk_1');
      expect(service.createdCount, 1);
      // The id is persisted in the store (the bridge's own fact).
      expect(AfkStore(file: storeFile).sessionId(), 'ses_afk_1');
    });

    test('a re-arm reuses the existing session (no duplicate) — the session '
        'outlives a disarm', () async {
      final component = mkComponent(armed: true);
      final first = await component.ensureSession();
      expect(first, 'ses_afk_1');

      // The session is still there (a disarm leaves it alone). A second
      // arm reuses it instead of creating a duplicate.
      final second = await component.ensureSession();
      expect(second, first);
      expect(service.createdCount, 1);
    });

    test(
      'a restarted bridge (fresh component) reuses the persisted session',
      () async {
        final component = mkComponent(armed: true);
        await component.ensureSession(); // Persists ses_afk_1 in the store.

        // A fresh component over the same store (a bridge restart) is seeded
        // with the persisted id and reuses it — no second create.
        final restarted = mkComponent(armed: true);
        final id = await restarted.ensureSession();
        expect(id, 'ses_afk_1');
        expect(service.createdCount, 1);
      },
    );

    test(
      'a changed model is effective from the next session creation',
      () async {
        final component = mkComponent(armed: true);
        await component.ensureSession(); // No model (empty default).
        expect(service.createModel, isNull);

        // The session was lost (a restart that dropped it): the next creation
        // uses the newly-pinned model.
        service.present.clear();
        component.updateSettings(
          const AfkSettings(enabled: true, parallelOrbs: 5, model: 'a/b#v'),
        );
        await component.ensureSession();
        expect(
          service.createModel,
          const ModelRef(providerId: 'a', id: 'b', variant: 'v'),
        );
      },
    );

    test('the live cap is exposed for the spawn boundary to read', () {
      final component = mkComponent(armed: true);
      component.updateSettings(
        const AfkSettings(enabled: true, parallelOrbs: 7, model: ''),
      );
      expect(component.settings.parallelOrbs, 7);
      expect(component.enabled, isTrue);
    });

    test(
      'no backend: no AFK session can be created (degrades to null)',
      () async {
        final component = AfkComponent(
          backend: null,
          store: AfkStore(file: storeFile),
          directoryOf: (_) async => '/main-checkout',
        );
        expect(await component.ensureSession(), isNull);
        expect(component.sessionId, isNull);
      },
    );

    test(
      'the default directoryOf resolves the first project canonical dir',
      () async {
        service.projectList = [
          const OpencodeProject(
            id: 'p1',
            name: 'proj',
            canonical: '/repo/main',
          ),
        ];
        final component = AfkComponent(
          backend: backend,
          store: AfkStore(file: storeFile),
        );
        await component.ensureSession();
        expect(service.createDirectory, '/repo/main');
      },
    );
  });
}
