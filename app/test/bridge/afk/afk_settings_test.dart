import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_settings.dart';
import 'package:opencodebridge/model/command.dart';

void main() {
  group('AfkSettings', () {
    test('defaults: off, cap 5, model empty (a fresh install is inert)', () {
      const settings = AfkSettings();
      expect(settings.enabled, isFalse);
      expect(settings.parallelOrbs, 5);
      expect(settings.model, '');
    });

    test('the cap bounds are 1 and 10', () {
      expect(AfkSettings.minParallelOrbs, 1);
      expect(AfkSettings.maxParallelOrbs, 10);
    });

    test('copyWith overrides only the named fields', () {
      const base = AfkSettings(enabled: true, parallelOrbs: 7, model: 'a/b');
      expect(
        base.copyWith(parallelOrbs: 3),
        const AfkSettings(enabled: true, parallelOrbs: 3, model: 'a/b'),
      );
      expect(
        base.copyWith(model: ''),
        const AfkSettings(enabled: true, parallelOrbs: 7, model: ''),
      );
    });
  });

  group('parseAfkModel', () {
    test('parses provider/model', () {
      expect(
        parseAfkModel('zhipu/glm-4.7'),
        const ModelRef(providerId: 'zhipu', id: 'glm-4.7'),
      );
    });

    test('parses provider/model#variant', () {
      expect(
        parseAfkModel('anthropic/claude-sonnet#high'),
        const ModelRef(
          providerId: 'anthropic',
          id: 'claude-sonnet',
          variant: 'high',
        ),
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        parseAfkModel('  zhipu/glm-4.7  '),
        const ModelRef(providerId: 'zhipu', id: 'glm-4.7'),
      );
    });

    test('a model with a slash in its name splits on the first slash', () {
      expect(
        parseAfkModel('provider/a/b'),
        const ModelRef(providerId: 'provider', id: 'a/b'),
      );
    });

    test('empty and blank answer null (no pin = inherit)', () {
      expect(parseAfkModel(''), isNull);
      expect(parseAfkModel('   '), isNull);
    });

    test('a value with no provider/model split answers null', () {
      expect(parseAfkModel('justamod'), isNull);
      expect(parseAfkModel('/nomodel'), isNull);
      expect(parseAfkModel('noprovider/'), isNull);
    });

    test('a trailing empty variant keeps the model (variant null)', () {
      expect(parseAfkModel('a/b#'), const ModelRef(providerId: 'a', id: 'b'));
    });
  });

  group('isValidAfkModel', () {
    test('empty is valid (inherit)', () {
      expect(isValidAfkModel(''), isTrue);
      expect(isValidAfkModel('   '), isTrue);
    });

    test('a well-formed model is valid', () {
      expect(isValidAfkModel('zhipu/glm-4.7'), isTrue);
      expect(isValidAfkModel('a/b#v'), isTrue);
    });

    test('a malformed model is invalid', () {
      expect(isValidAfkModel('no-slash'), isFalse);
      expect(isValidAfkModel('/x'), isFalse);
      expect(isValidAfkModel('x/'), isFalse);
    });
  });
}
