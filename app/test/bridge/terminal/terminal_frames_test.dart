import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/terminal_frames.dart';

void main() {
  group('TerminalFrame types', () {
    test('output and replay-complete are distinct, ordered frames', () {
      const out = TerminalOutput([1, 2, 3]);
      const done = TerminalReplayComplete(100);
      expect(out.bytes, [1, 2, 3]);
      expect(done.endOffset, 100);
      expect(out, isA<TerminalFrame>());
      expect(done, isA<TerminalFrame>());
    });
  });

  group('encode/parse round-trips', () {
    test('resize encodes and parses back', () {
      final frame = encodeResize(132, 43);
      final parsed = parseResize(frame);
      expect(parsed, isNotNull);
      expect(parsed!.cols, 132);
      expect(parsed.rows, 43);
    });

    test('replay-complete encodes and parses back', () {
      final frame = encodeReplayComplete(20163);
      expect(parseReplayComplete(frame), 20163);
    });

    test('a resize frame is not parsed as a replay-complete', () {
      expect(parseReplayComplete(encodeResize(80, 24)), isNull);
    });

    test('a replay-complete frame is not parsed as a resize', () {
      expect(parseResize(encodeReplayComplete(5)), isNull);
    });
  });

  group('raw input is never mistaken for a control frame', () {
    test('plain text keystrokes parse as no control', () {
      expect(parseResize('a'), isNull);
      expect(parseResize('hello'), isNull);
      expect(parseReplayComplete('hello'), isNull);
    });

    test('a JSON object that is not a known control is no control', () {
      expect(parseResize('{"type":"other","x":1}'), isNull);
      expect(parseReplayComplete('{"type":"other"}'), isNull);
    });

    test('a malformed object is no control', () {
      expect(parseResize('{"type":"resize","cols":'), isNull);
      expect(parseReplayComplete('not json'), isNull);
    });

    test('non-positive sizes are rejected', () {
      expect(parseResize('{"type":"resize","cols":0,"rows":24}'), isNull);
      expect(parseResize('{"type":"resize","cols":80,"rows":-1}'), isNull);
    });
  });
}
