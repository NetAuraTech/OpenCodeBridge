import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/order_store.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// A scripted [OpencodeService] for the backend tests: only the operations
/// the backend's deep core calls (the row composition, the create
/// composition, the detail fold, and [SessionsBackend.exists]' list
/// composition). The raw operations are the seam's own — their endpoint
/// behavior is covered by the bridge's route tests
/// (test/bridge/bridge_server_test.dart).
class FakeOpencodeService implements OpencodeService {
  FakeOpencodeService({
    this.sessions = const [],
    this.names = const {},
    this.active = const {},
    this.createdSession,
    this.createdInDirectory,
    this.detail,
    this.detailById = const {},
    this.permissions = const [],
    this.permissionsBySession = const {},
    this.questionsBySession = const {},
  });

  final List<OpencodeSession> sessions;
  final Map<String, String> names;
  final Set<String> active;

  /// The session [createSession] returns (the fake does not consult [names]).
  final OpencodeSession? createdSession;

  /// The session [createSessionInDirectory] returns.
  final OpencodeSession? createdInDirectory;

  final SessionDetail? detail;
  final Map<String, SessionDetail> detailById;
  final List<PermissionRequest> permissions;

  /// Per-session pending permission requests (the waiting fact, issue #208):
  /// the sessions absent here answer the shared [permissions]. A value of
  /// `null` makes the lookup for that session throw (the degraded-orb route).
  final Map<String, List<PermissionRequest>?> permissionsBySession;

  /// Per-session pending question forms (the waiting fact, issue #208):
  /// the sessions absent here answer the shared [questions]. A value of
  /// `null` makes the lookup for that session throw (the degraded-orb route).
  final Map<String, List<QuestionForm>?> questionsBySession;

  final List<String> created = [];
  final List<(ModelRef?, String?)> createdWith = [];

  final List<String> createdIn = [];
  final List<(ModelRef?, String?)> createdInWith = [];

  final List<(String, ModelRef)> modelsSet = [];

  @override
  Future<List<OpencodeSession>> listSessions() async => sessions;

  @override
  Future<Map<String, String>> projectNames() async => names;

  @override
  Future<Set<String>> activeSessionIds() async => active;

  @override
  Future<OpencodeSession> createSession(
    String projectId, {
    ModelRef? model,
    String? agent,
  }) async {
    created.add(projectId);
    createdWith.add((model, agent));
    final session = createdSession;
    if (session == null) {
      throw const OpencodeServiceError(500, 'no created session scripted');
    }
    return session;
  }

  @override
  Future<OpencodeSession> createSessionInDirectory(
    String directory, {
    ModelRef? model,
    String? agent,
  }) async {
    createdIn.add(directory);
    createdInWith.add((model, agent));
    final session = createdInDirectory;
    if (session == null) {
      throw const OpencodeServiceError(
        500,
        'no created-in-directory session scripted',
      );
    }
    return session;
  }

  @override
  Future<SessionDetail> getDetail(String id) async {
    final d = detailById[id] ?? detail;
    if (d == null) throw const OpencodeServiceError(404, 'no detail scripted');
    return d;
  }

  @override
  Future<void> setModel(String id, ModelRef model) async {
    modelsSet.add((id, model));
  }

  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async {
    final scripted = permissionsBySession;
    if (scripted.containsKey(id)) {
      final pending = scripted[id];
      if (pending == null) {
        throw const OpencodeServiceError(0, 'pending lookup down');
      }
      return pending;
    }
    return permissions;
  }

  // The structured view's question forms (issue #50): the waiting fact's
  // other pending state.

  final List<QuestionForm> questions = const [];

  @override
  Future<List<QuestionForm>> pendingQuestions(String id) async {
    final scripted = questionsBySession;
    if (scripted.containsKey(id)) {
      final pending = scripted[id];
      if (pending == null) {
        throw const OpencodeServiceError(0, 'pending lookup down');
      }
      return pending;
    }
    return questions;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

// An archived session (issue #234): the seam stays faithful — archived rows
// are still listed, so exists() and _defaultModel() still see them.
const sArchived = OpencodeSession(
  id: 'ses_archived',
  title: 'archived',
  projectId: 'p1',
  created: 400,
  location: '/archived',
  archived: true,
);

void main() {
  group('SessionsBackend.list', () {
    test('merges active and project name; newest first', () async {
      final service = FakeOpencodeService(
        sessions: [s1, s2, s3],
        names: {'p1': 'proj-one', 'p2': 'proj-two'},
        active: {'ses_3'},
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

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
        ),
      );
      expect(rows[1].active, isTrue);
      expect(rows[2].active, isFalse);
    });

    test('the archived fact rides every row (issue #234)', () async {
      final service = FakeOpencodeService(
        sessions: [s1, sArchived],
        names: {'p1': 'proj-one'},
        active: const {},
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final rows = await backend.list();

      // Newest first: the archived row sorts by created like any other.
      expect(rows.map((r) => r.id).toList(), ['ses_archived', 'ses_1']);
      expect(rows.byId('ses_archived').archived, isTrue);
      expect(rows.byId('ses_1').archived, isFalse);
      // The row shape carries the fact the bridge contract way.
      expect(rows.byId('ses_archived').toJson()['archived'], true);
    });

    test('unknown project id falls back', () async {
      final service = FakeOpencodeService(
        sessions: [s1],
        names: const {}, // no name for p1 -> falls back to the id
        active: const {},
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final row = (await backend.list()).single;
      expect(row.project, const SessionProject(id: 'p1', name: 'p1'));
    });

    // The waiting fact (issue #208): re-evaluated per session from the
    // service's pending states — the same endpoints the structured view
    // consumes — not from the active list.

    test('waiting true while the session holds a pending permission', () async {
      const permission = PermissionRequest(
        id: 'req_1',
        action: 'shell',
        resources: ['ls'],
      );
      final service = FakeOpencodeService(
        sessions: [s1, s2],
        permissionsBySession: {
          'ses_1': [permission],
        },
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final rows = await backend.list();

      expect(rows.byId('ses_1').waiting, isTrue);
      expect(rows.byId('ses_2').waiting, isFalse);
    });

    test('waiting true while the session holds a pending question', () async {
      const form = QuestionForm(
        id: 'q_1',
        title: 'Questions',
        questions: [
          Question(
            header: 'Pick',
            question: 'which model?',
            multiple: false,
            options: [QuestionOption(label: 'a')],
            custom: false,
          ),
        ],
      );
      final service = FakeOpencodeService(
        sessions: [s1, s2],
        questionsBySession: {
          'ses_2': [form],
        },
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final rows = await backend.list();

      expect(rows.byId('ses_2').waiting, isTrue);
      expect(rows.byId('ses_1').waiting, isFalse);
    });

    test('waiting false when nothing is pending', () async {
      final service = FakeOpencodeService(sessions: [s1, s2]);
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final rows = await backend.list();

      expect(rows.every((r) => !r.waiting), isTrue);
    });

    test('a degraded pending lookup degrades that session only', () async {
      const permission = PermissionRequest(
        id: 'req_2',
        action: 'shell',
        resources: ['git status'],
      );
      final service = FakeOpencodeService(
        sessions: [s1, s2, s3],
        // ses_2's owning route throws (a degraded orb); the other lookups
        // answer.
        permissionsBySession: {
          'ses_1': [permission],
          'ses_2': null,
          'ses_3': const [],
        },
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final rows = await backend.list();

      // The list itself stays up, in its newest-first order.
      expect(rows.map((r) => r.id).toList(), ['ses_2', 'ses_3', 'ses_1']);
      // The degraded session reads waiting false, the others keep theirs.
      expect(rows.byId('ses_2').waiting, isFalse);
      expect(rows.byId('ses_1').waiting, isTrue);
      expect(rows.byId('ses_3').waiting, isFalse);
    });

    test('evaluates every session, not just the active ones', () async {
      // s3 is not active: the waiting fact must still surface for it (during
      // a block the service may no longer mark the session active).
      const permission = PermissionRequest(
        id: 'req_3',
        action: 'shell',
        resources: ['ls'],
      );
      final service = FakeOpencodeService(
        sessions: [s1, s2, s3],
        active: const {},
        permissionsBySession: {
          'ses_3': [permission],
        },
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final rows = await backend.list();

      expect(rows.byId('ses_3').active, isFalse);
      expect(rows.byId('ses_3').waiting, isTrue);
    });
  });

  // The user-controlled display order (issue #237): the bridge-owned order
  // store keys on the session id, so the home list reads pinned-first —
  // the pinned block position ascending, then the unpinned newest-created.

  group('SessionsBackend.list ordering (issue #237)', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('oc-be-order');
      file = File('${dir.path}/session-order.json');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test(
      'pinned rows come first, position ascending, then newest-created',
      () async {
        final store = SessionOrderStore(file: file);
        await store.set('ses_1', 2);
        await store.set('ses_3', 0);
        final service = FakeOpencodeService(
          sessions: [s1, s2, s3],
          names: {'p1': 'proj-one', 'p2': 'proj-two'},
        );
        final backend = SessionsBackend(service: service, orderStore: store);

        final rows = await backend.list();

        // The pinned block (position ascending): ses_3 (0) then ses_1 (2);
        // then the unpinned newest-created: ses_2 (created 300).
        expect(rows.map((r) => r.id).toList(), ['ses_3', 'ses_1', 'ses_2']);
        expect(rows.byId('ses_3').pinned, isTrue);
        expect(rows.byId('ses_1').pinned, isTrue);
        expect(rows.byId('ses_2').pinned, isFalse);
      },
    );

    test(
      'the position follows a session moved host to orb (id preserved)',
      () async {
        final store = SessionOrderStore(file: file);
        await store.set('ses_1', 0);
        final backend = SessionsBackend(
          service: FakeOpencodeService(
            sessions: [s1, s2, s3],
            names: {'p1': 'proj-one', 'p2': 'proj-two'},
          ),
          orderStore: store,
        );

        var rows = await backend.list();
        expect(rows.first.id, 'ses_1');
        expect(rows.first.pinned, isTrue);
        expect(rows.first.orb, isNull);

        // The session moves onto an orb: the id is preserved (the move's
        // contract), the row's location/orb facts change, and the store —
        // keyed on the id alone — keeps it in its pinned place.
        const moved = OpencodeSession(
          id: 'ses_1',
          title: 'one',
          projectId: 'p1',
          created: 100,
          location: '/one',
          orb: 'orb_7',
        );
        rows = await SessionsBackend(
          service: FakeOpencodeService(
            sessions: [moved, s2, s3],
            names: {'p1': 'proj-one', 'p2': 'proj-two'},
          ),
          orderStore: store,
        ).list();

        expect(rows.first.id, 'ses_1');
        expect(rows.first.pinned, isTrue);
        expect(rows.first.orb, 'orb_7');
      },
    );

    test('the list read keeps the position of a session it does not see '
        '(issue #292: no prune on the read)', () async {
      final store = SessionOrderStore(file: file);
      await store.set('ses_1', 1);
      // The "orphan": a position for a session absent from this read (a
      // degraded pass, a waking orb, the boot window) — not deleted.
      await store.set('ses_gone', 0);
      final backend = SessionsBackend(
        service: FakeOpencodeService(sessions: [s1, s2], names: const {}),
        orderStore: store,
      );

      final rows = await backend.list();

      expect(rows.byId('ses_1').pinned, isTrue);
      // The position the read did not see is kept: the read no longer
      // prunes it (cleanup is on the observed deletion, issue #292).
      final onDisk = jsonDecode(file.readAsStringSync()) as Map;
      expect(onDisk, {'ses_1': 1, 'ses_gone': 0});

      // Once the session is visible again it reappears in the pinned block,
      // position ascending (ses_gone at 0 before ses_1 at 1).
      // A later read that sees the session again: it reappears in the
      // pinned block, position ascending (ses_gone at 0 before ses_1 at 1).
      final rowsVisible = await SessionsBackend(
        service: FakeOpencodeService(
          sessions: [
            s1,
            s2,
            const OpencodeSession(
              id: 'ses_gone',
              title: 'gone',
              projectId: 'p1',
              created: 50,
              location: '/gone',
            ),
          ],
          names: const {},
        ),
        orderStore: store,
      ).list();
      expect(rowsVisible.map((r) => r.id).toList(), [
        'ses_gone',
        'ses_1',
        'ses_2',
      ]);
    });

    test(
      'a store failure degrades to the unpinned order, never the list',
      () async {
        final service = FakeOpencodeService(
          sessions: [s1, s2],
          names: const {},
        );
        final backend = SessionsBackend(
          service: service,
          orderStore: _ThrowingOrderStore(),
        );

        final rows = await backend.list();

        expect(rows.map((r) => r.id).toList(), ['ses_2', 'ses_1']);
        expect(rows.every((r) => !r.pinned), isTrue);
      },
    );

    test('the backend writes through the store it was constructed with '
        '(issue #271: one write path)', () async {
      // The store the backend is constructed with is the one it writes
      // through — the set/clear land on it, and a second backend over a
      // different store sees none of the writes.
      final store = SessionOrderStore(file: file);
      final other = SessionOrderStore(file: File('${dir.path}/other.json'));
      final backend = SessionsBackend(
        service: FakeOpencodeService(sessions: [s1, s2]),
        orderStore: store,
      );

      await backend.setOrder('ses_1', 2);
      expect(store.load(), {'ses_1': 2});
      expect(other.load(), isEmpty);
      final rows = await backend.list();
      expect(rows.byId('ses_1').pinned, isTrue);

      await backend.clearOrder('ses_1');
      expect(store.load(), isEmpty);
      expect(other.load(), isEmpty);
      final rowsCleared = await backend.list();
      expect(rowsCleared.byId('ses_1').pinned, isFalse);
    });

    test('the comparator: pinned first (position ascending), then '
        'created descending', () {
      // The scripted positions: e and b tie at 0 (created descending breaks
      // the tie: e (500) before b (0)), a sits at 2; c and d are unpinned.
      final position = <String, num?>{'a': 2, 'b': 0, 'e': 0};
      final rows = [
        const Session(
          id: 'a',
          title: 'a',
          project: SessionProject(id: 'p', name: 'p'),
          created: 1000,
          location: '/a',
          active: false,
          pinned: true,
        ),
        const Session(
          id: 'b',
          title: 'b',
          project: SessionProject(id: 'p', name: 'p'),
          created: 0,
          location: '/b',
          active: false,
          pinned: true,
        ),
        const Session(
          id: 'c',
          title: 'c',
          project: SessionProject(id: 'p', name: 'p'),
          created: 999,
          location: '/c',
          active: false,
        ),
        const Session(
          id: 'd',
          title: 'd',
          project: SessionProject(id: 'p', name: 'p'),
          created: 1,
          location: '/d',
          active: false,
        ),
        // A position tie with b: created descending breaks it (e before b).
        const Session(
          id: 'e',
          title: 'e',
          project: SessionProject(id: 'p', name: 'p'),
          created: 500,
          location: '/e',
          active: false,
          pinned: true,
        ),
      ];

      rows.sort(
        (a, b) => SessionsBackend.homeListOrder(a, b, (id) => position[id]),
      );

      expect(rows.map((r) => r.id).toList(), ['e', 'b', 'a', 'c', 'd']);
    });

    test('the comparator without pins keeps today\'s newest-created order', () {
      final rows = [
        const Session(
          id: 'a',
          title: 'a',
          project: SessionProject(id: 'p', name: 'p'),
          created: 100,
          location: '/a',
          active: false,
        ),
        const Session(
          id: 'b',
          title: 'b',
          project: SessionProject(id: 'p', name: 'p'),
          created: 300,
          location: '/b',
          active: false,
        ),
        const Session(
          id: 'c',
          title: 'c',
          project: SessionProject(id: 'p', name: 'p'),
          created: 200,
          location: '/c',
          active: false,
        ),
      ];

      rows.sort((a, b) => SessionsBackend.homeListOrder(a, b, (id) => null));

      expect(rows.map((r) => r.id).toList(), ['b', 'c', 'a']);
    });
  });

  group('SessionsBackend.create', () {
    test('creates on the service and returns the row', () async {
      final created = const OpencodeSession(
        id: 'ses_new',
        title: 'new',
        projectId: 'p1',
        created: 400,
        location: '/new',
      );
      final service = FakeOpencodeService(
        sessions: [created],
        names: {'p1': 'proj-one'},
        createdSession: created,
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final row = await backend.create('p1');

      expect(service.created, ['p1']);
      expect(
        row,
        const Session(
          id: 'ses_new',
          title: 'new',
          project: SessionProject(id: 'p1', name: 'proj-one'),
          created: 400,
          location: '/new',
          active: false,
        ),
      );
    });

    test(
      'applies the model and thinking level from the most recent session',
      () async {
        const model = ModelRef(
          id: 'gpt',
          providerId: 'openai',
          variant: 'high',
        );
        final created = const OpencodeSession(
          id: 'ses_new',
          title: 'new',
          projectId: 'p1',
          created: 400,
          location: '/one',
        );
        final existing = const OpencodeSession(
          id: 'ses_old',
          title: 'old',
          projectId: 'p1',
          created: 100,
          location: '/one',
        );
        final service = FakeOpencodeService(
          sessions: [created, existing],
          names: {'p1': 'one'},
          createdSession: created,
          detailById: {
            'ses_old': SessionDetail(
              id: 'ses_old',
              title: 'old',
              location: '/one',
              cost: 0,
              tokens: const TokenUsage(
                input: 0,
                output: 0,
                reasoning: 0,
                cacheRead: 0,
                cacheWrite: 0,
              ),
              model: model,
              agent: 'build',
            ),
          },
        );
        final backend = SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        );

        await backend.create('p1');

        expect(service.createdWith.single, (model, null));
        expect(service.modelsSet, [('ses_new', model)]);
      },
    );

    test(
      'does not inherit the previous session\'s subagent (issue #184)',
      () async {
        const model = ModelRef(
          id: 'gpt',
          providerId: 'openai',
          variant: 'high',
        );
        final created = const OpencodeSession(
          id: 'ses_new',
          title: 'new',
          projectId: 'p1',
          created: 400,
          location: '/one',
        );
        final existing = const OpencodeSession(
          id: 'ses_old',
          title: 'old',
          projectId: 'p1',
          created: 100,
          location: '/one',
        );
        final service = FakeOpencodeService(
          sessions: [created, existing],
          names: {'p1': 'one'},
          createdSession: created,
          detailById: {
            'ses_old': SessionDetail(
              id: 'ses_old',
              title: 'old',
              location: '/one',
              cost: 0,
              tokens: const TokenUsage(
                input: 0,
                output: 0,
                reasoning: 0,
                cacheRead: 0,
                cacheWrite: 0,
              ),
              model: model,
              agent: 'reviewer-flash', // a restricted subagent, not the default
            ),
          },
        );
        final backend = SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        );

        await backend.create('p1');

        // The model is inherited (the intent of #136); the agent is not —
        // the service picks its default agent.
        expect(service.createdWith.single, (model, null));
        expect(service.modelsSet, [('ses_new', model)]);
      },
    );

    test('_defaultModel() still sees an archived session (issue #234: the seam '
        'is faithful, so the copy-model heuristic is untouched)', () async {
      const model = ModelRef(id: 'gpt', providerId: 'openai', variant: 'high');
      final created = const OpencodeSession(
        id: 'ses_new',
        title: 'new',
        projectId: 'p1',
        created: 500,
        location: '/one',
      );
      // The archived session is the one that already carries a model: the
      // heuristic must still read its detail and copy the model from it.
      final archived = const OpencodeSession(
        id: 'ses_old',
        title: 'old',
        projectId: 'p1',
        created: 100,
        location: '/one',
        archived: true,
      );
      final service = FakeOpencodeService(
        sessions: [created, archived],
        names: {'p1': 'one'},
        createdSession: created,
        detailById: {
          'ses_old': SessionDetail(
            id: 'ses_old',
            title: 'old',
            location: '/one',
            cost: 0,
            tokens: const TokenUsage(
              input: 0,
              output: 0,
              reasoning: 0,
              cacheRead: 0,
              cacheWrite: 0,
            ),
            model: model,
            agent: 'build',
          ),
        },
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      await backend.create('p1');

      expect(service.createdWith.single, (model, null));
      expect(service.modelsSet, [('ses_new', model)]);
    });
  });

  group('SessionsBackend.createInDirectory', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('oc-be-create-in');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('creates at the directory and returns the row', () async {
      final created = const OpencodeSession(
        id: 'ses_new_dir',
        title: 'new dir',
        projectId: 'p_dir',
        created: 400,
        location:
            '/tmp/oc-be-create-in.XXXXXX', // location as-is from the service
      );
      final service = FakeOpencodeService(
        names: const {}, // no name for p_dir -> falls back to the id
        createdInDirectory: created,
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final row = await backend.createInDirectory(dir.path);

      expect(service.createdIn, [dir.path]);
      expect(
        row,
        const Session(
          id: 'ses_new_dir',
          title: 'new dir',
          project: SessionProject(id: 'p_dir', name: 'p_dir'),
          created: 400,
          location: '/tmp/oc-be-create-in.XXXXXX',
          active: false,
        ),
      );
    });

    test('a missing directory is a clear 404, no service round-trip', () async {
      final service = FakeOpencodeService(
        createdInDirectory: const OpencodeSession(
          id: 'ses_never',
          title: 'never',
          projectId: 'p_never',
          created: 400,
          location: '/never',
        ),
      );
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      await expectLater(
        backend.createInDirectory('/definitely/not/a/real/path-oc-be-x'),
        throwsA(
          isA<OpencodeServiceError>().having(
            (e) => e.statusCode,
            'statusCode',
            HttpStatus.notFound,
          ),
        ),
      );
      expect(service.createdIn, isEmpty);
    });

    test(
      'does not inherit the previous session\'s subagent (issue #184)',
      () async {
        const model = ModelRef(
          id: 'gpt',
          providerId: 'openai',
          variant: 'high',
        );
        final created = OpencodeSession(
          id: 'ses_new_dir',
          title: 'new dir',
          projectId: 'p_dir',
          created: 400,
          location: dir.path,
        );
        final existing = const OpencodeSession(
          id: 'ses_old',
          title: 'old',
          projectId: 'p1',
          created: 100,
          location: '/one',
        );
        final service = FakeOpencodeService(
          sessions: [existing],
          names: const {},
          createdInDirectory: created,
          detailById: {
            'ses_old': SessionDetail(
              id: 'ses_old',
              title: 'old',
              location: '/one',
              cost: 0,
              tokens: const TokenUsage(
                input: 0,
                output: 0,
                reasoning: 0,
                cacheRead: 0,
                cacheWrite: 0,
              ),
              model: model,
              agent: 'reviewer-flash', // a restricted subagent, not the default
            ),
          },
        );
        final backend = SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        );

        await backend.createInDirectory(dir.path);

        // The model is inherited (the intent of #136); the agent is not —
        // the service picks its default agent.
        expect(service.createdInWith.single, (model, null));
        expect(service.modelsSet, [('ses_new_dir', model)]);
      },
    );
  });

  group('SessionsBackend.exists', () {
    test('true while the service has the session, false once gone', () async {
      final service = FakeOpencodeService(sessions: [s1]);
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      expect(await backend.exists('ses_1'), isTrue);
      expect(await backend.exists('ses_gone'), isFalse);
    });

    test(
      'an archived session still satisfies exists() '
      '(issue #234: the seam is faithful — archived rows are still listed)',
      () async {
        final service = FakeOpencodeService(sessions: [s1, sArchived]);
        final backend = SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        );

        expect(await backend.exists('ses_archived'), isTrue);
      },
    );
  });

  group('SessionsBackend.detailWithActive', () {
    const detail = SessionDetail(
      id: 'ses_1',
      title: 'one',
      location: '/one',
      cost: 0.5,
      tokens: TokenUsage(
        input: 10,
        output: 20,
        reasoning: 0,
        cacheRead: 0,
        cacheWrite: 0,
      ),
      outcome: null,
    );

    test('folds the live Active fact onto the detail', () async {
      final service = FakeOpencodeService(detail: detail, active: {'ses_1'});
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final folded = await backend.detailWithActive('ses_1');

      expect(folded.id, 'ses_1');
      expect(folded.active, isTrue);
      // The canCancel fact rides the same fold (the seam answers capable by
      // default; the composer's posture stands when the seam is silent).
      expect(folded.canCancel, isTrue);
    });

    test('an idle session folds active false', () async {
      final service = FakeOpencodeService(detail: detail, active: const {});
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      final folded = await backend.detailWithActive('ses_1');

      expect(folded.active, isFalse);
      expect(folded.canCancel, isTrue);
    });

    test('the detail error passes through', () async {
      final service = FakeOpencodeService();
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      await expectLater(
        backend.detailWithActive('ses_1'),
        throwsA(isA<OpencodeServiceError>()),
      );
    });
  });
}

extension on List<Session> {
  /// The row with [id] (the waiting tests' look-up).
  Session byId(String id) => firstWhere((row) => row.id == id);
}

/// An order store that fails every read (the degraded-store test): the list
/// must fall back to the unpinned order rather than fail.
class _ThrowingOrderStore implements SessionOrderStore {
  @override
  File get file => throw StateError('store down');

  @override
  Map<String, num> load() => throw StateError('store down');

  @override
  Future<void> set(String id, num position) async {}

  @override
  Future<void> clear(String id) async {}
}

/// An in-memory [SessionOrderStore] for tests that construct a
/// [SessionsBackend] but never touch the order store (issue #271: the store
/// is required at construction). It keeps the positions in memory, never the
/// app-owned file, so a test's store does not leak onto the host.
class _InMemoryOrderStore implements SessionOrderStore {
  final Map<String, num> _positions = {};

  @override
  File get file => throw StateError('in-memory store has no file');

  @override
  Map<String, num> load() => Map<String, num>.from(_positions);

  @override
  Future<void> set(String id, num position) async {
    _positions[id] = position;
  }

  @override
  Future<void> clear(String id) async {
    _positions.remove(id);
  }
}
