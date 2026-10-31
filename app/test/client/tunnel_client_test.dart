import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/tunnel_client.dart';

void main() {
  group('TunnelClient', () {
    late HttpServer server;
    late Uri base;
    late TunnelClient client;
    late Map<String, Object?> reportBody;
    late List<String> paths;

    /// When set, the server answers every tunnel path with 404 and this
    /// error body.
    late Object? notFound;

    setUp(() async {
      paths = [];
      notFound = null;
      reportBody = {
        'status': 'up',
        'running': true,
        'connections': 2,
        'port': 20241,
        'hostname': 'bridge.example.com',
        'missing': <String>[],
        'details': <String>[],
      };
      server = await HttpServer.bind('127.0.0.1', 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      client = TunnelClient(base);
      server.listen((request) async {
        final response = request.response;
        paths.add('${request.method} ${request.uri.path}');
        response.headers.contentType = ContentType.json;
        final error = notFound;
        if (error is Object) {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode(error));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode(reportBody));
        }
        await response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('report() GETs the tunnel status', () async {
      final report = await client.report();

      expect(paths, ['GET /api/tunnel']);
      expect(report.status.name, 'up');
      expect(report.running, isTrue);
      expect(report.registeredConnections, 2);
      expect(report.metricsPort, 20241);
      expect(report.hostname, 'bridge.example.com');
      expect(report.missing, isEmpty);
    });

    test('check() POSTs the recheck', () async {
      final report = await client.check();

      expect(paths, ['POST /api/tunnel/check']);
      expect(report.registeredConnections, 2);
    });

    test('start() POSTs the manual start', () async {
      final report = await client.start();

      expect(paths, ['POST /api/tunnel/start']);
      expect(report.registeredConnections, 2);
    });

    test(
      'a non-200 answer is a TunnelClientError with the bridge status',
      () async {
        notFound = {'error': 'tunnel_not_configured'};

        try {
          await client.start();
          fail('expected a TunnelClientError');
        } on TunnelClientError catch (e) {
          expect(e.statusCode, 404);
        }
      },
    );

    test(
      'an unreachable bridge is a TunnelClientError with status 0',
      () async {
        final port = server.port;
        await server.close(force: true);

        try {
          await client.report();
          fail('expected a TunnelClientError');
        } on TunnelClientError catch (e) {
          expect(e.statusCode, 0);
        }
        expect(port, isNonZero);
      },
    );
  });
}
