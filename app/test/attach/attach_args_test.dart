import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/attach/attach_args.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';

void main() {
  group('AttachArgs', () {
    test('toArgv renders the headless attach argv', () {
      const args = AttachArgs(
        sessionId: 'ses_1',
        token: 'tok',
        size: TerminalSize(cols: 80, rows: 24),
      );
      expect(args.toArgv(), [
        AttachArgs.flag,
        '--session',
        'ses_1',
        '--token',
        'tok',
        '--size',
        '80x24',
      ]);
    });

    test('toArgv omits --size when the size is unknown', () {
      const args = AttachArgs(sessionId: 's', token: 't');
      expect(args.toArgv(), [
        AttachArgs.flag,
        '--session',
        's',
        '--token',
        't',
      ]);
    });

    test('parse round-trips toArgv', () {
      const args = AttachArgs(
        sessionId: 'ses/1',
        token: 'tok',
        size: TerminalSize(cols: 132, rows: 43),
      );
      expect(AttachArgs.parse(args.toArgv()), args);
    });

    test('parse accepts an argv without --size', () {
      final args = AttachArgs.parse([
        AttachArgs.flag,
        '--session',
        's',
        '--token',
        't',
      ]);
      expect(args.sessionId, 's');
      expect(args.token, 't');
      expect(args.size, isNull);
    });

    test('parse rejects argv that is not an attach invocation', () {
      expect(() => AttachArgs.parse([]), throwsFormatException);
      expect(() => AttachArgs.parse(['--other']), throwsFormatException);
      expect(() => AttachArgs.parse([AttachArgs.flag]), throwsFormatException);
    });

    test('parse rejects a missing session or token', () {
      expect(
        () => AttachArgs.parse([AttachArgs.flag, '--token', 't']),
        throwsFormatException,
      );
      expect(
        () => AttachArgs.parse([AttachArgs.flag, '--session', 's']),
        throwsFormatException,
      );
    });

    test('parse rejects a malformed --size', () {
      expect(
        () => AttachArgs.parse([
          AttachArgs.flag,
          '--session',
          's',
          '--token',
          't',
          '--size',
          'n',
        ]),
        throwsFormatException,
      );
      expect(
        () => AttachArgs.parse([
          AttachArgs.flag,
          '--session',
          's',
          '--token',
          't',
          '--size',
          '80',
        ]),
        throwsFormatException,
      );
    });

    test('argvFor prepends the app binary', () {
      const args = AttachArgs(sessionId: 's', token: 't');
      expect(args.argvFor('/app/bin'), ['/app/bin', ...args.toArgv()]);
    });
  });
}
