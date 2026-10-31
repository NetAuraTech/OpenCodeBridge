import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/authenticated_http.dart';

void main() {
  group('bridgeRequest', () {
    late HttpServer server;
    late Uri uri;
    late List<String> seenAuthHeaders;

    setUp(() async {
      seenAuthHeaders = [];
      server = await HttpServer.bind('127.0.0.1', 0);
      uri = Uri.parse('http://127.0.0.1:${server.port}/api/health');
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('attaches the authorization header from the provider', () async {
      final forced = <bool>[];
      server.listen((req) async {
        seenAuthHeaders.add(req.headers.value('Authorization') ?? '<none>');
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      });
      final client = HttpClient();
      try {
        final response = await bridgeRequest(
          client,
          'GET',
          uri,
          auth: ({forceRefresh = false}) =>
              _header('Bearer a', 'Bearer b', forceRefresh, forced),
        );
        expect(response.statusCode, HttpStatus.ok);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
      expect(seenAuthHeaders, ['Bearer a']);
      expect(forced, [false]);
    });

    test('on 401 refreshes the token and retries once', () async {
      final forced = <bool>[];
      server.listen((req) async {
        final auth = req.headers.value('Authorization') ?? '<none>';
        seenAuthHeaders.add(auth);
        final response = req.response;
        if (auth == 'Bearer stale') {
          response.statusCode = HttpStatus.unauthorized;
        } else {
          response.statusCode = HttpStatus.ok;
        }
        await response.close();
      });
      final client = HttpClient();
      try {
        final response = await bridgeRequest(
          client,
          'GET',
          uri,
          auth: ({forceRefresh = false}) =>
              _header('Bearer stale', 'Bearer fresh', forceRefresh, forced),
        );
        expect(response.statusCode, HttpStatus.ok);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
      expect(seenAuthHeaders, ['Bearer stale', 'Bearer fresh']);
      expect(forced, [false, true]);
    });

    test('a second 401 is returned, not retried again', () async {
      final forced = <bool>[];
      server.listen((req) async {
        seenAuthHeaders.add(req.headers.value('Authorization') ?? '<none>');
        req.response.statusCode = HttpStatus.unauthorized;
        await req.response.close();
      });
      final client = HttpClient();
      try {
        final response = await bridgeRequest(
          client,
          'GET',
          uri,
          auth: ({forceRefresh = false}) =>
              _header('Bearer stale', 'Bearer fresh', forceRefresh, forced),
        );
        expect(response.statusCode, HttpStatus.unauthorized);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
      expect(seenAuthHeaders, ['Bearer stale', 'Bearer fresh']);
    });

    test('without a provider no header is sent and no retry happens', () async {
      server.listen((req) async {
        seenAuthHeaders.add(req.headers.value('Authorization') ?? '<none>');
        req.response.statusCode = HttpStatus.unauthorized;
        await req.response.close();
      });
      final client = HttpClient();
      try {
        final response = await bridgeRequest(client, 'GET', uri);
        expect(response.statusCode, HttpStatus.unauthorized);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
      expect(seenAuthHeaders, ['<none>']);
    });

    test(
      'a null header from the provider sends no Authorization at all',
      () async {
        server.listen((req) async {
          seenAuthHeaders.add(req.headers.value('Authorization') ?? '<none>');
          req.response.statusCode = HttpStatus.ok;
          await req.response.close();
        });
        final client = HttpClient();
        try {
          final response = await bridgeRequest(
            client,
            'GET',
            uri,
            auth: ({forceRefresh = false}) async => null,
          );
          expect(response.statusCode, HttpStatus.ok);
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
        expect(seenAuthHeaders, ['<none>']);
      },
    );

    test('posts the body and content type on both attempts', () async {
      var attempts = 0;
      server.listen((req) async {
        attempts++;
        final body = await _read(req);
        seenAuthHeaders.add(req.headers.value('Authorization') ?? '<none>');
        expect(req.headers.contentType?.mimeType, 'application/json');
        expect(body, '"{}"');
        req.response.statusCode = attempts == 1
            ? HttpStatus.unauthorized
            : HttpStatus.ok;
        await req.response.close();
      });
      final client = HttpClient();
      try {
        final response = await bridgeRequest(
          client,
          'POST',
          uri,
          body: '"{}"',
          contentType: ContentType.json,
          auth: ({forceRefresh = false}) async =>
              forceRefresh ? 'Bearer fresh' : 'Bearer stale',
        );
        expect(response.statusCode, HttpStatus.ok);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
      expect(attempts, 2);
    });
  });
}

Future<String> _read(HttpRequest request) async {
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
  }
  return const Utf8Decoder().convert(bytes);
}

Future<String?> _header(
  String first,
  String refreshed,
  bool forceRefresh,
  List<bool> forced,
) async {
  forced.add(forceRefresh);
  return forceRefresh ? refreshed : first;
}
