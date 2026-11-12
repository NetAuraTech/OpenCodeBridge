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
import 'package:opencodebridge/settings/app_settings.dart';
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

  /// The cancel calls (`cancel`), in order (issue #165's row Stop).
  final List<String> cancelled = [];

  /// When set, `cancel` throws it (the failure the row Stop reports).
  Object? cancelError;

  /// When set, `cancel` awaits it before returning (the cancel held in flight,
  /// to sequence it against the row's busy state).
  Completer<void>? cancelGate;

  @override
  Future<List<Session>> list() async {
    listCalls++;
    final error = listError;
    if (error is Object) throw error;
    return rows;
  }

  @override
  Future<void> cancel(String id) async {
    final gate = cancelGate;
    if (gate != null) await gate.future;
    cancelled.add(id);
    final error = cancelError;
    if (error is Object) throw error;
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

  /// The pending permission requests / question forms [getPermissions] and
  /// [getQuestions] answer (the waiting dot's source, issue #209); the tab
  /// re-derives a row's waiting fact from these on the permission/question
  /// events, the same endpoints the structured view consumes.
  List<PermissionRequest> permissionsResult = const [];
  List<QuestionForm> questionsResult = const [];

  @override
  Future<List<PermissionRequest>> getPermissions(String id) async =>
      permissionsResult;

  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {
    replies.add((id, requestID, reply));
  }

  @override
  Future<List<QuestionForm>> getQuestions(String id) async => questionsResult;

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
  AppSettings? settings,
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
          settings: settings,
        ),
      ),
    ),
  );
  await tester.pump();
  return client;
}

/// Pumps the tab on a narrow (phone-sized) surface (issue #133), below the
/// responsive breakpoint, and returns the client. The surface is reset by the
/// caller's `addTearDown(tester.view.reset)` — a bare `reset()` (no argument)
/// is safe whether or not the surface was actually changed.
Future<_FakeSessionsClient> _pumpTabNarrow(
  WidgetTester tester, {
  Size surfaceSize = const Size(390, 844),
  List<Session> rows = const [],
  _FakeEventsSource? events,
  _FakeFsClient? fs,
  _FakeOrbsClient? orbs,
  String? deepLinkSession,
  AppSettings? settings,
}) async {
  final client = _FakeSessionsClient(rows: List<Session>.of(rows));
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SessionsTab(
          apiBase: Uri.parse('http://bridge.test/'),
          client: client,
          fs: fs ?? _FakeFsClient(),
          orbs: orbs ?? _FakeOrbsClient(),
          events: events ?? _FakeEventsSource(),
          deepLinkSession: deepLinkSession,
          settings: settings,
        ),
      ),
    ),
  );
  await tester.pump();
  return client;
}

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

          // Project sections, newest activity first, with counts. p1 has an
          // active session (_two), so its count carries the active suffix
          // (issue #207); p2 has none, so it stays the bare count.
          expect(find.byKey(const ValueKey('project-p1')), findsOneWidget);
          expect(find.byKey(const ValueKey('project-p2')), findsOneWidget);
          expect(find.text('app'), findsOneWidget);
          expect(find.text('infra'), findsOneWidget);
          expect(find.text('3 sessions (1 active)'), findsOneWidget);
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
          // The prompt bar's action is now the Stop control (issue #199):
          // always visible in the Send button's old position (the header's
          // Stop is gone).
          expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
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

    group('collapsible sidebar (issue #132)', () {
      final toggle = find.byKey(const ValueKey('sessions-sidebar-toggle'));

      testWidgets(
        'the toggle collapses the sidebar; the detail takes the full width',
        (tester) async {
          await _pumpTab(tester, rows: [_one, _three]);
          await tester.tap(find.byKey(const ValueKey('session-ses_1')));
          await tester.pumpAndSettle();

          // Expanded: the sidebar occupies its column, the detail the rest.
          expect(
            find.byKey(const ValueKey('sessions-list-pane')),
            findsOneWidget,
          );
          final detailWidth = tester
              .getSize(find.byKey(const ValueKey('sessions-detail-pane')))
              .width;
          expect(detailWidth, lessThan(800));

          await tester.tap(toggle);
          await tester.pumpAndSettle();

          // Collapsed: the sidebar is gone entirely, the detail is full width
          // (everything right of the toggle rail, to the window's edge).
          expect(
            find.byKey(const ValueKey('sessions-list-pane')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('sessions-list')), findsNothing);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          final detailRect = tester.getRect(
            find.byKey(const ValueKey('sessions-detail-pane')),
          );
          expect(detailRect.right, 800);
          expect(detailRect.left, tester.getRect(toggle).right);
          expect(toggle, findsOneWidget);
        },
      );

      testWidgets('when collapsed, only the toggle remains visible', (
        tester,
      ) async {
        const orb = OrbRecord(
          id: 'orb_1',
          name: 'api-orb',
          project: 'p1',
          branch: 'orb/orb_1',
          state: 'running',
          created: '2025-01-01T00:00:00Z',
        );
        await _pumpTab(
          tester,
          rows: [_two, _one, _orbOne],
          orbs: _FakeOrbsClient(orbs: [orb]),
        );

        await tester.tap(toggle);
        await tester.pumpAndSettle();

        // No list, no rows, no project groups, no New project button, no
        // icons rail, no status dots (active or orb chips) — only the toggle.
        expect(toggle, findsOneWidget);
        expect(find.byKey(const ValueKey('sessions-new')), findsNothing);
        expect(find.byKey(const ValueKey('project-p1')), findsNothing);
        expect(find.byKey(const ValueKey('session-ses_1')), findsNothing);
        expect(find.byKey(const ValueKey('session-ses_2')), findsNothing);
        expect(find.byKey(const ValueKey('active-ses_2')), findsNothing);
        expect(find.byKey(const ValueKey('orb-chip-orb_1')), findsNothing);
        expect(find.byKey(const ValueKey('host-ses_1')), findsNothing);
      });

      testWidgets('the toggle stays at the same spot in both states', (
        tester,
      ) async {
        await _pumpTab(tester, rows: [_one]);

        final expanded = tester.getTopLeft(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(toggle), expanded);

        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(toggle), expanded);
      });

      testWidgets(
        're-expanding restores the sidebar with the selection intact',
        (tester) async {
          await _pumpTab(tester, rows: [_one, _three]);
          await tester.tap(find.byKey(const ValueKey('session-ses_3')));
          await tester.pumpAndSettle();
          expect(find.byType(StructuredSessionPanel), findsOneWidget);

          await tester.tap(toggle);
          await tester.pumpAndSettle();
          // The detail is unaffected by the collapse.
          expect(find.byType(StructuredSessionPanel), findsOneWidget);

          await tester.tap(toggle);
          await tester.pumpAndSettle();

          // The sidebar is back; the selection never changed.
          expect(
            find.byKey(const ValueKey('sessions-list-pane')),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
          expect(find.byKey(const ValueKey('session-ses_3')), findsOneWidget);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(find.text('docker logs'), findsWidgets);
        },
      );

      testWidgets('the collapsed state survives a restart', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = await AppSettings.load();
        await _pumpTab(tester, rows: [_one], settings: settings);
        expect(
          find.byKey(const ValueKey('sessions-list-pane')),
          findsOneWidget,
        );

        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(settings.sessionsSidebarCollapsed, isTrue);

        // The next launch: a fresh tab over the same settings starts collapsed.
        await tester.pumpWidget(const SizedBox());
        await _pumpTab(tester, rows: [_one], settings: settings);
        expect(find.byKey(const ValueKey('sessions-list-pane')), findsNothing);
        expect(toggle, findsOneWidget);

        // Toggling open again persists the expanded state.
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('sessions-list-pane')),
          findsOneWidget,
        );
        expect(settings.sessionsSidebarCollapsed, isFalse);
      });
    });

    group('responsive drawer (issue #133)', () {
      final toggle = find.byKey(const ValueKey('sessions-sidebar-toggle'));
      final drawer = find.byKey(const ValueKey('sessions-drawer'));
      final scrim = find.byKey(const ValueKey('sessions-drawer-scrim'));
      final detailPane = find.byKey(const ValueKey('sessions-detail-pane'));
      final listPane = find.byKey(const ValueKey('sessions-list-pane'));

      testWidgets(
        'below the breakpoint the detail fills the screen and no persistent '
        'sidebar is shown',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await _pumpTabNarrow(tester, rows: [_one, _three]);

          // No persistent sidebar: the wide rail and list column are gone.
          expect(listPane, findsNothing);
          // No overlay drawer until opened: the list is not on screen yet.
          expect(drawer, findsNothing);
          expect(scrim, findsNothing);
          expect(find.byKey(const ValueKey('sessions-list')), findsNothing);

          // The detail fills the screen (no selection yet, so the empty hint),
          // flush to the left edge — nothing to the left of it.
          final detail = tester.getRect(detailPane);
          expect(detail.left, 0);
          expect(detail.right, 390);
          expect(
            find.byKey(const ValueKey('sessions-detail-empty')),
            findsOneWidget,
          );
          // The top bar carries the drawer's toggle.
          expect(toggle, findsOneWidget);
        },
      );

      testWidgets(
        'a toggle in the top bar opens the sidebar as an overlay drawer with '
        'a scrim',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await _pumpTabNarrow(tester, rows: [_one, _three]);

          // The toggle sits in the top bar, at the left edge.
          expect(tester.getTopLeft(toggle).dx, 0);

          await tester.tap(toggle);
          await tester.pumpAndSettle();

          // The drawer is up, from the left edge over the detail, and below
          // the top bar (which stays on top so the toggle is still reachable).
          final drawerRect = tester.getRect(drawer);
          expect(drawerRect.left, 0);
          expect(drawerRect.right, 320);
          expect(drawerRect.top, kToolbarHeight);
          // A scrim behind it (a tap target across the whole width, below the
          // top bar).
          expect(scrim, findsOneWidget);
          final scrimRect = tester.getRect(scrim);
          expect(scrimRect.left, 0);
          expect(scrimRect.top, kToolbarHeight);
          expect(scrimRect.right, 390);
          // The list (and its rows) is inside the drawer, not a persistent
          // column.
          expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
          expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
          expect(listPane, findsNothing);
          // The detail still fills the screen underneath (its left edge stays
          // at 0 — the drawer does not push it).
          expect(tester.getRect(detailPane).left, 0);
          expect(tester.getRect(detailPane).right, 390);
        },
      );

      testWidgets(
        'tapping outside the drawer closes it without changing the selected '
        'session',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await _pumpTabNarrow(tester, rows: [_one, _three]);

          // Select a session first (from the drawer).
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('session-ses_1')));
          await tester.pumpAndSettle();
          // The selection closed the drawer and shows the detail underneath.
          expect(drawer, findsNothing);
          expect(scrim, findsNothing);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(find.text('fix the flaky test'), findsWidgets);

          // Re-open the drawer and tap the scrim (the visible part, right of
          // the drawer): it closes, and the selection is untouched (the same
          // session's detail remains).
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(drawer, findsOneWidget);
          await tester.tapAt(const Offset(350, 400));
          await tester.pumpAndSettle();
          expect(drawer, findsNothing);
          expect(scrim, findsNothing);
          // Still on the session that was selected, not reset.
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(find.text('fix the flaky test'), findsWidgets);
        },
      );

      testWidgets('selecting a session in the drawer closes it and shows that '
          "session's detail underneath", (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await _pumpTabNarrow(tester, rows: [_one, _three]);

        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(drawer, findsOneWidget);

        // Pick a session from the drawer (the other project's session).
        await tester.tap(find.byKey(const ValueKey('session-ses_3')));
        await tester.pumpAndSettle();

        // The drawer is gone and the detail underneath shows that session.
        expect(drawer, findsNothing);
        expect(scrim, findsNothing);
        expect(find.byType(StructuredSessionPanel), findsOneWidget);
        expect(
          find.byKey(const ValueKey('sessions-detail-empty')),
          findsNothing,
        );
        expect(find.text('docker logs'), findsWidgets);
      });

      testWidgets(
        'the drawer toggle does not persist the wide-screen collapsed '
        'setting (it is transient)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final settings = await AppSettings.load();
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await _pumpTabNarrow(tester, rows: [_one], settings: settings);

          // Opening the drawer is an overlay action: it must not touch the
          // wide-screen collapse setting (which stays for wide layouts only).
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(settings.sessionsSidebarCollapsed, isFalse);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(settings.sessionsSidebarCollapsed, isFalse);
        },
      );

      testWidgets(
        'at a wide size the existing persistent collapsible layout is '
        'unchanged (no top bar, no drawer)',
        (tester) async {
          // The default 800x600 surface is wide. Re-assert the #131/#132
          // layout passes with the new breakpoint in place.
          await _pumpTab(tester, rows: [_one, _three]);
          await tester.tap(find.byKey(const ValueKey('session-ses_1')));
          await tester.pumpAndSettle();

          expect(listPane, findsOneWidget);
          expect(drawer, findsNothing);
          expect(scrim, findsNothing);
          // The detail sits right of the rail, not full width.
          final detail = tester.getRect(detailPane);
          expect(detail.left, greaterThan(0));
          expect(detail.right, 800);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);

          // The rail toggle still collapses the persistent sidebar.
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(listPane, findsNothing);
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(listPane, findsOneWidget);
        },
      );
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

      group('the row Stop (issue #165)', () {
        testWidgets('is offered only on the active row and cancels that '
            'session', (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(
            tester,
            rows: [_one, _two], // _two is active, _one idle
            events: events,
          );
          // The Stop control is offered on the active row only: present for
          // ses_2, absent for the idle ses_1.
          expect(find.byKey(const ValueKey('stop-ses_2')), findsOneWidget);
          expect(find.byKey(const ValueKey('stop-ses_1')), findsNothing);

          // Tapping it cancels the row's session (the bridge's cancel).
          await tester.tap(find.byKey(const ValueKey('stop-ses_2')));
          await tester.pump();
          await tester.pump();
          expect(client.cancelled, ['ses_2']);
        });

        testWidgets('clears the row dot on session.turn.cancelled, in place '
            '(no refetch)', (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(
            tester,
            rows: [_two], // active
            events: events,
          );
          expect(client.listCalls, 1);
          expect(find.byKey(const ValueKey('active-ses_2')), findsOneWidget);

          // A stop (from the row, the panel, or Escape) settles: the
          // bridge's cancelled-turn outcome clears the dot in place.
          events.emit(
            const BridgeEvent(
              id: 'evt_turn_cancelled',
              created: 0,
              type: 'session.turn.cancelled',
              data: {'sessionID': 'ses_2'},
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(find.byKey(const ValueKey('active-ses_2')), findsNothing);
          // The Stop goes with the dot (the row is no longer Active).
          expect(find.byKey(const ValueKey('stop-ses_2')), findsNothing);
          // In place: no list refetch happened.
          expect(client.listCalls, 1);
        });

        testWidgets('keeps the dot and offers Stop again on a failed '
            'cancel', (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(
            tester,
            rows: [_two], // active
            events: events,
          );
          expect(find.byKey(const ValueKey('stop-ses_2')), findsOneWidget);

          // The cancel fails (e.g. the service is down, a 502): the reason is
          // reported, the dot stays, and the Stop is offered again to retry.
          client.cancelError = const SessionsClientError(
            502,
            'opencode_unreachable',
          );
          await tester.tap(find.byKey(const ValueKey('stop-ses_2')));
          await tester.pump();
          await tester.pump();
          await tester.pump();
          expect(client.cancelled, ['ses_2']);
          expect(find.byKey(const ValueKey('stop-ses_2')), findsOneWidget);
          expect(find.byKey(const ValueKey('active-ses_2')), findsOneWidget);
        });
      });

      testWidgets(
        'a cancelled turn clears the row active dot in place (issue #164)',
        (tester) async {
          // The row is active (a running turn, started before the list load —
          // the common case: the panel has the session open and it is busy).
          final events = _FakeEventsSource();
          final client = await _pumpTab(tester, rows: [_two], events: events);
          expect(client.listCalls, 1);
          expect(find.byKey(const ValueKey('active-ses_2')), findsOneWidget);

          // The bridge-native cancel arrives (no durable seq; the session id
          // in data, like session.closed): the dot goes out in place, no
          // refetch.
          events.emit(
            const BridgeEvent(
              id: 'evt_cancelled',
              created: 0,
              type: 'session.turn.cancelled',
              data: {'sessionID': 'ses_2', 'messageID': 'msg_1'},
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('active-ses_2')), findsNothing);
          expect(client.listCalls, 1, reason: 'no refetch: patched in place');
        },
      );

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

    group('unread dot (issue #207)', () {
      BridgeEvent sessionEvent(
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
        'a turn ending while the session is not shown lights a violet unread '
        'dot in place, for every terminal (no list refetch)',
        (tester) async {
          Future<void> runFor(String terminal, {Session? active}) async {
            // A fresh tab per terminal: a bare `pumpWidget` would reuse the
            // previous State (same widget type at the same tree spot), so reset
            // the tree first to get a clean, in-memory instance.
            await tester.pumpWidget(const SizedBox());
            final events = _FakeEventsSource();
            final client = await _pumpTab(
              tester,
              rows: [active ?? _one],
              events: events,
            );
            expect(client.listCalls, 1);
            // Not shown in the detail pane yet: the empty-state hint.
            expect(
              find.byKey(const ValueKey('sessions-detail-empty')),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);

            events.emit(sessionEvent(terminal, 'ses_1'));
            await tester.pumpAndSettle();

            // The dot turned violet, in place: the detail pane still shows
            // the empty hint (nothing was opened), no list refetch happened.
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);
            expect(
              find.byKey(const ValueKey('sessions-detail-empty')),
              findsOneWidget,
            );
            expect(client.listCalls, 1, reason: 'patched in place, no refetch');
          }

          await runFor('session.execution.succeeded');
          await runFor('session.execution.failed');
          await runFor('session.execution.interrupted');
          await runFor(
            'session.turn.cancelled',
            active: _one.copyWith(active: true),
          );
        },
      );

      testWidgets(
        'a turn ending while the session is shown in the detail pane does not '
        'light the dot',
        (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(
            tester,
            rows: [_one, _three],
            events: events,
          );

          // Show ses_1 in the detail pane (watching it live).
          await tester.tap(find.byKey(const ValueKey('session-ses_1')));
          await tester.pumpAndSettle();
          expect(find.byType(StructuredSessionPanel), findsOneWidget);

          // The turn ends on the session that is shown: no unread dot.
          events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
          await tester.pumpAndSettle();

          expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
          // Still showing the (now idle) session in the detail pane.
          expect(find.byType(StructuredSessionPanel), findsOneWidget);
          expect(client.listCalls, 1);
        },
      );

      testWidgets(
        'opening an unread session clears the dot: wide row tap, narrow drawer '
        'row tap, and a tapped-notification deep link',
        (tester) async {
          // Wide layout: a row tap clears it.
          {
            final events = _FakeEventsSource();
            await _pumpTab(tester, rows: [_one], events: events);
            events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);

            await tester.tap(find.byKey(const ValueKey('session-ses_1')));
            await tester.pumpAndSettle();
            expect(find.byType(StructuredSessionPanel), findsOneWidget);
            expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
          }

          // Narrow drawer: a row tap inside the drawer clears it.
          {
            // A fresh tab (the wide block's State would otherwise be reused).
            await tester.pumpWidget(const SizedBox());
            final events = _FakeEventsSource();
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);
            await _pumpTabNarrow(tester, rows: [_one], events: events);
            events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
            await tester.pumpAndSettle();

            await tester.tap(
              find.byKey(const ValueKey('sessions-sidebar-toggle')),
            );
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);

            await tester.tap(find.byKey(const ValueKey('session-ses_1')));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('sessions-drawer')), findsNothing);
            expect(find.byType(StructuredSessionPanel), findsOneWidget);
            expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
          }

          // Deep link: a tapped "Turn finished"-style notification lands on
          // the row and clears it. Runs wide (like the deep-link tests):
          // reset the tree and the surface first.
          {
            await tester.pumpWidget(const SizedBox());
            tester.view.reset();
            final client = _FakeSessionsClient(rows: [_one, _three]);
            final events = _FakeEventsSource();
            Future<void> pump(String? target) => tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: SessionsTab(
                    key: const ValueKey('sessions-tab'),
                    apiBase: Uri.parse('http://bridge.test/'),
                    client: client,
                    fs: _FakeFsClient(),
                    orbs: _FakeOrbsClient(),
                    events: events,
                    deepLinkSession: target,
                  ),
                ),
              ),
            );
            await pump(null);
            await tester.pump();
            expect(client.listCalls, 1);

            events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);

            await pump('ses_1');
            await tester.pumpAndSettle();
            expect(find.byType(StructuredSessionPanel), findsOneWidget);
            expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
          }
        },
      );

      testWidgets(
        'a new turn starting on an unread session clears the unread dot and '
        'shows the green active dot',
        (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(
            tester,
            rows: [_one, _three],
            events: events,
          );

          // ses_1 is unread; the user is looking at ses_3.
          events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('session-ses_3')));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);

          // A new turn starts on the unread session: the unread fact is stale.
          events.emit(sessionEvent('session.execution.started', 'ses_1'));
          await tester.pumpAndSettle();

          expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
          expect(find.byKey(const ValueKey('active-ses_1')), findsOneWidget);
          expect(client.listCalls, 1, reason: 'patched in place, no refetch');
        },
      );

      testWidgets(
        'the unread mark survives a list reload (event-driven quiet refresh '
        'and app-foreground re-fetch) and is dropped for a deleted session',
        (tester) async {
          // Event-driven quiet refresh: a created session reloads the list;
          // the mark on ses_1 survives.
          {
            final events = _FakeEventsSource();
            final client = await _pumpTab(
              tester,
              rows: [_one, _three],
              events: events,
            );
            expect(client.listCalls, 1);

            events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);

            client.rows.insert(0, _orbSession());
            events.emit(sessionEvent('session.created', 'ses_orb1'));
            await tester.pumpAndSettle();

            expect(client.listCalls, 2, reason: 'the created session reloads');
            expect(
              find.byKey(const ValueKey('session-ses_orb1')),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);
          }

          // App-foreground re-fetch: resumed re-fetches the list; the mark
          // survives.
          {
            // A fresh tab (the previous block's State would be reused).
            await tester.pumpWidget(const SizedBox());
            final events = _FakeEventsSource();
            final client = await _pumpTab(tester, rows: [_one], events: events);
            expect(client.listCalls, 1);

            events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);

            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump();

            expect(client.listCalls, 2, reason: 'the foreground re-fetch');
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);
          }

          // A session that leaves the list (deleted) has its mark dropped.
          {
            // A fresh tab (the previous block's State would be reused).
            await tester.pumpWidget(const SizedBox());
            final events = _FakeEventsSource();
            final client = await _pumpTab(
              tester,
              rows: [_one, _three],
              events: events,
            );

            events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);

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

            expect(find.byKey(const ValueKey('session-ses_1')), findsNothing);
            expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
            expect(find.byKey(const ValueKey('session-ses_3')), findsOneWidget);
          }
        },
      );

      testWidgets(
        'the mark is in memory only: it is not persisted across a restart and '
        'is not part of the sessions API contract',
        (tester) async {
          // In-memory only: a fresh tab over the same (in-memory) clients has
          // no mark, and no setting persists it.
          final events = _FakeEventsSource();
          final orbs = _FakeOrbsClient();
          final client = await _pumpTab(
            tester,
            rows: [_one],
            events: events,
            orbs: orbs,
          );
          events.emit(sessionEvent('session.execution.succeeded', 'ses_1'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('unread-ses_1')), findsOneWidget);

          // "Restart": a brand-new tab (fresh state) over the same clients.
          await tester.pumpWidget(const SizedBox());
          await _pumpTab(tester, rows: [_one], events: events, orbs: orbs);
          expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
          expect(
            find.byKey(const ValueKey('unread-ses_1')),
            findsNothing,
            reason: 'the mark is per running instance, not persisted',
          );

          // The home-list wire shape carries no unread field; the row still
          // carries the existing active fact and the waiting fact (issue
          // #208), and nothing else.
          final row = (await client.list()).single;
          final wire = row.toJson();
          expect(wire.containsKey('unread'), isFalse);
          expect(wire['active'], isA<bool>());
          expect(
            {for (final entry in wire.entries) entry.key},
            {
              'id',
              'title',
              'project',
              'created',
              'location',
              'active',
              'waiting',
            },
          );
        },
      );

      group('project group active subtitle', () {
        testWidgets(
          'appends "(M active)" after the count only while at least one of the '
          "project's sessions is active",
          (tester) async {
            // p1 has ses_2 active and ses_1 idle -> "2 sessions (1 active)";
            // p2 has no active session -> "1 session" (unchanged).
            await _pumpTab(tester, rows: [_two, _one, _three]);

            expect(find.text('2 sessions (1 active)'), findsOneWidget);
            expect(find.text('1 session'), findsOneWidget);
            // The bare count is replaced by the annotated one for p1.
            expect(find.text('2 sessions'), findsNothing);
          },
        );

        testWidgets('leaves the subtitle unchanged when nothing is active', (
          tester,
        ) async {
          await _pumpTab(tester, rows: [_one, _three]);
          expect(find.text('1 session'), findsNWidgets(2));
          expect(find.textContaining('active'), findsNothing);
        });
      });
    });

    group('waiting dot (issue #209)', () {
      /// A pending-permission event, as the bridge fans it out: the session in
      /// `data.sessionID` (no durable seq — `permission.asked` carries none).
      /// The same event the structured view already consumes.
      BridgeEvent permEvent(String type, String sessionId) => BridgeEvent(
        id: 'evt_$type',
        created: 0,
        type: type,
        data: {'sessionID': sessionId},
      );

      /// A pending-question event (`form.*`), as the bridge fans it out: the
      /// session nests under `data.form` (the form object), no durable seq.
      /// The same events the structured view already consumes.
      BridgeEvent formEvent(String type, String sessionId) => BridgeEvent(
        id: 'evt_$type',
        created: 0,
        type: type,
        data: {
          'form': {'id': 'form_1', 'sessionID': sessionId},
        },
      );

      testWidgets(
        'a waiting session shows an orange dot, derived from the row\'s '
        'waiting fact',
        (tester) async {
          await _pumpTab(tester, rows: [_one.copyWith(waiting: true)]);

          expect(find.byKey(const ValueKey('waiting-ses_1')), findsOneWidget);
          // It is orange — not the green active dot, not the violet unread dot.
          final dot = tester.widget<Container>(
            find.byKey(const ValueKey('waiting-ses_1')),
          );
          expect((dot.decoration as BoxDecoration).color, Colors.orange);
          expect(find.byKey(const ValueKey('active-ses_1')), findsNothing);
          expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
        },
      );

      testWidgets(
        'orange takes precedence over green: a waiting session that is also '
        'active reads orange, while an active non-waiting session stays green',
        (tester) async {
          // Waiting and active at once: the service still marks it active
          // during the block, but the dot reads orange.
          await _pumpTab(tester, rows: [_two.copyWith(waiting: true)]);
          expect(find.byKey(const ValueKey('waiting-ses_2')), findsOneWidget);
          expect(find.byKey(const ValueKey('active-ses_2')), findsNothing);

          // Active but not waiting: the green dot stands.
          await tester.pumpWidget(const SizedBox());
          await _pumpTab(tester, rows: [_two]);
          expect(find.byKey(const ValueKey('active-ses_2')), findsOneWidget);
          expect(find.byKey(const ValueKey('waiting-ses_2')), findsNothing);
        },
      );

      testWidgets(
        'an inactive, non-waiting session shows no dot, and neither does a '
        'waiting idle row show the green dot',
        (tester) async {
          await _pumpTab(tester, rows: [_one, _three]);
          // Both idle and non-waiting: no dot at all.
          expect(find.byKey(const ValueKey('active-ses_1')), findsNothing);
          expect(find.byKey(const ValueKey('waiting-ses_1')), findsNothing);
          expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
          expect(find.byKey(const ValueKey('active-ses_3')), findsNothing);
          expect(find.byKey(const ValueKey('waiting-ses_3')), findsNothing);
        },
      );

      testWidgets(
        'the dot reverts on resolution — none when the row is idle, green '
        'when it is active — in place, without a list reload',
        (tester) async {
          Future<void> runFor({required bool active}) async {
            // A fresh tab per case (a bare pumpWidget would reuse the State).
            await tester.pumpWidget(const SizedBox());
            final events = _FakeEventsSource();
            final client = await _pumpTab(
              tester,
              rows: [_one.copyWith(active: active, waiting: true)],
              events: events,
            );
            expect(client.listCalls, 1);
            // Waiting: the dot is orange regardless of the active fact.
            expect(find.byKey(const ValueKey('waiting-ses_1')), findsOneWidget);

            // The permission is resolved: the service holds nothing pending
            // (the fake answers empty), and the resolution event lands (the
            // same one the structured view consumes). The dot reverts in
            // place.
            events.emit(permEvent('permission.replied', 'ses_1'));
            await tester.pumpAndSettle();

            expect(find.byKey(const ValueKey('waiting-ses_1')), findsNothing);
            if (active) {
              // Active, non-waiting: back to green.
              expect(
                find.byKey(const ValueKey('active-ses_1')),
                findsOneWidget,
              );
            } else {
              // Idle, non-waiting: no dot at all.
              expect(find.byKey(const ValueKey('active-ses_1')), findsNothing);
              expect(find.byKey(const ValueKey('unread-ses_1')), findsNothing);
            }
            expect(
              client.listCalls,
              1,
              reason: 'patched in place, no list reload',
            );
          }

          await runFor(active: false);
          await runFor(active: true);
        },
      );

      testWidgets(
        'the dot flips live on the permission/question events (asked/created '
        'to orange, resolved to off), without a list reload',
        (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(tester, rows: [_one], events: events);
          expect(client.listCalls, 1);
          expect(find.byKey(const ValueKey('waiting-ses_1')), findsNothing);

          // A permission is asked: the service now holds it, the event lands.
          client.permissionsResult = const [
            PermissionRequest(id: 'req_1', action: 'shell', resources: ['ls']),
          ];
          events.emit(permEvent('permission.asked', 'ses_1'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('waiting-ses_1')), findsOneWidget);
          expect(client.listCalls, 1, reason: 'no list reload');

          // The permission is answered: the service holds nothing, it reverts.
          client.permissionsResult = const [];
          events.emit(permEvent('permission.replied', 'ses_1'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('waiting-ses_1')), findsNothing);
          expect(client.listCalls, 1, reason: 'no list reload');

          // A question form is created: a pending question is waiting too, so
          // the dot turns orange again.
          client.questionsResult = const [
            QuestionForm(id: 'form_1', title: 'Questions', questions: []),
          ];
          events.emit(formEvent('form.created', 'ses_1'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('waiting-ses_1')), findsOneWidget);
          expect(client.listCalls, 1, reason: 'no list reload');

          // The question form is cancelled: the dot reverts.
          client.questionsResult = const [];
          events.emit(formEvent('form.cancelled', 'ses_1'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('waiting-ses_1')), findsNothing);
          expect(client.listCalls, 1, reason: 'no list reload');
        },
      );

      testWidgets(
        'a pending-question event nests the session under data.form (no '
        'durable seq), and the dot still flips',
        (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(tester, rows: [_three], events: events);
          expect(find.byKey(const ValueKey('waiting-ses_3')), findsNothing);

          client.questionsResult = const [
            QuestionForm(id: 'form_1', title: 'Questions', questions: []),
          ];
          // `form.created` carries no top-level sessionID: the tab must match
          // the nested `data.form.sessionID`.
          events.emit(formEvent('form.created', 'ses_3'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('waiting-ses_3')), findsOneWidget);
          expect(client.listCalls, 1, reason: 'no list reload');
        },
      );

      testWidgets(
        'a permission event naming a session the list does not know reloads '
        '(a missed create), like any other unknown-session event',
        (tester) async {
          final events = _FakeEventsSource();
          final client = await _pumpTab(tester, rows: [_one], events: events);
          expect(client.listCalls, 1);

          // ses_orb1 is not in the list (its create was missed, e.g. a spawned
          // orb session): the permission event for it must not be swallowed —
          // it reloads, coalesced and quiet, so the fresh row (with its waiting
          // fact) arrives. The known-row flip does no such reload, so this is
          // the reload the unknown-session path performs.
          events.emit(permEvent('permission.asked', 'ses_orb1'));
          await tester.pumpAndSettle();
          expect(client.listCalls, 2, reason: 'a create was missed');
        },
      );
    });
  });
}
