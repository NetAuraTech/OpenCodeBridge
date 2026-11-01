import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/notify/notify_kind.dart';

void main() {
  group('NotifyKind.parseEvents', () {
    test('parses the wire values into the enabled kinds', () {
      expect(
        NotifyKind.parseEvents(
          ['permissionAsked', 'turnEnded', 'dockerContainer'],
        ),
        {
          NotifyKind.permissionAsked,
          NotifyKind.turnEnded,
          NotifyKind.dockerContainer,
        },
      );
    });

    test('an empty list is the empty set (no push enabled)', () {
      expect(NotifyKind.parseEvents(const []), <NotifyKind>{});
    });

    test('duplicates collapse to one kind', () {
      expect(
        NotifyKind.parseEvents(['turnEnded', 'turnEnded']),
        {NotifyKind.turnEnded},
      );
    });

    test('a non-list is malformed', () {
      expect(NotifyKind.parseEvents(null), isNull);
      expect(NotifyKind.parseEvents('turnEnded'), isNull);
    });

    test('a non-string or unknown entry is malformed', () {
      expect(NotifyKind.parseEvents([null]), isNull);
      expect(NotifyKind.parseEvents([1]), isNull);
      expect(NotifyKind.parseEvents(['nope']), isNull);
    });
  });
}
