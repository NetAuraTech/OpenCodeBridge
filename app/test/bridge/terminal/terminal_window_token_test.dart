import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/terminal/terminal_window_token.dart';

void main() {
  group('TerminalWindowToken', () {
    test('is a 256-bit (64 hex char) random value', () {
      final token = TerminalWindowToken.generate();
      expect(token.value, hasLength(64));
      expect(
        RegExp('^[0-9a-f]{64}\$').hasMatch(token.value),
        isTrue,
        reason: 'lowercase hex',
      );
    });

    test('two tokens differ (random per startup)', () {
      expect(
        TerminalWindowToken.generate().value,
        isNot(TerminalWindowToken.generate().value),
      );
    });

    test('is deterministic with a seeded random', () {
      final a = TerminalWindowToken.generate(random: Random(42));
      final b = TerminalWindowToken.generate(random: Random(42));
      expect(a.value, b.value);
    });

    group('verify', () {
      final token = TerminalWindowToken.generate();

      test('accepts the token', () {
        expect(token.verify(token.value), isTrue);
      });

      test('rejects a wrong token', () {
        expect(token.verify('deadbeef'), isFalse);
      });

      test('rejects null and empty', () {
        expect(token.verify(null), isFalse);
        expect(token.verify(''), isFalse);
      });

      test('rejects a single-bit difference', () {
        final flipped =
            (token.value[0] == '0' ? '1' : '0') + token.value.substring(1);
        expect(token.verify(flipped), isFalse);
      });
    });
  });
}
