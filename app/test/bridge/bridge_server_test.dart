import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/health.dart';

void main() {
  group('BridgeServer', () {
    late BridgeServer server;
    late Uri base;

    setUp(() async {
      server = await BridgeServer.start(
        port: 0,
        health: () => const HealthReport(
          bridge: ComponentStatus.ok,
          opencode: ComponentStatus.unreachable,
          docker: ComponentStatus.ok,
        ),
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test('GET /api/health answers 200 with the report as JSON', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(base.replace(path: 'api/health'));
        final response = await request.close();
        expect(response.statusCode, 200);
        final body = await response.transform(const Utf8Decoder()).join();
        expect(jsonDecode(body), {
          'bridge': 'ok',
          'opencode': 'unreachable',
          'docker': 'ok',
        });
      } finally {
        client.close(force: true);
      }
    });

    test('unknown paths are 404', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(base.replace(path: 'api/nope'));
        final response = await request.close();
        expect(response.statusCode, 404);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    });

    test('POST /api/health is not the health route', () async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(base.replace(path: 'api/health'));
        final response = await request.close();
        expect(response.statusCode, 404);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    });
  });

  group('BridgeServer defaults', () {
    test(
      'default report: bridge ok, opencode and docker not configured',
      () async {
        final server = await BridgeServer.start(port: 0);
        try {
          final client = HttpClient();
          final request = await client.getUrl(
            server.baseUri.replace(path: 'api/health'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          final body = await response.transform(const Utf8Decoder()).join();
          client.close(force: true);
          expect(jsonDecode(body), {
            'bridge': 'ok',
            'opencode': 'not_configured',
            'docker': 'not_configured',
          });
        } finally {
          await server.stop();
        }
      },
    );

    test('listens on loopback only', () async {
      final server = await BridgeServer.start(port: 0);
      try {
        expect(server.baseUri.host, '127.0.0.1');
      } finally {
        await server.stop();
      }
    });

    test('default port is the fixed bridge port', () {
      expect(BridgeServer.defaultPort, 48201);
    });
  });
}
