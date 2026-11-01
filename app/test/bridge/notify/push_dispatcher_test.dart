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

  String opencode(String type, {String? session = 'ses_1'}) =>
      jsonEncode({
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

  test(
      'permission.asked carries its session in data.sessionID (the real '
      'wire shape: no durable seq)', () async {
    await dispatcher.write(jsonEncode({
      'id': 'evt_2',
      'type': 'permission.asked',
      'data': {'sessionID': 'ses_live', 'action': 'shell'},
    }));
    expect(sender.sent, hasLength(1));
    final sent = sender.sent.single;
    expect(sent.title, 'Permission requested');
    expect(sent.body, 'label-ses_live');
    expect(sent.link, 'opencodebridge://session/ses_live');
  });

  test('each execution outcome pushes turnEnded with its title', () async {
    await dispatcher.write(opencode('session.execution.succeeded'));
    await dispatcher.write(opencode('session.execution.failed'));
    await dispatcher.write(opencode('session.execution.interrupted'));
    expect(
      sender.sent.map((s) => s.title),
      ['Turn finished', 'Turn failed', 'Turn interrupted'],
    );
    expect(
      sender.sent.every(
        (s) => s.link == 'opencodebridge://session/ses_1',
      ),
      isTrue,
    );
  });

  test('an opencode event with no session id anywhere is not a push',
      () async {
    await dispatcher.write(opencode('permission.asked', session: null));
    expect(sender.sent, isEmpty);
  });

  test('docker.container.stopped pushes the container link', () async {
    await dispatcher.write(jsonEncode({
      'type': 'docker.container.stopped',
      'data': {'name': 'postgres'},
    }));
    expect(sender.sent, hasLength(1));
    final sent = sender.sent.single;
    expect(sent.title, 'Container stopped');
    expect(sent.body, 'postgres');
    expect(sent.link, 'opencodebridge://container/postgres');
  });

  test('docker.container.crashed pushes the exit code in the body', () async {
    await dispatcher.write(jsonEncode({
      'type': 'docker.container.crashed',
      'data': {'name': 'postgres', 'exitCode': 137},
    }));
    final sent = sender.sent.single;
    expect(sent.title, 'Container crashed');
    expect(sent.body, 'postgres (exit 137)');
    expect(sent.link, 'opencodebridge://container/postgres');
  });

  test('a docker event without a container name is not a push', () async {
    await dispatcher.write(jsonEncode({
      'type': 'docker.container.stopped',
      'data': <String, Object?>{},
    }));
    expect(sender.sent, isEmpty);
  });

  test('every other event on the stream is not a push', () async {
    await dispatcher.write(opencode('session.updated'));
    await dispatcher.write(jsonEncode({'type': 'message.part.updated'}));
    await dispatcher.write('not json at all');
    expect(sender.sent, isEmpty);
  });

  test(
      'the body falls back to the session id when the labeler '
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
    upstream.add(OpencodeEvent(
      raw: opencode('session.execution.succeeded'),
      type: 'session.execution.succeeded',
    ));
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
  }) async {
    sent.add(_Sent(token, title, body, link));
  }
}

class _Sent {
  const _Sent(this.token, this.title, this.body, this.link);

  final String token;
  final String title;
  final String body;
  final String link;
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
