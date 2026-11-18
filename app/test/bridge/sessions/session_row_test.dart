import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/session_row.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// A scripted [OpencodeService] for the row-composer tests: it controls the
/// per-row facts the composer reads — the per-session pending lookups (the
/// waiting fact), the interrupt capability (the canCancel fact), and the
/// active set — and records nothing else. Everything the composer never reads
/// is a stub that throws if reached (the tests should not call it).
class FakeComposerService implements OpencodeService {
  FakeComposerService({
    this.sessions = const [],
    this.names = const {},
    this.active = const {},
    this.detail,
    this.permissionsBySession = const {},
    this.questionsBySession = const {},
    this.canCancel = true,
    this.canCancelError,
  });

  final List<OpencodeSession> sessions;
  final Map<String, String> names;
  final Set<String> active;
  final SessionDetail? detail;

  /// Per-session pending permission requests (the waiting fact, issue #208):
  /// an absent session answers none; a value of `null` makes the lookup for
  /// that session throw (the degraded-orb route).
  final Map<String, List<PermissionRequest>?> permissionsBySession;

  /// Per-session pending question forms (the waiting fact, issue #208):
  /// an absent session answers none; a value of `null` makes the lookup for
  /// that session throw (the degraded-orb route).
  final Map<String, List<QuestionForm>?> questionsBySession;

  /// The interrupt capability (issue #165), when [canCancelError] is unset.
  final bool canCancel;

  /// When set, [canCancelTurn] throws it (the degraded-capability route).
  final Object? canCancelError;

  // The facts the composer reads.

  @override
  Future<List<OpencodeSession>> listSessions() async => List.of(sessions);

  @override
  Future<Map<String, String>> projectNames() async => Map.of(names);

  @override
  Future<Set<String>> activeSessionIds() async => Set.of(active);

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
    return const [];
  }

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
    return const [];
  }

  @override
  Future<bool> canCancelTurn(String id) async {
    final error = canCancelError;
    if (error != null) throw error;
    return canCancel;
  }

  @override
  Future<SessionDetail> getDetail(String id) async {
    final d = detail;
    if (d == null) throw const OpencodeServiceError(404, 'no detail scripted');
    return d;
  }

  // Everything the composer never reads: stubs that throw if reached.

  @override
  Future<OpencodeSession> probe(String id) async =>
      throw StateError('not scripted');

  @override
  Future<List<OpencodeProject>> projects() async =>
      throw StateError('not scripted');
  @override
  Future<OpencodeSession> createSession(
    String projectId, {
    ModelRef? model,
    String? agent,
  }) async => throw StateError('not scripted');
  @override
  Future<OpencodeSession> createSessionInDirectory(
    String directory, {
    ModelRef? model,
    String? agent,
  }) async => throw StateError('not scripted');
  @override
  Future<void> deleteSession(String id) async {}
  @override
  Future<void> archive(String id, bool archived) async {}
  @override
  Future<List<SessionMessage>> getMessages(String id) async => const [];
  @override
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) async => const MessagePage(messages: [], nextCursor: null);
  @override
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async {}
  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {}
  @override
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) async {}
  @override
  Future<void> dismissQuestion(String id, String formID) async {}
  @override
  Future<List<OpencodeCommand>> listCommands() async => const [];
  @override
  Future<void> runCommand(String id, String name, String text) async {}
  @override
  Future<List<ModelOption>> listModels() async => const [];
  @override
  Future<ModelRef?> currentModel(String id) async => null;
  @override
  Future<void> setModel(String id, ModelRef model) async {}
  @override
  Future<List<AgentOption>> listAgents() async => const [];
  @override
  Future<void> setAgent(String id, String agentId) async {}
  @override
  Future<List<SkillOption>> listSkills() async => const [];
  @override
  Future<void> activateSkill(String id, String skillId) async {}
  @override
  Future<void> compact(String id) async {}
  @override
  Future<void> cancelTurn(String id) async => throw StateError('not scripted');
  @override
  Future<void> undo(String id) async {}
  @override
  Future<void> redo(String id) async {}
  @override
  Future<String> fork(String id) async => throw StateError('not scripted');
  @override
  Future<void> rename(String id, String title) async {}
  @override
  Future<String> exportSession(String id) async =>
      throw StateError('not scripted');
  @override
  Future<void> move(String id, String directory) async {}
  @override
  Future<String> generate(String id, String prompt) async =>
      throw StateError('not scripted');
  @override
  Future<String> diff(String id) async => throw StateError('not scripted');
  @override
  Future<String> stats(String id) async => throw StateError('not scripted');
  @override
  Future<String> worktrees(String sessionId) async =>
      throw StateError('not scripted');
  @override
  Future<List<String>> findFiles(String id, String query) async => const [];
  @override
  Future<String> usage() async => throw StateError('not scripted');
  @override
  Future<String> mcps() async => throw StateError('not scripted');
  @override
  Future<String> integrations() async => throw StateError('not scripted');
  @override
  Future<String> connectIntegration(
    String integrationId,
    String methodId,
  ) async => throw StateError('not scripted');
  @override
  Future<String> status() async => throw StateError('not scripted');
  @override
  Future<String> pair() async => throw StateError('not scripted');
  @override
  Future<void> reload() async {}
  @override
  Future<String> plugins() async => throw StateError('not scripted');
}

const permission = PermissionRequest(
  id: 'req_1',
  action: 'shell',
  resources: ['ls'],
);

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

const baseDetail = SessionDetail(
  id: 'ses_1',
  title: 'one',
  location: '/one',
  cost: 0,
  tokens: TokenUsage(
    input: 0,
    output: 0,
    reasoning: 0,
    cacheRead: 0,
    cacheWrite: 0,
  ),
);

void main() {
  group('SessionRowComposer.row (the single composition)', () {
    test('composes the per-row flags onto the Session row', () {
      final composer = SessionRowComposer.composerFor(FakeComposerService());
      const s = OpencodeSession(
        id: 'ses_1',
        title: 'one',
        projectId: 'p1',
        created: 100,
        location: '/one',
        archived: true,
      );

      final row = composer.row(
        s,
        {'p1': 'proj-one'},
        {'ses_1'},
        waiting: true,
        pinned: true,
      );

      // The identity facts ride the service session row.
      expect(row.id, 'ses_1');
      expect(row.title, 'one');
      expect(row.project, const SessionProject(id: 'p1', name: 'proj-one'));
      expect(row.created, 100);
      expect(row.location, '/one');
      // The per-row flags are composed from their facts.
      expect(row.active, isTrue, reason: 'the id is in the active set');
      expect(row.waiting, isTrue);
      expect(row.pinned, isTrue);
      expect(row.archived, isTrue, reason: 'carried off the service row');
      // canCancel is not a Session field: the row carries no cancel capability.
      expect(row.toJson().containsKey('canCancel'), isFalse);
    });

    test('falls back to the project id when no name is known', () {
      final composer = SessionRowComposer.composerFor(FakeComposerService());
      const s = OpencodeSession(
        id: 'ses_1',
        title: 'one',
        projectId: 'p1',
        created: 100,
        location: '/one',
      );

      final row = composer.row(s, const {}, const {});

      expect(row.project, const SessionProject(id: 'p1', name: 'p1'));
    });

    test('waiting and pinned default to false (the create reads)', () {
      final composer = SessionRowComposer.composerFor(FakeComposerService());
      const s = OpencodeSession(
        id: 'ses_1',
        title: 'one',
        projectId: 'p1',
        created: 100,
        location: '/one',
      );

      final row = composer.row(s, const {}, const {});

      expect(row.active, isFalse);
      expect(row.waiting, isFalse);
      expect(row.pinned, isFalse);
    });

    test(
      'stamps the orb fact when the caller supplies one (the orb create)',
      () {
        final composer = SessionRowComposer.composerFor(FakeComposerService());
        // The raw orb service reports no orb attribution...
        const s = OpencodeSession(
          id: 'ses_o',
          title: 'orb session',
          projectId: 'p1',
          created: 100,
          location: '/workspace',
        );

        final row = composer.row(s, const {}, const {}, orb: 'orb_7');

        // ...but the caller knows the session it created lives on that orb.
        expect(row.orb, 'orb_7');
      },
    );

    test('otherwise carries the session orb fact through (the list reads)', () {
      final composer = SessionRowComposer.composerFor(FakeComposerService());
      // A composite-listed orb row already carries its orb attribution.
      const s = OpencodeSession(
        id: 'ses_o',
        title: 'orb session',
        projectId: 'p1',
        created: 100,
        location: '/workspace',
        orb: 'orb_7',
      );

      final row = composer.row(s, const {}, const {});

      expect(row.orb, 'orb_7');
    });
  });

  // Each fact keeps its own degradation posture, now the composer's one-per-
  // fact method. A change to one flag's semantics touches this one method —
  // not the four call sites that used to each carry the logic.

  group('the per-fact degradation postures', () {
    test('active: membership in the active set (the host-failure posture '
        'lives upstream in activeSessionIds, not here)', () {
      expect(SessionRowComposer.activeOf(const {'a', 'b'}, 'a'), isTrue);
      expect(SessionRowComposer.activeOf(const {'a'}, 'z'), isFalse);
      expect(SessionRowComposer.activeOf(const <String>{}, 'a'), isFalse);
    });

    test(
      'waiting: a degraded pending lookup degrades that session only',
      () async {
        final composer = SessionRowComposer.composerFor(
          FakeComposerService(
            permissionsBySession: {
              'ses_1': [permission], // holding a permission -> waiting
              'ses_2': null, // the lookup throws -> degrade to false
              'ses_3': const [], // nothing pending -> false
            },
          ),
        );

        expect(await composer.waitingOf('ses_1'), isTrue);
        expect(
          await composer.waitingOf('ses_2'),
          isFalse,
          reason: 'the degraded session reads waiting false, the others intact',
        );
        expect(await composer.waitingOf('ses_3'), isFalse);
      },
    );

    test(
      'waiting: a pending question (with no permission) reads waiting',
      () async {
        final composer = SessionRowComposer.composerFor(
          FakeComposerService(
            questionsBySession: {
              'ses_2': [form],
            },
          ),
        );

        expect(await composer.waitingOf('ses_2'), isTrue);
        expect(await composer.waitingOf('ses_1'), isFalse);
      },
    );

    test('waiting: a degraded question lookup degrades to false', () async {
      final composer = SessionRowComposer.composerFor(
        FakeComposerService(
          // No permission (absent -> none), so the question lookup runs —
          // and it throws for this session.
          questionsBySession: {'ses_1': null},
        ),
      );

      expect(await composer.waitingOf('ses_1'), isFalse);
    });

    test('pinned: a store that read nothing reads unpinned; a stored '
        'position reads pinned', () {
      // A store failure degrades to an empty map in the caller (list); the
      // composer just reads membership, so every row reads unpinned.
      expect(SessionRowComposer.pinnedOf(const {}, 'ses_1'), isFalse);
      expect(SessionRowComposer.pinnedOf(const {'ses_1': 0}, 'ses_1'), isTrue);
    });

    test('archived: the service fact passes straight through', () {
      const archived = OpencodeSession(
        id: 'ses_1',
        title: 'a',
        projectId: 'p1',
        created: 100,
        location: '/a',
        archived: true,
      );
      const unarchived = OpencodeSession(
        id: 'ses_2',
        title: 'b',
        projectId: 'p1',
        created: 100,
        location: '/b',
      );

      expect(SessionRowComposer.archivedOf(archived), isTrue);
      expect(SessionRowComposer.archivedOf(unarchived), isFalse);
    });

    test('canCancel: a lookup failure reads as capable', () async {
      final composer = SessionRowComposer.composerFor(
        FakeComposerService(
          canCancelError: const OpencodeServiceError(502, 'capability down'),
        ),
      );

      expect(await composer.canCancelOf('ses_1'), isTrue);
    });

    test('canCancel: the service answer is carried (capable or not)', () async {
      final capable = SessionRowComposer.composerFor(
        FakeComposerService(canCancel: true),
      );
      final incapable = SessionRowComposer.composerFor(
        FakeComposerService(canCancel: false),
      );

      expect(await capable.canCancelOf('ses_1'), isTrue);
      expect(await incapable.canCancelOf('ses_1'), isFalse);
    });
  });

  // The five facts composed together: a mini read that drives the composer
  // the way list() does (active set + per-row waiting + per-row pinned), and
  // the detail read's active + canCancel fold.

  group('the composition together', () {
    test('builds each row from its five facts', () async {
      final service = FakeComposerService(
        active: {'ses_2'},
        permissionsBySession: {
          'ses_1': [permission],
        },
      );
      final composer = SessionRowComposer.composerFor(service);
      const s1 = OpencodeSession(
        id: 'ses_1',
        title: 'one',
        projectId: 'p1',
        created: 100,
        location: '/one',
        archived: true,
      );
      const s2 = OpencodeSession(
        id: 'ses_2',
        title: 'two',
        projectId: 'p2',
        created: 200,
        location: '/two',
      );

      // The read: one active set, one waiting fact per session, one pinned
      // fact per session — exactly the shape list() hands to the composer.
      final names = await service.projectNames();
      final active = await service.activeSessionIds();
      final waiting = {
        for (final s in [s1, s2]) s.id: await composer.waitingOf(s.id),
      };
      final positions = {'ses_2': 0};
      final rows = {
        for (final s in [s1, s2])
          s.id: composer.row(
            s,
            names,
            active,
            waiting: waiting[s.id] ?? false,
            pinned: SessionRowComposer.pinnedOf(positions, s.id),
          ),
      };

      // ses_1: not active, waiting (a permission), unpinned, archived.
      expect(rows['ses_1']!.active, isFalse);
      expect(rows['ses_1']!.waiting, isTrue);
      expect(rows['ses_1']!.pinned, isFalse);
      expect(rows['ses_1']!.archived, isTrue);
      // ses_2: active, not waiting, pinned, not archived.
      expect(rows['ses_2']!.active, isTrue);
      expect(rows['ses_2']!.waiting, isFalse);
      expect(rows['ses_2']!.pinned, isTrue);
      expect(rows['ses_2']!.archived, isFalse);
    });

    test('the detail read folds the active and canCancel facts', () async {
      final composer = SessionRowComposer.composerFor(
        FakeComposerService(
          active: {'ses_1'},
          canCancel: false,
          detail: baseDetail,
        ),
      );

      final detail = await composer.detailWithActive(
        await composer.service.getDetail('ses_1'),
        'ses_1',
      );

      expect(detail.active, isTrue, reason: 'the id is in the active set');
      expect(detail.canCancel, isFalse, reason: 'the service says incapable');
    });

    test(
      'the detail read still reads capable when the capability fails',
      () async {
        final composer = SessionRowComposer.composerFor(
          FakeComposerService(
            active: const {},
            canCancelError: const OpencodeServiceError(502, 'capability down'),
            detail: baseDetail,
          ),
        );

        final detail = await composer.detailWithActive(
          await composer.service.getDetail('ses_1'),
          'ses_1',
        );

        expect(detail.active, isFalse);
        expect(detail.canCancel, isTrue, reason: 'a failure reads as capable');
      },
    );
  });
}
