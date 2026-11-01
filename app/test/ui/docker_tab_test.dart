import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/access_session.dart';
import 'package:opencodebridge/access/token_store.dart';
import 'package:opencodebridge/client/docker_client.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/model/compose_project.dart';
import 'package:opencodebridge/model/container.dart';
import 'package:opencodebridge/ui/docker_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A scripted [DockerClient] for the tab tests.
class _FakeDockerClient extends DockerClient {
  _FakeDockerClient({this.rows = const [], this.composeProjects = const []})
    : super(Uri.parse('http://bridge.test/'));

  /// The rows the client returns; actions mutate them, like a re-fetch
  /// would see.
  final List<DockerContainer> rows;

  /// The compose projects [compose] returns (issue #21 follow-on).
  final List<ComposeProject> composeProjects;

  final List<(String, DockerAction)> actions = [];
  final List<String> logNames = [];

  /// The compose actions taken, as (project id, action, service).
  final List<(String, ComposeAction, String?)> composeActions = [];

  /// The log lines the log stream yields.
  final StreamController<String> logLines =
      StreamController<String>.broadcast();

  Object? listError;
  Object? actionError;
  Object? composeError;
  Object? composeActionError;
  var listCalls = 0;
  var composeCalls = 0;

  @override
  Future<List<DockerContainer>> list() async {
    listCalls++;
    final error = listError;
    if (error is Object) throw error;
    return rows;
  }

  @override
  Future<void> action(String name, DockerAction action) async {
    final error = actionError;
    if (error is Object) throw error;
    actions.add((name, action));
    final index = rows.indexWhere((r) => r.name == name);
    if (index >= 0) {
      final row = rows[index];
      rows[index] = DockerContainer(
        name: row.name,
        image: row.image,
        state: action == DockerAction.start
            ? DockerState.running
            : DockerState.exited,
        uptime: action == DockerAction.start ? 'less than a second ago' : null,
      );
    }
  }

  @override
  Stream<String> logs(String name, {bool follow = true}) {
    logNames.add(name);
    return logLines.stream;
  }

  @override
  Future<List<ComposeProject>> compose() async {
    composeCalls++;
    final error = composeError;
    if (error is Object) throw error;
    return composeProjects;
  }

  @override
  Future<void> composeAction(
    String id,
    ComposeAction action, {
    String? service,
  }) async {
    final error = composeActionError;
    if (error is Object) throw error;
    composeActions.add((id, action, service));
  }
}

/// A scripted [EventSource] for the tab tests (no real SSE connection).
class _FakeEventsSource implements EventSource {
  final _controller = StreamController<BridgeEvent>.broadcast();
  final _gaps = StreamController<SessionGap>.broadcast();

  StreamController<BridgeEvent> get controller => _controller;

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

  /// How often the tab forced a fresh connection (issue #41, foreground).
  var reconnectCalls = 0;

  @override
  Future<void> reconnect() async {
    reconnectCalls++;
  }
}

BridgeEvent _dockerEvent(String type, Map<String, Object?> data) =>
    BridgeEvent(id: 'evt_1', created: 1, type: type, data: data);

Future<(_FakeDockerClient, _FakeEventsSource)> _pumpTab(
  WidgetTester tester, {
  List<DockerContainer> rows = const [],
  List<ComposeProject> composeProjects = const [],
  AccessSession? access,
}) async {
  final client = _FakeDockerClient(
    rows: List.of(rows),
    composeProjects: List.of(composeProjects),
  );
  final events = _FakeEventsSource();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DockerTab(
          apiBase: Uri.parse('http://bridge.test/'),
          client: client,
          events: events,
          access: access,
        ),
      ),
    ),
  );
  await tester.pump();
  return (client, events);
}

const _web = DockerContainer(
  name: 'web',
  image: 'nginx:latest',
  state: DockerState.exited,
  uptime: null,
);

const _db = DockerContainer(
  name: 'db',
  image: 'postgres:16',
  state: DockerState.exited,
  uptime: null,
);

void main() {
  group('DockerTab', () {
    group('container list', () {
      testWidgets('shows every container with its state and uptime', (
        tester,
      ) async {
        await _pumpTab(
          tester,
          rows: [
            const DockerContainer(
              name: 'web',
              image: 'nginx:latest',
              state: DockerState.running,
              uptime: '2 hours ago',
            ),
            _db,
          ],
        );

        expect(find.byKey(const ValueKey('container-web')), findsOneWidget);
        expect(find.byKey(const ValueKey('container-db')), findsOneWidget);
        expect(find.text('nginx:latest'), findsOneWidget);
        // The running container shows its uptime…
        expect(find.text('2 hours ago'), findsOneWidget);
        // …the stopped one shows its state instead.
        expect(find.text('exited'), findsOneWidget);
      });

      testWidgets('an empty list says there are no containers', (tester) async {
        await _pumpTab(tester);
        expect(find.text('No containers.'), findsOneWidget);
      });

      testWidgets('an unreachable bridge shows the error with a retry', (
        tester,
      ) async {
        final client = _FakeDockerClient();
        client.listError = const DockerClientError(0, 'refused');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DockerTab(
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
        await tester.tap(find.byKey(const ValueKey('docker-retry')));
        await tester.pumpAndSettle();
        expect(client.listCalls, 2);
        expect(find.text('No containers.'), findsOneWidget);
      });

      testWidgets('without a bridge, points at Settings', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: DockerTab(apiBase: null))),
        );
        await tester.pump();
        expect(
          find.text('No bridge configured. Set the tunnel URL in Settings.'),
          findsOneWidget,
        );
      });
    });

    group('detail', () {
      testWidgets('tapping a row opens the detail with state and actions', (
        tester,
      ) async {
        await _pumpTab(
          tester,
          rows: [
            const DockerContainer(
              name: 'web',
              image: 'nginx:latest',
              state: DockerState.running,
              uptime: '2 hours ago',
            ),
          ],
        );

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('state-running')), findsOneWidget);
        expect(find.text('2 hours ago'), findsOneWidget);
        for (final action in DockerAction.values) {
          expect(
            find.byKey(ValueKey('docker-action-${action.wire}')),
            findsOneWidget,
          );
        }
        // A running container admits stop/restart, not start.
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('docker-action-start')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('docker-action-stop')),
              )
              .onPressed,
          isNotNull,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
      });

      testWidgets('an action posts for the container and refreshes the state', (
        tester,
      ) async {
        final (client, _) = await _pumpTab(tester, rows: [_web]);

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('docker-action-start')));
        await tester.pumpAndSettle();

        expect(client.actions, [('web', DockerAction.start)]);
        // The re-fetch picked up the started state.
        expect(find.byKey(const ValueKey('state-running')), findsOneWidget);
      });

      testWidgets('an action failure shows a snackbar and keeps the state', (
        tester,
      ) async {
        final (client, _) = await _pumpTab(tester, rows: [_web]);
        client.actionError = const DockerClientError(404, 'gone');

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('docker-action-start')));
        await tester.pumpAndSettle();

        expect(client.actions, isEmpty);
        expect(
          find.textContaining('Could not start the container'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('state-exited')), findsOneWidget);
      });

      testWidgets('closing the detail re-loads the list', (tester) async {
        final (client, _) = await _pumpTab(tester, rows: [_web]);

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();
        final before = client.listCalls;
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(client.listCalls, before + 1);
      });

      testWidgets('closing the detail re-fetches the compose section too', (
        tester,
      ) async {
        final (client, _) = await _pumpTab(
          tester,
          rows: [_web],
          composeProjects: [
            ComposeProject(
              id: Uri.encodeComponent('/repo'),
              project: 'demo',
              path: '/repo',
              composeFile: '/repo/docker-compose.yml',
              services: [
                const ComposeService(
                  name: 'web',
                  state: DockerState.running,
                  image: 'nginx:latest',
                  container: 'demo-web-1',
                ),
              ],
            ),
          ],
        );

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        // The action may have changed a container the compose section also
        // shows, so it re-fetches alongside the list.
        expect(client.listCalls, 2);
        expect(client.composeCalls, 2);
      });
    });

    group('live logs', () {
      testWidgets('the detail streams the container logs', (tester) async {
        final (client, _) = await _pumpTab(tester, rows: [_web]);

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();

        expect(client.logNames, ['web']);
        expect(find.text('No log output.'), findsOneWidget);

        client.logLines.add('alpha');
        client.logLines.add('beta');
        await tester.pump();
        await tester.pump();

        expect(find.text('alpha'), findsOneWidget);
        expect(find.text('beta'), findsOneWidget);
      });

      testWidgets('the keyword filter is client-side and case-insensitive', (
        tester,
      ) async {
        final (client, _) = await _pumpTab(tester, rows: [_web]);

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();

        client.logLines.add('error: boom');
        client.logLines.add('all good');
        await tester.pump();
        await tester.pump();
        expect(find.text('error: boom'), findsOneWidget);
        expect(find.text('all good'), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('docker-log-filter')),
          'ERROR',
        );
        await tester.pump();
        expect(find.text('error: boom'), findsOneWidget);
        expect(find.text('all good'), findsNothing);

        await tester.enterText(
          find.byKey(const ValueKey('docker-log-filter')),
          '',
        );
        await tester.pump();
        expect(find.text('all good'), findsOneWidget);
      });
    });

    group('events', () {
      testWidgets('a docker event re-fetches the list', (tester) async {
        final (client, events) = await _pumpTab(tester, rows: [_web]);

        events.controller.add(
          _dockerEvent('docker.container.stopped', {'name': 'web'}),
        );
        await tester.pump();

        expect(client.listCalls, 2);
      });

      testWidgets('a docker event for another container still re-fetches', (
        tester,
      ) async {
        final (client, events) = await _pumpTab(tester, rows: [_web]);

        events.controller.add(
          _dockerEvent('docker.container.crashed', {'name': 'db'}),
        );
        await tester.pump();

        expect(client.listCalls, 2);
      });

      testWidgets('a container event re-fetches the compose section too', (
        tester,
      ) async {
        final (client, events) = await _pumpTab(tester, rows: [_web]);
        expect(client.listCalls, 1);
        expect(client.composeCalls, 1);

        events.controller.add(
          _dockerEvent('docker.container.stopped', {'name': 'web'}),
        );
        await tester.pump();

        // A stopped or crashed container changes what the compose section
        // shows as well, so both views re-fetch.
        expect(client.listCalls, 2);
        expect(client.composeCalls, 2);
      });

      testWidgets('non-docker events leave the list alone', (tester) async {
        final (client, events) = await _pumpTab(tester, rows: [_web]);

        events.controller.add(
          _dockerEvent('session.closed', {'sessionID': 'ses_1'}),
        );
        await tester.pump();

        expect(client.listCalls, 1);
      });

      testWidgets('a matching event re-fetches the open detail row', (
        tester,
      ) async {
        final (client, events) = await _pumpTab(tester, rows: [_web]);

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();
        final before = client.listCalls;

        events.controller.add(
          _dockerEvent('docker.container.crashed', {'name': 'web'}),
        );
        await tester.pump();

        // The detail re-fetches for its own container (and so does the
        // list behind it).
        expect(client.listCalls, greaterThan(before));
      });

      testWidgets('an event for another container leaves the detail alone', (
        tester,
      ) async {
        final (client, events) = await _pumpTab(tester, rows: [_web]);

        await tester.tap(find.byKey(const ValueKey('container-web')));
        await tester.pumpAndSettle();
        final before = client.listCalls;

        events.controller.add(
          _dockerEvent('docker.container.stopped', {'name': 'db'}),
        );
        await tester.pump();

        // Only the list behind the detail re-fetches.
        expect(client.listCalls, before + 1);
      });

      testWidgets('resumed re-connects events and re-fetches both views', (
        tester,
      ) async {
        final (client, events) = await _pumpTab(tester, rows: [_web]);
        expect(client.listCalls, 1);
        expect(client.composeCalls, 1);
        expect(events.reconnectCalls, 0);

        // Android suspends the app and brings it back to the foreground.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        expect(events.reconnectCalls, 1);
        expect(client.listCalls, 2);
        expect(client.composeCalls, 2);
      });
    });

    group('compose projects (issue #21 follow-on)', () {
      final demo = ComposeProject(
        id: Uri.encodeComponent('/repo'),
        project: 'demo',
        path: '/repo',
        composeFile: '/repo/docker-compose.yml',
        services: [
          const ComposeService(
            name: 'web',
            state: DockerState.running,
            image: 'nginx:latest',
            container: 'demo-web-1',
          ),
          const ComposeService(name: 'db', state: null),
        ],
      );

      testWidgets('shows each project with its services and state', (
        tester,
      ) async {
        await _pumpTab(tester, composeProjects: [demo]);

        expect(find.text('demo'), findsOneWidget);
        expect(find.text('/repo'), findsOneWidget);
        expect(find.text('1/2 up'), findsOneWidget);
        // The created service shows its image…
        expect(find.text('nginx:latest'), findsOneWidget);
        // …the never-created one shows only its name.
        expect(find.text('db'), findsOneWidget);
        expect(find.text('Start all'), findsOneWidget);
        expect(find.text('Stop all'), findsOneWidget);
      });

      testWidgets('no compose file in any repo says so', (tester) async {
        await _pumpTab(tester);
        expect(find.text('No compose projects detected.'), findsOneWidget);
      });

      testWidgets('starting a service takes the up action on it', (
        tester,
      ) async {
        final (client, _) = await _pumpTab(tester, composeProjects: [demo]);

        await tester.tap(
          find.byKey(ValueKey('compose-btn-svc|${demo.id}|db|up')),
        );
        await tester.pump();

        expect(client.composeActions, [(demo.id, ComposeAction.up, 'db')]);
      });

      testWidgets('Start all takes the up action on the whole project', (
        tester,
      ) async {
        final (client, _) = await _pumpTab(tester, composeProjects: [demo]);

        await tester.tap(
          find.byKey(ValueKey('compose-btn-proj|${demo.id}|up')),
        );
        await tester.pump();

        expect(client.composeActions, [(demo.id, ComposeAction.up, null)]);
      });

      testWidgets('a compose load failure shows the error', (tester) async {
        final client = _FakeDockerClient();
        client.composeError = const DockerClientError(502, 'oops');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DockerTab(
                apiBase: Uri.parse('http://bridge.test/'),
                client: client,
                events: _FakeEventsSource(),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.text('The bridge could not list compose projects (status 502).'),
          findsOneWidget,
        );
      });

      testWidgets('a compose action re-fetches the container list too', (
        tester,
      ) async {
        final (client, _) = await _pumpTab(tester, composeProjects: [demo]);
        expect(client.listCalls, 1);
        expect(client.composeCalls, 1);

        await tester.tap(
          find.byKey(ValueKey('compose-btn-proj|${demo.id}|up')),
        );
        await tester.pumpAndSettle();

        // The container list re-fetches alongside the compose projects, so
        // the two views of the same containers stay in sync.
        expect(client.listCalls, 2);
        expect(client.composeCalls, 2);
      });
    });

    group('access login completion (issue #41)', () {
      testWidgets('the login finishing re-fetches both views and the events', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final store = await AccessTokenStore.load();
        final access = AccessSession(
          tunnelBase: () => Uri.parse('https://tunnel.test/'),
          store: store,
        );
        final (client, events) = await _pumpTab(
          tester,
          rows: [_web],
          access: access,
        );
        expect(client.listCalls, 1);
        expect(client.composeCalls, 1);
        expect(events.reconnectCalls, 0);

        // The browser bounce brought the app to the foreground before the
        // token exchange finished (the foreground re-fetch saw a 401); the
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
        expect(client.composeCalls, 2);
        expect(events.reconnectCalls, 1);
      });
    });
  });
}
