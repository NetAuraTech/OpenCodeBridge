import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/notify_client.dart';
import 'package:opencodebridge/notify/notify_kind.dart';

void main() {
  late HttpServer server;
  late Uri base;
  Map<String, Object?>? body;
  String? authHeader;
  var status = 200;

  setUp(() async {
    body = null;
    authHeader = null;
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://${server.address.host}:${server.port}/');
    server.listen((request) async {
      final raw = await utf8.decodeStream(request);
      body = jsonDecode(raw) as Map<String, Object?>;
      authHeader = request.headers.value('authorization');
      request.response.statusCode = status;
      request.response.write(jsonEncode({}));
      await request.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  group('NotifyClient.registerDevice', () {
    test('POSTs the token and the enabled events to the device-token path',
        () async {
      await NotifyClient(base).registerDevice(
        'tok_1',
        {NotifyKind.turnEnded, NotifyKind.permissionAsked},
      );
      expect(
        body,
        {
          'token': 'tok_1',
          'events': ['turnEnded', 'permissionAsked'],
        },
      );
      expect(authHeader, isNull);
    });

    test('sends the Access Authorization header when provided', () async {
      await NotifyClient(
        base,
        auth: ({bool forceRefresh = false}) async => 'Bearer test-token',
      ).registerDevice(
        'tok_1',
        {NotifyKind.dockerContainer},
      );
      expect(authHeader, 'Bearer test-token');
      expect(body!['events'], ['dockerContainer']);
    });

    test('a non-200 answer is a NotifyClientError with the status', () async {
      status = 400;
      Object? error;
      try {
        await NotifyClient(base).registerDevice('tok_1', {});
      } catch (e) {
        error = e;
      }
      expect(error, isA<NotifyClientError>());
      expect((error as NotifyClientError).statusCode, 400);
    });

    test('an unreachable bridge is a NotifyClientError(0)', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close(force: true);

      Object? error;
      try {
        await NotifyClient(
          Uri.parse('http://${server.address.host}:$port/'),
        ).registerDevice('tok_1', {});
      } catch (e) {
        error = e;
      }
      expect(error, isA<NotifyClientError>());
      expect((error as NotifyClientError).statusCode, 0);
    });
  });
}
