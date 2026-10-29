import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/attach/attach_client.dart';
import 'package:opencodebridge/bridge/terminal/terminal_frames.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';

void main() {
  const size = TerminalSize(cols: 80, rows: 24);
  final bridgeUri = Uri.parse('ws://127.0.0.1:48201');

  group('TerminalAttachClient', () {
    test(
      'connects with the window token, cursor 0, and the session path',
      () async {
        final transports = <_FakeTransport>[];
        final uris = <Uri>[];
        final client = TerminalAttachClient(
          sessionId: 'ses_1',
          token: 'tok',
          bridgeUri: bridgeUri,
          connect: _connect(transports, uris),
          input: _input(),
          render: (_) {},
        );
        final future = client.run();
        final transport = await _waitFor(transports, 1);
        final uri = uris.single;
        expect(uri.path, '/api/sessions/ses_1/terminal');
        expect(uri.queryParameters['token'], 'tok');
        expect(uri.queryParameters['cursor'], '0');
        expect(transport, isNotNull);
        await client.stop();
        await future;
      },
    );

    test('renders binary frames as passthrough and reports the size', () async {
      final transports = <_FakeTransport>[];
      final rendered = <int>[];
      final client = TerminalAttachClient(
        sessionId: 's',
        token: 't',
        bridgeUri: bridgeUri,
        connect: _connect(transports, <Uri>[]),
        input: _input(),
        render: (List<int> bytes) => rendered.addAll(bytes),
        size: size,
      );
      final future = client.run();
      final transport = await _waitFor(transports, 1);
      transport.emitData([1, 2, 3]);
      await _eventually(() => rendered.length == 3);
      expect(rendered, [1, 2, 3]);
      expect(transport.sent, [encodeResize(size.cols, size.rows)]);
      await client.stop();
      await future;
    });

    test('reconnects resuming from the last replay endOffset', () async {
      final transports = <_FakeTransport>[];
      final uris = <Uri>[];
      final client = TerminalAttachClient(
        sessionId: 's',
        token: 't',
        bridgeUri: bridgeUri,
        connect: _connect(transports, uris),
        input: _input(),
        render: (_) {},
      );
      final future = client.run();
      final first = await _waitFor(transports, 1);
      first.emitControl(encodeReplayComplete(42));
      first.closeTransport();
      final second = await _waitFor(transports, 2);
      expect(uris[1].queryParameters['cursor'], '42');
      expect(second, isNotNull);
      await client.stop();
      await future;
    });

    test('keeps the newest endOffset across several replays', () async {
      final transports = <_FakeTransport>[];
      final uris = <Uri>[];
      final client = TerminalAttachClient(
        sessionId: 's',
        token: 't',
        bridgeUri: bridgeUri,
        connect: _connect(transports, uris),
        input: _input(),
        render: (_) {},
      );
      final future = client.run();
      final first = await _waitFor(transports, 1);
      first.emitControl(encodeReplayComplete(10));
      first.closeTransport();
      final second = await _waitFor(transports, 2);
      second.emitControl(encodeReplayComplete(99));
      second.closeTransport();
      await _waitFor(transports, 3);
      expect(uris[2].queryParameters['cursor'], '99');
      await client.stop();
      await future;
    });

    test('forwards local keystrokes to the current attach', () async {
      final transports = <_FakeTransport>[];
      final input = StreamController<List<int>>();
      final client = TerminalAttachClient(
        sessionId: 's',
        token: 't',
        bridgeUri: bridgeUri,
        connect: _connect(transports, <Uri>[]),
        input: input.stream,
        render: (_) {},
      );
      final future = client.run();
      final transport = await _waitFor(transports, 1);
      input.add([7]);
      await _eventually(() => transport.sent.isNotEmpty);
      expect(transport.sent.single, [7]);
      await client.stop();
      await future;
    });

    test(
      'reconnects with growing, capped backoff while the bridge is down',
      () async {
        final client = TerminalAttachClient(
          sessionId: 's',
          token: 't',
          bridgeUri: bridgeUri,
          connect: (Uri uri) async => throw StateError('bridge down'),
          input: _input(),
          render: (_) {},
          initialBackoff: const Duration(milliseconds: 100),
          maxBackoff: const Duration(milliseconds: 400),
        );
        final future = client.run();
        await _eventually(() => client.backoffs.length >= 3);
        expect(client.backoffs, [
          const Duration(milliseconds: 100),
          const Duration(milliseconds: 200),
          const Duration(milliseconds: 400),
        ]);
        await client.stop();
        await future;
      },
    );

    test('stops when the input closes (the window closed)', () async {
      final transports = <_FakeTransport>[];
      final input = StreamController<List<int>>();
      final client = TerminalAttachClient(
        sessionId: 's',
        token: 't',
        bridgeUri: bridgeUri,
        connect: _connect(transports, <Uri>[]),
        input: input.stream,
        render: (_) {},
      );
      final future = client.run();
      await _waitFor(transports, 1);
      await input.close();
      await future.timeout(const Duration(seconds: 5));
      expect(client.isStopped, isTrue);
    });

    test('stop closes the current attach and run completes', () async {
      final transports = <_FakeTransport>[];
      final client = TerminalAttachClient(
        sessionId: 's',
        token: 't',
        bridgeUri: bridgeUri,
        connect: _connect(transports, <Uri>[]),
        input: _input(),
        render: (_) {},
      );
      final future = client.run();
      final transport = await _waitFor(transports, 1);
      await client.stop();
      expect(transport.closed, isTrue);
      await future;
    });
  });
}

/// A fresh input stream that never closes (only a window close does).
Stream<List<int>> _input() => StreamController<List<int>>().stream;

/// A [connect] factory that records every attach uri and hands out a fresh
/// [_FakeTransport] per attempt.
Future<AttachTransport> Function(Uri uri) _connect(
  List<_FakeTransport> transports,
  List<Uri> uris,
) {
  return (Uri uri) async {
    uris.add(uri);
    final transport = _FakeTransport();
    transports.add(transport);
    return transport;
  };
}

/// Waits until [transports] holds at least [n] entries (the client created
/// the n-th attach) and returns it.
Future<_FakeTransport> _waitFor(List<_FakeTransport> transports, int n) =>
    _eventually(() => transports.length >= n).then((_) => transports[n - 1]);

/// Polls [condition] on short real delays (the client loop runs on real
/// timers) until it holds.
Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('condition not met within 5 s');
}

/// A scripted attach: the test emits frames and closes it; the client
/// observes both.
class _FakeTransport implements AttachTransport {
  final sent = <Object>[];
  bool closed = false;
  final _data = StreamController<List<int>>();
  final _control = StreamController<String>();
  final _done = Completer<void>();

  @override
  Stream<List<int>> get data => _data.stream;

  @override
  Stream<String> get control => _control.stream;

  @override
  Future<void> get done => _done.future;

  void emitData(List<int> bytes) => _data.add(bytes);

  void emitControl(String frame) => _control.add(frame);

  void closeTransport() {
    if (_done.isCompleted) return;
    _done.complete();
    _data.close();
    _control.close();
  }

  @override
  void send(Object frame) => sent.add(frame);

  @override
  Future<void> close() async {
    closed = true;
    closeTransport();
  }
}
