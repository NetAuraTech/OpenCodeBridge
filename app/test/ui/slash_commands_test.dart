import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/ui/slash_commands.dart';

void main() {
  group('SlashCommands.catalog', () {
    test('carries every service command (the issue tables) in menu order', () {
      expect(SlashCommands.catalog.map((c) => c.name).toList(), const [
        // Service — session scope.
        'models',
        'agents',
        'variants',
        'compact',
        'undo',
        'redo',
        'fork',
        'rename',
        'export',
        'cd',
        'skills',
        'btw',
        'diff',
        'stats',
        'terminal',
        'worktrees',
        // Service — global scope.
        'sessions',
        'new',
        'open',
        'usage',
        'mcps',
        'connect',
        'status',
        'pair',
        'reload',
        'plugins',
        // Local.
        'clear',
        'timeline',
        'copy',
        'help',
        'settings',
        'debug',
        'exit',
      ]);
    });

    test('service commands are service-family; the in-app ones local', () {
      final local = {
        'clear',
        'timeline',
        'copy',
        'help',
        'settings',
        'debug',
        'exit',
      };
      for (final command in SlashCommands.catalog) {
        final family = local.contains(command.name)
            ? CommandFamily.local
            : CommandFamily.service;
        expect(command.family, family, reason: command.name);
      }
    });

    test('the argument commands carry takesArg and an argument hint', () {
      SlashCommand byName(String name) =>
          SlashCommands.catalog.firstWhere((c) => c.name == name);

      expect(byName('rename').takesArg, isTrue);
      expect(byName('rename').argHint, '<title>');
      expect(byName('cd').takesArg, isTrue);
      expect(byName('cd').argHint, '<path>');
      expect(byName('btw').takesArg, isTrue);
      expect(byName('btw').argHint, '<question>');

      // The no-argument commands carry no hint.
      expect(byName('models').takesArg, isFalse);
      expect(byName('models').argHint, isNull);
      expect(byName('compact').takesArg, isFalse);
    });

    test('the TUI aliases are kept', () {
      SlashCommand byName(String name) =>
          SlashCommands.catalog.firstWhere((c) => c.name == name);

      expect(byName('variants').aliases, containsAll(['thinking', 'effort']));
      expect(byName('sessions').aliases, containsAll(['resume', 'continue']));
      expect(byName('open').aliases, containsAll(['projects', 'project']));
      expect(byName('pair').aliases, contains('web'));
      expect(byName('exit').aliases, containsAll(['quit', 'q']));
    });

    test('the agent call commands are deliberately left out', () {
      final names = {for (final c in SlashCommands.catalog) c.name};
      // Each of the five is absent (not merely "not all five").
      for (final name in const [
        'editor',
        'themes',
        'highlights',
        'update',
        'restart',
      ]) {
        expect(names, isNot(contains(name)), reason: name);
      }
    });
  });

  group('SlashCommand.matches', () {
    SlashCommand byName(String name) =>
        SlashCommands.catalog.firstWhere((c) => c.name == name);

    test('an empty query matches every command', () {
      for (final command in SlashCommands.catalog) {
        expect(command.matches(''), isTrue, reason: command.name);
      }
    });

    test('a typed name prefix matches the command', () {
      expect(byName('models').matches('mod'), isTrue);
      expect(byName('models').matches('models'), isTrue);
      expect(byName('models').matches('modelsx'), isFalse);
    });

    test('an alias prefix matches the command', () {
      expect(byName('variants').matches('thinking'), isTrue);
      expect(byName('variants').matches('eff'), isTrue);
      expect(byName('sessions').matches('resume'), isTrue);
      expect(byName('exit').matches('q'), isTrue);
    });

    test('the match is case-insensitive and a prefix, not a substring', () {
      expect(byName('models').matches('MODELS'), isTrue);
      expect(byName('models').matches('think'), isFalse);
      expect(byName('variants').matches('THINKING'), isTrue);
      // `undo` is not an alias of anything else; a longer token that merely
      // contains it does not match.
      expect(byName('undo').matches('undone'), isFalse);
    });
  });

  group('SlashCommands.withCustom', () {
    test('appends the project commands as custom, argument-taking rows', () {
      const custom = [OpencodeCommand(name: 'deploy', description: 'ship it')];
      final merged = SlashCommands.withCustom(custom);

      expect(merged.length, SlashCommands.catalog.length + 1);
      final added = merged.last;
      expect(added.name, 'deploy');
      expect(added.family, CommandFamily.custom);
      expect(added.scope, CommandScope.session);
      expect(added.takesArg, isTrue);
      expect(added.subtitle, 'ship it');
      // The built-ins are preserved in order.
      expect(
        merged.take(SlashCommands.catalog.length).map((c) => c.name).toList(),
        SlashCommands.catalog.map((c) => c.name).toList(),
      );
    });

    test(
      'a custom command does not replace a built-in (the built-in wins)',
      () {
        const custom = [
          OpencodeCommand(name: 'models', description: 'override attempt'),
          OpencodeCommand(name: 'deploy', description: 'ship it'),
        ];
        final merged = SlashCommands.withCustom(custom);

        expect(merged.length, SlashCommands.catalog.length + 1);
        // The built-in `models` is unchanged; only `deploy` is added.
        expect(merged.where((c) => c.name == 'models').length, 1);
        expect(
          merged.firstWhere((c) => c.name == 'models').family,
          CommandFamily.service,
        );
        expect(
          merged.firstWhere((c) => c.name == 'models').subtitle,
          'Switch model',
        );
        expect(merged.last.name, 'deploy');
      },
    );

    test('a custom command with no description falls back to its name', () {
      const custom = [OpencodeCommand(name: 'ship', description: '')];
      final merged = SlashCommands.withCustom(custom);
      expect(merged.last.subtitle, 'ship');
    });
  });
}
