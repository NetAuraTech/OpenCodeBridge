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
/// composition, the detail fold, and [SessionsBackend.exists]' light probe,
/// issue #272 — recorded in [probedIds] / [listSessionsCalls] for the cost
/// assertions). The raw operations are the seam's own — their endpoint
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
    this.probeError,
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

  /// The ids [probe] was asked about (the pin write's existence check,
  /// issue #272): the cost assertion reads this — the probe is one
  /// identity read, and [listSessionsCalls] stays 0 on that path.
  final List<String> probedIds = [];

  /// When set, [probe] throws it (the degraded-probe route: a non-404
  /// failure the backend's `exists` propagates).
  Object? probeError;

  /// The [listSessions] calls (the cost the old existence check's paginated
  /// walk spent; the probe's path never walks the list, issue #272).
  var listSessionsCalls = 0;

  @override
  Future<List<OpencodeSession>> listSessions() async {
    listSessionsCalls++;
    return sessions;
  }

  @override
  Future<OpencodeSession> probe(String id) async {
    probedIds.add(id);
    final error = probeError;
    if (error != null) throw error;
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    throw const OpencodeServiceError(404, 'no such session');
  }

  @override
  Future<Map<String, String>> projectNames() async => names;

  @override
  Future<Set<String>> activeSessionIds() async => active;

  @override
  Future<OpencodeSession> createSession(
    String projectId, {
    ModelRef? model,
    String? agent,
    List<Map<String, Object?>>? permissions,
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
    List<Map<String, Object?>>? permissions,
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

    test('a store failure degrades to the unpinned order, never the list, and '
        'the degrade is scoped to that read (issue #273)', () async {
      // The on-disk fact the read should see when it can read: the
      // app-owned file carries a pin.
      await SessionOrderStore(file: file).set('ses_1', 0);
      final service = FakeOpencodeService(sessions: [s1, s2], names: const {});
      final backend = SessionsBackend(
        service: service,
        orderStore: _ThrowingOrderStore(),
      );

      final rows = await backend.list();

      // The failed read degrades that read only: the list stays up,
      // unpinned.
      expect(rows.map((r) => r.id).toList(), ['ses_2', 'ses_1']);
      expect(rows.every((r) => !r.pinned), isTrue);
      // ...and it never leaked into the store: the on-disk file still
      // carries the pin (read back the way the ordering tests do).
      final onDisk = jsonDecode(file.readAsStringSync()) as Map;
      expect(onDisk, {'ses_1': 0});

      // ...nor into later reads: a subsequent read over the store whose
      // file is intact still pins (a fresh store reads the same
      // app-owned file).
      final laterRows = await SessionsBackend(
        service: FakeOpencodeService(sessions: [s1, s2], names: const {}),
        orderStore: SessionOrderStore(file: file),
      ).list();
      expect(laterRows.map((r) => r.id).toList(), ['ses_1', 'ses_2']);
      expect(laterRows.byId('ses_1').pinned, isTrue);
    });

    test(
      'a write failure cannot touch the read (issue #272): the load '
      'succeeds, every write fails, the rows stay intact and pinned',
      () async {
        final service = FakeOpencodeService(
          sessions: [s1, s2],
          names: const {},
        );
        final backend = SessionsBackend(
          service: service,
          orderStore: _ReadThenFailOrderStore(positions: {'ses_1': 0}),
        );

        final rows = await backend.list();

        // The loaded map's pins stand on their own: the rows are intact and
        // sorted pinned-first — a store that cannot write still reads.
        expect(rows.map((r) => r.id).toList(), ['ses_1', 'ses_2']);
        expect(rows.byId('ses_1').pinned, isTrue);
        expect(rows.byId('ses_2').pinned, isFalse);
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

  // The read's tie (issue #273): the row's pinned fact (pinnedOf) and the
  // pinned-first sort (the comparator's position closure) must both be
  // derived from the read's one store read — a divergence (one derivation
  // re-read from the store) would put a row in the wrong block silently.
  // The store's reads are scripted (a counted load that serves a different
  // map on a second call) so a second derivation would show.

  group('SessionsBackend.list store tie (issue #273)', () {
    test('one store read per list read, and the pinned rows are exactly the '
        'rows the comparator sorted into the pinned block', () async {
      // The store's read serves the first script's map; a second load
      // (a re-derived derivation) would serve the next one, so a
      // divergence between the pinned fact and the sort cannot hide.
      final store = _ScriptedLoadOrderStore([
        {'ses_3': 0, 'ses_1': 1},
        {'ses_2': 0},
      ]);
      final backend = SessionsBackend(
        service: FakeOpencodeService(
          sessions: [s1, s2, s3],
          names: {'p1': 'proj-one', 'p2': 'proj-two'},
        ),
        orderStore: store,
      );

      final rows = await backend.list();

      // (a) exactly one store read per list read.
      expect(store.loads, 1);
      // (b) the set of rows whose pinned fact is true is exactly the set
      // the comparator sorted into the pinned block: re-sorted over the
      // rows with the map the store served, the pinned fact agrees and
      // the read's order is the comparator's.
      final served = store.served.single;
      expect(
        {
          for (final row in rows)
            if (row.pinned) row.id,
        },
        {
          for (final row in rows)
            if (served.containsKey(row.id)) row.id,
        },
      );
      final reSorted = [...rows]
        ..sort(
          (a, b) => SessionsBackend.homeListOrder(a, b, (id) => served[id]),
        );
      expect(
        reSorted.map((r) => r.id).toList(),
        rows.map((r) => r.id).toList(),
        reason:
            'the read\u0027s order must be the comparator\u0027s order '
            'over the map it served',
      );
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

  group('SessionsBackend.exists (issue #272: the light probe)', () {
    test('true while the service has the session, false once gone — and the '
        'probe, not the paginated list, is the check', () async {
      final service = FakeOpencodeService(sessions: [s1]);
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );

      expect(await backend.exists('ses_1'), isTrue);
      expect(await backend.exists('ses_gone'), isFalse);

      // The cost: each check is one identity probe, and the paginated list
      // walk (up to a thousand pages) is never spent on the check.
      expect(service.probedIds, ['ses_1', 'ses_gone']);
      expect(service.listSessionsCalls, 0);
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

    test(
      'a non-404 probe failure propagates (the route maps it, as before)',
      () async {
        final service = FakeOpencodeService(
          sessions: [s1],
          probeError: const OpencodeServiceError(0, 'service down'),
        );
        final backend = SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        );

        await expectLater(
          backend.exists('ses_1'),
          throwsA(
            isA<OpencodeServiceError>().having(
              (e) => e.statusCode,
              'statusCode',
              0,
            ),
          ),
        );
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

/// An order store whose read succeeds (serving [positions]) and whose writes
/// fail (issue #272's separated degrade): the read path is 100 % read-only
/// on the store (the #292 separation), so the failing writes are unreachable
/// from `list()` — the read returns the loaded map's rows intact, pins and
/// all; only the write paths (the pin/un-pin, the event-driven cleanup) hit
/// the failure.
class _ReadThenFailOrderStore implements SessionOrderStore {
  _ReadThenFailOrderStore({this.positions = const {}});

  final Map<String, num> positions;

  @override
  File get file => throw StateError('write-down store has no file');

  @override
  Map<String, num> load() => Map<String, num>.from(positions);

  @override
  Future<void> set(String id, num position) async =>
      throw StateError('write down');

  @override
  Future<void> clear(String id) async => throw StateError('write down');
}

/// An order store whose reads are scripted (issue #273's tie): it counts
/// its [load] calls and serves [scripts] in call order, a later call than
/// the script's length serving the last one. The point of the different
/// maps is that a second read does not read the same map, so a
/// re-derived derivation (the pinned fact, or the comparator's input,
/// re-read from the store) would show in [loads] and break the tie the
/// test pins: one read per list read, one map feeding both. The write
/// paths are not read from the list read (the #292 separation), so they
/// fail, as the write-down store's do.
class _ScriptedLoadOrderStore implements SessionOrderStore {
  _ScriptedLoadOrderStore(this.scripts);

  /// The maps the successive [load] calls serve, in call order.
  final List<Map<String, num>> scripts;

  /// The [load] calls so far (the tie's cost: one per list read).
  int loads = 0;

  /// The maps [load] has served so far (the tie's map: the one read).
  final List<Map<String, num>> served = [];

  @override
  File get file => throw StateError('scripted-load store has no file');

  @override
  Map<String, num> load() {
    final script = scripts[loads < scripts.length ? loads : scripts.length - 1];
    loads++;
    final map = Map<String, num>.from(script);
    served.add(map);
    return map;
  }

  @override
  Future<void> set(String id, num position) async =>
      throw StateError('scripted-load store is read-only');

  @override
  Future<void> clear(String id) async =>
      throw StateError('scripted-load store is read-only');
}
