import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/session_store.dart';
import 'package:opencodebridge/model/session.dart';

/// A scripted [OpencodeService] for the backend tests.
class FakeOpencodeService implements OpencodeService {
  FakeOpencodeService({
    this.sessions = const [],
    this.names = const {},
    this.active = const {},
    this.allProjects = const [],
    this.createdSession,
  });

  final List<OpencodeSession> sessions;
  final Map<String, String> names;
  final Set<String> active;
  final List<OpencodeProject> allProjects;

  /// The session [createSession] returns (the fake does not consult [names]).
  final OpencodeSession? createdSession;

  final List<String> deleted = [];

  final List<String> created = [];

  @override
  Future<List<OpencodeSession>> listSessions() async => sessions;

  @override
  Future<Map<String, String>> projectNames() async => names;

  @override
  Future<Set<String>> activeSessionIds() async => active;

  @override
  Future<List<OpencodeProject>> projects() async => allProjects;

  @override
  Future<OpencodeSession> createSession(String projectId) async {
    created.add(projectId);
    final session = createdSession;
    if (session == null) {
      throw const OpencodeServiceError(500, 'no created session scripted');
    }
    return session;
  }

  @override
  Future<void> deleteSession(String id) async {
    deleted.add(id);
  }
}

const s1 = OpencodeSession(
  id: 'ses_1',
  title: 'one',
  projectId: 'p1',
  created: 100,
  location: '/one',
);
const s2 = OpencodeSession(
  id: 'ses_2',
  title: 'two',
  projectId: 'p1',
  created: 300,
  location: '/two',
);
const s3 = OpencodeSession(
  id: 'ses_3',
  title: 'three',
  projectId: 'p2',
  created: 200,
  location: '/three',
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-backend');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  group('SessionsBackend.list', () {
    test('merges classification, active, project name; newest first', () async {
      final store = await SessionStore.load(dir: dir);
      // ses_2 is persisted but not live -> app-launched-closed.
      store.add('ses_2');
      await store.save();

      final service = FakeOpencodeService(
        sessions: [s1, s2, s3],
        names: {'p1': 'proj-one', 'p2': 'proj-two'},
        active: {'ses_3'},
      );
      final backend = SessionsBackend(service: service, store: store);

      final rows = await backend.list();

      // Newest first regardless of service order (created desc).
      expect(rows.map((r) => r.id).toList(), ['ses_2', 'ses_3', 'ses_1']);

      expect(
        rows[0],
        const Session(
          id: 'ses_2',
          title: 'two',
          project: SessionProject(id: 'p1', name: 'proj-one'),
          created: 300,
          location: '/two',
          active: false,
          classification: SessionClassification.appLaunchedClosed,
        ),
      );
      expect(rows[1].active, isTrue);
      expect(rows[1].classification, SessionClassification.external);
      expect(rows[2].classification, SessionClassification.external);
    });

    test(
      'persisted + live -> app-launched-live; unknown project id falls back',
      () async {
        final store = await SessionStore.load(dir: dir);
        store.add('ses_1');
        await store.save();

        final service = FakeOpencodeService(
          sessions: [s1],
          names: const {}, // no name for p1 -> falls back to the id
          active: const {},
        );
        final backend = SessionsBackend(
          service: service,
          store: store,
          liveSessionIds: const {'ses_1'},
        );

        final row = (await backend.list()).single;
        expect(row.classification, SessionClassification.appLaunchedLive);
        expect(row.project, const SessionProject(id: 'p1', name: 'p1'));
      },
    );
  });

  group('SessionsBackend.delete', () {
    test(
      'deletes on the service and removes the record in one action',
      () async {
        final store = await SessionStore.load(dir: dir);
        store.add('ses_1');
        await store.save();

        final service = FakeOpencodeService(sessions: [s1]);
        final backend = SessionsBackend(service: service, store: store);

        await backend.delete('ses_1');

        expect(service.deleted, ['ses_1']);
        expect(store.has('ses_1'), isFalse);
        // Persisted the removal.
        expect((await SessionStore.load(dir: dir)).has('ses_1'), isFalse);
      },
    );

    test(
      'delete of an external session still deletes on the service',
      () async {
        final store = await SessionStore.load(dir: dir);
        final service = FakeOpencodeService(sessions: [s3]);
        final backend = SessionsBackend(service: service, store: store);

        await backend.delete('ses_3');

        expect(service.deleted, ['ses_3']);
        expect(store.ids(), isEmpty);
      },
    );
  });

  group('SessionsBackend.reconcile', () {
    test('drops store records no longer on the service', () async {
      final store = await SessionStore.load(dir: dir);
      store.add('ses_1');
      store.add('ses_gone');
      await store.save();

      final service = FakeOpencodeService(sessions: [s1]);
      final backend = SessionsBackend(service: service, store: store);

      await backend.reconcile();

      expect((await SessionStore.load(dir: dir)).ids(), {'ses_1'});
    });
  });

  group('SessionsBackend.create', () {
    test('creates on the service, persists the id at launch, and classifies '
        'the row app-launched-closed until the window opens', () async {
      final created = const OpencodeSession(
        id: 'ses_new',
        title: 'new',
        projectId: 'p1',
        created: 400,
        location: '/new',
      );
      final store = await SessionStore.load(dir: dir);
      final service = FakeOpencodeService(
        sessions: [created],
        names: {'p1': 'proj-one'},
        createdSession: created,
      );
      final backend = SessionsBackend(service: service, store: store);

      final row = await backend.create('p1');

      expect(service.created, ['p1']);
      expect(store.has('ses_new'), isTrue);
      // The persistence "add id" write was saved, not just in memory.
      expect((await SessionStore.load(dir: dir)).has('ses_new'), isTrue);
      expect(
        row,
        const Session(
          id: 'ses_new',
          title: 'new',
          project: SessionProject(id: 'p1', name: 'proj-one'),
          created: 400,
          location: '/new',
          active: false,
          classification: SessionClassification.appLaunchedClosed,
        ),
      );
    });

    test('a live window flips the returned row to app-launched-live', () async {
      final created = const OpencodeSession(
        id: 'ses_new',
        title: 'new',
        projectId: 'p1',
        created: 400,
        location: '/new',
      );
      final store = await SessionStore.load(dir: dir);
      final service = FakeOpencodeService(
        sessions: [created],
        names: const {},
        createdSession: created,
      );
      final backend = SessionsBackend(
        service: service,
        store: store,
        liveSessionIds: <String>{},
      );
      backend.liveSessionIds.add('ses_new');

      final row = await backend.create('p1');

      expect(row.classification, SessionClassification.appLaunchedLive);
    });
  });

  group('SessionsBackend.projects', () {
    test('passes the service project list through', () async {
      const projects = [
        OpencodeProject(id: 'p1', name: 'proj-one', canonical: '/one'),
        OpencodeProject(id: 'p2', name: 'proj-two', canonical: '/two'),
      ];
      final store = await SessionStore.load(dir: dir);
      final service = FakeOpencodeService(allProjects: projects);
      final backend = SessionsBackend(service: service, store: store);

      expect(await backend.projects(), projects);
    });
  });

  group('SessionsBackend.isAppLaunched', () {
    test('reflects the persistence records', () async {
      final store = await SessionStore.load(dir: dir);
      store.add('ses_1');
      await store.save();
      final service = FakeOpencodeService(sessions: [s1]);
      final backend = SessionsBackend(service: service, store: store);

      expect(backend.isAppLaunched('ses_1'), isTrue);
      expect(backend.isAppLaunched('ses_3'), isFalse);
    });
  });

  group('SessionsBackend.exists', () {
    test('true while the service has the session, false once gone', () async {
      final store = await SessionStore.load(dir: dir);
      final service = FakeOpencodeService(sessions: [s1]);
      final backend = SessionsBackend(service: service, store: store);

      expect(await backend.exists('ses_1'), isTrue);
      expect(await backend.exists('ses_gone'), isFalse);
    });
  });
}
