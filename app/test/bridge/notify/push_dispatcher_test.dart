import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/event_hub.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';
import 'package:opencodebridge/bridge/notify/fcm_sender.dart';
import 'package:opencodebridge/bridge/notify/notify_service.dart';
import 'package:opencodebridge/bridge/notify/push_dispatcher.dart';
import 'package:opencodebridge/notify/notify_kind.dart';

void main() {
  late _FakeSender sender;
  late NotifyService service;
  late PushDispatcher dispatcher;

  setUp(() {
    sender = _FakeSender();
    service = NotifyService(sender: sender);
    service.registerDevice('tok', NotifyKind.values.toSet());
    dispatcher = PushDispatcher(
      service,
      sessionLabel: (id) async => 'label-$id',
    );
  });

  tearDown(() async {
    await dispatcher.close();
  });

  String opencode(String type, {String? session = 'ses_1'}) => jsonEncode({
    'id': 'evt_1',
    'type': type,
    'data': <String, Object?>{},
    if (session != null)
      'durable': {'aggregateID': session, 'seq': 1, 'version': 1},
  });

  test('permission.asked pushes permissionAsked to the session link', () async {
    await dispatcher.write(opencode('permission.asked'));
    expect(sender.sent, hasLength(1));
    final sent = sender.sent.single;
    expect(sent.token, 'tok');
    expect(sent.title, 'Permission requested');
    expect(sent.body, 'label-ses_1');
    expect(sent.link, 'opencodebridge://session/ses_1');
  });

  test('permission.asked carries its session in data.sessionID (the real '
      'wire shape: no durable seq)', () async {
    await dispatcher.write(
      jsonEncode({
        'id': 'evt_2',
        'type': 'permission.asked',
        'data': {'sessionID': 'ses_live', 'action': 'shell'},
      }),
    );
    expect(sender.sent, hasLength(1));
    final sent = sender.sent.single;
    expect(sent.title, 'Permission requested');
    expect(sent.body, 'label-ses_live');
    expect(sent.link, 'opencodebridge://session/ses_live');
  });

  test('a session id that arrives only as the form-nested id is resolved by '
      'the envelope (issue #256, S2c)', () async {
    // The session id arrives ONLY as `data.form.sessionID`: no durable seq,
    // no top-level `data.sessionID`. The shared envelope's form-nested branch
    // must resolve it, so the dispatcher attributes the push to that session
    // — the decode did not drop the frame.
    await dispatcher.write(
      jsonEncode({
        'id': 'evt_3',
        'type': 'permission.asked',
        'data': {
          'form': {'sessionID': 'ses_form'},
        },
      }),
    );
    expect(sender.sent, hasLength(1));
    final sent = sender.sent.single;
    expect(sent.title, 'Permission requested');
    expect(sent.body, 'label-ses_form');
    expect(sent.link, 'opencodebridge://session/ses_form');
  });

  test('each execution outcome pushes turnEnded with its title', () async {
    await dispatcher.write(opencode('session.execution.succeeded'));
    await dispatcher.write(opencode('session.execution.failed'));
    await dispatcher.write(opencode('session.execution.interrupted'));
    expect(sender.sent.map((s) => s.title), [
      'Turn finished',
      'Turn failed',
      'Turn interrupted',
    ]);
    expect(
      sender.sent.every((s) => s.link == 'opencodebridge://session/ses_1'),
      isTrue,
    );
  });

  test('an opencode event with no session id anywhere is not a push', () async {
    await dispatcher.write(opencode('permission.asked', session: null));
    expect(sender.sent, isEmpty);
  });

  test(
    'a cancelled turn pushes "Turn stopped", not "Turn interrupted"',
    () async {
      // The bridge-native cancel event (no durable seq; the session id in
      // data, like the other bridge-native events).
      await dispatcher.write(
        jsonEncode({
          'id': 'evt_cancel',
          'type': 'session.turn.cancelled',
          'data': {'sessionID': 'ses_1', 'messageID': 'msg_1'},
        }),
      );
      expect(sender.sent, hasLength(1));
      final sent = sender.sent.single;
      expect(sent.title, 'Turn stopped');
      expect(sent.body, 'label-ses_1');
      expect(sent.link, 'opencodebridge://session/ses_1');
    },
  );

  test(
    'the cancel follow-on terminal is not re-announced as interrupted',
    () async {
      // The bridge reports the cancel as "Turn stopped". The service settles
      // the same turn with its own `session.execution.interrupted` — that
      // terminal must not add a second "Turn interrupted" push.
      await dispatcher.write(opencode('session.execution.started'));
      await dispatcher.write(
        jsonEncode({
          'id': 'evt_cancel',
          'type': 'session.turn.cancelled',
          'data': {'sessionID': 'ses_1', 'messageID': 'msg_1'},
        }),
      );
      await dispatcher.write(opencode('session.execution.interrupted'));
      expect(sender.sent.map((s) => s.title), ['Turn stopped']);
    },
  );

  test(
    'a user interrupt (no bridge cancel) still pushes "Turn interrupted"',
    () async {
      // No `session.turn.cancelled` precedes it: the terminal is a genuine
      // user interrupt, reported as before.
      await dispatcher.write(opencode('session.execution.started'));
      await dispatcher.write(opencode('session.execution.interrupted'));
      expect(sender.sent.map((s) => s.title), ['Turn interrupted']);
    },
  );

  test('a stale cancel marker is cleared by the next turn start', () async {
    // A cancel whose terminal was missed (a service restart in between) must
    // not suppress a later, genuine interrupt of the next turn.
    await dispatcher.write(
      jsonEncode({
        'id': 'evt_cancel',
        'type': 'session.turn.cancelled',
        'data': {'sessionID': 'ses_1', 'messageID': 'msg_1'},
      }),
    );
    await dispatcher.write(opencode('session.execution.started'));
    await dispatcher.write(opencode('session.execution.interrupted'));
    expect(sender.sent.map((s) => s.title), [
      'Turn stopped',
      'Turn interrupted',
    ]);
  });

  test('docker.container.stopped pushes the container link', () async {
    await dispatcher.write(
      jsonEncode({
        'type': 'docker.container.stopped',
        'data': {'name': 'postgres'},
      }),
    );
    expect(sender.sent, hasLength(1));
    final sent = sender.sent.single;
    expect(sent.title, 'Container stopped');
    expect(sent.body, 'postgres');
    expect(sent.link, 'opencodebridge://container/postgres');
  });

  test('docker.container.crashed pushes the exit code in the body', () async {
    await dispatcher.write(
      jsonEncode({
        'type': 'docker.container.crashed',
        'data': {'name': 'postgres', 'exitCode': 137},
      }),
    );
    final sent = sender.sent.single;
    expect(sent.title, 'Container crashed');
    expect(sent.body, 'postgres (exit 137)');
    expect(sent.link, 'opencodebridge://container/postgres');
  });

  test('a docker event without a container name is not a push', () async {
    await dispatcher.write(
      jsonEncode({
        'type': 'docker.container.stopped',
        'data': <String, Object?>{},
      }),
    );
    expect(sender.sent, isEmpty);
  });

  group('the AFK runs (spec #376, T5): the two "look now" moments', () {
    late PushDispatcher dispatcher;

    setUp(() {
      dispatcher = PushDispatcher(
        service,
        sessionLabel: (id) async => 'label-$id',
        // The AFK session the failure push deep-links to (in-app, to read the
        // agent's FAILED narration).
        afkSession: () async => 'ses_afk',
      );
    });

    tearDown(() async {
      await dispatcher.close();
    });

    test('afk.pr_open pushes one high-priority afkRun, deep-linking the PR '
        'in the external browser', () async {
      await dispatcher.write(
        jsonEncode({
          'type': 'afk.pr_open',
          'data': {
            'issueNumber': 7,
            'title': 'Add a README',
            'prNumber': 41,
            'prUrl': 'https://github.com/o/r/pull/41',
          },
        }),
      );
      expect(sender.sent, hasLength(1));
      final sent = sender.sent.single;
      expect(sent.title, 'AFK run : PR ouverte');
      expect(sent.body, 'Add a README · #7');
      expect(sent.link, 'https://github.com/o/r/pull/41');
      expect(sent.highPriority, isTrue);
    });

    test('afk.failed pushes one high-priority afkRun, deep-linking the AFK '
        'session in the app', () async {
      await dispatcher.write(
        jsonEncode({
          'type': 'afk.failed',
          'data': {
            'issueNumber': 7,
            'title': 'Add a README',
            'reason': 'model under load',
          },
        }),
      );
      expect(sender.sent, hasLength(1));
      final sent = sender.sent.single;
      expect(sent.title, 'AFK run : échec');
      expect(sent.body, 'Add a README · #7 — needs-triage');
      expect(sent.link, 'opencodebridge://session/ses_afk');
      expect(sent.highPriority, isTrue);
    });

    test('a retry emits no event, so the dispatcher sends nothing '
        '(a retried run posts no afk event)', () async {
      // The run service emits no event on a retry — only on pr-open and
      // terminal failure. The dispatcher has no retry arm: the only AFK
      // event types it maps are the two "look now" ones. A feed / a
      // re-dispatch (a retry) is not an event at all, so nothing reaches the
      // dispatcher to push.
      await dispatcher.write(opencode('session.updated'));
      expect(sender.sent, isEmpty);
    });

    test('the afkRun kind is delivered to devices that have it enabled, and '
        'silenced for those that have not (armed-but-silenced)', () async {
      // This dispatcher's service has a device with every kind enabled (the
      // file's setUp), so it receives the push. A device registered with only
      // the other kinds is silent for the AFK event (the per-kind toggle
      // filtering lives in the NotifyService).
      final silentSender = _FakeSender();
      final silentService = NotifyService(sender: silentSender);
      silentService.registerDevice('silent', {
        NotifyKind.permissionAsked,
        NotifyKind.turnEnded,
        NotifyKind.dockerContainer,
      });
      final silent = PushDispatcher(
        silentService,
        afkSession: () async => 'ses_afk',
      );
      await silent.write(
        jsonEncode({
          'type': 'afk.pr_open',
          'data': {
            'issueNumber': 7,
            'title': 'Add a README',
            'prNumber': 41,
            'prUrl': 'https://github.com/o/r/pull/41',
          },
        }),
      );
      expect(silentSender.sent, isEmpty);
    });

    test('an afk.pr_open with no PR url is not a push (the deep-link is the '
        'PR)', () async {
      await dispatcher.write(
        jsonEncode({
          'type': 'afk.pr_open',
          'data': {'issueNumber': 7, 'title': 'Add a README'},
        }),
      );
      expect(sender.sent, isEmpty);
    });

    test('an afk event with no title or issue number is not a push', () async {
      await dispatcher.write(
        jsonEncode({
          'type': 'afk.pr_open',
          'data': {'prUrl': 'https://github.com/o/r/pull/41'},
        }),
      );
      expect(sender.sent, isEmpty);
    });

    test('the pushes ride the event hub: a raw SSE consumer of the same '
        'event sees it too (no direct send from the state machine)', () async {
      final upstream = _FakeUpstream();
      final hub = EventHub(service: upstream);
      hub.add(dispatcher);
      final sse = _RecordingSse();
      hub.add(sse);
      upstream.add(
        OpencodeEvent(
          raw: jsonEncode({
            'type': 'afk.pr_open',
            'data': {
              'issueNumber': 7,
              'title': 'Add a README',
              'prNumber': 41,
              'prUrl': 'https://github.com/o/r/pull/41',
            },
          }),
          type: 'afk.pr_open',
        ),
      );
      await _until(() => sender.sent.length == 1);
      // The push went out …
      expect(sender.sent.single.title, 'AFK run : PR ouverte');
      // … and the same frame fanned out to the SSE consumer verbatim.
      expect(sse.payloads, hasLength(1));
      expect(sse.payloads.single, contains('afk.pr_open'));
      await hub.close();
    });
  });

  test('every other event on the stream is not a push', () async {
    await dispatcher.write(opencode('session.updated'));
    await dispatcher.write(jsonEncode({'type': 'message.part.updated'}));
    await dispatcher.write('not json at all');
    expect(sender.sent, isEmpty);
  });

  test('the archive events (issue #235) are not push events: archiving is a '
      'local housekeeping act, merged into the row, not announced', () async {
    await dispatcher.write(opencode('session.archived'));
    await dispatcher.write(opencode('session.unarchived'));
    expect(sender.sent, isEmpty);
  });

  test('the body falls back to the session id when the labeler '
      'is absent or fails', () async {
    final bareSender = _FakeSender();
    final bareService = NotifyService(sender: bareSender);
    bareService.registerDevice('tok', {NotifyKind.turnEnded});
    final bare = PushDispatcher(bareService);
    await bare.write(opencode('session.execution.succeeded'));
    expect(bareSender.sent.single.body, 'ses_1');

    final failingSender = _FakeSender();
    final failingService = NotifyService(sender: failingSender);
    failingService.registerDevice('tok', {NotifyKind.turnEnded});
    final failing = PushDispatcher(
      failingService,
      sessionLabel: (id) async => throw StateError('service down'),
    );
    await failing.write(opencode('session.execution.succeeded'));
    expect(failingSender.sent.single.body, 'ses_1');
  });

  test('attached to the hub, it receives the stream verbatim', () async {
    final upstream = _FakeUpstream();
    final hub = EventHub(service: upstream);
    hub.add(dispatcher);
    upstream.add(
      OpencodeEvent(
        raw: opencode('session.execution.succeeded'),
        type: 'session.execution.succeeded',
      ),
    );
    await _until(() => sender.sent.length == 1);
    expect(sender.sent.single.title, 'Turn finished');
    expect(sender.sent.single.link, 'opencodebridge://session/ses_1');
    await hub.close();
  });

  test('close() completes done', () async {
    await dispatcher.close();
    expect(dispatcher.done, completes);
  });
}

class _FakeSender extends FcmSender {
  final sent = <_Sent>[];

  @override
  Future<void> send({
    required String token,
    required String title,
    required String body,
    required String link,
    bool highPriority = false,
  }) async {
    sent.add(_Sent(token, title, body, link, highPriority));
  }
}

class _Sent {
  const _Sent(this.token, this.title, this.body, this.link, this.highPriority);

  final String token;
  final String title;
  final String body;
  final String link;
  final bool highPriority;
}

/// A raw SSE consumer of the hub: records every verbatim `data:` payload the
/// hub fans out (the app's event-stream connection, for the "the pushes ride
/// the event hub" assertion — an SSE consumer of the same event sees it too).
class _RecordingSse implements EventConnection {
  final payloads = <String>[];

  @override
  Future<void> write(String rawPayload) async => payloads.add(rawPayload);

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Completer<void>().future;
}

/// A scripted upstream event service: one broadcast controller.
class _FakeUpstream implements OpencodeEventService {
  final StreamController<OpencodeEvent> controller =
      StreamController<OpencodeEvent>.broadcast();

  void add(OpencodeEvent event) => controller.add(event);

  @override
  Stream<OpencodeEvent> get events => controller.stream;

  @override
  Future<void> close() async {}
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the push');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
