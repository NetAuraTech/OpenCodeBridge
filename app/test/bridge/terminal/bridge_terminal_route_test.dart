import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/session_store.dart';
import 'package:opencodebridge/bridge/terminal/opencode_terminal_service.dart';
import 'package:opencodebridge/bridge/terminal/terminal_backend.dart';
import 'package:opencodebridge/bridge/terminal/terminal_frames.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';
import 'package:opencodebridge/bridge/terminal/terminal_window_token.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// Endpoint 10 (`GET /api/sessions/{id}/terminal`, WebSocket) end-to-end over
/// a real [HttpServer]: the attach replays from the cursor, fans live output
/// out to multiple simultaneous attachers, forwards raw input and resize
/// controls to the upstream, and rejects attachers without a valid window
/// token (spec §7, §10, §14).
const _sessionId = 'ses_1';
const _fiveS = Duration(seconds: 5);

void main() {
  late BridgeServer server;
  late Uri base;
  late _FakeTerminalService service;
  late TerminalWindowToken token;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-term');
    service = _FakeTerminalService();
    token = TerminalWindowToken.generate(random: Random());
    final store = await SessionStore.load(dir: dir);
    server = await BridgeServer.start(
      port: 0,
      sessions: SessionsBackend(service: _NoopSessions(), store: store),
      terminals: TerminalBackend(
        service: service,
        token: token,
        sessionCwd: (String id) async => '/cwd/$id',
      ),
    );
    base = server.baseUri;
  });

  tearDown(() async {
    await server.stop();
    await dir.delete(recursive: true);
  });

  String attachUri({String? token, int cursor = 0}) {
    final q = <String, String>{'cursor': '$cursor'};
    if (token != null) q['token'] = token;
    return base
        .replace(
          scheme: 'ws',
          path: 'api/sessions/$_sessionId/terminal',
          queryParameters: q,
        )
        .toString();
  }

  test(
    'a valid token attaches, replays the ring, then receives live frames',
    () async {
      final ws = await WebSocket.connect(attachUri(token: token.value));
      final frames = _Frames(ws);
      try {
        final replay = await frames.next();
        expect(replay, isA<List<int>>());
        expect(utf8.decode(replay as List<int>), 'REPLAY');
        final complete = await frames.next();
        expect(complete, isA<String>());
        expect(parseReplayComplete(complete as String), 6);

        service.connection!.emitLive(utf8.encode('LIVE'));
        final live = await frames.next();
        expect(live, isA<List<int>>());
        expect(utf8.decode(live as List<int>), 'LIVE');
      } finally {
        await ws.close();
      }
    },
  );

  test(
    'multiple simultaneous attachers share one upstream and identical live',
    () async {
      final ws1 = await WebSocket.connect(attachUri(token: token.value));
      final ws2 = await WebSocket.connect(attachUri(token: token.value));
      final f1 = _Frames(ws1);
      final f2 = _Frames(ws2);
      try {
        final r1 = await f1.next();
        final r2 = await f2.next();
        expect(utf8.decode(r1 as List<int>), 'REPLAY');
        expect(utf8.decode(r2 as List<int>), 'REPLAY');
        await f1.next(); // replay_complete
        await f2.next(); // replay_complete
        expect(service.connects, 1, reason: 'a single upstream attach');

        service.connection!.emitLive(utf8.encode('LIVE'));
        final l1 = await f1.next();
        final l2 = await f2.next();
        expect(utf8.decode(l1 as List<int>), 'LIVE');
        expect(utf8.decode(l2 as List<int>), 'LIVE');
      } finally {
        await ws1.close();
        await ws2.close();
      }
    },
  );

  test('raw input from an attacher reaches the upstream TUI', () async {
    final ws = await WebSocket.connect(attachUri(token: token.value));
    final frames = _Frames(ws);
    try {
      await frames.next(); // REPLAY
      await frames.next(); // replay_complete
      ws.add(utf8.encode('a'));
      await until(() => service.inputWrites.length == 1);
      expect(service.inputWrites, [utf8.encode('a')]);
    } finally {
      await ws.close();
    }
  });

  test('a resize control is forwarded to the PTY', () async {
    final ws = await WebSocket.connect(attachUri(token: token.value));
    final frames = _Frames(ws);
    try {
      await frames.next(); // REPLAY
      await frames.next(); // replay_complete
      ws.add(encodeResize(80, 24));
      await until(() => service.resizes.length == 1);
      expect(service.resizes, [const TerminalSize(cols: 80, rows: 24)]);
    } finally {
      await ws.close();
    }
  });

  test('a wrong token is rejected with 1008 and no frames', () async {
    final ws = await WebSocket.connect(attachUri(token: 'wrong'));
    final received = await ws.toList().timeout(_fiveS);
    expect(received, isEmpty, reason: 'no attach for a bad token');
    expect(ws.closeCode, 1008);
  });

  test('a missing token is rejected with 1008', () async {
    final ws = await WebSocket.connect(attachUri());
    final received = await ws.toList().timeout(_fiveS);
    expect(received, isEmpty);
    expect(ws.closeCode, 1008);
  });
}

/// Polls [cond] until it holds (guarding against a hang).
Future<void> until(bool Function() cond) async {
  final deadline = DateTime.now().add(_fiveS);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A sequential reader over a single-subscription [WebSocket]: subscribes once
/// and yields frames one at a time, so a test can interleave its own actions
/// (emitting a live frame, sending input) between reads.
class _Frames {
  _Frames(WebSocket ws) {
    ws.listen(
      (event) {
        _events.add(event);
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  final List<dynamic> _events = [];
  final List<Completer<void>> _waiters = [];
  bool _done = false;

  Future<dynamic> next() async {
    while (_events.isEmpty && !_done) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future.timeout(
        _fiveS,
        onTimeout: () => fail('timed out waiting for a frame'),
      );
    }
    if (_events.isEmpty) {
      throw StateError('the terminal stream ended');
    }
    return _events.removeAt(0);
  }

  void _wake() {
    while (_waiters.isNotEmpty && (_events.isNotEmpty || _done)) {
      _waiters.removeAt(0).complete();
    }
  }
}

/// A scripted persistent-PTY family: always reports a running PTY, hands out a
/// scripted upstream [TerminalConnection], and records connects, input, and
/// resizes so the tests can assert on the wire.
class _FakeTerminalService implements OpencodeTerminalService {
  late final TerminalInfo _info;

  int connects = 0;
  final resizes = <TerminalSize>[];
  final inputWrites = <List<int>>[];

  _FakeConnection? _connection;
  _FakeConnection? get connection => _connection;

  _FakeTerminalService() {
    _info = TerminalInfo(
      id: 'pty_1',
      status: TerminalStatus.running,
      size: TerminalSize.defaultSize,
      sessionId: _sessionId,
    );
  }

  @override
  Future<TerminalInfo> createTerminal(
    String sessionId, {
    required String cwd,
    TerminalSize? size,
    String? title,
  }) async => _info;

  @override
  Future<List<TerminalInfo>> listTerminals(String sessionId) async => [_info];

  @override
  Future<TerminalInfo> runningTerminal(String sessionId) async => _info;

  @override
  Future<TerminalTicket> connectToken(String ptyId) async =>
      const TerminalTicket(ticket: 'tk', expiresIn: 60);

  @override
  Future<TerminalConnection> connect(
    String ptyId, {
    required String ticket,
    int cursor = 0,
    required TerminalSize size,
  }) async {
    connects++;
    final conn = _FakeConnection(this);
    _connection = conn;
    return conn;
  }

  @override
  Future<TerminalInfo> resize(String ptyId, TerminalSize size) async {
    resizes.add(size);
    return _info;
  }

  @override
  Future<void> delete(String ptyId) async {}
}

/// A scripted upstream attach. On construction it schedules the initial replay
/// on a later event-loop turn (so it is buffered before the proxy subscribes,
/// matching the real service), then marks the replay complete; the test pushes
/// live frames with [emitLive].
class _FakeConnection implements TerminalConnection {
  final _controller = StreamController<List<int>>();
  final _replayDone = Completer<void>();
  final _FakeTerminalService _service;
  bool closed = false;

  _FakeConnection(this._service) {
    Future<void>.delayed(const Duration(), () {
      _controller.add(utf8.encode('REPLAY'));
      _replayDone.complete();
    });
  }

  void emitLive(List<int> bytes) {
    if (closed) return;
    _controller.add(bytes);
  }

  @override
  Stream<List<int>> get output => _controller.stream;

  @override
  Future<void> get initialReplayDone => _replayDone.future;

  @override
  Future<void> write(List<int> input) async {
    _service.inputWrites.add(input);
  }

  @override
  Future<void> resize(int cols, int rows) async {
    _service.resizes.add(TerminalSize(cols: cols, rows: rows));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!_replayDone.isCompleted) _replayDone.complete();
    await _controller.close();
  }
}

class _NoopSessions implements OpencodeService {
  @override
  Future<List<OpencodeSession>> listSessions() async => const [];
  @override
  Future<Map<String, String>> projectNames() async => const {};
  @override
  Future<Set<String>> activeSessionIds() async => const {};
  @override
  Future<List<OpencodeProject>> projects() async => const [];
  @override
  Future<OpencodeSession> createSession(String projectId) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<void> deleteSession(String id) async {}
  @override
  Future<SessionDetail> getDetail(String id) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<List<SessionMessage>> getMessages(String id) async => const [];
  @override
  Future<void> prompt(String id, String text) async {}
  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async =>
      const [];
  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {}
  @override
  Future<List<OpencodeCommand>> listCommands() async => const [];
  @override
  Future<void> runCommand(String id, String name, String text) async {}
  @override
  Future<List<ModelOption>> listModels() async => const [];
  @override
  Future<ModelRef?> currentModel(String id) async => null;
  @override
  Future<void> setModel(String id, ModelRef model) async {}
  @override
  Future<List<AgentOption>> listAgents() async => const [];
  @override
  Future<void> setAgent(String id, String agentId) async {}
  @override
  Future<List<SkillOption>> listSkills() async => const [];
  @override
  Future<void> activateSkill(String id, String skillId) async {}
  @override
  Future<void> compact(String id) async {}
  @override
  Future<void> undo(String id) async {}
  @override
  Future<void> redo(String id) async {}
  @override
  Future<String> fork(String id) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<void> rename(String id, String title) async {}
  @override
  Future<String> exportSession(String id) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<void> move(String id, String directory) async {}
  @override
  Future<String> generate(String id, String prompt) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> diff(String id) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> stats(String id) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> newTerminal(String id) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> worktrees(String projectId) async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> usage() async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> mcps() async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> integrations() async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> connectIntegration(
    String integrationId,
    String methodId,
  ) async => throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> status() async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<String> pair() async =>
      throw const OpencodeServiceError(500, 'not scripted');
  @override
  Future<void> reload() async {}
  @override
  Future<String> plugins() async =>
      throw const OpencodeServiceError(500, 'not scripted');
}
