import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/docker_client.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/model/container.dart';
import 'package:opencodebridge/ui/docker_tab.dart';

/// A scripted [DockerClient] for the tab tests.
class _FakeDockerClient extends DockerClient {
  _FakeDockerClient({this.rows = const []})
    : super(Uri.parse('http://bridge.test/'));

  /// The rows the client returns; actions mutate them, like a re-fetch
  /// would see.
  final List<DockerContainer> rows;

  final List<(String, DockerAction)> actions = [];
  final List<String> logNames = [];

  /// The log lines the log stream yields.
  final StreamController<String> logLines =
      StreamController<String>.broadcast();

  Object? listError;
  Object? actionError;
  var listCalls = 0;

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
}

BridgeEvent _dockerEvent(String type, Map<String, Object?> data) =>
    BridgeEvent(id: 'evt_1', created: 1, type: type, data: data);

Future<(_FakeDockerClient, _FakeEventsSource)> _pumpTab(
  WidgetTester tester, {
  List<DockerContainer> rows = const [],
}) async {
  final client = _FakeDockerClient(rows: List.of(rows));
  final events = _FakeEventsSource();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DockerTab(
          apiBase: Uri.parse('http://bridge.test/'),
          client: client,
          events: events,
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
    });
  });
}
