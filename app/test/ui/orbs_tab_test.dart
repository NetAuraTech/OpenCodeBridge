import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/bridge_event.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/client/orbs_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/orb.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/project.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/ui/orbs_tab.dart';
import 'package:opencodebridge/ui/structured_view.dart';

const _project = Project(id: 'p1', name: 'app', canonical: '/code/app');

const _running = OrbRecord(
  id: 'orb_1',
  name: 'api',
  project: 'p1',
  branch: 'orb/orb_1',
  state: 'running',
  created: '2025-01-01T00:00:00Z',
);

const _preparing = OrbRecord(
  id: 'orb_2',
  name: 'worker',
  project: 'p1',
  branch: 'orb/orb_2',
  state: 'preparing:cloning',
  created: '2025-01-01T00:00:00Z',
);

const _stopped = OrbRecord(
  id: 'orb_3',
  name: 'stalled',
  project: 'p1',
  branch: 'orb/orb_3',
  state: 'stopped',
  created: '2025-01-01T00:00:00Z',
);

const _brokenWorkspace = OrbRecord(
  id: 'orb_4',
  name: 'wrecked',
  project: 'p1',
  branch: 'orb/orb_4',
  state: 'broken:workspace',
  created: '2025-01-01T00:00:00Z',
);

const _brokenState = OrbRecord(
  id: 'orb_5',
  name: 'hollowed',
  project: 'p1',
  branch: 'orb/orb_5',
  state: 'broken:state',
  created: '2025-01-01T00:00:00Z',
);

const _orphan = OrbRecord(
  id: 'orb_6',
  name: 'ghost',
  project: 'p1',
  branch: 'orb/orb_6',
  state: 'orphan',
  created: '2025-01-01T00:00:00Z',
);

const _cleanupPending = OrbRecord(
  id: 'orb_7',
  name: 'dirty',
  project: 'p1',
  branch: 'orb/orb_7',
  state: 'cleanup_pending:uncommitted work',
  created: '2025-01-01T00:00:00Z',
);

const _prOpen = OrbRecord(
  id: 'orb_8',
  name: 'proposed',
  project: 'p1',
  branch: 'orb/orb_8',
  state: 'running',
  created: '2025-01-01T00:00:00Z',
  pr: OrbPr(state: 'open', url: 'https://github.com/o/r/pull/7'),
);

const _prMerged = OrbRecord(
  id: 'orb_9',
  name: 'landed',
  project: 'p1',
  branch: 'orb/orb_9',
  state: 'running',
  created: '2025-01-01T00:00:00Z',
  pr: OrbPr(state: 'merged', url: 'https://github.com/o/r/pull/8'),
);

/// The record the wizard's create produces (the id the bridge mints).
const _workerRecord = OrbRecord(
  id: 'orb_new',
  name: 'worker',
  project: 'p1',
  branch: 'orb/orb_new',
  state: 'running',
  created: '2025-01-03T00:00:00Z',
);

const _sessionA = Session(
  id: 'ses_1',
  title: 'a',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 100,
  location: '/code/app',
  active: false,
  orb: 'orb_1',
);

const _sessionB = Session(
  id: 'ses_2',
  title: 'b',
  project: SessionProject(id: 'p1', name: 'app'),
  created: 200,
  location: '/code/app',
  active: false,
  orb: 'orb_1',
);

/// A scripted [OrbsClient] for the tab tests (no real bridge).
class _FakeOrbsClient extends OrbsClient {
  _FakeOrbsClient({this.orbs = const []})
    : super(Uri.parse('http://bridge.test/'));

  final List<OrbRecord> orbs;

  Object? listError;

  /// The record [create] answers with (a sensible default otherwise).
  OrbRecord? created;

  Object? createError;

  /// When set, [create] waits for it before answering — the "close the
  /// sheet mid-boot" tests keep the boot in flight.
  Completer<void>? createGate;

  Object? rebuildError;
  String rebuildTag = 'orb:abc123';
  Object? deleteError;

  /// The (issue #97) lifecycle scripts: errors, gates, and the wake/session
  /// records.
  Object? stopError;
  Completer<void>? stopGate;
  Object? wakeError;
  Completer<void>? wakeGate;
  OrbRecord? wakeRecord;
  Object? newSessionError;
  Completer<void>? newSessionGate;
  Session? newSessionRecord;

  /// The (issue #98) exit-path scripts: the per-orb update and the
  /// force delete.
  Object? updateError;
  Completer<void>? updateGate;
  OrbRecord? updateRecord;
  Object? forceDeleteError;
  Completer<void>? forceDeleteGate;

  var listCalls = 0;
  final List<bool> listIncludePr = [];
  final List<(String, String)> createdRequests = [];
  var rebuildCalls = 0;
  final List<String> deleted = [];
  final List<String> stopped = [];
  final List<String> woken = [];
  final List<String> newSessions = [];
  final List<String> updated = [];
  final List<(String, bool)> forceDeleted = [];

  @override
  Future<List<OrbRecord>> list({bool includePr = false}) async {
    listCalls++;
    listIncludePr.add(includePr);
    final error = listError;
    if (error is Object) throw error;
    return orbs;
  }

  @override
  Future<OrbRecord> create(String projectId, String name) async {
    createdRequests.add((projectId, name));
    final gate = createGate;
    if (gate != null) await gate.future;
    final error = createError;
    if (error is Object) throw error;
    final record = created;
    if (record != null) return record;
    return OrbRecord(
      id: 'orb_new',
      name: name,
      project: projectId,
      branch: 'orb/orb_new',
      state: 'running',
      created: '2025-01-03T00:00:00Z',
    );
  }

  @override
  Future<String> rebuildImage() async {
    rebuildCalls++;
    final error = rebuildError;
    if (error is Object) throw error;
    return rebuildTag;
  }

  @override
  Future<void> deleteOrphan(String id) async {
    final error = deleteError;
    if (error is Object) throw error;
    deleted.add(id);
  }

  @override
  Future<void> delete(String id, {bool force = false}) async {
    final gate = forceDeleteGate;
    if (gate != null) await gate.future;
    final error = forceDeleteError;
    if (error is Object) throw error;
    forceDeleted.add((id, force));
  }

  @override
  Future<OrbRecord> update(String id) async {
    final gate = updateGate;
    if (gate != null) await gate.future;
    final error = updateError;
    if (error is Object) throw error;
    updated.add(id);
    final record = updateRecord;
    if (record != null) return record;
    return OrbRecord(
      id: id,
      name: 'updated',
      project: 'p1',
      branch: 'orb/$id',
      state: 'running',
      created: '2025-01-03T00:00:00Z',
    );
  }

  @override
  Future<void> stop(String id) async {
    final gate = stopGate;
    if (gate != null) await gate.future;
    final error = stopError;
    if (error is Object) throw error;
    stopped.add(id);
  }

  @override
  Future<OrbRecord> wake(String id) async {
    final gate = wakeGate;
    if (gate != null) await gate.future;
    final error = wakeError;
    if (error is Object) throw error;
    woken.add(id);
    final record = wakeRecord;
    if (record != null) return record;
    return OrbRecord(
      id: id,
      name: 'woken',
      project: 'p1',
      branch: 'orb/$id',
      state: 'running',
      created: '2025-01-03T00:00:00Z',
    );
  }

  @override
  Future<Session> createSessionOnOrb(String id) async {
    final gate = newSessionGate;
    if (gate != null) await gate.future;
    final error = newSessionError;
    if (error is Object) throw error;
    newSessions.add(id);
    final record = newSessionRecord;
    if (record != null) return record;
    return const Session(
      id: 'ses_orb_new',
      title: 'new on orb',
      project: SessionProject(id: 'p1', name: 'app'),
      created: 300,
      location: '/workspace',
      active: false,
    );
  }
}

/// A scripted [SessionsClient] for the tab tests (no real bridge): the
/// per-card session count and the wizard's project picker.
class _FakeSessionsClient extends SessionsClient {
  _FakeSessionsClient({this.rows = const [], this.projectsResult = const []})
    : super(Uri.parse('http://bridge.test/'));

  final List<Session> rows;
  final List<Project> projectsResult;

  Object? listError;
  Object? projectsError;
  var listCalls = 0;

  @override
  Future<List<Session>> list() async {
    listCalls++;
    final error = listError;
    if (error is Object) throw error;
    return rows;
  }

  @override
  Future<List<Project>> projects() async {
    final error = projectsError;
    if (error is Object) throw error;
    return projectsResult;
  }

  // The endpoints the opened structured view fetches (issue #97's New
  // session): not scripted here — the view's error state stands in for them,
  // no real bridge is reached.
  @override
  Future<SessionDetail> getDetail(String id) async {
    throw const SessionsClientError(502, 'not scripted');
  }

  @override
  Future<List<SessionMessage>> getMessages(String id) async {
    throw const SessionsClientError(502, 'not scripted');
  }

  @override
  Future<List<PermissionRequest>> getPermissions(String id) async {
    throw const SessionsClientError(502, 'not scripted');
  }

  @override
  Future<List<QuestionForm>> getQuestions(String id) async {
    throw const SessionsClientError(502, 'not scripted');
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

  @override
  Future<void> reconnect() async {}

  /// One line of an orb's boot log onto the stream (spec §8).
  void emitOrbBoot(String id, String line) {
    _controller.add(
      BridgeEvent(
        id: 'evt',
        created: 0,
        type: BridgeEventType.orbBoot,
        data: {'id': id, 'line': line},
      ),
    );
  }
}

Future<
  ({
    _FakeOrbsClient orbs,
    _FakeSessionsClient sessions,
    _FakeEventsSource events,
  })
>
_pumpTab(
  WidgetTester tester, {
  List<OrbRecord> orbs = const [],
  List<Session> sessionRows = const [],
  List<Project> projects = const [],
  _FakeEventsSource? events,
  Object? listError,
  Object? projectsError,
  String? highlight,
  VoidCallback? onHighlightConsumed,
}) async {
  final orbsClient = _FakeOrbsClient(orbs: List<OrbRecord>.of(orbs));
  orbsClient.listError = listError;
  final sessionsClient = _FakeSessionsClient(
    rows: List<Session>.of(sessionRows),
    projectsResult: List<Project>.of(projects),
  );
  sessionsClient.projectsError = projectsError;
  final eventsSource = events ?? _FakeEventsSource();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OrbsTab(
          apiBase: Uri.parse('http://bridge.test/'),
          client: orbsClient,
          sessions: sessionsClient,
          events: eventsSource,
          highlight: highlight,
          onHighlightConsumed: onHighlightConsumed,
        ),
      ),
    ),
  );
  await tester.pump();
  return (orbs: orbsClient, sessions: sessionsClient, events: eventsSource);
}

/// The FAB opens the wizard's sheet: the sheet slides in over the default
/// 250 ms bottom-sheet animation, so the clock has to advance past it
/// (plain pumps keep `animationValue` at 0 and the sheet stays below the
/// viewport). The project list then lands on one more frame — the fake's
/// fetch is a microtask.
Future<void> _openWizard(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('orbs-fab')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// Picks the project, types the name, and submits the wizard's form.
Future<void> _submitWizard(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('orb-project-p1')));
  await tester.pump();
  await tester.enterText(find.byKey(const ValueKey('orb-name')), name);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('create-orb')));
  await tester.pump();
}

/// How many action buttons the card of [orbId] carries.
int _actionsOf(WidgetTester tester, String orbId) => find
    .byWidgetPredicate(
      (w) =>
          w.key is ValueKey &&
          (w.key as ValueKey).value is String &&
          ((w.key as ValueKey).value as String).startsWith(
            'orb-action-$orbId-',
          ),
    )
    .evaluate()
    .length;

void main() {
  group('OrbsTab', () {
    group('card grid', () {
      testWidgets(
        'a running card shows the name, project · branch, state and sessions',
        (tester) async {
          final tab = await _pumpTab(
            tester,
            orbs: [_running],
            sessionRows: [_sessionA, _sessionB],
          );

          expect(find.byKey(const ValueKey('orb-orb_1')), findsOneWidget);
          expect(find.text('api'), findsOneWidget);
          expect(find.text('p1 · orb/orb_1'), findsOneWidget);
          expect(find.text('running'), findsOneWidget);
          expect(find.text('2 sessions'), findsOneWidget);
          // The Orbs tab is the only caller that asks for the PR enrichment.
          expect(tab.orbs.listIncludePr, [true]);
        },
      );

      testWidgets('a single session is singular', (tester) async {
        await _pumpTab(tester, orbs: [_running], sessionRows: [_sessionA]);
        expect(find.text('1 session'), findsOneWidget);
      });

      testWidgets('a preparing card shows the current boot stage', (
        tester,
      ) async {
        await _pumpTab(tester, orbs: [_preparing]);
        expect(find.text('preparing'), findsOneWidget);
        expect(find.text('stage: cloning'), findsOneWidget);
      });

      testWidgets('broken cards name the missing part', (tester) async {
        await _pumpTab(tester, orbs: [_brokenWorkspace, _brokenState]);
        expect(find.text('broken'), findsNWidgets(2));
        expect(find.text('workspace volume missing'), findsOneWidget);
        expect(find.text('state directory missing'), findsOneWidget);
      });

      testWidgets('a cleanup-pending card shows the reason', (tester) async {
        await _pumpTab(tester, orbs: [_cleanupPending]);
        expect(find.text('cleanup pending'), findsOneWidget);
        expect(find.text('uncommitted work'), findsOneWidget);
      });

      testWidgets('an orphan card wears the orphaned state', (tester) async {
        await _pumpTab(tester, orbs: [_orphan]);
        expect(find.text('orphaned'), findsOneWidget);
        expect(find.text('volumes without a container'), findsOneWidget);
      });

      testWidgets('the PR badge renders only for an open PR', (tester) async {
        await _pumpTab(tester, orbs: [_prOpen, _prMerged]);
        expect(find.byKey(const ValueKey('pr-orb_8')), findsOneWidget);
        expect(find.byKey(const ValueKey('pr-orb_9')), findsNothing);
      });
    });

    group('card actions (gated by state, tickets as tooltips)', () {
      testWidgets(
        'a running card carries Stop, New session, Update and Force delete',
        (tester) async {
          await _pumpTab(tester, orbs: [_running]);
          expect(_actionsOf(tester, 'orb_1'), 4);
          expect(
            find.byKey(const ValueKey('orb-action-orb_1-Stop')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('orb-action-orb_1-New session')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('orb-action-orb_1-Update')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('orb-action-orb_1-Force delete')),
            findsOneWidget,
          );
          // All four are wired (issues #97 and #98).
          for (final label in const [
            'Stop',
            'New session',
            'Update',
            'Force delete',
          ]) {
            expect(
              tester
                  .widget<TextButton>(
                    find.byKey(ValueKey('orb-action-orb_1-$label')),
                  )
                  .onPressed,
              isNotNull,
            );
          }
        },
      );

      testWidgets('a stopped card carries Wake, Update and Force delete', (
        tester,
      ) async {
        await _pumpTab(tester, orbs: [_stopped]);
        expect(_actionsOf(tester, 'orb_3'), 3);
        expect(
          find.byKey(const ValueKey('orb-action-orb_3-Wake')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('orb-action-orb_3-Update')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('orb-action-orb_3-Force delete')),
          findsOneWidget,
        );
        // All three are wired (issues #97 and #98).
        for (final label in const ['Wake', 'Update', 'Force delete']) {
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(ValueKey('orb-action-orb_3-$label')),
                )
                .onPressed,
            isNotNull,
          );
        }
      });

      testWidgets('a broken:workspace card carries Force delete', (
        tester,
      ) async {
        await _pumpTab(tester, orbs: [_brokenWorkspace]);
        expect(_actionsOf(tester, 'orb_4'), 1);
        expect(
          find.byKey(const ValueKey('orb-action-orb_4-Force delete')),
          findsOneWidget,
        );
      });

      testWidgets('a broken:state card carries Force delete and Fresh state', (
        tester,
      ) async {
        await _pumpTab(tester, orbs: [_brokenState]);
        expect(_actionsOf(tester, 'orb_5'), 2);
        expect(
          find.byKey(const ValueKey('orb-action-orb_5-Force delete')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('orb-action-orb_5-Fresh state')),
          findsOneWidget,
        );
      });

      testWidgets('preparing and cleanup-pending cards carry no actions', (
        tester,
      ) async {
        await _pumpTab(tester, orbs: [_preparing, _cleanupPending]);
        expect(_actionsOf(tester, 'orb_2'), 0);
        expect(_actionsOf(tester, 'orb_7'), 0);
      });

      testWidgets('an orphan card carries an enabled Clean up', (tester) async {
        await _pumpTab(tester, orbs: [_orphan]);
        final button = tester.widget<TextButton>(
          find.byKey(const ValueKey('orb-action-orb_6-Clean up')),
        );
        expect(button.onPressed, isNotNull);
      });
    });

    group('orphan cleanup', () {
      testWidgets('Clean up confirms, then deletes, reloads and reports', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_orphan]);

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_6-Clean up')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Clean up the orphan?'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('orb-clean-confirm')));
        await tester.pumpAndSettle();

        expect(tab.orbs.deleted, ['orb_6']);
        expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
        expect(find.text('Orphan cleaned up.'), findsOneWidget);
      });

      testWidgets('cancelling the confirm keeps the orphan', (tester) async {
        final tab = await _pumpTab(tester, orbs: [_orphan]);

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_6-Clean up')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(tab.orbs.deleted, isEmpty);
        expect(find.byKey(const ValueKey('orb-orb_6')), findsOneWidget);
      });

      testWidgets('a failed cleanup reports the failure', (tester) async {
        final tab = await _pumpTab(tester, orbs: [_orphan]);
        tab.orbs.deleteError = const OrbsClientError(409, 'orb_exists');

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_6-Clean up')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('orb-clean-confirm')));
        await tester.pumpAndSettle();

        expect(find.text('Could not clean up the orphan.'), findsOneWidget);
      });
    });

    group('lifecycle (issue #97)', () {
      testWidgets('Stop confirms, then stops, reloads and reports', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_1-Stop')));
        await tester.pumpAndSettle();
        expect(find.text('Stop this orb?'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('orb-stop-confirm')));
        await tester.pumpAndSettle();

        expect(tab.orbs.stopped, ['orb_1']);
        expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
        expect(find.text('Orb stopped.'), findsOneWidget);
      });

      testWidgets('cancelling the stop confirm keeps the orb', (tester) async {
        final tab = await _pumpTab(tester, orbs: [_running]);

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_1-Stop')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(tab.orbs.stopped, isEmpty);
        expect(find.byKey(const ValueKey('orb-orb_1')), findsOneWidget);
      });

      testWidgets('a failed stop reports the decoded wire error', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);
        tab.orbs.stopError = const OrbsClientError(503, 'opencode_unavailable');

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_1-Stop')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('orb-stop-confirm')));
        await tester.pumpAndSettle();

        expect(tab.orbs.stopped, isEmpty);
        expect(
          find.text('Could not stop the orb: opencode_unavailable'),
          findsOneWidget,
        );
      });

      testWidgets('the Stop button carries its busy label over the move', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);
        final gate = Completer<void>();
        tab.orbs.stopGate = gate;

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_1-Stop')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('orb-stop-confirm')));
        await tester.pump();

        expect(find.text('Stopping…'), findsOneWidget);
        expect(tab.orbs.stopped, isEmpty);

        gate.complete();
        await tester.pumpAndSettle();

        expect(tab.orbs.stopped, ['orb_1']);
        expect(find.text('Stopping…'), findsNothing);
      });

      testWidgets('Wake wakes without confirming, then reloads and reports', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_stopped]);

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_3-Wake')));
        await tester.pumpAndSettle();

        expect(tab.orbs.woken, ['orb_3']);
        expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
        expect(find.text('Orb woken.'), findsOneWidget);
      });

      testWidgets('a failed wake reports the decoded error', (tester) async {
        final tab = await _pumpTab(tester, orbs: [_stopped]);
        tab.orbs.wakeError = const OrbCreateError(
          statusCode: 502,
          code: 'orb_boot_failed',
          details: 'the orb did not come up in time',
          logTail: ['fatal: no go'],
        );

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_3-Wake')));
        await tester.pumpAndSettle();

        expect(tab.orbs.woken, isEmpty);
        expect(
          find.text('Could not wake the orb: the orb did not come up in time'),
          findsOneWidget,
        );
      });

      testWidgets('the Wake button carries its busy label over the boot', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_stopped]);
        final gate = Completer<void>();
        tab.orbs.wakeGate = gate;

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_3-Wake')));
        await tester.pump();

        expect(find.text('Waking…'), findsOneWidget);
        expect(tab.orbs.woken, isEmpty);

        gate.complete();
        await tester.pumpAndSettle();

        expect(tab.orbs.woken, ['orb_3']);
        expect(find.text('Waking…'), findsNothing);
      });

      testWidgets(
        'New session creates on the orb and opens the structured view',
        (tester) async {
          final tab = await _pumpTab(tester, orbs: [_running]);

          await tester.tap(
            find.byKey(const ValueKey('orb-action-orb_1-New session')),
          );
          await tester.pumpAndSettle();

          expect(tab.orbs.newSessions, ['orb_1']);
          expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
          // The new session's structured view is on top…
          expect(find.byType(StructuredSessionScreen), findsOneWidget);
          expect(find.text('new on orb'), findsOneWidget);
        },
      );

      testWidgets('a failed New session reports the decoded error', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);
        tab.orbs.newSessionError = const OrbCreateError(
          statusCode: 400,
          code: 'not_running',
          details: 'the orb is stopped',
        );

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_1-New session')),
        );
        await tester.pumpAndSettle();

        expect(tab.orbs.newSessions, isEmpty);
        expect(
          find.text('Could not create the session: the orb is stopped'),
          findsOneWidget,
        );
        expect(find.byType(StructuredSessionScreen), findsNothing);
      });
    });

    group('exit paths (issue #98)', () {
      testWidgets(
        'Update updates without confirming, then reloads and reports',
        (tester) async {
          final tab = await _pumpTab(tester, orbs: [_running]);

          await tester.tap(
            find.byKey(const ValueKey('orb-action-orb_1-Update')),
          );
          await tester.pumpAndSettle();

          // No confirm dialog — the update is lossless.
          expect(tab.orbs.updated, ['orb_1']);
          expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
          expect(find.text('Orb updated.'), findsOneWidget);
        },
      );

      testWidgets('a stopped orb can be updated too', (tester) async {
        final tab = await _pumpTab(tester, orbs: [_stopped]);

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_3-Update')));
        await tester.pumpAndSettle();

        expect(tab.orbs.updated, ['orb_3']);
        expect(find.text('Orb updated.'), findsOneWidget);
      });

      testWidgets('the Update button carries its busy label over the reboot', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);
        final gate = Completer<void>();
        tab.orbs.updateGate = gate;

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_1-Update')));
        await tester.pump();

        expect(find.text('Updating…'), findsOneWidget);
        expect(tab.orbs.updated, isEmpty);

        gate.complete();
        await tester.pumpAndSettle();

        expect(tab.orbs.updated, ['orb_1']);
        expect(find.text('Updating…'), findsNothing);
      });

      testWidgets('a failed update reports the decoded wire error', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);
        tab.orbs.updateError = const OrbCreateError(
          statusCode: 400,
          code: 'update_busy',
          details: 'a session is running',
        );

        await tester.tap(find.byKey(const ValueKey('orb-action-orb_1-Update')));
        await tester.pumpAndSettle();

        expect(tab.orbs.updated, isEmpty);
        expect(
          find.text('Could not update the orb: a session is running'),
          findsOneWidget,
        );
      });

      testWidgets('Force delete confirms, then deletes, reloads and reports', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_1-Force delete')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Force delete this orb?'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('orb-force-delete-confirm')),
        );
        await tester.pumpAndSettle();

        // The protected deletion with the human override.
        expect(tab.orbs.forceDeleted, [('orb_1', true)]);
        expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
        expect(find.text('Orb deleted.'), findsOneWidget);
      });

      testWidgets('cancelling the force-delete confirm keeps the orb', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_1-Force delete')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(tab.orbs.forceDeleted, isEmpty);
        expect(find.byKey(const ValueKey('orb-orb_1')), findsOneWidget);
      });

      testWidgets('a failed force delete reports the decoded wire error', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);
        tab.orbs.forceDeleteError = const OrbsClientError(
          409,
          'deletion_refused',
        );

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_1-Force delete')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('orb-force-delete-confirm')),
        );
        await tester.pumpAndSettle();

        expect(tab.orbs.forceDeleted, isEmpty);
        expect(
          find.text('Could not delete the orb: deletion_refused'),
          findsOneWidget,
        );
      });

      testWidgets('the Force delete button carries its busy label', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_running]);
        final gate = Completer<void>();
        tab.orbs.forceDeleteGate = gate;

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_1-Force delete')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('orb-force-delete-confirm')),
        );
        await tester.pump();

        expect(find.text('Deleting…'), findsOneWidget);
        expect(tab.orbs.forceDeleted, isEmpty);

        gate.complete();
        await tester.pumpAndSettle();

        expect(tab.orbs.forceDeleted, [('orb_1', true)]);
        expect(find.text('Deleting…'), findsNothing);
      });

      testWidgets('a broken:workspace card force-deletes through the dialog', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, orbs: [_brokenWorkspace]);

        await tester.tap(
          find.byKey(const ValueKey('orb-action-orb_4-Force delete')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('orb-force-delete-confirm')),
        );
        await tester.pumpAndSettle();

        expect(tab.orbs.forceDeleted, [('orb_4', true)]);
        expect(find.text('Orb deleted.'), findsOneWidget);
      });
    });

    group('image rebuild', () {
      testWidgets('Rebuild image reports the built tag', (tester) async {
        final tab = await _pumpTab(tester, orbs: [_running]);

        await tester.tap(find.byKey(const ValueKey('orbs-rebuild')));
        await tester.pumpAndSettle();

        expect(tab.orbs.rebuildCalls, 1);
        expect(find.text('Image rebuilt: orb:abc123'), findsOneWidget);
      });

      testWidgets('a failed rebuild reports the failure', (tester) async {
        final tab = await _pumpTab(tester, orbs: [_running]);
        tab.orbs.rebuildError = const OrbsClientError(
          503,
          'docker_unavailable',
        );

        await tester.tap(find.byKey(const ValueKey('orbs-rebuild')));
        await tester.pumpAndSettle();

        expect(find.text('Could not rebuild the image.'), findsOneWidget);
      });
    });

    group('states', () {
      testWidgets('without a bridge the tab points at Settings', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(home: OrbsTab(apiBase: null)),
        );
        await tester.pump();

        expect(
          find.text('No bridge configured. Set the tunnel URL in Settings.'),
          findsOneWidget,
        );
      });

      testWidgets(
        'a bridge that cannot list orbs shows the error with a retry',
        (tester) async {
          final tab = await _pumpTab(
            tester,
            listError: const OrbsClientError(503, 'docker_unavailable'),
          );

          expect(
            find.text('The bridge could not list orbs (status 503).'),
            findsOneWidget,
          );

          // The bridge is back: the retry reloads the (empty) list.
          tab.orbs.listError = null;
          await tester.tap(find.byKey(const ValueKey('orbs-retry')));
          await tester.pump();

          expect(find.text('No orbs yet.'), findsOneWidget);
        },
      );

      testWidgets('an empty list shows the empty state', (tester) async {
        await _pumpTab(tester);
        expect(find.text('No orbs yet.'), findsOneWidget);
      });
    });

    group('create-orb wizard (spec §9.3)', () {
      testWidgets('the FAB opens the form with the project chips', (
        tester,
      ) async {
        await _pumpTab(tester, projects: [_project]);

        await _openWizard(tester);

        expect(find.text('New orb'), findsOneWidget);
        expect(find.byKey(const ValueKey('orb-project-p1')), findsOneWidget);
        expect(find.text('app'), findsOneWidget);
        // The submit is disabled before a project is picked.
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('create-orb')))
              .onPressed,
          isNull,
        );
      });

      testWidgets('the form validates the name and submits the pick', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, projects: [_project]);
        tab.orbs.createGate = Completer<void>();

        await _openWizard(tester);

        // An empty name refuses the submit.
        await tester.tap(find.byKey(const ValueKey('orb-project-p1')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('create-orb')));
        await tester.pump();
        expect(find.text('Give the orb a name.'), findsOneWidget);
        expect(tab.orbs.createdRequests, isEmpty);

        // A name over 40 characters refuses it too.
        await tester.enterText(
          find.byKey(const ValueKey('orb-name')),
          'x' * 41,
        );
        await tester.tap(find.byKey(const ValueKey('create-orb')));
        await tester.pump();
        expect(find.text('Keep the name under 40 characters.'), findsOneWidget);
        expect(tab.orbs.createdRequests, isEmpty);

        // A valid name fires the POST and the sheet stays on the boot.
        await tester.enterText(
          find.byKey(const ValueKey('orb-name')),
          'worker',
        );
        await tester.tap(find.byKey(const ValueKey('create-orb')));
        await tester.pump();
        expect(tab.orbs.createdRequests, [('p1', 'worker')]);
        expect(find.byKey(const ValueKey('boot-log')), findsOneWidget);
        expect(find.text('Waiting for the boot to start…'), findsOneWidget);
      });

      testWidgets(
        'boot lines of the new orb stream into the sheet, not the known orbs',
        (tester) async {
          final tab = await _pumpTab(
            tester,
            orbs: [_running],
            projects: [_project],
          );
          tab.orbs.createGate = Completer<void>();

          await _openWizard(tester);
          await _submitWizard(tester, 'worker');

          // The known orb's stage line does not leak into the sheet…
          tab.events.emitOrbBoot('orb_1', '[orb] stage: ready');
          await tester.pump();
          expect(find.text('[orb] stage: ready'), findsNothing);

          // …but the new orb's lines do (its id is minted by the bridge).
          tab.events.emitOrbBoot('orb_new', '[orb] stage: cloning');
          await tester.pump();
          expect(find.text('[orb] stage: cloning'), findsOneWidget);
        },
      );

      testWidgets(
        'a stage line re-fetches the list: the card appears behind the sheet',
        (tester) async {
          final tab = await _pumpTab(
            tester,
            orbs: [_running],
            projects: [_project],
          );
          tab.orbs.createGate = Completer<void>();

          await _openWizard(tester);
          await _submitWizard(tester, 'worker');

          // The bridge answers the list with the new orb from now on.
          tab.orbs.orbs.add(_workerRecord);
          tab.events.emitOrbBoot('orb_new', '[orb] stage: services');
          await tester.pump();

          expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
          expect(find.byKey(const ValueKey('orb-orb_new')), findsOneWidget);
        },
      );

      testWidgets('the ready phase lands on the created record', (
        tester,
      ) async {
        final tab = await _pumpTab(
          tester,
          orbs: [_running],
          projects: [_project],
        );
        final gate = Completer<void>();
        tab.orbs.createGate = gate;
        tab.orbs.created = _workerRecord;

        await _openWizard(tester);
        await _submitWizard(tester, 'worker');

        gate.complete();
        await tester.pumpAndSettle();

        expect(find.text('worker is up'), findsOneWidget);
        expect(find.byKey(const ValueKey('orb-ready-close')), findsOneWidget);
        // The grid was reloaded behind the sheet.
        expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
      });

      testWidgets('a name refusal lands on the failed phase with its details', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, projects: [_project]);
        final gate = Completer<void>();
        tab.orbs.createGate = gate;
        tab.orbs.createError = const OrbCreateError(
          statusCode: 409,
          code: OrbCreateError.nameTaken,
          details: 'An orb named "worker" already exists.',
        );

        await _openWizard(tester);
        await _submitWizard(tester, 'worker');

        gate.complete();
        await tester.pumpAndSettle();

        expect(find.text('The orb could not be created.'), findsOneWidget);
        expect(
          find.text('An orb named "worker" already exists.'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('orb-failed-close')), findsOneWidget);
      });

      testWidgets('a failed boot lands on the failed phase with its log tail', (
        tester,
      ) async {
        final tab = await _pumpTab(tester, projects: [_project]);
        final gate = Completer<void>();
        tab.orbs.createGate = gate;
        tab.orbs.createError = const OrbCreateError(
          statusCode: 502,
          code: OrbCreateError.bootFailed,
          details: 'the container exited',
          logTail: ['[orb] stage: cloning', 'fatal: bad url'],
        );

        await _openWizard(tester);
        await _submitWizard(tester, 'worker');

        gate.complete();
        await tester.pumpAndSettle();

        expect(find.text('The orb could not be created.'), findsOneWidget);
        expect(find.text('the container exited'), findsOneWidget);
        expect(find.text('fatal: bad url'), findsOneWidget);
      });

      testWidgets('closing the sheet mid-boot lets the boot finish', (
        tester,
      ) async {
        final tab = await _pumpTab(
          tester,
          orbs: [_running],
          projects: [_project],
        );
        final gate = Completer<void>();
        tab.orbs.createGate = gate;
        tab.orbs.created = _workerRecord;

        await _openWizard(tester);
        await _submitWizard(tester, 'worker');

        // The sheet closes; the POST keeps running at the tab level.
        await tester.tap(find.byKey(const ValueKey('orb-sheet-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('boot-log')), findsNothing);

        gate.complete();
        await tester.pumpAndSettle();

        expect(tab.orbs.createdRequests, [('p1', 'worker')]);
        // The finished create reloaded the grid.
        expect(tab.orbs.listCalls, greaterThanOrEqualTo(2));
      });

      testWidgets('a failed project list degrades the picker', (tester) async {
        await _pumpTab(
          tester,
          projects: [_project],
          projectsError: const SessionsClientError(503, 'docker_unavailable'),
        );

        await _openWizard(tester);

        expect(find.text('Could not load the projects.'), findsOneWidget);
      });
    });

    group('highlight (spec §9.2)', () {
      testWidgets('an initial highlight borders the card', (tester) async {
        await _pumpTab(tester, orbs: [_running], highlight: 'orb_1');

        final card = tester.widget<Container>(
          find.byKey(const ValueKey('orb-orb_1')),
        );
        expect((card.decoration as BoxDecoration).border, isA<Border>());
      });

      testWidgets(
        'a highlight update borders the card, reports consumption, and a tap clears it',
        (tester) async {
          final client = _FakeOrbsClient(orbs: [_running]);
          final sessions = _FakeSessionsClient();
          final events = _FakeEventsSource();
          final consumed = <int>[];

          Widget tree({String? highlight}) => MaterialApp(
            home: Scaffold(
              body: OrbsTab(
                apiBase: Uri.parse('http://bridge.test/'),
                client: client,
                sessions: sessions,
                events: events,
                highlight: highlight,
                onHighlightConsumed: () => consumed.add(1),
              ),
            ),
          );

          await tester.pumpWidget(tree());
          await tester.pump();
          expect(consumed, isEmpty);

          // The chip tap arrives as a widget update (the tab is already
          // mounted in the shell's IndexedStack).
          await tester.pumpWidget(tree(highlight: 'orb_1'));
          await tester.pump();

          final card = tester.widget<Container>(
            find.byKey(const ValueKey('orb-orb_1')),
          );
          expect((card.decoration as BoxDecoration).border, isA<Border>());
          // The consumption is reported after the frame.
          expect(consumed, [1]);

          // Tapping the highlighted card clears it locally (the tap lands
          // on the card's title row — the action buttons absorb their own
          // taps).
          await tester.tapAt(
            tester.getTopLeft(find.byKey(const ValueKey('orb-orb_1'))) +
                const Offset(24, 24),
          );
          await tester.pump();
          final cleared = tester.widget<Container>(
            find.byKey(const ValueKey('orb-orb_1')),
          );
          expect((cleared.decoration as BoxDecoration).border, isNull);
        },
      );
    });
  });
}
