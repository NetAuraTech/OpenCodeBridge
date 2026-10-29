import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/opencode_terminal_service.dart';
import 'package:opencodebridge/bridge/terminal/terminal_attach_proxy.dart';
import 'package:opencodebridge/bridge/terminal/terminal_frames.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';

/// A stand-in for the shared opencode service's persistent-PTY family that the
/// attach proxy drives: it hands out a scripted upstream [TerminalConnection]
/// that emits an initial ANSI replay, a `replay_complete` (via
/// [TerminalConnection.initialReplayDone]), and then whatever live frames the
/// test pushes. It records connects, token requests, resizes, and raw input so
/// the tests can assert on the wire.
class _FakeService implements OpencodeTerminalService {
  _FakeService() {
    _info = TerminalInfo(
      id: ptyId,
      status: TerminalStatus.running,
      size: TerminalSize.defaultSize,
      sessionId: 'ses_1',
    );
  }

  static const ptyId = 'pty_1';

  late final TerminalInfo _info;

  int connects = 0;
  int tokenRequests = 0;
  final resizes = <TerminalSize>[];
  final inputWrites = <List<int>>[];

  _FakeConnection? _connection;
  _FakeConnection? get connection => _connection;

  @override
  Future<TerminalInfo> createTerminal(
    String sessionId, {
    required String cwd,
    TerminalSize? size,
    String? title,
  }) => throw UnimplementedError('createTerminal is the caller\'s concern');

  @override
  Future<List<TerminalInfo>> listTerminals(String sessionId) async => [_info];

  @override
  Future<TerminalInfo> runningTerminal(String sessionId) async => _info;

  @override
  Future<TerminalTicket> connectToken(String ptyId) async {
    tokenRequests++;
    return const TerminalTicket(ticket: 'tk', expiresIn: 60);
  }

  @override
  Future<TerminalConnection> connect(
    String ptyId, {
    required String ticket,
    int cursor = 0,
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

/// A scripted upstream attach. On construction it schedules the initial
/// replay so it is buffered before the proxy starts listening, then marks the
/// replay complete; the test pushes live frames with [emitLive].
class _FakeConnection implements TerminalConnection {
  _FakeConnection(this._service) {
    // Like the real service, the replay arrives on the socket AFTER the proxy
    // has subscribed to `output`, so emit on a later event-loop turn: the
    // bytes are ingested before `initialReplayDone` completes.
    Future<void>.delayed(const Duration(), () {
      _controller.add(utf8.encode('REPLAY'));
      _replayDone.complete();
    });
  }

  final _FakeService _service;
  final _controller = StreamController<List<int>>();
  final _replayDone = Completer<void>();
  bool closed = false;

  @override
  Stream<List<int>> get output => _controller.stream;

  @override
  Future<void> get initialReplayDone => _replayDone.future;

  void emitLive(List<int> bytes) {
    if (closed) return;
    _controller.add(bytes);
  }

  @override
  Future<void> write(List<int> input) async {
    _service.inputWrites.add(input);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _controller.close();
  }
}

/// Collects [count] frames from [frames], guarding against a hang.
Future<List<TerminalFrame>> collect(
  Stream<TerminalFrame> frames,
  int count,
) async {
  return frames.take(count).toList().timeout(const Duration(seconds: 5));
}

/// Asserts [frames] match [expected], where a `String` is an ANSI
/// [TerminalOutput] and an `int` is a [TerminalReplayComplete] endOffset.
void expectSequence(List<TerminalFrame> frames, List<Object> expected) {
  expect(frames, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    final frame = frames[i];
    final want = expected[i];
    if (want is String) {
      expect(frame, isA<TerminalOutput>(), reason: 'frame $i is an output');
      expect(utf8.decode((frame as TerminalOutput).bytes), want);
    } else if (want is int) {
      expect(
        frame,
        isA<TerminalReplayComplete>(),
        reason: 'frame $i is replay_complete',
      );
      expect((frame as TerminalReplayComplete).endOffset, want);
    } else {
      fail('unexpected expected value ${want.runtimeType} at $i');
    }
  }
}

void main() {
  TerminalAttachProxy makeProxy(_FakeService service) => TerminalAttachProxy(
    service: service,
    pty: () => service.runningTerminal('ses_1'),
  );

  test(
    'one upstream attach fans out identical frames to N attachers',
    () async {
      final service = _FakeService();
      final proxy = makeProxy(service);

      final a1 = await proxy.attach();
      final a2 = await proxy.attach();
      expect(service.connects, 1, reason: 'a single upstream attach');

      service.connection!.emitLive(utf8.encode('LIVE'));

      final f1 = await collect(a1.frames, 3);
      final f2 = await collect(a2.frames, 3);
      expectSequence(f1, ['REPLAY', 6, 'LIVE']);
      expectSequence(f2, ['REPLAY', 6, 'LIVE']);

      await proxy.close();
    },
  );

  test('raw input from any attacher reaches the upstream TUI', () async {
    final service = _FakeService();
    final proxy = makeProxy(service);

    final a1 = await proxy.attach();
    final a2 = await proxy.attach();

    await a1.write(utf8.encode('a'));
    await a2.write(utf8.encode('b'));

    expect(service.inputWrites, [utf8.encode('a'), utf8.encode('b')]);

    await proxy.close();
  });

  test('a resize request is forwarded to the service', () async {
    final service = _FakeService();
    final proxy = makeProxy(service);

    final a1 = await proxy.attach();
    await a1.resize(80, 24);

    expect(service.resizes, [const TerminalSize(cols: 80, rows: 24)]);

    await proxy.close();
  });

  test(
    'a new attacher replays the buffered ring and exposes endOffset',
    () async {
      final service = _FakeService();
      final proxy = makeProxy(service);

      final a1 = await proxy.attach();
      service.connection!.emitLive(utf8.encode('LIVE'));
      // Drain a1 up to the live frame so the ring is known to hold it.
      await collect(a1.frames, 3);
      expect(proxy.endOffset, 10, reason: 'REPLAY(6) + LIVE(4)');

      final a2 = await proxy.attach();
      final f2 = await collect(a2.frames, 2);
      expectSequence(f2, ['REPLAYLIVE', 10]);

      await proxy.close();
    },
  );

  test('an out-of-range cursor replays the current screen', () async {
    final service = _FakeService();
    final proxy = makeProxy(service);

    final a1 = await proxy.attach();
    await collect(a1.frames, 2); // REPLAY, 6

    final a2 = await proxy.attach(cursor: 9999);
    final f2 = await collect(a2.frames, 2);
    expectSequence(f2, ['REPLAY', 6]);

    await proxy.close();
  });

  test('an in-range cursor resumes mid-ring', () async {
    final service = _FakeService();
    final proxy = makeProxy(service);

    final a1 = await proxy.attach();
    await collect(a1.frames, 2);

    final a2 = await proxy.attach(cursor: 2);
    final f2 = await collect(a2.frames, 2);
    expectSequence(f2, ['PLAY', 6]);

    await proxy.close();
  });

  test('the last attacher leaving releases the upstream attach', () async {
    final service = _FakeService();
    final proxy = makeProxy(service);

    final a1 = await proxy.attach();
    final a2 = await proxy.attach();
    await collect(a1.frames, 2);

    await a1.close();
    expect(service.connection!.closed, isFalse, reason: 'an attacher remains');
    expect(proxy.attachers, 1);

    await a2.close();
    expect(
      service.connection!.closed,
      isTrue,
      reason: 'the last attacher released the upstream',
    );
    expect(proxy.attachers, 0);
  });

  test('re-attaching after release opens a fresh upstream attach', () async {
    final service = _FakeService();
    final proxy = makeProxy(service);

    final a1 = await proxy.attach();
    await a1.close();
    expect(service.connects, 1);
    expect(proxy.attachers, 0);

    final a2 = await proxy.attach();
    expect(service.connects, 2);
    final f2 = await collect(a2.frames, 2);
    expectSequence(f2, ['REPLAY', 6]);

    await proxy.close();
  });

  test('a closed proxy refuses attachers and closes its streams', () async {
    final service = _FakeService();
    final proxy = makeProxy(service);

    final a1 = await proxy.attach();
    await proxy.close();

    expect(proxy.isClosed, isTrue);
    await expectLater(proxy.attach(), throwsStateError);

    final drained = await a1.frames.toList();
    expect(drained, hasLength(2), reason: 'the stream is done');
  });

  test('a failing PTY resolver propagates from attach', () async {
    final service = _FakeService();
    final proxy = TerminalAttachProxy(
      service: service,
      pty: () async => throw StateError('no running PTY'),
    );

    await expectLater(proxy.attach(), throwsStateError);
    expect(service.connects, 0);
  });
}
