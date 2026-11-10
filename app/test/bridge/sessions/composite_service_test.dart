import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/sessions/composite_service.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/orb.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// A scripted [OpencodeService] for the composite tests: mutable state, call
/// records, and an optional scripted failure on [listSessions].
class FakeService implements OpencodeService {
  FakeService({
    List<OpencodeSession>? sessions,
    Map<String, String>? names,
    Set<String>? active,
    this.listError,
  }) : sessions = sessions ?? [],
       names = names ?? {},
       active = active ?? {};

  List<OpencodeSession> sessions;
  Map<String, String> names;
  Set<String> active;

  /// When set, [listSessions] throws it (a degraded orb / a dead host).
  Object? listError;

  final List<String> detailCalls = [];
  final List<String> cancelled = [];
  final List<String> deleted = [];
  final List<String> forked = [];
  var projectsCalls = 0;
  var createCalls = 0;
  var createInCalls = 0;
  var modelsCalls = 0;
  var agentsCalls = 0;
  var skillsCalls = 0;
  var commandsCalls = 0;
  var usageCalls = 0;

  @override
  Future<List<OpencodeSession>> listSessions() async {
    final error = listError;
    if (error != null) throw error;
    return List.of(sessions);
  }

  @override
  Future<Map<String, String>> projectNames() async => Map.of(names);

  @override
  Future<Set<String>> activeSessionIds() async => Set.of(active);

  @override
  Future<List<OpencodeProject>> projects() async {
    projectsCalls++;
    return const [];
  }

  @override
  Future<OpencodeSession> createSession(
    String projectId, {
    ModelRef? model,
    String? agent,
  }) async {
    createCalls++;
    throw const OpencodeServiceError(500, 'not scripted');
  }

  @override
  Future<OpencodeSession> createSessionInDirectory(
    String directory, {
    ModelRef? model,
    String? agent,
  }) async {
    createInCalls++;
    throw const OpencodeServiceError(500, 'not scripted');
  }

  @override
  Future<void> deleteSession(String id) async {
    deleted.add(id);
    sessions.removeWhere((s) => s.id == id);
  }

  @override
  Future<SessionDetail> getDetail(String id) async {
    detailCalls.add(id);
    throw const OpencodeServiceError(404, 'no detail scripted');
  }

  @override
  Future<String> fork(String id) async {
    forked.add(id);
    return 'fork_of_$id'; // NOT added to [sessions]: only the composite's
    // registration may route it.
  }

  // Everything below is a no-op pass-through (the composite tests only
  // observe which service was routed to).

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
  Future<List<PermissionRequest>> pendingPermissions(String id) async =>
      const [];

  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {}

  @override
  Future<List<QuestionForm>> pendingQuestions(String id) async => const [];

  @override
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) async {}

  @override
  Future<void> dismissQuestion(String id, String formID) async {}

  @override
  Future<List<OpencodeCommand>> listCommands() async {
    commandsCalls++;
    return const [];
  }

  @override
  Future<void> runCommand(String id, String name, String text) async {}

  @override
  Future<List<ModelOption>> listModels() async {
    modelsCalls++;
    return const [];
  }

  @override
  Future<ModelRef?> currentModel(String id) async => null;

  @override
  Future<void> setModel(String id, ModelRef model) async {}

  @override
  Future<List<AgentOption>> listAgents() async {
    agentsCalls++;
    return const [];
  }

  @override
  Future<void> setAgent(String id, String agentId) async {}

  @override
  Future<List<SkillOption>> listSkills() async {
    skillsCalls++;
    return const [];
  }

  @override
  Future<void> activateSkill(String id, String skillId) async {}

  @override
  Future<void> compact(String id) async {}

  @override
  Future<void> undo(String id) async {}

  @override
  Future<void> redo(String id) async {}

  @override
  Future<void> cancelTurn(String id) async {
    cancelled.add(id);
  }

  @override
  Future<void> rename(String id, String title) async {}

  @override
  Future<String> exportSession(String id) async => '{}';

  @override
  Future<void> move(String id, String directory) async {}

  @override
  Future<String> generate(String id, String prompt) async => '';

  @override
  Future<String> diff(String id) async => '{}';

  @override
  Future<String> stats(String id) async => '{}';

  @override
  Future<String> worktrees(String sessionId) async => '{}';

  @override
  Future<List<String>> findFiles(String id, String query) async => const [];

  @override
  Future<String> usage() async {
    usageCalls++;
    return '{}';
  }

  @override
  Future<String> mcps() async => '{}';

  @override
  Future<String> integrations() async => '{}';

  @override
  Future<String> connectIntegration(
    String integrationId,
    String methodId,
  ) async => '{}';

  @override
  Future<String> status() async => '{}';

  @override
  Future<String> pair() async => '{}';

  @override
  Future<void> reload() async {}

  @override
  Future<String> plugins() async => '{}';
}

const hostSession = OpencodeSession(
  id: 'ses_host',
  title: 'host',
  projectId: 'p1',
  created: 100,
  location: '/host',
);

const orbSession = OpencodeSession(
  id: 'ses_orb',
  title: 'orb',
  projectId: 'p1',
  created: 200,
  location: '/orb',
);

OrbRecord runningOrb(String id, {String url = 'http://127.0.0.1:41234'}) =>
    OrbRecord(
      id: id,
      name: 'n-$id',
      project: 'proj',
      branch: 'orb/$id',
      state: 'running',
      created: '2026-01-01T00:00:00Z',
      url: url,
    );

CompositeOpencodeService makeComposite({
  required FakeService host,
  Future<List<OrbRecord>> Function()? orbs,
  Future<String?> Function(String)? passwords,
  Map<String, FakeService>? upstreams,
}) {
  final upstreamMap = upstreams ?? const {};
  return CompositeOpencodeService(
    host: host,
    orbList: orbs ?? () async => const [],
    orbPassword: passwords ?? ((_) async => null),
    upstreamFactory: (baseUrl, password) {
      final fake = upstreamMap['$baseUrl|$password'];
      if (fake == null) {
        throw StateError('no scripted upstream for $baseUrl|$password');
      }
      return fake;
    },
  );
}

Future<void> swallow(Future<Object?> Function() call) async {
  try {
    await call();
  } catch (_) {}
}

void main() {
  group('CompositeOpencodeService.listSessions', () {
    test(
      'merges host + orb sessions; orb rows are stamped, host rows are not',
      () async {
        final host = FakeService(sessions: [hostSession]);
        final orb1 = FakeService(sessions: [orbSession]);
        final composite = makeComposite(
          host: host,
          orbs: () async => [runningOrb('orb1')],
          passwords: (_) async => 'pw1',
          upstreams: {'http://127.0.0.1:41234|pw1': orb1},
        );

        final all = await composite.listSessions();

        expect(all.map((s) => s.id), containsAll(['ses_host', 'ses_orb']));
        final orbRow = all.firstWhere((s) => s.id == 'ses_orb');
        expect(orbRow.orb, 'orb1');
        final hostRow = all.firstWhere((s) => s.id == 'ses_host');
        expect(hostRow.orb, isNull);
      },
    );

    test('a stopped orb (no url) gets no upstream and no rows', () async {
      final host = FakeService(sessions: [hostSession]);
      final composite = makeComposite(
        host: host,
        orbs: () async => [
          const OrbRecord(
            id: 'orb1',
            name: 'n',
            project: 'proj',
            branch: 'orb/orb1',
            state: 'stopped',
            created: '2026-01-01T00:00:00Z',
          ),
        ],
      );

      final all = await composite.listSessions();

      expect(all.map((s) => s.id), ['ses_host']);
    });

    test('a running orb without a password is skipped', () async {
      final host = FakeService(sessions: [hostSession]);
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        // No password: the orb is still booting.
      );

      final all = await composite.listSessions();

      expect(all.map((s) => s.id), ['ses_host']);
    });

    test('an orb-list failure degrades to host-only', () async {
      final host = FakeService(sessions: [hostSession]);
      final composite = makeComposite(
        host: host,
        orbs: () async => throw const DockerUnavailableError('docker is down'),
      );

      final all = await composite.listSessions();

      expect(all.map((s) => s.id), ['ses_host']);
    });

    test('a per-orb list failure is swallowed (degraded pass)', () async {
      final host = FakeService(sessions: [hostSession]);
      final orb1 = FakeService(
        sessions: [orbSession],
        listError: const OpencodeServiceError(502, 'orb down'),
      );
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );

      final all = await composite.listSessions();

      expect(all.map((s) => s.id), ['ses_host']);
    });

    test('a host list failure propagates', () async {
      final host = FakeService(
        listError: const OpencodeServiceError(502, 'host down'),
      );
      final composite = makeComposite(host: host);

      await expectLater(
        composite.listSessions(),
        throwsA(isA<OpencodeServiceError>()),
      );
    });
  });

  group('CompositeOpencodeService.activeSessionIds', () {
    test('is the union across host + orbs', () async {
      final host = FakeService(active: {'ses_host_active'});
      final orb1 = FakeService(active: {'ses_orb_active'});
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );

      final active = await composite.activeSessionIds();

      expect(active, {'ses_host_active', 'ses_orb_active'});
    });
  });

  group('CompositeOpencodeService.projectNames', () {
    test('merges orb names, host wins on a shared id', () async {
      final host = FakeService(names: {'p1': 'host-name', 'p2': 'host-only'});
      final orb1 = FakeService(names: {'p1': 'orb-name', 'p3': 'orb-only'});
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );

      final names = await composite.projectNames();

      expect(names, {'p1': 'host-name', 'p2': 'host-only', 'p3': 'orb-only'});
    });
  });

  group('CompositeOpencodeService routing', () {
    test('a known orb session is routed to the orb service', () async {
      final host = FakeService(sessions: [hostSession]);
      final orb1 = FakeService(sessions: [orbSession]);
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );
      await composite.listSessions(); // learn the table

      await swallow(() => composite.getDetail('ses_orb'));

      expect(orb1.detailCalls, ['ses_orb']);
      expect(host.detailCalls, isEmpty);
    });

    test('a host session is routed to the host service', () async {
      final host = FakeService(sessions: [hostSession]);
      final orb1 = FakeService(sessions: [orbSession]);
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );
      await composite.listSessions();

      await swallow(() => composite.getDetail('ses_host'));

      expect(host.detailCalls, ['ses_host']);
      expect(orb1.detailCalls, isEmpty);
    });

    test(
      'an unknown session id falls back to the host after a refresh',
      () async {
        final host = FakeService(sessions: [hostSession]);
        final composite = makeComposite(host: host);

        await swallow(() => composite.getDetail('ses_unknown'));

        expect(host.detailCalls, ['ses_unknown']);
      },
    );

    test(
      'a session on a newly started orb routes after the on-miss refresh',
      () async {
        final host = FakeService(sessions: [hostSession]);
        final orb1 = FakeService(sessions: [orbSession]);
        final orbs = <OrbRecord>[]; // nothing running at first
        final composite = makeComposite(
          host: host,
          orbs: () async => orbs,
          passwords: (_) async => 'pw1',
          upstreams: {'http://127.0.0.1:41234|pw1': orb1},
        );

        // Before the orb exists: the host is consulted.
        await swallow(() => composite.getDetail('ses_orb'));
        expect(host.detailCalls, ['ses_orb']);
        expect(orb1.detailCalls, isEmpty);

        // The orb starts: the next on-miss refresh discovers it.
        orbs.add(runningOrb('orb1'));
        await swallow(() => composite.getDetail('ses_orb'));
        expect(orb1.detailCalls, ['ses_orb']);
      },
    );

    test(
      'deleteSession routes to the orb and clears the table entry',
      () async {
        final host = FakeService(sessions: [hostSession]);
        final orb1 = FakeService(sessions: [orbSession]);
        final composite = makeComposite(
          host: host,
          orbs: () async => [runningOrb('orb1')],
          passwords: (_) async => 'pw1',
          upstreams: {'http://127.0.0.1:41234|pw1': orb1},
        );
        await composite.listSessions();

        await composite.deleteSession('ses_orb');

        expect(orb1.deleted, ['ses_orb']);
        // The fake dropped the session from its list: the entry must now fall
        // through to the host.
        await swallow(() => composite.getDetail('ses_orb'));
        expect(host.detailCalls, ['ses_orb']);
      },
    );

    test('a host deleteSession routes to the host', () async {
      final host = FakeService(sessions: [hostSession]);
      final composite = makeComposite(host: host);

      await composite.deleteSession('ses_host');

      expect(host.deleted, ['ses_host']);
    });

    test('cancelTurn routes to the owning orb', () async {
      final host = FakeService(sessions: [hostSession]);
      final orb1 = FakeService(sessions: [orbSession]);
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );
      await composite.listSessions();

      await composite.cancelTurn('ses_orb');

      expect(orb1.cancelled, ['ses_orb']);
      expect(host.cancelled, isEmpty);
    });

    test('a host cancelTurn routes to the host', () async {
      final host = FakeService(sessions: [hostSession]);
      final orb1 = FakeService(sessions: [orbSession]);
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );
      await composite.listSessions();

      await composite.cancelTurn('ses_host');

      expect(host.cancelled, ['ses_host']);
      expect(orb1.cancelled, isEmpty);
    });

    test('fork registers the new id under the parent orb', () async {
      final host = FakeService(sessions: [hostSession]);
      final orb1 = FakeService(sessions: [orbSession]);
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );
      await composite.listSessions();

      final newId = await composite.fork('ses_orb');

      expect(newId, 'fork_of_ses_orb');
      expect(orb1.forked, ['ses_orb']);
      // The child is NOT in the orb's list (the fake does not add it): only
      // the composite's registration may route it.
      await swallow(() => composite.getDetail('fork_of_ses_orb'));
      expect(orb1.detailCalls, ['fork_of_ses_orb']);
      expect(host.detailCalls, isEmpty);
    });

    test('a fork of a host session stays on the host', () async {
      final host = FakeService(sessions: [hostSession]);
      final composite = makeComposite(host: host);

      final newId = await composite.fork('ses_host');

      expect(newId, 'fork_of_ses_host');
      await swallow(() => composite.getDetail('fork_of_ses_host'));
      expect(host.detailCalls, ['fork_of_ses_host']);
    });

    test(
      'a password rotation replaces the upstream (new url|password key)',
      () async {
        final host = FakeService(sessions: [hostSession]);
        final orb1a = FakeService(sessions: [orbSession]);
        final orb1b = FakeService(sessions: [orbSession]);
        String password = 'pw1';
        final composite = makeComposite(
          host: host,
          orbs: () async => [runningOrb('orb1')],
          passwords: (_) async => password,
          upstreams: {
            'http://127.0.0.1:41234|pw1': orb1a,
            'http://127.0.0.1:41234|pw2': orb1b,
          },
        );
        await composite.listSessions();
        expect(orb1a.sessions, [orbSession]); // first upstream wired up
        expect(orb1a.detailCalls, isEmpty);

        // The orb respawns: same port, new password (last log line wins).
        password = 'pw2';
        await swallow(() => composite.getDetail('ses_orb'));

        expect(orb1b.detailCalls, ['ses_orb']);
        expect(orb1a.detailCalls, isEmpty);
      },
    );

    test(
      'a stopped orb drops its upstream; its sessions route to the host',
      () async {
        final host = FakeService(sessions: [hostSession]);
        final orb1 = FakeService(sessions: [orbSession]);
        final orbs = [runningOrb('orb1')];
        final composite = makeComposite(
          host: host,
          orbs: () async => orbs,
          passwords: (_) async => 'pw1',
          upstreams: {'http://127.0.0.1:41234|pw1': orb1},
        );
        await composite.listSessions();
        await swallow(() => composite.getDetail('ses_orb'));
        expect(orb1.detailCalls, ['ses_orb']);

        // The orb stops.
        orbs.clear();
        await swallow(() => composite.getDetail('ses_orb'));

        expect(host.detailCalls, ['ses_orb']);
      },
    );
  });

  group('CompositeOpencodeService host-only surface', () {
    test(
      'projects, creation, registries, and global commands go to the host',
      () async {
        final host = FakeService(sessions: [hostSession]);
        final orb1 = FakeService(sessions: [orbSession]);
        final composite = makeComposite(
          host: host,
          orbs: () async => [runningOrb('orb1')],
          passwords: (_) async => 'pw1',
          upstreams: {'http://127.0.0.1:41234|pw1': orb1},
        );
        await composite.listSessions();

        await composite.projects();
        await swallow(() => composite.createSession('p1'));
        await swallow(() => composite.createSessionInDirectory('/dir'));
        await composite.listModels();
        await composite.listAgents();
        await composite.listSkills();
        await composite.listCommands();
        await composite.usage();

        expect(host.projectsCalls, 1);
        expect(host.createCalls, 1);
        expect(host.createInCalls, 1);
        expect(host.modelsCalls, 1);
        expect(host.agentsCalls, 1);
        expect(host.skillsCalls, 1);
        expect(host.commandsCalls, 1);
        expect(host.usageCalls, 1);
        expect(orb1.projectsCalls, 0);
        expect(orb1.createCalls, 0);
        expect(orb1.modelsCalls, 0);
      },
    );
  });
}
