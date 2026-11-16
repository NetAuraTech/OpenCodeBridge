import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/notify/deep_link.dart';
import 'package:opencodebridge/ui/deep_link_target.dart';

/// The one-shot deep-link target's lifecycle, tested flat (no widget):
/// set → consume → cleared, replacement, and the exclusivity of the two
/// target kinds (issue #287).
void main() {
  group('DeepLinkTarget', () {
    test('starts with no target', () {
      final model = DeepLinkTarget();
      expect(model.target, isNull);
    });

    test('set → consume → cleared', () {
      final model = DeepLinkTarget();
      model.apply(DeepLink.session('ses_1'));
      expect(model.target, DeepLink.session('ses_1'));

      // Consumed: the target is gone, so a later identical link is a new
      // event.
      model.consume();
      expect(model.target, isNull);
    });

    test('a container target is consumed the same way', () {
      final model = DeepLinkTarget();
      model.apply(DeepLink.container('postgres'));
      expect(model.target, DeepLink.container('postgres'));

      model.consume();
      expect(model.target, isNull);
    });

    test('consume with no target is a no-op (not an error)', () {
      final model = DeepLinkTarget();
      expect(() => model.consume(), returnsNormally);
      expect(model.target, isNull);
    });

    test('a new target replaces the previous one', () {
      final model = DeepLinkTarget();
      model.apply(DeepLink.session('ses_1'));
      model.apply(DeepLink.session('ses_2'));
      expect(model.target, DeepLink.session('ses_2'));
    });

    test('a new target of the other kind clears the first (exclusive)', () {
      final model = DeepLinkTarget();
      model.apply(DeepLink.session('ses_1'));
      // A container link replaces the pending session target.
      model.apply(DeepLink.container('postgres'));
      expect(model.target, DeepLink.container('postgres'));

      // And a session link replaces the pending container target.
      model.apply(DeepLink.session('ses_3'));
      expect(model.target, DeepLink.session('ses_3'));
    });

    test('a null link is ignored', () {
      final model = DeepLinkTarget();
      model.apply(null);
      expect(model.target, isNull);
    });

    test('applying and consuming notify the listeners', () {
      final model = DeepLinkTarget();
      var notifies = 0;
      void listener() => notifies++;
      model.addListener(listener);

      model.apply(DeepLink.session('ses_1'));
      expect(notifies, 1);

      // consume clears and notifies (so the shell's tab switch settles).
      model.consume();
      expect(notifies, 2);
      expect(model.target, isNull);

      // A consume with no target does not notify.
      model.consume();
      expect(notifies, 2);

      model.removeListener(listener);
    });
  });
}
