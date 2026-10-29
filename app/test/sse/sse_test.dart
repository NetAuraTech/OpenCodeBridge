import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/sse/sse.dart';

void main() {
  // Drive [sseDataLines] with a list of chunks, collecting every yielded
  // `data:` value.
  Future<List<String>> feed(List<String> chunks) async {
    final controller = StreamController<String>();
    final results = <String>[];
    final done = sseDataLines(controller.stream).forEach((v) => results.add(v));
    for (final chunk in chunks) {
      controller.add(chunk);
    }
    await controller.close();
    await done;
    return results;
  }

  group('sseDataLines', () {
    test('yields the value of a single data line', () async {
      expect(await feed(['data: {"a":1}\n\n']), ['{"a":1}']);
    });

    test('strips exactly one leading space after data:', () async {
      expect(await feed(['data:{"a":1}\n']), ['{"a":1}']); // no space
      expect(await feed(['data:  {"a":1}\n']), [' {"a":1}']); // keeps 2nd space
    });

    test('drops comment lines (heartbeats) and other fields', () async {
      expect(
        await feed([
          ': heartbeat\n',
          'event: thing\n',
          'id: 7\n',
          'data: {"a":1}\n',
          ': heartbeat\n',
        ]),
        ['{"a":1}'],
      );
    });

    test('reassembles a line split across chunks', () async {
      expect(await feed(['data: {"a":', '1}\n\n']), ['{"a":1}']);
    });

    test('reassembles a data keyword split across chunks', () async {
      expect(await feed(['dat', 'a: {"a":1}\n']), ['{"a":1}']);
    });

    test('handles a trailing line with no newline at stream end', () async {
      expect(await feed(['data: {"a":1}']), ['{"a":1}']);
    });

    test('handles CRLF line endings', () async {
      expect(await feed(['data: {"a":1}\r\n\n']), ['{"a":1}']);
    });

    test('handles many frames in one chunk and across chunks', () async {
      expect(
        await feed(['data: {"n":1}\n\ndata: {"n":2}\n\ndata: {"n":', '3}\n\n']),
        ['{"n":1}', '{"n":2}', '{"n":3}'],
      );
    });

    test('an empty stream yields nothing', () async {
      expect(await feed([]), isEmpty);
    });
  });
}
