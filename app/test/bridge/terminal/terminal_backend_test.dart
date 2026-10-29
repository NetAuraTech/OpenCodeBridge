import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/opencode_terminal_service.dart';
import 'package:opencodebridge/bridge/terminal/terminal_backend.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';
import 'package:opencodebridge/bridge/terminal/terminal_window_token.dart';

void main() {
  group('TerminalBackend', () {
    test('verifyToken accepts the startup token and rejects others', () {
      final token = TerminalWindowToken.generate(random: Random());
      final backend = _backend(token);
      expect(backend.verifyToken(token.value), isTrue);
      expect(backend.verifyToken('wrong'), isFalse);
      expect(backend.verifyToken(null), isFalse);
    });

    test('proxyFor is per-session and stable', () {
      final backend = _backend(TerminalWindowToken.generate(random: Random()));
      expect(backend.proxyFor('a'), same(backend.proxyFor('a')));
      expect(backend.proxyFor('a'), isNot(same(backend.proxyFor('b'))));
      expect(backend.token, isA<TerminalWindowToken>());
    });

    test('attach uses the running PTY when one exists', () async {
      final service = _FakeService(hasRunning: true);
      final backend = _backend(
        TerminalWindowToken.generate(random: Random()),
        service: service,
      );
      final attacher = await backend.proxyFor('ses_1').attach();
      expect(service.createCalls, isEmpty, reason: 'a PTY is already running');
      expect(service.connects, 1);
      await attacher.close();
      await backend.close();
    });

    test(
      'attach creates the PTY in the session cwd when none is running',
      () async {
        final service = _FakeService(hasRunning: false);
        final backend = _backend(
          TerminalWindowToken.generate(random: Random()),
          service: service,
        );
        final attacher = await backend.proxyFor('ses_1').attach();
        expect(service.createCalls, ['ses_1:/cwd/ses_1']);
        await attacher.close();
        await backend.close();
      },
    );
  });
}

TerminalBackend _backend(
  TerminalWindowToken token, {
  OpencodeTerminalService? service,
}) => TerminalBackend(
  service: service ?? _FakeService(),
  token: token,
  sessionCwd: (String id) async => '/cwd/$id',
);

/// A scripted persistent-PTY family: [hasRunning] controls whether
/// [listTerminals] reports a running PTY (so the backend resolves it) or is
/// empty (forcing a create). Records connects and create calls.
class _FakeService implements OpencodeTerminalService {
  _FakeService({bool hasRunning = true}) {
    _hasRunning = hasRunning;
    _info = TerminalInfo(
      id: 'pty_1',
      status: TerminalStatus.running,
      size: TerminalSize.defaultSize,
      sessionId: 'ses_1',
    );
  }

  bool _hasRunning = true;
  late final TerminalInfo _info;

  int connects = 0;
  final List<String> createCalls = [];

  @override
  Future<TerminalInfo> createTerminal(
    String sessionId, {
    required String cwd,
    TerminalSize? size,
    String? title,
  }) async {
    createCalls.add('$sessionId:$cwd');
    return _info;
  }

  @override
  Future<List<TerminalInfo>> listTerminals(String sessionId) async =>
      _hasRunning ? [_info] : const [];

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
  }) async {
    connects++;
    return _FakeConnection();
  }

  @override
  Future<TerminalInfo> resize(String ptyId, TerminalSize size) async => _info;

  @override
  Future<void> delete(String ptyId) async {}
}

/// A scripted upstream attach that emits an initial replay on a later
/// event-loop turn, then marks the replay complete.
class _FakeConnection implements TerminalConnection {
  final _controller = StreamController<List<int>>();
  final _replayDone = Completer<void>();

  _FakeConnection() {
    Future<void>.delayed(const Duration(), () {
      _controller.add('REPLAY'.codeUnits);
      _replayDone.complete();
    });
  }

  @override
  Stream<List<int>> get output => _controller.stream;

  @override
  Future<void> get initialReplayDone => _replayDone.future;

  @override
  Future<void> write(List<int> input) async {}

  @override
  Future<void> close() async {
    if (!_replayDone.isCompleted) _replayDone.complete();
    await _controller.close();
  }
}
