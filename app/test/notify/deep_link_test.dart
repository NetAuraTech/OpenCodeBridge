import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/notify/deep_link.dart';

void main() {
  group('DeepLink', () {
    test('session and container URIs round-trip', () {
      expect(
        DeepLink.sessionUri('ses_1').toString(),
        'opencodebridge://session/ses_1',
      );
      final session = DeepLink.tryParse(DeepLink.sessionUri('ses_1'));
      expect(session, isNotNull);
      expect(session!.isSession, isTrue);
      expect(session.isContainer, isFalse);
      expect(session.id, 'ses_1');

      expect(
        DeepLink.containerUri('postgres').toString(),
        'opencodebridge://container/postgres',
      );
      final container = DeepLink.tryParse(DeepLink.containerUri('postgres'));
      expect(container!.isContainer, isTrue);
      expect(container.isSession, isFalse);
      expect(container.id, 'postgres');
    });

    test('an external URL is a deep link to be opened in the browser '
        '(spec #376, T5)', () {
      const url = 'https://github.com/o/r/pull/41';
      // The link form is the URL itself: the bridge puts the PR's GitHub URL
      // straight in the push's `data.link`.
      expect(DeepLink.externalUri(url).toString(), url);

      final parsed = DeepLink.tryParse(DeepLink.externalUri(url));
      expect(parsed, isNotNull);
      expect(parsed!.isExternal, isTrue);
      expect(parsed.isSession, isFalse);
      expect(parsed.isContainer, isFalse);
      expect(parsed.id, url);
    });

    test('an external link is distinct from a session link of the same id', () {
      expect(
        DeepLink.tryParse(DeepLink.externalUri('https://x/ses_1')),
        isNot(DeepLink.tryParse(DeepLink.sessionUri('ses_1'))),
      );
    });

    test('tryParse rejects what is not a deep link', () {
      expect(
        DeepLink.tryParse(Uri.parse('opencodebridge://other/ses_1')),
        isNull,
      );
      expect(DeepLink.tryParse(Uri.parse('opencodebridge://session')), isNull);
      expect(
        DeepLink.tryParse(Uri.parse('opencodebridge://session/a/b')),
        isNull,
      );
      // No scheme (and no recognized deep-link scheme): not a deep link.
      expect(DeepLink.tryParse(Uri.parse('session/ses_1')), isNull);
      expect(DeepLink.tryParse(Uri.parse('ftp://host/ses_1')), isNull);
    });

    test('links are equal on target and id', () {
      expect(
        DeepLink.tryParse(DeepLink.sessionUri('ses_1')),
        DeepLink.tryParse(DeepLink.sessionUri('ses_1')),
      );
      expect(
        DeepLink.tryParse(DeepLink.sessionUri('ses_1')),
        isNot(DeepLink.tryParse(DeepLink.sessionUri('ses_2'))),
      );
    });
  });
}
