import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/terminal_attach_proxy.dart';
import 'package:opencodebridge/bridge/terminal/terminal_frames.dart';
import 'package:opencodebridge/ui/terminal_view.dart';
import 'package:xterm/xterm.dart';

/// A scripted [TerminalAttacher] for the terminal view tests.
class _FakeAttacher implements TerminalAttacher {
  final StreamController<TerminalFrame> _frames =
      StreamController<TerminalFrame>.broadcast();

  /// Raw input writes, in order.
  final List<List<int>> writes = [];

  /// Resize requests, as (cols, rows), in order.
  final List<(int, int)> resizes = [];

  /// True once [close] has been called.
  bool closed = false;

  /// Emits [frame] on the downstream stream.
  void emit(TerminalFrame frame) => _frames.add(frame);

  @override
  Stream<TerminalFrame> get frames => _frames.stream;

  @override
  Future<void> write(List<int> input) async {
    writes.add(List<int>.of(input));
  }

  @override
  Future<void> resize(int cols, int rows) async {
    resizes.add((cols, rows));
  }

  @override
  Future<void> close() async {
    closed = true;
    await _frames.close();
  }
}

Future<_FakeAttacher> _pumpScreen(
  WidgetTester tester,
  _FakeAttacher attacher, {
  bool failAttach = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TerminalScreen(
        title: 'fix the flaky test',
        attach: failAttach
            ? () => throw StateError('no terminal')
            : () => Future.value(attacher),
      ),
    ),
  );
  await tester.pump();
  return attacher;
}

TerminalView _view(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView));

void main() {
  group('TerminalScreen', () {
    testWidgets('renders output frames on the terminal', (tester) async {
      final attacher = _FakeAttacher();
      await _pumpScreen(tester, attacher);

      attacher.emit(const TerminalOutput([104, 105])); // "hi"
      await tester.pump();

      expect(_view(tester).terminal.buffer.toString(), contains('hi'));
    });

    testWidgets('keeps rendering after the replay-complete frame', (
      tester,
    ) async {
      final attacher = _FakeAttacher();
      await _pumpScreen(tester, attacher);

      attacher.emit(const TerminalReplayComplete(12345));
      await tester.pump();
      attacher.emit(const TerminalOutput([108, 111, 118, 101])); // "love"
      await tester.pump();

      expect(_view(tester).terminal.buffer.toString(), contains('love'));
    });

    testWidgets('forwards terminal output (typed input) to the attacher', (
      tester,
    ) async {
      final attacher = _FakeAttacher();
      await _pumpScreen(tester, attacher);

      // Drives the xterm's onOutput callback, the same path the
      // TerminalView's keyboard handling takes.
      _view(tester).terminal.textInput('a');
      await tester.pump();

      expect(attacher.writes, [
        [97], // utf8("a")
      ]);
    });

    testWidgets('forwards the terminal size as a resize request', (
      tester,
    ) async {
      final attacher = _FakeAttacher();
      await _pumpScreen(tester, attacher);

      expect(attacher.resizes, isNotEmpty);
      expect(attacher.resizes.last.$1, greaterThan(0));
      expect(attacher.resizes.last.$2, greaterThan(0));
    });

    testWidgets('an attach failure shows the error state', (tester) async {
      await _pumpScreen(tester, _FakeAttacher(), failAttach: true);

      expect(
        find.textContaining('Could not attach to the terminal.'),
        findsOneWidget,
      );
      expect(find.byType(TerminalView), findsNothing);
    });

    testWidgets('releases the attach when the view is disposed', (
      tester,
    ) async {
      final attacher = _FakeAttacher();
      await _pumpScreen(tester, attacher);

      expect(attacher.closed, isFalse);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(attacher.closed, isTrue);
    });
  });
}
