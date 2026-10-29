import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/opencode_http_terminal_service.dart';
import 'package:opencodebridge/bridge/terminal/opencode_terminal_service.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';

/// A stand-in for the shared opencode service's persistent-PTY family. It
/// serves the create/list/connect-token/resize/delete endpoints (checking
/// Basic auth and the same-host ticket header) and a WebSocket `connect`
/// endpoint that emits the `attached` frame, a raw ANSI replay, and
/// `replay_complete`.
void main() {
  const password = 'secret';
  const ptyId = 'pty_persistent_test';

  late HttpServer server;
  late Uri base;

  // Recorded by the fake so the tests can assert on the wire.
  late Map<String, Object?> createdBody;
  late Map<String, Object?> resizedBody;
  late String? lastConnectQuery;
  late bool lastConnectTokenTicketHeader;
  final deletedPtyIds = <String>[];
  final receivedWsFrames = <Object>[];

  setUp(() async {
    createdBody = {};
    resizedBody = {};
    lastConnectQuery = null;
    lastConnectTokenTicketHeader = false;
    deletedPtyIds.clear();
    receivedWsFrames.clear();

    server = await HttpServer.bind('127.0.0.1', 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((req) async {
      final resp = req.response;
      final path = req.uri.path;
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      final expected =
          'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
      if (auth != expected) {
        resp.statusCode = HttpStatus.unauthorized;
        resp.write(jsonEncode({'error': 'unauthorized'}));
        await resp.close();
        return;
      }

      // The WebSocket connect: upgrade and drive the frame protocol.
      if (req.method == 'GET' && path.endsWith('/connect')) {
        lastConnectQuery = req.uri.query;
        final ws = await WebSocketTransformer.upgrade(req);
        ws.add('{"type":"attached","attachmentID":"a","inputProtocol":1}');
        ws.add(utf8.encode('REPLAY-ANSI'));
        ws.add(encodeReplayCompleteValue(11));
        // Keep the socket open (live); record every client frame.
        ws.listen(
          (frame) {
            receivedWsFrames.add(frame);
          },
          onDone: () {},
          onError: (e) {},
        );
        return;
      }

      resp.headers.contentType = ContentType.json;
      if (req.method == 'POST' &&
          path == '/api/experimental/session/ses_1/terminal') {
        createdBody = await _readBody(req);
        resp.write(
          jsonEncode({
            'data': {
              'id': ptyId,
              'title': 'OpenCode',
              'command': 'opencode',
              'args': ['--session', 'ses_1'],
              'cwd': '/proj',
              'status': 'running',
              'pid': 7,
              'sessionID': 'ses_1',
              'foregroundProcess': 'opencode',
              'size': {'cols': 120, 'rows': 30},
            },
          }),
        );
      } else if (req.method == 'GET' &&
          path == '/api/experimental/session/ses_1/terminal') {
        resp.write(
          jsonEncode({
            'data': [
              {
                'id': ptyId,
                'title': 'OpenCode',
                'command': 'opencode',
                'args': ['--session', 'ses_1'],
                'cwd': '/proj',
                'status': 'running',
                'pid': 7,
                'sessionID': 'ses_1',
                'foregroundProcess': 'opencode',
                'size': {'cols': 120, 'rows': 30},
              },
              {'id': 'pty_old', 'status': 'exited', 'sessionID': 'ses_1'},
            ],
          }),
        );
      } else if (req.method == 'POST' &&
          path == '/api/experimental/persistent-pty/$ptyId/connect-token') {
        lastConnectTokenTicketHeader =
            req.headers.value('x-opencode-ticket') == '1';
        resp.write(
          jsonEncode({
            'data': {'ticket': 'tk_1', 'expires_in': 60},
          }),
        );
      } else if (req.method == 'PUT' &&
          path == '/api/experimental/persistent-pty/$ptyId') {
        resizedBody = await _readBody(req);
        resp.write(
          jsonEncode({
            'data': {
              'id': ptyId,
              'status': 'running',
              'size': {'cols': 2, 'rows': 3},
            },
          }),
        );
      } else if (req.method == 'DELETE' &&
          path.startsWith('/api/experimental/persistent-pty/')) {
        final id = path.split('/').last;
        deletedPtyIds.add(id);
        resp.statusCode = HttpStatus.noContent;
      } else if (req.method == 'GET' &&
          path == '/api/experimental/session/ses_missing/terminal') {
        resp.statusCode = HttpStatus.notFound;
        resp.write(jsonEncode({'error': 'not_found'}));
      } else {
        resp.statusCode = HttpStatus.notFound;
        resp.write(jsonEncode({'error': 'not_found'}));
      }
      await resp.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  group('OpencodeHttpTerminalService', () {
    test(
      'createTerminal sends the TUI command, env quirk, cwd and size',
      () async {
        final service = OpencodeHttpTerminalService(
          baseUrl: base,
          password: password,
        );
        final info = await service.createTerminal(
          'ses_1',
          cwd: '/proj',
          size: const TerminalSize(cols: 80, rows: 24),
        );
        expect(info.id, ptyId);
        expect(info.status, TerminalStatus.running);
        expect(info.sessionId, 'ses_1');
        expect(createdBody['command'], 'opencode');
        expect(createdBody['args'], ['--session', 'ses_1']);
        expect(createdBody['env'], <String, String>{}); // runtime-required
        expect(createdBody['cwd'], '/proj');
        expect(createdBody['size'], {'cols': 80, 'rows': 24});
      },
    );

    test('createTerminal defaults the size to 120x30 when omitted', () async {
      final service = OpencodeHttpTerminalService(
        baseUrl: base,
        password: password,
      );
      await service.createTerminal('ses_1', cwd: '/proj');
      expect(createdBody['size'], {'cols': 120, 'rows': 30});
    });

    test('listTerminals returns every PTY bound to the session', () async {
      final service = OpencodeHttpTerminalService(
        baseUrl: base,
        password: password,
      );
      final list = await service.listTerminals('ses_1');
      expect(list.map((t) => t.id), [ptyId, 'pty_old']);
      expect(list[1].status, TerminalStatus.exited);
    });

    test(
      'runningTerminal returns the running PTY, not the exited one',
      () async {
        final service = OpencodeHttpTerminalService(
          baseUrl: base,
          password: password,
        );
        final running = await service.runningTerminal('ses_1');
        expect(running.id, ptyId);
        expect(running.status, TerminalStatus.running);
      },
    );

    test('runningTerminal is an error when none is running', () async {
      final service = OpencodeHttpTerminalService(
        baseUrl: base,
        password: password,
      );
      // No running PTY on the unknown session -> the service 404s the list.
      await expectLater(
        service.runningTerminal('ses_missing'),
        throwsA(
          isA<OpencodeTerminalServiceError>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('connectToken sends the same-host ticket header', () async {
      final service = OpencodeHttpTerminalService(
        baseUrl: base,
        password: password,
      );
      final ticket = await service.connectToken(ptyId);
      expect(lastConnectTokenTicketHeader, isTrue);
      expect(ticket.ticket, 'tk_1');
      expect(ticket.expiresIn, 60);
    });

    test(
      'connect opens the WS, filters to ANSI bytes, and marks replay done',
      () async {
        final service = OpencodeHttpTerminalService(
          baseUrl: base,
          password: password,
        );
        final ticket = await service.connectToken(ptyId);
        final conn = await service.connect(
          ptyId,
          ticket: ticket.ticket,
          cursor: 0,
          size: const TerminalSize(cols: 80, rows: 24),
        );
        try {
          // The connect carried the ticket and the framed input protocol.
          final query = Uri.parse('?$lastConnectQuery').queryParameters;
          expect(query['ticket'], 'tk_1');
          expect(query['input_protocol'], '1');
          expect(query['cursor'], '0');

          // Only the raw ANSI replay is exposed (text frames are filtered).
          final bytes = await conn.output.first;
          expect(utf8.decode(bytes), 'REPLAY-ANSI');

          await conn.initialReplayDone;
        } finally {
          await conn.close();
        }
      },
    );

    test('resize sends a protocol-1 frame (flag 0) and no payload', () async {
      final service = OpencodeHttpTerminalService(
        baseUrl: base,
        password: password,
      );
      final ticket = await service.connectToken(ptyId);
      final conn = await service.connect(
        ptyId,
        ticket: ticket.ticket,
        cursor: 0,
        size: const TerminalSize(cols: 80, rows: 24),
      );
      try {
        // Consume the initial replay so the socket settles before we drive it
        // (the same handshake the connect test performs).
        await conn.output.first;
        await conn.resize(2, 3);
        await until(() => receivedWsFrames.isNotEmpty);
        // [flag 0, colsHi, colsLo, rowsHi, rowsLo], big-endian, no payload.
        expect(receivedWsFrames.last, [0, 0, 2, 0, 3]);
      } finally {
        await conn.close();
      }
    });

    test(
      'write sends a protocol-1 input frame headed by the current PTY size',
      () async {
        final service = OpencodeHttpTerminalService(
          baseUrl: base,
          password: password,
        );
        final ticket = await service.connectToken(ptyId);
        final conn = await service.connect(
          ptyId,
          ticket: ticket.ticket,
          cursor: 0,
          size: const TerminalSize(cols: 80, rows: 24),
        );
        try {
          // Consume the initial replay so the socket settles before we drive it
          // (the same handshake the connect test performs).
          await conn.output.first;
          receivedWsFrames.clear();
          await conn.write(utf8.encode('hi'));
          await until(() => receivedWsFrames.isNotEmpty);
          // Flag 1, size 80x24 (big-endian), then the bytes 'hi' (104 105).
          expect(receivedWsFrames.last, [1, 0, 80, 0, 24, 104, 105]);

          // A resize updates the size the next input is framed with.
          receivedWsFrames.clear();
          await conn.resize(2, 3);
          await until(() => receivedWsFrames.isNotEmpty);
          receivedWsFrames.clear();
          await conn.write(utf8.encode('x'));
          await until(() => receivedWsFrames.isNotEmpty);
          // Now framed with 2x3 and the byte 'x' (120).
          expect(receivedWsFrames.last, [1, 0, 2, 0, 3, 120]);
        } finally {
          await conn.close();
        }
      },
    );

    test('resize PUTs the new size', () async {
      final service = OpencodeHttpTerminalService(
        baseUrl: base,
        password: password,
      );
      final info = await service.resize(
        ptyId,
        const TerminalSize(cols: 2, rows: 3),
      );
      expect(resizedBody, {
        'size': {'cols': 2, 'rows': 3},
      });
      expect(info.size, const TerminalSize(cols: 2, rows: 3));
    });

    test('delete issues a DELETE and accepts 204', () async {
      final service = OpencodeHttpTerminalService(
        baseUrl: base,
        password: password,
      );
      await service.delete(ptyId); // no throw on 204
      expect(deletedPtyIds, [ptyId]);
    });

    test('an unreachable service surfaces a 0-status error', () async {
      final dead = OpencodeHttpTerminalService(
        baseUrl: Uri.parse('http://127.0.0.1:1/'),
        password: password,
      );
      await expectLater(
        dead.listTerminals('ses_1'),
        throwsA(
          isA<OpencodeTerminalServiceError>().having(
            (e) => e.statusCode,
            'statusCode',
            0,
          ),
        ),
      );
    });
  });
}

Future<Map<String, Object?>> _readBody(HttpRequest req) async {
  final chunks = <int>[];
  await for (final chunk in req) {
    chunks.addAll(chunk);
  }
  return jsonDecode(utf8.decode(chunks)) as Map<String, Object?>;
}

/// Polls [condition] until true, so the tests can wait on an asynchronous
/// WebSocket frame arriving at the fake server.
Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > timeout) {
      throw TimeoutException('until condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String encodeReplayCompleteValue(int endOffset) =>
    '{"type":"replay_complete","endOffset":$endOffset}';
