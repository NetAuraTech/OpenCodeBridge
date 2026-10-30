import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/llama_speed_feed.dart';

void main() {
  const password = 'secret';

  late HttpServer providerServer;
  late HttpServer llamaServer;
  late Uri providerBase;
  late Uri llamaBase;

  setUp(() async {
    llamaServer = await HttpServer.bind('127.0.0.1', 0);
    llamaBase = Uri.parse('http://127.0.0.1:${llamaServer.port}');
    llamaServer.listen((req) async {
      final resp = req.response;
      if (req.uri.path != '/stream') {
        resp.statusCode = HttpStatus.notFound;
        await resp.close();
        return;
      }
      resp.headers.contentType = ContentType.parse('text/event-stream');
      resp.bufferOutput = false;
      resp.write('event: hello\ndata: {}\n\n');
      await resp.flush();
      resp.write(
        'event: prefill\n'
        'data: {"speed":1234.5,"progress":0.5,"tokens":100}\n\n',
      );
      await resp.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      resp.write(
        'event: timing\n'
        'data: {"predicted_n":5,"predicted_ms":105}\n\n',
      );
      await resp.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      resp.write('event: busy\ndata: {"state":false}\n\n');
      await resp.flush();
      await resp.done; // Hold the stream open until the client leaves.
    });

    providerServer = await HttpServer.bind('127.0.0.1', 0);
    providerBase = Uri.parse('http://127.0.0.1:${providerServer.port}');
    providerServer.listen((req) async {
      final resp = req.response;
      if (req.uri.path != '/api/provider') {
        resp.statusCode = HttpStatus.notFound;
        await resp.close();
        return;
      }
      resp.headers.contentType = ContentType.json;
      // The good llama.cpp candidate plus a dead one (this same server 404s
      // /stream) to exercise candidate rotation.
      final catalog = {
        'data': [
          {
            'settings': {'baseURL': '$llamaBase/v1'},
          },
          {
            'settings': {'baseURL': '$providerBase/v1'},
          },
        ],
      };
      resp.write(jsonEncode(catalog));
      await resp.close();
    });
  });

  tearDown(() async {
    await providerServer.close(force: true);
    await llamaServer.close(force: true);
  });

  group('LlamaSpeedFeed', () {
    test(
      're-emits llama.cpp prefill and decode throughput as llama.speed, '
      'resolving the base from /api/provider and skipping dead candidates',
      () async {
        final emitted = <Map<String, Object?>>[];
        final feed = LlamaSpeedFeed(
          serviceBase: providerBase,
          password: password,
          emit: (raw) {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, Object?> &&
                decoded['type'] == 'llama.speed') {
              emitted.add(
                (decoded['data'] as Map<String, Object?>?) ??
                    const <String, Object?>{},
              );
            }
          },
          reconnectDelay: const Duration(milliseconds: 5),
        );
        feed.start();
        await _until(
          () =>
              _hasPhase(emitted, prefill: true) &&
              _hasPhase(emitted, decode: true) &&
              _hasPhase(emitted, idle: true),
          message: 'expected prefill, decode, and idle llama.speed events',
        );

        expect(
          _phase(emitted, prefill: true)['prefill'],
          closeTo(1234.5, 0.001),
          reason: 'the prefill event carries the llama.cpp prefill speed',
        );
        expect(
          _phase(emitted, decode: true)['decode'],
          closeTo(5 / 105 * 1000, 0.01),
          reason: 'decode = predicted_n / predicted_ms * 1000',
        );
        final idle = _phase(emitted, idle: true);
        expect(idle['prefill'], isNull);
        expect(idle['decode'], isNull);
        await feed.close();
      },
    );

    test('fromHost reads url + password from the descriptor', () async {
      final dir = await Directory.systemTemp.createTemp('llama-speed');
      final file = File('${dir.path}/service.json');
      await file.writeAsString(
        jsonEncode({'url': providerBase.toString(), 'password': password}),
      );
      try {
        final emitted = <Map<String, Object?>>[];
        final feed = await LlamaSpeedFeed.fromHost(
          statePath: file.path,
          emit: (raw) {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, Object?> &&
                decoded['type'] == 'llama.speed') {
              emitted.add(
                (decoded['data'] as Map<String, Object?>?) ??
                    const <String, Object?>{},
              );
            }
          },
        );
        if (feed == null) fail('fromHost should build the feed');
        feed.start();
        await _until(
          () => _hasPhase(emitted, prefill: true),
          message: 'expected a prefill event',
        );
        await feed.close();
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('a non-http service base is rejected', () {
      expect(
        () => LlamaSpeedFeed(
          serviceBase: Uri.parse('ftp://host/'),
          password: password,
          emit: (_) {},
        ),
        throwsArgumentError,
      );
    });
  });
}

/// The first emitted [llama.speed] payload in [emitted] matching the phase.
Map<String, Object?> _phase(
  List<Map<String, Object?>> emitted, {
  bool prefill = false,
  bool decode = false,
  bool idle = false,
}) {
  for (final data in emitted) {
    final hasPrefill = data['prefill'] != null;
    final hasDecode = data['decode'] != null;
    if (idle && !hasPrefill && !hasDecode) return data;
    if (prefill && hasPrefill) return data;
    if (decode && hasDecode) return data;
  }
  fail('no emitted llama.speed matched the requested phase');
}

bool _hasPhase(
  List<Map<String, Object?>> emitted, {
  bool prefill = false,
  bool decode = false,
  bool idle = false,
}) {
  for (final data in emitted) {
    final hasPrefill = data['prefill'] != null;
    final hasDecode = data['decode'] != null;
    if (idle && !hasPrefill && !hasDecode) return true;
    if (prefill && hasPrefill) return true;
    if (decode && hasDecode) return true;
  }
  return false;
}

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
