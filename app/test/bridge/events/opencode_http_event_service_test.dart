import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';
import 'package:opencodebridge/bridge/events/opencode_http_event_service.dart';

void main() {
  const password = 'secret';

  late HttpServer server;
  late Uri base;
  int connections = 0;
  String? lastAuth;
  // When true the server 401s the first attempt (auth failure) then serves.
  bool firstAttemptFailsAuth = false;

  setUp(() async {
    connections = 0;
    lastAuth = null;
    firstAttemptFailsAuth = false;
    server = await HttpServer.bind('127.0.0.1', 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((req) async {
      final resp = req.response;
      if (req.uri.path != '/api/event') {
        resp.statusCode = HttpStatus.notFound;
        await resp.close();
        return;
      }
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      lastAuth = auth;
      final expected =
          'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
      final n = ++connections;
      if (auth != expected || (firstAttemptFailsAuth && n == 1)) {
        resp.statusCode = HttpStatus.unauthorized;
        await resp.close();
        return;
      }
      resp.headers.contentType = ContentType.parse('text/event-stream');
      resp.bufferOutput = false;
      if (n == 1) {
        // First "service instance": one event, then it goes away (restart).
        resp.write(': heartbeat\n\n');
        resp.write(_frame(1));
        await resp.close();
      } else {
        // Second (restarted) instance: keeps serving.
        resp.write(_frame(2));
        await resp.done; // Hold until the client disconnects.
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  group('OpencodeHttpEventService', () {
    test(
      'emits events (verbatim raw + parsed), drops heartbeats, re-subscribes '
      'across a service restart, and sends Basic auth',
      () async {
        final service = OpencodeHttpEventService(
          baseUrl: base,
          password: password,
          reconnectDelay: const Duration(milliseconds: 5),
        );
        final seen = <OpencodeEvent>[];
        final subscription = service.events.listen(seen.add);
        await _until(
          () => seen.length >= 2,
          message: 'expected 2 events across the restart',
        );
        expect(seen.map((e) => e.type).toList(), [
          'session.execution.started',
          'session.usage.updated',
        ]);
        expect(seen[0].seq, 1);
        expect(seen[1].seq, 2);
        expect(seen[0].aggregateID, 'ses_x');
        expect(
          seen[0].raw,
          _payload(1),
          reason: 'raw must be the verbatim data-field payload',
        );
        expect(
          connections,
          greaterThanOrEqualTo(2),
          reason: 'the service must have re-subscribed',
        );
        expect(
          lastAuth,
          'Basic ${base64Encode(utf8.encode('opencode:$password'))}',
        );
        await subscription.cancel();
        await service.close();
      },
    );

    test('a 401 is survived: the service retries and then emits', () async {
      firstAttemptFailsAuth = true;
      // Two "restarts" of the service: both 401 first, then serve.
      final service = OpencodeHttpEventService(
        baseUrl: base,
        password: password,
        reconnectDelay: const Duration(milliseconds: 5),
      );
      final seen = <OpencodeEvent>[];
      final subscription = service.events.listen(seen.add);
      await _until(
        () => seen.isNotEmpty,
        message: 'expected an event after the auth retry',
      );
      expect(seen.first.type, isNot(isEmpty));
      await subscription.cancel();
      await service.close();
    });

    test('close() stops the subscription', () async {
      final service = OpencodeHttpEventService(
        baseUrl: base,
        password: password,
        reconnectDelay: const Duration(milliseconds: 5),
      );
      var done = false;
      final subscription = service.events.listen(
        (_) {},
        onDone: () => done = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.close();
      expect(service.events, isNot(null));
      expect(done, isTrue, reason: 'the events stream completes on close');
      await subscription.cancel();
    });

    test('fromHost reads url + password from the descriptor', () async {
      final dir = await Directory.systemTemp.createTemp('opencode-events');
      final file = File('${dir.path}/service.json');
      await file.writeAsString(
        jsonEncode({'url': base.toString(), 'password': password}),
      );
      try {
        final service = await OpencodeHttpEventService.fromHost(
          statePath: file.path,
        );
        final seen = <OpencodeEvent>[];
        final subscription = service.events.listen(seen.add);
        await _until(() => seen.isNotEmpty, message: 'expected an event');
        expect(seen.first.seq, isNotNull);
        await subscription.cancel();
        await service.close();
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('a non-http base is rejected', () {
      expect(
        () => OpencodeHttpEventService(
          baseUrl: Uri.parse('ftp://host/'),
          password: password,
        ),
        throwsArgumentError,
      );
    });
  });
}

String _payload(int seq) =>
    '{"id":"evt_$seq","created":$seq,"type":'
    '${seq == 1 ? '"session.execution.started"' : '"session.usage.updated"'},'
    '"data":{"n":$seq},"durable":{"aggregateID":"ses_x","seq":$seq,"version":1}}';

String _frame(int seq) => 'data: ${_payload(seq)}\n\n';

Future<void> _until(
  bool Function() condition, {
  String message = 'condition',
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
