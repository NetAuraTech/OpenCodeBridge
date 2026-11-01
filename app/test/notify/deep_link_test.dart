import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/notify/deep_link.dart';

void main() {
  group('DeepLink', () {
    test('session and container URIs round-trip', () {
      expect(
        DeepLink.sessionUri('ses_1').toString(),
        'opencodebridge://session/ses_1',
      );
      final session = DeepLink.tryParse(
        DeepLink.sessionUri('ses_1'),
      );
      expect(session, isNotNull);
      expect(session!.isSession, isTrue);
      expect(session.isContainer, isFalse);
      expect(session.id, 'ses_1');

      expect(
        DeepLink.containerUri('postgres').toString(),
        'opencodebridge://container/postgres',
      );
      final container = DeepLink.tryParse(
        DeepLink.containerUri('postgres'),
      );
      expect(container!.isContainer, isTrue);
      expect(container.isSession, isFalse);
      expect(container.id, 'postgres');
    });

    test('tryParse rejects what is not a deep link', () {
      expect(
        DeepLink.tryParse(Uri.parse('https://session/ses_1')),
        isNull,
      );
      expect(
        DeepLink.tryParse(Uri.parse('opencodebridge://other/ses_1')),
        isNull,
      );
      expect(
        DeepLink.tryParse(Uri.parse('opencodebridge://session')),
        isNull,
      );
      expect(
        DeepLink.tryParse(Uri.parse('opencodebridge://session/a/b')),
        isNull,
      );
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
