import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/access_session.dart';
import 'package:opencodebridge/access/token_store.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/client/fs_client.dart';
import 'package:opencodebridge/client/orbs_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/orb.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/ui/sessions_tab.dart';
import 'package:opencodebridge/ui/structured_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _one = Session(
  id: 'ses_1',
  title: 'fix the flaky test',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 100,
  location: '/code/app',
  active: false,
);
const _two = Session(
  id: 'ses_2',
  title: 'refactor auth',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 300,
  location: '/code/app',
  active: true,
);
const _three = Session(
  id: 'ses_3',
  title: 'docker logs',
  project: SessionProject(id: 'p2', name: 'infra'),
  created: 200,
  location: '/code/infra',
  active: false,
);
const _four = Session(
  id: 'ses_4',
  title: 'new from the app',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 400,
  location: '/code/app',
  active: false,
);

/// A session living on a running orb (spec §9.2): the row wears its orb's
/// chip.
const _orbOne = Session(
  id: 'ses_orb1',
  title: 'working in the orb',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 100,
  location: '/code/app',
  active: false,
  orb: 'orb_1',
);

/// A session living on a running orb (spec §9.2), built per call so each test
/// gets its own list (a `const` fixture would be canonicalised in the cache).
Session _orbSession() => Session(
  id: 'ses_orb1',
  title: 'working in the orb',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 100,
  location: '/code/app',
  active: false,
  orb: 'orb_1',
);

/// A scripted [SessionsClient] for the tab tests.
class _FakeSessionsClient extends SessionsClient {
  _FakeSessionsClient({this.rows = const []})
    : super(Uri.parse('http://bridge.test/'));

  /// The rows the client returns; delete mutates it, like a re-fetch would
  /// see.
  final List<Session> rows;

  Object? listError;
  Object? deleteError;
  Object? createError;
  Object? createDirectoryError;
  Object? moveError;

  final List<String> deleted = [];
  final List<String> created = [];
  final List<String> createdIn = [];
  final List<(String, String)> moved = [];
  final List<(String, String)> prompts = [];
  final List<(String, String, PermissionReply)> replies = [];
  var listCalls = 0;

  @override
  Future<List<Session>> list() async {
    listCalls++;
    final error = listError;
    if (error is Object) throw error;
    return rows;
  }

  @override
  Future<Session> create(String projectId) async {
    final error = createError;
    if (error is Object) throw error;
    created.add(projectId);
    final session = Session(
      id: 'ses_new',
      title: 'new from the app',
      project: SessionProject(id: projectId, name: 'app'),
      created: 500,
      location: '/code/app',
      active: false,
    );
    rows.insert(0, session);
    return session;
  }

  @override
  Future<Session> createInDirectory(String directory) async {
    final error = createDirectoryError;
    if (error is Object) throw error;
    createdIn.add(directory);
    final session = Session(
      id: 'ses_new_dir',
      title: 'new in $directory',
      project: SessionProject(id: 'p_dir', name: 'p_dir'),
      created: 500,
      location: directory,
      active: false,
    );
    rows.insert(0, session);
    return session;
  }

  @override
  Future<void> delete(String id) async {
    final error = deleteError;
    if (error is Object) throw error;
    deleted.add(id);
    rows.removeWhere((s) => s.id == id);
  }

  @override
  Future<void> moveToOrb(String id, String orbName) async {
    final error = moveError;
    if (error is Object) throw error;
    moved.add((id, orbName));
  }

  @override
  Future<SessionDetail> getDetail(String id) async => SessionDetail(
    id: id,
    title: 'detail',
    location: '/detail',
    cost: 0.01,
    tokens: TokenUsage(
      input: 1,
      output: 2,
      reasoning: 0,
      cacheRead: 0,
      cacheWrite: 0,
    ),
    outcome: null,
  );

  @override
  Future<List<SessionMessage>> getMessages(String id) async => const [
    SessionMessage(role: 'user', text: 'hello'),
  ];

  @override
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) async {
    return const MessagePage(
      messages: [SessionMessage(role: 'user', text: 'hello')],
      nextCursor: null,
    );
  }

  @override
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async {
    prompts.add((id, text));
  }

  @override
  Future<List<PermissionRequest>> getPermissions(String id) async => const [];

  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {
    replies.add((id, requestID, reply));
  }

  @override
  Future<List<QuestionForm>> getQuestions(String id) async => const [];

  @override
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) async {}

  @override
  Future<void> dismissQuestion(String id, String formID) async {}
}

/// A scripted [FsClient] for the tab tests (no real bridge).
class _FakeFsClient extends FsClient {
  _FakeFsClient({
    this.drivesResult = const [],
    this.subdirectoriesResult = const {},
  }) : super(Uri.parse('http://bridge.test/'));

  /// The drives (the picker's top level).
  final List<String> drivesResult;

  /// The subdirectories, keyed by the directory asked for.
  final Map<String, List<String>> subdirectoriesResult;

  Object? drivesError;
  Object? subdirectoriesError;
  Object? createDirectoryError;

  var drivesCalls = 0;
  final List<String> subdirectoriesCalls = [];
  final List<String> createdDirectories = [];

  @override
  Future<List<String>> drives() async {
    drivesCalls++;
    final error = drivesError;
    if (error is Object) throw error;
    return drivesResult;
  }

  @override
  Future<List<String>> subdirectories(String path) async {
    subdirectoriesCalls.add(path);
    final error = subdirectoriesError;
    if (error is Object) throw error;
    return subdirectoriesResult[path] ?? const [];
  }

  @override
  Future<void> createDirectory(String path) async {
    final error = createDirectoryError;
    if (error is Object) throw error;
    createdDirectories.add(path);
  }
}

/// A scripted [EventSource] for the tab tests (no real SSE connection).
class _FakeEventsSource implements EventSource {
  final _controller = StreamController<BridgeEvent>.broadcast();
  final _gaps = StreamController<SessionGap>.broadcast();

  @override
  Stream<BridgeEvent> get events => _controller.stream;

  @override
  Stream<SessionGap> get gaps => _gaps.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {
    await _controller.close();
    await _gaps.close();
  }

  /// Emits a bridge event on the stream frontier (the tab's own list
  /// subscription and the detail pane's both hear it).
  void emit(BridgeEvent event) => _controller.add(event);

  /// How often the tab forced a fresh connection (issue #41, foreground).
  var reconnectCalls = 0;

  @override
  Future<void> reconnect() async {
    reconnectCalls++;
  }
}

Future<_FakeSessionsClient> _pumpTab(
  WidgetTester tester, {
  List<Session> rows = const [],
  _FakeEventsSource? events,
  AccessSession? access,
  _FakeFsClient? fs,
  _FakeOrbsClient? orbs,
  ValueChanged<String>? onOrbChipTapped,
  String? deepLinkSession,
  VoidCallback? onDeepLinkSessionConsumed,
  FutureOr<void> Function()? onOpenSettings,
}) async {
  final client = _FakeSessionsClient(rows: List<Session>.of(rows));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SessionsTab(
          apiBase: Uri.parse('http://bridge.test/'),
          client: client,
          fs: fs ?? _FakeFsClient(),
          orbs: orbs ?? _FakeOrbsClient(),
          events: events ?? _FakeEventsSource(),
          access: access,
          onOrbChipTapped: onOrbChipTapped,
          deepLinkSession: deepLinkSession,
          onDeepLinkSessionConsumed: onDeepLinkSessionConsumed,
          onOpenSettings: onOpenSettings,
        ),
      ),
    ),
  );
  await tester.pump();
  return client;
}

/// A scripted [OrbsClient] for the tab tests (no real bridge).
class _FakeOrbsClient extends OrbsClient {
  _FakeOrbsClient({this.orbs = const []})
    : super(Uri.parse('http://bridge.test/'));

  final List<OrbRecord> orbs;
  Object? listError;
  var listCalls = 0;

  /// The (issue #98) workspace-export script: the path [export] answers
  /// with, an error to throw, and a gate to hold the call in flight.
  String exportResult = '/code/app/api-orb-20250101-000000UTC.tar.gz';
  Object? exportError;
  final List<String> exported = [];

  @override
  Future<List<OrbRecord>> list({bool includePr = false}) async {
    listCalls++;
    final error = listError;
    if (error is Object) throw error;
    return orbs;
  }

  @override
  Future<String> export(String id) async {
    exported.add(id);
    final error = exportError;
    if (error is Object) throw error;
    return exportResult;
  }
}

void main() {
  group('SessionsTab', () {
    group('home list', () {
      testWidgets(
        'every session sits in its project group, newest first, no captions',
        (tester) async {
          await _pumpTab(
            tester,
            rows: [_four, _two, _three, _one], // newest first, as delivered
          );

          // Project sections, newest activity first, with counts.
          expect(find.byKey(const ValueKey('project-p1')), findsOneWidget);
          expect(find.byKey(const ValueKey('project-p2')), findsOneWidget);
          expect(find.text('app'), findsOneWidget);
          expect(find.text('infra'), findsOneWidget);
          expect(find.text('3 sessions'), findsOneWidget);
          expect(find.text('1 session'), findsOneWidget);

          // Within the app group: newest first.
          final four = tester
              .getTopLeft(find.byKey(const ValueKey('session-ses_4')))
              .dy;
          final one = tester
              .getTopLeft(find.byKey(const ValueKey('session-ses_1')))
              .dy;
          expect(four, lessThan(one));

          // Every session row and its location are visible.
          expect(find.text('new from the app'), findsOneWidget);
          expect(find.text('refactor auth'), findsOneWidget);
          expect(find.text('fix the flaky test'), findsOneWidget);
          expect(find.text('docker logs'), findsOneWidget);
          expect(find.text('/code/infra'), findsOneWidget);

          // No "App-launched" captions anywhere.
          expect(find.textContaining('App-launched'), findsNothing);

          // Each group carries its own New session action.
          expect(find.byKey(const ValueKey('session-new-p1')), findsOneWidget);
          expect(find.byKey(const ValueKey('session-new-p2')), findsOneWidget);
        },
      );

      testWidgets('no Closed section: closed rows sit in their project group', (
        tester,
      ) async {
        await _pumpTab(tester, rows: [_two, _three]);

        expect(find.byKey(const ValueKey('closed-section')), findsNothing);
        expect(find.byKey(const ValueKey('session-ses_2')), findsOneWidget);
        expect(find.textContaining('App-launched'), findsNothing);
      });

      testWidgets('shows the active indicator only on active sessions', (
        tester,
      ) async {
        await _pumpTab(tester, rows: [_two, _one]);
        expect(find.byKey(const ValueKey('active-ses_2')), findsOneWidget);
        expect(find.byKey(const ValueKey('active-ses_1')), findsNothing);
      });
    });

    group('new project (issue #54)', () {
      testWidgets('browse the drives, create here, open the structured view', (
        tester,
      ) async {
        final fs = _FakeFsClient(
          drivesResult: const ['/proj'],
          subdirectoriesResult: const {
            '/proj': ['/proj/one'],
          },
        );
        final client = await _pumpTab(tester, fs: fs);

        await tester.tap(find.byKey(const ValueKey('sessions-new')));
        await tester.pumpAndSettle();

        // The dialog opens at the drives level, fed by GET /api/fs/drives.
        expect(
          find.byKey(const ValueKey('new-project-dialog')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('dir-/proj')), findsOneWidget);
        expect(fs.drivesCalls, 1);

        // Descend one level into the drive.
        await tester.tap(find.byKey(const ValueKey('dir-/proj')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('dir-/proj/one')), findsOneWidget);
        expect(fs.subdirectoriesCalls, ['/proj']);

        // "Create here" creates at the directory on screen; the
        // structured view opens on the new session in the detail pane.
        await tester.tap(find.byKey(const ValueKey('new-project-create')));
        await tester.pumpAndSettle();

        expect(client.createdIn, ['/proj']);
        expect(find.byType(StructuredSessionScreen), findsNothing);
        expect(find.byType(StructuredSessionPanel), findsOneWidget);
        expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('session-ses_new_dir')),
          findsOneWidget,
        );
      });

      testWidgets(
        'a group\'s New session button creates in its project, no dialog',
        (tester) async {
          final client = await _pumpTab(tester, rows: [_one]);

          await tester.tap(find.byKey(const ValueKey('session-new-p1')));
          await tester.pumpAndSettle();

          // No dialog: created straight in the group's project, and the
          // structured view opens on the new session in the detail pane.
          expect(
            find.byKey(const ValueKey('new-project-dialog')),
            findsNothing,
          );
          expect(client.created, ['p1']);
          expect(find.byType(StructuredSessionScreen), findsNothing);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
          expect(find.byKey(const ValueKey('session-ses_new')), findsOneWidget);
        },
      );

      testWidgets('canceling the dialog creates nothing', (tester) async {
        final fs = _FakeFsClient(drivesResult: const ['/proj']);
        final client = await _pumpTab(tester, fs: fs);

        await tester.tap(find.byKey(const ValueKey('sessions-new')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(client.createdIn, isEmpty);
        expect(client.created, isEmpty);
        expect(find.byKey(const ValueKey('new-project-dialog')), findsNothing);
      });

      testWidgets('a create failure shows a snackbar and no view', (
        tester,
      ) async {
        final fs = _FakeFsClient(drivesResult: const ['/proj']);
        final client = await _pumpTab(tester, fs: fs);
        client.createDirectoryError = const SessionsClientError(
          404,
          'no such directory',
        );

        await tester.tap(find.byKey(const ValueKey('sessions-new')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('dir-/proj')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('new-project-create')));
        await tester.pumpAndSettle();

        expect(client.createdIn, isEmpty);
        expect(
          find.textContaining('Could not create the project'),
          findsOneWidget,
        );
        expect(find.byType(StructuredSessionScreen), findsNothing);
      });
    });

    group('row taps', () {
      testWidgets(
        'tapping a row shows its structured view in the right pane and the '
        'list stays visible (issue #131)',
        (tester) async {
          await _pumpTab(tester, rows: [_four]);

          // No session selected yet: the empty-state hint is shown.
          expect(
            find.byKey(const ValueKey('sessions-detail-empty')),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const ValueKey('session-ses_4')));
          await tester.pumpAndSettle();

          // The detail opens in the pane (no navigator push); the list stays.
          expect(find.byType(StructuredSessionScreen), findsNothing);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
          expect(
            find.byKey(const ValueKey('sessions-detail-empty')),
            findsNothing,
          );
          // The session row is still visible in the list.
          expect(find.byKey(const ValueKey('session-ses_4')), findsOneWidget);
        },
      );

      testWidgets(
        'tapping an external row shows the history, cost bar, and prompt in '
        'the pane (issue #131)',
        (tester) async {
          await _pumpTab(tester, rows: [_one, _three]);

          await tester.tap(find.byKey(const ValueKey('session-ses_1')));
          await tester.pumpAndSettle();

          // The structured view shows the history, the cost bar, and the
          // always-enabled prompt input — in the pane, no navigator route.
          expect(find.byType(StructuredSessionScreen), findsNothing);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(find.text('You'), findsOneWidget);
          expect(find.text('hello'), findsOneWidget);
          expect(find.text('Cost \$0.0100'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('structured-prompt-input')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('structured-prompt-send')),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
        },
      );

      testWidgets(
        'selecting another session swaps the detail pane in place, no push/pop '
        '(issue #131)',
        (tester) async {
          await _pumpTab(tester, rows: [_one, _three]);

          await tester.tap(find.byKey(const ValueKey('session-ses_1')));
          await tester.pumpAndSettle();
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          // The panel shows ses_1's title in its header.
          expect(find.text('fix the flaky test'), findsWidgets);

          // Select a different session: the pane swaps in place.
          await tester.tap(find.byKey(const ValueKey('session-ses_3')));
          await tester.pumpAndSettle();

          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(find.byType(StructuredSessionScreen), findsNothing);
          expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
          // The pane now shows ses_3's title.
          expect(find.text('docker logs'), findsWidgets);
          // The list still shows both rows.
          expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
          expect(find.byKey(const ValueKey('session-ses_3')), findsOneWidget);
        },
      );
    });

    group('delete', () {
      testWidgets('delete a session created from the app', (tester) async {
        final client = await _pumpTab(tester, rows: [_four, _one]);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_4')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete session…'));
        await tester.pumpAndSettle();

        // No terminal window is involved any more.
        expect(find.textContaining('terminal window'), findsNothing);

        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(client.deleted, ['ses_4']);
        expect(find.byKey(const ValueKey('session-ses_4')), findsNothing);
        expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
      });

      testWidgets('delete: confirm removes the session and refreshes', (
        tester,
      ) async {
        final client = await _pumpTab(tester, rows: [_two, _one]);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete session…'));
        await tester.pumpAndSettle();

        // No terminal window is mentioned for any session.
        expect(
          find.textContaining('terminal window will be closed'),
          findsNothing,
        );

        // Confirm.
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(client.deleted, ['ses_1']);
        expect(find.byKey(const ValueKey('session-ses_1')), findsNothing);
        expect(find.byKey(const ValueKey('session-ses_2')), findsOneWidget);
      });

      testWidgets('delete: cancel keeps the session', (tester) async {
        final client = await _pumpTab(tester, rows: [_two, _one]);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete session…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(client.deleted, isEmpty);
        expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
      });

      testWidgets('a failed delete shows a snackbar and keeps the row', (
        tester,
      ) async {
        final client = await _pumpTab(tester, rows: [_two, _one]);
        client.deleteError = const SessionsClientError(500, 'boom');

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete session…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(client.deleted, isEmpty);
        expect(
          find.textContaining('Could not delete the session'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
      });
    });

    group('move to orb (issue #97)', () {
      testWidgets('a host row offers Move to orb…; an orb row does not', (
        tester,
      ) async {
        await _pumpTab(tester, rows: [_one, _orbOne]);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.text('Move to orb…'), findsOneWidget);
        expect(find.text('Delete session…'), findsOneWidget);
        // A tap outside the menu closes it (the barrier).
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_orb1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.text('Move to orb…'), findsNothing);
        expect(find.text('Delete session…'), findsOneWidget);
      });

      testWidgets(
        'naming the target moves the session, refreshes and reports',
        (tester) async {
          final client = await _pumpTab(tester, rows: [_one]);

          await tester.tap(
            find.byKey(const ValueKey('menu-ses_1')),
            warnIfMissed: false,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Move to orb…'));
          await tester.pumpAndSettle();
          expect(find.text('Move to an orb?'), findsOneWidget);

          await tester.enterText(
            find.byKey(const ValueKey('move-to-orb-name')),
            'dev',
          );
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('move-to-orb-confirm')));
          await tester.pumpAndSettle();

          expect(client.moved, [('ses_1', 'dev')]);
          expect(client.listCalls, greaterThanOrEqualTo(2));
          expect(find.text('Session moved to the orb "dev".'), findsOneWidget);
        },
      );

      testWidgets('cancelling the name prompt moves nothing', (tester) async {
        final client = await _pumpTab(tester, rows: [_one]);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move to orb…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(client.moved, isEmpty);
        expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
      });

      testWidgets('an empty name is not a confirmation', (tester) async {
        final client = await _pumpTab(tester, rows: [_one]);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move to orb…'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('move-to-orb-confirm')));
        await tester.pump();

        // The prompt stays open; nothing was sent.
        expect(find.text('Move to an orb?'), findsOneWidget);
        expect(client.moved, isEmpty);
      });

      testWidgets('a failed move shows the decoded error and keeps the row', (
        tester,
      ) async {
        final client = await _pumpTab(tester, rows: [_one]);
        client.moveError = const SessionsClientError(
          502,
          'exit 1: import conflict',
        );

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move to orb…'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('move-to-orb-name')),
          'dev',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('move-to-orb-confirm')));
        await tester.pumpAndSettle();

        expect(client.moved, isEmpty);
        expect(
          find.text('Could not move the session: exit 1: import conflict'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
      });
    });

    group('states', () {
      testWidgets('an unreachable bridge shows the error with a retry', (
        tester,
      ) async {
        final client = _FakeSessionsClient(rows: const []);
        client.listError = const SessionsClientError(0, 'refused');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SessionsTab(
                apiBase: Uri.parse('http://bridge.test/'),
                client: client,
                events: _FakeEventsSource(),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Cannot reach the bridge.'), findsOneWidget);

        // The bridge comes back; retry loads the list.
        client.listError = null;
        await tester.tap(find.byKey(const ValueKey('sessions-retry')));
        await tester.pumpAndSettle();
        expect(client.listCalls, 2);
        expect(find.text('No sessions yet.'), findsOneWidget);
      });

      testWidgets('an empty list says there are no sessions', (tester) async {
        await _pumpTab(tester);
        expect(find.text('No sessions yet.'), findsOneWidget);
        expect(find.byKey(const ValueKey('sessions-new')), findsOneWidget);
      });

      testWidgets('without a bridge, points at Settings', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SessionsTab(apiBase: null))),
        );
        await tester.pump();
        expect(
          find.text('No bridge configured. Set the tunnel URL in Settings.'),
          findsOneWidget,
        );
      });
    });

    group('foreground return (issue #41)', () {
      testWidgets('resumed re-connects events and re-fetches the list', (
        tester,
      ) async {
        final events = _FakeEventsSource();
        final client = await _pumpTab(tester, rows: [_one], events: events);
        expect(client.listCalls, 1);
        expect(events.reconnectCalls, 0);

        // Android suspends the app and brings it back to the foreground.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        expect(events.reconnectCalls, 1);
        expect(client.listCalls, 2);
      });
    });

    group('access login completion (issue #41)', () {
      testWidgets('the login finishing re-fetches the list and the events', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final store = await AccessTokenStore.load();
        final access = AccessSession(
          tunnelBase: () => Uri.parse('https://tunnel.test/'),
          store: store,
        );
        final events = _FakeEventsSource();
        final client = await _pumpTab(
          tester,
          rows: [_one],
          events: events,
          access: access,
        );
        expect(client.listCalls, 1);

        // The browser bounce brought the app to the foreground before the
        // token exchange finished (the resumed re-fetch saw a 401); the
        // login completes now: the tab goes out again with the token.
        store.save(
          'tunnel.test',
          AccessLoginRecord(
            clientId: 'c1',
            accessToken: 'tok',
            refreshToken: 'rtok',
            accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        );
        await access.restore();
        await tester.pump();

        expect(client.listCalls, 2);
        expect(events.reconnectCalls, 1);
      });
    });

    group('two-pane deep link and settings (issue #131)', () {
      testWidgets(
        'a deep link selects the targeted session in the detail pane',
        (tester) async {
          final client = _FakeSessionsClient(rows: [_one, _three]);
          final fs = _FakeFsClient();
          final orbs = _FakeOrbsClient();
          final events = _FakeEventsSource();
          var consumed = 0;
          Future<void> pump(String? target) => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SessionsTab(
                  key: const ValueKey('sessions-tab'),
                  apiBase: Uri.parse('http://bridge.test/'),
                  client: client,
                  fs: fs,
                  orbs: orbs,
                  events: events,
                  deepLinkSession: target,
                  onDeepLinkSessionConsumed: () => consumed++,
                ),
              ),
            ),
          );

          await pump(null);
          await tester.pump();

          await pump('ses_3');
          await tester.pumpAndSettle();

          expect(consumed, 1);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
          expect(find.byType(StructuredSessionScreen), findsNothing);
          expect(find.text('docker logs'), findsWidgets);
        },
      );

      testWidgets('onOpenSettings is wired through to the detail pane', (
        tester,
      ) async {
        var opened = 0;
        await _pumpTab(tester, rows: [_one], onOpenSettings: () => opened++);

        await tester.tap(find.byKey(const ValueKey('session-ses_1')));
        await tester.pumpAndSettle();

        // The panel is rendered with the onOpenSettings callback. Invoke the
        // /settings path by typing the command (the panel's slash command
        // flow: close then open settings).
        final prompt = find.byKey(const ValueKey('structured-prompt-input'));
        expect(prompt, findsOneWidget);
        await tester.enterText(prompt, '/settings');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(opened, 1);
        // /settings closes the detail view (deselects) then opens settings.
        expect(
          find.byKey(const ValueKey('sessions-detail-empty')),
          findsOneWidget,
        );
      });
    });

    group('orb chip and host label (spec §9.2)', () {
      const orb = OrbRecord(
        id: 'orb_1',
        name: 'api-orb',
        project: 'p1',
        branch: 'orb/orb_1',
        state: 'running',
        created: '2025-01-01T00:00:00Z',
      );

      testWidgets('an orb session row wears a chip with the orb name', (
        tester,
      ) async {
        await _pumpTab(
          tester,
          rows: [_orbOne],
          orbs: _FakeOrbsClient(orbs: [orb]),
        );

        expect(find.byKey(const ValueKey('orb-chip-orb_1')), findsOneWidget);
        expect(find.text('api-orb'), findsOneWidget);
      });

      testWidgets('a host session row wears a muted host label, no chip', (
        tester,
      ) async {
        await _pumpTab(
          tester,
          rows: [_one],
          orbs: _FakeOrbsClient(orbs: [orb]),
        );

        expect(find.byKey(const ValueKey('host-ses_1')), findsOneWidget);
        expect(find.text('host'), findsOneWidget);
        expect(find.byKey(const ValueKey('orb-chip-ses_1')), findsNothing);
      });

      testWidgets(
        'tapping the chip reports the orb id and does not open the row',
        (tester) async {
          final tapped = <String>[];
          await _pumpTab(
            tester,
            rows: [_orbOne],
            orbs: _FakeOrbsClient(orbs: [orb]),
            onOrbChipTapped: tapped.add,
          );

          await tester.tap(find.byKey(const ValueKey('orb-chip-orb_1')));
          await tester.pump();

          expect(tapped, ['orb_1']);
          // The chip swallows the tap: the structured view did not open.
          expect(find.text('working in the orb'), findsOneWidget);
        },
      );

      testWidgets('a chip falls back to the orb id when the orb is gone', (
        tester,
      ) async {
        await _pumpTab(tester, rows: [_orbOne], orbs: _FakeOrbsClient());

        expect(find.byKey(const ValueKey('orb-chip-orb_1')), findsOneWidget);
        expect(find.text('orb_1'), findsOneWidget);
      });

      testWidgets('a failed orb list degrades to the id, rows stay', (
        tester,
      ) async {
        final orbs = _FakeOrbsClient();
        orbs.listError = OrbsClientError(0, 'no bridge');
        await _pumpTab(tester, rows: [_orbOne], orbs: orbs);

        expect(find.text('working in the orb'), findsOneWidget);
        expect(find.byKey(const ValueKey('orb-chip-orb_1')), findsOneWidget);
        expect(find.text('orb_1'), findsOneWidget);
      });
    });

    group('workspace export (issue #98)', () {
      testWidgets('an orb row offers Export workspace…; a host row does not', (
        tester,
      ) async {
        await _pumpTab(tester, rows: [_one, _orbOne]);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_orb1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.text('Export workspace…'), findsOneWidget);
        expect(find.text('Delete session…'), findsOneWidget);
        // A tap outside the menu closes it (the barrier).
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.text('Export workspace…'), findsNothing);
        expect(find.text('Delete session…'), findsOneWidget);
      });

      testWidgets('exporting exports the orb, reports the path, and clears', (
        tester,
      ) async {
        final orbs = _FakeOrbsClient();
        orbs.exportResult = '/code/app/api-orb-20261106-101500UTC.tar.gz';
        await _pumpTab(tester, rows: [_orbOne], orbs: orbs);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_orb1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Export workspace…'));
        await tester.pumpAndSettle();

        expect(orbs.exported, ['orb_1']);
        expect(
          find.text(
            'Workspace exported to /code/app/api-orb-20261106-101500UTC.tar.gz.',
          ),
          findsOneWidget,
        );
        // The row's spinner is gone once the export lands.
        expect(find.byKey(const ValueKey('session-ses_orb1')), findsOneWidget);
      });

      testWidgets('a failed export reports the decoded wire error', (
        tester,
      ) async {
        final orbs = _FakeOrbsClient();
        orbs.exportError = const OrbCreateError(
          statusCode: 400,
          code: 'missing_checkout',
          details: 'no local clone for project p1',
        );
        await _pumpTab(tester, rows: [_orbOne], orbs: orbs);

        await tester.tap(
          find.byKey(const ValueKey('menu-ses_orb1')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Export workspace…'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Could not export the workspace: no local clone for project p1',
          ),
          findsOneWidget,
        );
      });
    });

    group('live session list (the unified event stream)', () {
      /// An opencode event as the bridge fans it out: the durable aggregate id
      /// is the session id (the shape every session-scoped event carries).
      BridgeEvent session(
        String type,
        String sessionId, {
        Map<String, Object?> data = const {},
      }) => BridgeEvent(
        id: 'evt_$type',
        created: 0,
        type: type,
        data: data,
        durable: Durable(aggregateID: sessionId, seq: 1),
      );

      testWidgets(
        'a session created on an orb appears without any user action',
        (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(tester, rows: [_one], events: events);
          expect(client.listCalls, 1);
          expect(find.text('working in the orb'), findsNothing);

          // The agent spawned an orb: the bridge's unified stream now carries the
          // new session on the orb's service.
          client.rows.insert(0, _orbSession());
          events.emit(session('session.created', 'ses_orb1'));
          await tester.pumpAndSettle();

          expect(client.listCalls, 2);
          expect(find.text('working in the orb'), findsOneWidget);
        },
      );

      testWidgets(
        'the title the agent assigns lands in the list (session.renamed)',
        (tester) async {
          const untitled = Session(
            id: 'ses_new',
            title: '',
            project: SessionProject(id: 'p1', name: 'app'),
            created: 500,
            location: '/code/app',
            active: false,
          );
          final events = _FakeEventsSource();
          final client = await _pumpTab(
            tester,
            rows: [untitled],
            events: events,
          );
          expect(client.listCalls, 1);
          // A just-created session has no title yet: its directory stands in,
          // rather than a blank row.
          expect(find.text('/code/app'), findsWidgets);

          client.rows[0] = untitled.copyWith(title: 'fix the flaky test');
          events.emit(
            session(
              'session.renamed',
              'ses_new',
              data: {'title': 'fix the flaky test'},
            ),
          );
          await tester.pumpAndSettle();

          // Patched in place: no refetch needed to show the agent's title.
          expect(client.listCalls, 1);
          expect(find.text('fix the flaky test'), findsOneWidget);
        },
      );

      testWidgets('a burst of session events coalesces into one reload', (
        tester,
      ) async {
        final events = _FakeEventsSource();
        final client = await _pumpTab(tester, rows: [_one], events: events);
        expect(client.listCalls, 1);

        client.rows.insert(0, _orbSession());
        events
          ..emit(session('session.created', 'ses_orb1'))
          ..emit(
            session(
              'session.renamed',
              'ses_orb1',
              data: {'title': 'working in the orb'},
            ),
          )
          ..emit(session('session.execution.started', 'ses_orb1'));
        await tester.pumpAndSettle();

        expect(client.listCalls, 2);
        expect(find.text('working in the orb'), findsOneWidget);
      });

      testWidgets('the turn boundaries move the row active dot in place', (
        tester,
      ) async {
        final events = _FakeEventsSource();
        final client = await _pumpTab(tester, rows: [_one], events: events);
        expect(find.byKey(const ValueKey('active-ses_1')), findsNothing);

        events.emit(session('session.execution.started', 'ses_1'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('active-ses_1')), findsOneWidget);

        events.emit(session('session.execution.succeeded', 'ses_1'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('active-ses_1')), findsNothing);
        expect(client.listCalls, 1);
      });

      testWidgets('a bridge session.closed drops the row', (tester) async {
        final events = _FakeEventsSource();
        final client = await _pumpTab(
          tester,
          rows: [_one, _three],
          events: events,
        );
        expect(find.text('fix the flaky test'), findsOneWidget);

        client.rows.removeWhere((row) => row.id == 'ses_1');
        events.emit(
          const BridgeEvent(
            id: 'evt_closed',
            created: 0,
            type: 'session.closed',
            data: {'sessionID': 'ses_1'},
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('fix the flaky test'), findsNothing);
        expect(find.text('docker logs'), findsOneWidget);
      });
    });
  });
}
