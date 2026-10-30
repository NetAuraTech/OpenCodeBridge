import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/ui/diff_view.dart';

void main() {
  group('DiffView.parse', () {
    test('parses the hunk lines with the hunk header line numbers', () {
      const patch =
          'Index: a.dart\n'
          '===================================================================\n'
          '--- a.dart\n'
          '+++ a.dart\n'
          '@@ -3,4 +3,5 @@\n'
          ' keep one\n'
          '-old one\n'
          '-old two\n'
          '+new one\n'
          '+new two\n'
          '+new three\n'
          ' keep two\n';
      final lines = DiffView.parse(patch);
      expect(
        [for (final line in lines) line.text],
        const [
          'keep one',
          'old one',
          'old two',
          'new one',
          'new two',
          'new three',
          'keep two',
        ],
      );
      expect(
        [for (final line in lines) line.number],
        // The context/removed lines show the old file's number, the added
        // lines the new file's (a context line advances both counters).
        const [3, 4, 5, 4, 5, 6, 6],
      );
    });

    test('parses hunks without line counts and a second hunk', () {
      const patch =
          '--- a\n'
          '+++ a\n'
          '@@ -1 +1 @@\n'
          '-a\n'
          '+b\n'
          '@@ -10,2 +10,2 @@\n'
          ' ten\n'
          '-x\n'
          '+y\n';
      final lines = DiffView.parse(patch);
      expect([for (final line in lines) line.number], const [1, 1, 10, 11, 11]);
    });

    test('skips the file headers between the hunks', () {
      const patch =
          'Index: a\n'
          '--- a\n'
          '+++ a\n'
          '@@ -1 +1 @@\n'
          '-a\n'
          '+b\n'
          'Index: b\n'
          '--- b\n'
          '+++ b\n'
          '@@ -1 +1 @@\n'
          '-c\n'
          '+d\n';
      final lines = DiffView.parse(patch);
      expect([for (final line in lines) line.text], const ['a', 'b', 'c', 'd']);
    });
  });
}
