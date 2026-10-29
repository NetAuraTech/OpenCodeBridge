import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/opencode_terminal_service.dart';
import 'package:opencodebridge/bridge/terminal/terminal_backend.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';
import 'package:opencodebridge/bridge/terminal/terminal_window_token.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/project.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/ui/sessions_tab.dart';
import 'package:xterm/xterm.dart';

const _one = Session(
  id: 'ses_1',
  title: 'fix the flaky test',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 100,
  location: '/code/app',
  active: false,
  classification: SessionClassification.external,
);
const _two = Session(
  id: 'ses_2',
  title: 'refactor auth',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 300,
  location: '/code/app',
  active: true,
  classification: SessionClassification.appLaunchedClosed,
);
const _three = Session(
  id: 'ses_3',
  title: 'docker logs',
  project: SessionProject(id: 'p2', name: 'infra'),
  created: 200,
  location: '/code/infra',
  active: false,
  classification: SessionClassification.external,
);
const _four = Session(
  id: 'ses_4',
  title: 'new from the app',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 400,
  location: '/code/app',
  active: false,
  classification: SessionClassification.appLaunchedLive,
);

/// A scripted [SessionsClient] for the tab tests.
class _FakeSessionsClient extends SessionsClient {
  _FakeSessionsClient({this.rows = const [], this.pickerProjects = const []})
    : super(Uri.parse('http://bridge.test/'));

  /// The rows the client returns; delete mutates it, like a re-fetch would
  /// see.
  final List<Session> rows;

  /// The picker's rows (spec fill-in †).
  final List<Project> pickerProjects;

  Object? listError;
  Object? deleteError;
  Object? projectsError;
  Object? createError;
  Object? openWindowError;

  final List<String> deleted = [];
  final List<String> created = [];
  final List<String> windowsOpened = [];
  var listCalls = 0;
  var projectsCalls = 0;

  @override
  Future<List<Session>> list() async {
    listCalls++;
    final error = listError;
    if (error is Object) throw error;
    return rows;
  }

  @override
  Future<List<Project>> projects() async {
    projectsCalls++;
    final error = projectsError;
    if (error is Object) throw error;
    return pickerProjects;
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
      classification: SessionClassification.appLaunchedLive,
    );
    rows.insert(0, session);
    return session;
  }

  @override
  Future<void> openWindow(String id) async {
    final error = openWindowError;
    if (error is Object) throw error;
    windowsOpened.add(id);
  }

  @override
  Future<void> delete(String id) async {
    final error = deleteError;
    if (error is Object) throw error;
    deleted.add(id);
    rows.removeWhere((s) => s.id == id);
  }
}

/// A [TerminalBackend] over a fake terminal service with one running PTY,
/// the server-mode in-process attach seam (spec §12).
TerminalBackend _terminals() => TerminalBackend(
  service: _FakeTerminalService(),
  token: TerminalWindowToken.generate(random: Random()),
  sessionCwd: (String id) async => '/cwd/$id',
);

Future<_FakeSessionsClient> _pumpTab(
  WidgetTester tester, {
  List<Session> rows = const [],
  List<Project> projects = const [],
  TerminalBackend? terminals,
}) async {
  final client = _FakeSessionsClient(
    rows: List<Session>.of(rows),
    pickerProjects: List<Project>.of(projects),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SessionsTab(
          apiBase: Uri.parse('http://bridge.test/'),
          client: client,
          terminals: terminals,
        ),
      ),
    ),
  );
  await tester.pump();
  return client;
}

void main() {
  group('SessionsTab', () {
    group('home list', () {
      testWidgets('groups live rows by project, newest first, with the count', (
        tester,
      ) async {
        await _pumpTab(
          tester,
          rows: [_four, _two, _three, _one], // newest first, as delivered
        );

        // Project sections, newest activity first, with counts.
        expect(find.byKey(const ValueKey('project-p1')), findsOneWidget);
        expect(find.byKey(const ValueKey('project-p2')), findsOneWidget);
        expect(find.text('app'), findsOneWidget);
        expect(find.text('infra'), findsOneWidget);
        expect(find.text('2 sessions'), findsOneWidget);
        expect(find.text('1 session'), findsOneWidget);

        // Within the app group: newest first, live rows only.
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
      });

      testWidgets(
        'closed app-launched sessions collect in the Closed section',
        (tester) async {
          await _pumpTab(tester, rows: [_two, _three]);

          expect(find.byKey(const ValueKey('closed-section')), findsOneWidget);
          expect(find.byKey(const ValueKey('session-ses_2')), findsOneWidget);
          expect(find.byKey(const ValueKey('session-ses_3')), findsOneWidget);
          expect(find.text('App-launched · window closed'), findsOneWidget);
          // The Closed section sits below the project groups.
          final closed = tester
              .getTopLeft(find.byKey(const ValueKey('closed-section')))
              .dy;
          final infra = tester
              .getTopLeft(find.byKey(const ValueKey('project-p2')))
              .dy;
          expect(closed, greaterThan(infra));
        },
      );

      testWidgets('shows the active indicator only on active sessions', (
        tester,
      ) async {
        await _pumpTab(tester, rows: [_two, _one]);
        expect(find.byKey(const ValueKey('active-ses_2')), findsOneWidget);
        expect(find.byKey(const ValueKey('active-ses_1')), findsNothing);
      });
    });

    group('new session', () {
      const project = Project(id: 'p1', name: 'app', canonical: '/code/app');

      testWidgets('server mode: pick a project, create, follow the terminal', (
        tester,
      ) async {
        final terminals = _terminals();
        final client = await _pumpTab(
          tester,
          projects: [project],
          terminals: terminals,
        );

        await tester.tap(find.byKey(const ValueKey('sessions-new')));
        await tester.pumpAndSettle();

        // The project picker, fed by GET /api/projects.
        expect(find.byKey(const ValueKey('project-picker')), findsOneWidget);
        expect(client.projectsCalls, 1);
        expect(find.text('/code/app'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('project-p1')));
        await tester.pumpAndSettle();

        // Created with the project as the only parameter; the row appears.
        // The home route is inactive behind the terminal route, so the
        // finder must not skip offstage routes.
        expect(client.created, ['p1']);
        expect(
          find.byKey(const ValueKey('session-ses_new'), skipOffstage: false),
          findsOneWidget,
        );

        // The app follows the terminal: the in-process attach is live and
        // the interactive view is showing.
        expect(find.byType(TerminalView), findsOneWidget);

        // Going back returns to the list.
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(TerminalView), findsNothing);
      });

      testWidgets(
        'client mode: create reports the window on the host, no terminal',
        (tester) async {
          final client = await _pumpTab(tester, projects: [project]);

          await tester.tap(find.byKey(const ValueKey('sessions-new')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('project-p1')));
          await tester.pumpAndSettle();

          expect(client.created, ['p1']);
          expect(find.byKey(const ValueKey('session-ses_new')), findsOneWidget);
          expect(find.byType(TerminalView), findsNothing);
          expect(
            find.textContaining('terminal window opened on the host'),
            findsOneWidget,
          );
        },
      );

      testWidgets('canceling the picker creates nothing', (tester) async {
        final client = await _pumpTab(tester, projects: [project]);

        await tester.tap(find.byKey(const ValueKey('sessions-new')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(client.projectsCalls, 1);
        expect(client.created, isEmpty);
      });

      testWidgets('a project-list failure shows a snackbar', (tester) async {
        final client = await _pumpTab(tester, projects: [project]);
        client.projectsError = const SessionsClientError(502, 'down');

        await tester.tap(find.byKey(const ValueKey('sessions-new')));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Could not load the projects'),
          findsOneWidget,
        );
        expect(client.created, isEmpty);
      });

      testWidgets('a create failure shows a snackbar and no terminal', (
        tester,
      ) async {
        final client = await _pumpTab(
          tester,
          projects: [project],
          terminals: _terminals(),
        );
        client.createError = const SessionsClientError(502, 'down');

        await tester.tap(find.byKey(const ValueKey('sessions-new')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project-p1')));
        await tester.pumpAndSettle();

        expect(client.created, isEmpty);
        expect(
          find.textContaining('Could not create the session'),
          findsOneWidget,
        );
        expect(find.byType(TerminalView), findsNothing);
      });
    });

    group('follow and reopen', () {
      testWidgets('tapping a live row follows the terminal', (tester) async {
        await _pumpTab(tester, rows: [_four], terminals: _terminals());

        await tester.tap(find.byKey(const ValueKey('session-ses_4')));
        await tester.pumpAndSettle();

        expect(find.byType(TerminalView), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      });

      testWidgets('server mode: tapping a closed row reopens and follows', (
        tester,
      ) async {
        final client = await _pumpTab(
          tester,
          rows: [_two],
          terminals: _terminals(),
        );

        await tester.tap(find.byKey(const ValueKey('reopen-ses_2')));
        await tester.pumpAndSettle();

        expect(client.windowsOpened, ['ses_2']);
        expect(find.byType(TerminalView), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      });

      testWidgets('client mode: tapping a closed row reopens on the host', (
        tester,
      ) async {
        final client = await _pumpTab(tester, rows: [_two]);

        await tester.tap(find.byKey(const ValueKey('reopen-ses_2')));
        await tester.pumpAndSettle();

        expect(client.windowsOpened, ['ses_2']);
        expect(find.byType(TerminalView), findsNothing);
        expect(
          find.textContaining('Window reopened on the host'),
          findsOneWidget,
        );
      });

      testWidgets('a failed reopen shows a snackbar', (tester) async {
        final client = await _pumpTab(
          tester,
          rows: [_two],
          terminals: _terminals(),
        );
        client.openWindowError = const SessionsClientError(502, 'down');

        await tester.tap(find.byKey(const ValueKey('reopen-ses_2')));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Could not reopen the window'),
          findsOneWidget,
        );
        expect(find.byType(TerminalView), findsNothing);
      });
    });

    group('delete', () {
      testWidgets(
        'delete on a live app-launched session says the window closes',
        (tester) async {
          final client = await _pumpTab(
            tester,
            rows: [_four, _one],
            terminals: _terminals(),
          );

          await tester.tap(
            find.byKey(const ValueKey('menu-ses_4')),
            warnIfMissed: false,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Delete session…'));
          await tester.pumpAndSettle();

          expect(
            find.textContaining('terminal window will be closed'),
            findsOneWidget,
          );

          await tester.tap(find.text('Delete'));
          await tester.pumpAndSettle();

          expect(client.deleted, ['ses_4']);
          expect(find.byKey(const ValueKey('session-ses_4')), findsNothing);
          expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
        },
      );

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

        // The external session has no window to close.
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
  });
}

/// A scripted persistent-PTY family with one running PTY, for the
/// server-mode attach in the tab tests.
class _FakeTerminalService implements OpencodeTerminalService {
  final _info = TerminalInfo(
    id: 'pty_1',
    status: TerminalStatus.running,
    size: TerminalSize.defaultSize,
    sessionId: 'ses_1',
  );

  int connects = 0;

  @override
  Future<TerminalInfo> createTerminal(
    String sessionId, {
    required String cwd,
    TerminalSize? size,
    String? title,
  }) async => _info;

  @override
  Future<List<TerminalInfo>> listTerminals(String sessionId) async => [_info];

  @override
  Future<TerminalInfo> runningTerminal(String sessionId) async => _info;

  @override
  Future<TerminalTicket> connectToken(String ptyId) async =>
      const TerminalTicket(ticket: 'tk', expiresIn: 60);

  @override
  Future<TerminalConnection> connect(
    String ptyId, {
    required String ticket,
    int cursor = 0,
    required TerminalSize size,
  }) async {
    connects++;
    return _FakeConnection();
  }

  @override
  Future<TerminalInfo> resize(String ptyId, TerminalSize size) async => _info;

  @override
  Future<void> delete(String ptyId) async {}
}

/// A scripted upstream attach that emits an initial replay on a later
/// event-loop turn, marks the replay complete, then stays open.
class _FakeConnection implements TerminalConnection {
  final _controller = StreamController<List<int>>();
  final _replayDone = Completer<void>();

  _FakeConnection() {
    Future<void>.delayed(const Duration(), () {
      _controller.add('REPLAY'.codeUnits);
      _replayDone.complete();
    });
  }

  @override
  Stream<List<int>> get output => _controller.stream;

  @override
  Future<void> get initialReplayDone => _replayDone.future;

  @override
  Future<void> write(List<int> input) async {}

  @override
  Future<void> resize(int cols, int rows) async {}

  @override
  Future<void> close() async {
    if (!_replayDone.isCompleted) _replayDone.complete();
    await _controller.close();
  }
}
