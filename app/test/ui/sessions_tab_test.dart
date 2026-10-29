import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/ui/sessions_tab.dart';

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

/// A scripted [SessionsClient] for the tab tests.
class _FakeSessionsClient extends SessionsClient {
  _FakeSessionsClient({this.rows = const []})
    : super(Uri.parse('http://bridge.test/'));

  /// The rows the client returns; delete mutates it, like a re-fetch would
  /// see.
  final List<Session> rows;

  Object? listError;
  Object? deleteError;

  final List<String> deleted = [];
  var listCalls = 0;

  @override
  Future<List<Session>> list() async {
    listCalls++;
    final error = listError;
    if (error is Object) throw error;
    return rows;
  }

  @override
  Future<void> delete(String id) async {
    final error = deleteError;
    if (error is Object) throw error;
    deleted.add(id);
    rows.removeWhere((s) => s.id == id);
  }
}

Future<_FakeSessionsClient> _pumpTab(
  WidgetTester tester, {
  List<Session> rows = const [],
}) async {
  final client = _FakeSessionsClient(rows: List<Session>.of(rows));
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
  return client;
}

void main() {
  group('SessionsTab', () {
    testWidgets('groups by project, newest first, with the count', (
      tester,
    ) async {
      await _pumpTab(
        tester,
        rows: [_two, _three, _one], // newest first, as the client delivers
      );

      // Project sections, newest activity first, with counts.
      expect(find.byKey(const ValueKey('project-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('project-p2')), findsOneWidget);
      expect(find.text('app'), findsOneWidget);
      expect(find.text('infra'), findsOneWidget);
      expect(find.text('2 sessions'), findsOneWidget);
      expect(find.text('1 session'), findsOneWidget);

      // Within the app group: newest first.
      final two = tester
          .getTopLeft(find.byKey(const ValueKey('session-ses_2')))
          .dy;
      final one = tester
          .getTopLeft(find.byKey(const ValueKey('session-ses_1')))
          .dy;
      expect(two, lessThan(one));

      // Every session row and its location are visible.
      expect(find.text('refactor auth'), findsOneWidget);
      expect(find.text('fix the flaky test'), findsOneWidget);
      expect(find.text('docker logs'), findsOneWidget);
      expect(find.text('/code/infra'), findsOneWidget);
    });

    testWidgets('shows the active indicator only on active sessions', (
      tester,
    ) async {
      await _pumpTab(tester, rows: [_two, _one]);
      expect(find.byKey(const ValueKey('active-ses_2')), findsOneWidget);
      expect(find.byKey(const ValueKey('active-ses_1')), findsNothing);
    });

    testWidgets('delete: confirm removes the session and refreshes', (
      tester,
    ) async {
      final client = await _pumpTab(tester, rows: [_two, _one]);

      // Open the menu on the first (newest) row.
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session…'));
      await tester.pumpAndSettle();

      // Confirm.
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(client.deleted, ['ses_2']);
      expect(find.byKey(const ValueKey('session-ses_2')), findsNothing);
      expect(find.byKey(const ValueKey('session-ses_1')), findsOneWidget);
    });

    testWidgets('delete: cancel keeps the session', (tester) async {
      final client = await _pumpTab(tester, rows: [_two, _one]);

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(client.deleted, isEmpty);
      expect(find.byKey(const ValueKey('session-ses_2')), findsOneWidget);
    });

    testWidgets('a failed delete shows a snackbar and keeps the row', (
      tester,
    ) async {
      final client = await _pumpTab(tester, rows: [_two, _one]);
      client.deleteError = const SessionsClientError(500, 'boom');

      await tester.tap(find.byType(PopupMenuButton<String>).first);
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
      expect(find.byKey(const ValueKey('session-ses_2')), findsOneWidget);
    });

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
}
