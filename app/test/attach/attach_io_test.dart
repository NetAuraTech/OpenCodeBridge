import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/attach/attach_io.dart';
import 'package:opencodebridge/bridge/terminal/terminal_frames.dart';

void main() {
  test(
    'connectAttach splits frames both ways and signals done on close',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final serverFrames = <Object>[];
      late WebSocket ws;
      server.listen((HttpRequest request) async {
        ws = await WebSocketTransformer.upgrade(request);
        ws.listen((dynamic event) => serverFrames.add(event));
        await Future<void>.delayed(const Duration());
        ws.add([1, 2, 3]);
        ws.add(encodeReplayComplete(5));
      });

      final transport = await connectAttach(
        Uri.parse('ws://127.0.0.1:${server.port}/api/sessions/s/terminal'),
      );
      final data = <int>[];
      final control = <String>[];
      final done = Completer<void>();
      transport.data.listen(data.addAll);
      transport.control.listen(control.add);
      transport.done.then(done.complete);

      await _eventually(() => data.length == 3 && control.length == 1);
      expect(data, [1, 2, 3]);
      expect(control.single, encodeReplayComplete(5));

      transport.send([7]);
      transport.send(encodeResize(80, 24));
      await _eventually(() => serverFrames.length == 2);
      expect(serverFrames, <Object>[
        [7],
        encodeResize(80, 24),
      ]);

      await ws.close();
      await done.future.timeout(const Duration(seconds: 5));
      await server.close(force: true);
    },
  );

  test('connectAttach throws when the endpoint refuses the upgrade', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((HttpRequest request) {
      request.response.statusCode = HttpStatus.ok;
      request.response.close();
    });
    expect(
      () => connectAttach(Uri.parse('http://127.0.0.1:${server.port}/x')),
      throwsA(isA<WebSocketException>()),
    );
    await server.close(force: true);
  });
}

Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('condition not met within 5 s');
}
