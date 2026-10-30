import 'dart:async';
import 'dart:convert';

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

  // Drive [sseDataLines] through the production byte seam
  // (`transform(const Utf8Decoder())` then parse), feeding raw bytes split
  // at arbitrary points — a multi-byte character may straddle any chunk
  // boundary off the wire.
  Future<List<String>> feedBytes(List<List<int>> chunks) async {
    final controller = StreamController<List<int>>();
    final results = <String>[];
    final done = sseDataLines(controller.stream.transform(const Utf8Decoder()))
        .forEach((v) => results.add(v));
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

  group('sseDataLines over raw bytes (the Utf8Decoder seam)', () {
    test(
      'reassembles a multi-byte character split across chunk boundaries',
      () async {
        // "data: café\n\n" with é (U+00E9 = C3 A9) split across three chunks.
        expect(
          await feedBytes([
            utf8.encode('data: caf'),
            [0xC3],
            [0xA9],
            utf8.encode('\n\n'),
          ]),
          ['café'],
        );
      },
    );

    test('reassembles UTF-8 across a full multi-byte frame', () async {
      // A realistic payload: a JSON frame whose text field carries
      // multi-byte characters, split mid-character at several points.
      final frame = utf8.encode('data: {"text":"très bien — café"}\n\n');
      final chunks = <List<int>>[];
      for (var i = 0; i < frame.length; i += 3) {
        chunks.add(frame.sublist(i, (i + 3).clamp(0, frame.length)));
      }
      expect(await feedBytes(chunks), ['{"text":"très bien — café"}']);
    });
  });
}
