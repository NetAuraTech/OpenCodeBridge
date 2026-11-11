import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/events/event_hub.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/composite_service.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/paths.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/orb.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// Cancellation end to end (issue #165): the whole cancel path exercised
/// against a scripted service and a scripted event stream, host and orb
/// sessions alike. The app talks only to the bridge, so "end to end" is the
/// app's real clients — [SessionsClient] over the bridge's HTTP cancel/detail
/// routes and [EventsClient] over its SSE stream — pointed at a real
/// [BridgeServer] whose backend is a real [CompositeOpencodeService] routing
/// to scripted services. No real opencode service and no network beyond the
/// bridge's own loopback bind.
void main() {
  late BridgeServer server;
  late Uri base;
  late SessionsClient client;
  late _ScriptedService host;
  late _ScriptedService orb;
  late _FakeEventUpstream events;
  late EventHub hub;

  setUp(() async {
    host = _ScriptedService(session: _hostSession, active: true);
    orb = _ScriptedService(session: _orbSession, active: true);
    final composite = CompositeOpencodeService(
      host: host,
      // One running orb ("orb-1") so the composite reconciles an upstream for
      // it and routes its session to [orb] (not the host).
      orbList: () async => [
        OrbRecord(
          id: 'orb-1',
          name: 'demo',
          project: 'proj',
          branch: 'orb/orb-1',
          state: 'running',
          created: '2026-01-01T00:00:00Z',
          url: 'http://127.0.0.1:41234',
        ),
      ],
      orbPassword: (_) async => 'orb-secret',
      // The orb's upstream is the scripted [orb] service, keyed by the
      // (url|password) the reconciliation derives.
      upstreamFactory: (url, password) {
        // [url] is `Uri.parse(record.url)`; its string is `http://127.0.0.1:41234`
        // (no trailing slash).
        if (url.toString() == 'http://127.0.0.1:41234' &&
            password == 'orb-secret') {
          return orb;
        }
        throw StateError('no scripted upstream for $url|$password');
      },
    );
    events = _FakeEventUpstream();
    hub = EventHub(service: events);
    server = await BridgeServer.start(
      port: 0,
      sessions: SessionsBackend(service: composite),
      events: hub,
    );
    base = server.baseUri;
    client = SessionsClient(base);
  });

  tearDown(() async {
    await server.stop();
    await hub.close();
    await events.close();
  });

  group('host session (issue #165)', () {
    test('a turn started before the view opens routes its cancel to the host '
        'service', () async {
      // The turn is running: the service lists the session active and the
      // history opens mid-turn (no closing idle).
      expect(await host.activeSessionIds(), {'ses_host'});
      final page = await client.getMessagesPage('ses_host');
      expect(page.messages.where((m) => m.role == 'idle'), isEmpty);

      // The app cancels through the bridge (the banner Stop / Escape / /stop
      // all post this one route).
      await client.cancel('ses_host');

      // The cancel landed on the HOST service's interrupt, not the orb's.
      expect(host.cancelled, ['ses_host']);
      expect(orb.cancelled, isEmpty);
    });

    test('a successful cancel emits session.turn.cancelled on the stream', () async {
      // The hub already has at least one downstream connection before this
      // test (the TurnTracker the bridge attached in start), so ">= 1" is no
      // proof the SSE client is live. Baseline the count first, then wait for
      // this client's own HttpEventConnection to land: only once it is in the
      // hub's fan-out does a frame reach it.
      final connectionsBefore = hub.connections;
      final eventsClient = EventsClient(base);
      addTearDown(eventsClient.disconnect);
      await eventsClient.connect();
      await _until(
        () => hub.connections > connectionsBefore,
        message: 'the SSE client attached to the hub',
      );

      final received = <BridgeEvent>[];
      final sub = eventsClient.events.listen(received.add);
      addTearDown(sub.cancel);

      // The turn is running: the bridge's TurnTracker (issue #164) learns the
      // session is mid-turn from the `session.execution.started` on the stream
      // (not the service's active list), and only then does a cancel report a
      // `session.turn.cancelled`. The tracker is in-process (fast) while the
      // SSE read is over HTTP (slow), so waiting for the SSE client to receive
      // the `started` event guarantees the tracker has processed it.
      events.add(_opencodeEvent('session.execution.started', 'ses_host'));
      await _until(
        () => received.any((e) => e.type == 'session.execution.started'),
      );

      // The cancel lands, and the bridge emits its bridge-native
      // cancelled-turn outcome on the unified stream.
      await client.cancel('ses_host');
      await _until(
        () => received.any((e) => e.type == 'session.turn.cancelled'),
      );

      // The cancelled event carries the session id (its only session marker —
      // no durable seq, like session.closed) and is what the home-list dot and
      // the panel settle on.
      final cancelled = received.firstWhere(
        (e) => e.type == 'session.turn.cancelled',
      );
      expect(cancelled.durable, isNull);
      expect(cancelled.data['sessionID'], 'ses_host');
      // And the cancel itself routed to the host service.
      expect(host.cancelled, ['ses_host']);
    });
  });

  group('orb session (issue #165)', () {
    test('its cancel routes to the orb service, not the host', () async {
      // First read the home list (the app does this), so the composite's
      // routing table learns the orb session belongs to orb-1.
      final rows = await client.list();
      expect(rows.where((s) => s.id == 'ses_orb').single.orb, 'orb-1');

      await client.cancel('ses_orb');

      // The cancel reached the ORB's service; the host never saw it.
      expect(orb.cancelled, ['ses_orb']);
      expect(host.cancelled, isEmpty);
    });
  });

  group('failure paths (issue #165)', () {
    test('502 (service down) surfaces the message, keeps the turn, retry '
        'succeeds', () async {
      host.failCancelOnce = true;
      await expectLater(
        client.cancel('ses_host'),
        throwsA(
          isA<SessionsClientError>().having(
            (e) => e.statusCode,
            'statusCode',
            502,
          ),
        ),
      );
      // The failure surfaces (opencode_unreachable) and the turn was NOT
      // cancelled — the running state is retained for the retry.
      expect(host.cancelled, isEmpty);

      // The retry lands now that the service is reachable.
      await client.cancel('ses_host');
      expect(host.cancelled, ['ses_host']);
    });

    test(
      '404 (unknown session) surfaces not_found and cancels nothing',
      () async {
        await expectLater(
          client.cancel('ses_missing'),
          throwsA(
            isA<SessionsClientError>().having(
              (e) => e.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
        expect(host.cancelled, isEmpty);
        expect(orb.cancelled, isEmpty);
      },
    );

    test('503 when the bridge has no sessions backend', () async {
      // Skip on a host that publishes a shared opencode service descriptor:
      // the bridge default then builds a real sessions backend, so a bare
      // start is not backend-less (the 503 path is unreachable there).
      if (_hostHasServiceDescriptor()) return;
      final bare = await BridgeServer.start(port: 0);
      addTearDown(bare.stop);
      final bareClient = SessionsClient(bare.baseUri);
      await expectLater(
        bareClient.cancel('ses_host'),
        throwsA(
          isA<SessionsClientError>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });
  });

  group('unsupported capability (issue #165, ticket 2)', () {
    test(
      'a service without the interrupt route is a 502 at the bridge',
      () async {
        // The host has no interrupt route: the typed refusal maps to 502.
        host.servesInterrupt = false;
        await expectLater(
          client.cancel('ses_host'),
          throwsA(
            isA<SessionsClientError>().having(
              (e) => e.statusCode,
              'statusCode',
              502,
            ),
          ),
        );
        expect(host.cancelled, isEmpty);
      },
    );

    test('the detail read reports canCancel: false, so the view offers no '
        'Stop', () async {
      host.servesInterrupt = false;
      final detail = await client.getDetail('ses_host');
      // The structured view gates its Stop on this (issue #165, ticket #2):
      // false hides the Stop on an Active turn rather than offer a control
      // that would only fail with a 502.
      expect(detail.canCancel, isFalse);
      expect(detail.active, isTrue);

      // A service that serves the route reports it can cancel.
      host.servesInterrupt = true;
      expect((await client.getDetail('ses_host')).canCancel, isTrue);
    });
  });

  group('reopening mid-turn (issue #165)', () {
    test('a turn running from another client shows Active; the stop settles '
        'it on the terminal execution', () async {
      // The turn is already running (started from another client): the
      // service lists the session active and the history is mid-turn.
      expect(await host.activeSessionIds(), {'ses_host'});
      final detail = await client.getDetail('ses_host');
      expect(
        detail.active,
        isTrue,
      ); // the view seeds its Active state from this
      expect(
        (await client.getMessagesPage('ses_host')).messages
            .where((m) => m.role == 'idle'),
        isEmpty,
      );

      // The Stop cancels; the service's terminal event then settles it (the
      // panel and the home-list dot both clear on it — covered by the view
      // and list widget tests).
      await client.cancel('ses_host');
      expect(host.cancelled, ['ses_host']);
    });
  });
}

/// One scripted service: a single session, a mutable interrupt-route
/// capability (the old-binary-without-/interrupt path), and an active flag
/// (so the home-list detail read reports the turn running). Records cancels.
class _ScriptedService implements OpencodeService {
  _ScriptedService({required this.session, required this.active});

  final OpencodeSession session;

  /// Whether the session's turn is running (its detail's [SessionDetail.active]).
  bool active;

  /// When false, the service has no interrupt route (an old binary): the
  /// cancel refuses with the typed [CancelUnsupportedError] (the bridge maps
  /// it to 502) and the capability read reports false.
  bool servesInterrupt = true;

  /// When set, the next cancel throws a service-down error once, then clears
  /// (so the retry succeeds).
  bool failCancelOnce = false;

  /// The session ids cancelled, in order.
  final List<String> cancelled = [];

  @override
  Future<List<OpencodeSession>> listSessions() async => [session];

  @override
  Future<Map<String, String>> projectNames() async => {
    session.projectId: 'proj',
  };

  @override
  Future<Set<String>> activeSessionIds() async =>
      active ? {session.id} : <String>{};

  @override
  Future<SessionDetail> getDetail(String id) async {
    if (id != session.id) {
      throw const OpencodeServiceError(404, 'not found');
    }
    return SessionDetail(
      id: session.id,
      title: session.title,
      location: session.location,
      cost: 0,
      tokens: const TokenUsage(
        input: 0,
        output: 0,
        reasoning: 0,
        cacheRead: 0,
        cacheWrite: 0,
      ),
      active: active,
    );
  }

  @override
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) async {
    // The mid-turn history: a user prompt and an in-flight assistant message,
    // no closing idle (the turn is still running).
    if (id != session.id) throw const OpencodeServiceError(404, 'not found');
    return MessagePage(
      messages: const [
        SessionMessage(role: 'user', text: 'go', created: 0),
        SessionMessage(id: 'm2', role: 'assistant'),
      ],
      nextCursor: null,
    );
  }

  @override
  Future<void> cancelTurn(String id) async {
    if (failCancelOnce) {
      failCancelOnce = false;
      throw const OpencodeServiceError(0, 'service down');
    }
    if (!servesInterrupt) {
      throw const CancelUnsupportedError('this service has no interrupt route');
    }
    if (id != session.id) throw const OpencodeServiceError(404, 'not found');
    cancelled.add(id);
  }

  @override
  Future<bool> canCancelTurn(String id) async => servesInterrupt;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A scripted upstream event service (the bridge's single `GET /api/event`
/// subscription): one broadcast controller.
class _FakeEventUpstream implements OpencodeEventService {
  final controller = StreamController<OpencodeEvent>.broadcast();

  void add(OpencodeEvent event) => controller.add(event);

  @override
  Stream<OpencodeEvent> get events => controller.stream;

  @override
  Future<void> close() async {
    await controller.close();
  }
}

/// True on a host that publishes a shared opencode service descriptor, where
/// the bridge's default builds a real sessions backend (so a bare start is
/// not the backend-less 503 case). Mirrors the guard in
/// `bridge_server_test.dart`.
bool _hostHasServiceDescriptor() {
  if (File('${homeDirectory()}/.local/state/opencode/service.json')
      .existsSync()) {
    markTestSkipped(
      'the host publishes a shared opencode service descriptor, so the '
      'bridge default builds a real sessions backend',
    );
    return true;
  }
  return false;
}

const _hostSession = OpencodeSession(
  id: 'ses_host',
  title: 'host session',
  projectId: 'p1',
  created: 100,
  location: '/host',
);

const _orbSession = OpencodeSession(
  id: 'ses_orb',
  title: 'orb session',
  projectId: 'p1',
  created: 200,
  location: '/orb',
);

/// One durable opencode event in the wire envelope the bridge re-emits
/// verbatim.
OpencodeEvent _opencodeEvent(String type, String sessionId) {
  final raw = jsonEncode({
    'id': 'evt_${type}_1',
    'type': type,
    'data': <String, Object?>{},
    'durable': {'aggregateID': sessionId, 'seq': 1, 'version': 1},
  });
  return OpencodeEvent(raw: raw, type: type, aggregateID: sessionId, seq: 1);
}

Future<void> _until(
  bool Function() condition, {
  String message = 'the condition',
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $message');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
