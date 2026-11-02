import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/fs_client.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late List<String> directoryQueries;

  var failDrives = false;

  setUp(() async {
    directoryQueries = [];
    failDrives = false;
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (request.method == 'GET' && request.uri.path == '/api/fs/drives') {
        if (failDrives) {
          response.statusCode = HttpStatus.badGateway;
          response.write(jsonEncode({'error': 'nope'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode(['/mnt/data', '/']));
        }
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/fs/directories') {
        final path = request.uri.queryParameters['path'] ?? '';
        directoryQueries.add(path);
        if (path == '/tmp') {
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode(['/tmp/b', '/tmp/a']));
        } else if (path == '/tmp/missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.badRequest;
          response.write(jsonEncode({'error': 'invalid_path'}));
        }
      } else {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'not_found'}));
      }
      response.close();
    });
    base = Uri.parse('http://127.0.0.1:${server.port}/');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('drives parses the JSON list of absolute paths', () async {
    expect(await FsClient(base).drives(), ['/mnt/data', '/']);
  });

  test('drives maps a non-200 to FsClientError with the status', () async {
    failDrives = true;
    final client = FsClient(base);
    try {
      await client.drives();
      fail('expected FsClientError');
    } on FsClientError catch (e) {
      expect(e.statusCode, HttpStatus.badGateway);
    }
  });

  test(
    'subdirectories sends the path query and parses the JSON list',
    () async {
      expect(await FsClient(base).subdirectories('/tmp'), ['/tmp/b', '/tmp/a']);
      expect(directoryQueries, ['/tmp']);
    },
  );

  test('subdirectories maps the bridge 404 to FsClientError(404)', () async {
    final client = FsClient(base);
    try {
      await client.subdirectories('/tmp/missing');
      fail('expected FsClientError');
    } on FsClientError catch (e) {
      expect(e.statusCode, HttpStatus.notFound);
    }
  });

  test('subdirectories maps the bridge 400 to FsClientError(400)', () async {
    final client = FsClient(base);
    try {
      await client.subdirectories('/tmp/bad');
      fail('expected FsClientError');
    } on FsClientError catch (e) {
      expect(e.statusCode, HttpStatus.badRequest);
    }
  });

  test('an unreachable bridge is FsClientError(0)', () async {
    final unreachable = FsClient(Uri.parse('http://127.0.0.1:1/'));
    try {
      await unreachable.drives();
      fail('expected FsClientError');
    } on FsClientError catch (e) {
      expect(e.statusCode, 0);
    }
  });
}
