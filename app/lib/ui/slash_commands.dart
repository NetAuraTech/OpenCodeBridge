/// The structured view's `/` command menu catalog and its filtering
/// (issue #46). This is pure data + a pure filter, separate from the widget
/// that renders it and the screen that executes the commands, so both can be
/// exercised on their own.
///
/// Three families are surfaced in the menu:
///
/// - [CommandFamily.service] — the built-in commands backed by a shared-service
///   endpoint (the issue's service tables). Running one calls the endpoint;
///   because the service is the single source of truth the effect is reflected
///   live in any attached TUI.
/// - [CommandFamily.custom] — the project's own commands (markdown files /
///   config `commands`), listed from `GET /api/command` and merged in at
///   runtime (not part of the static [SlashCommands.catalog]).
/// - [CommandFamily.local] — the TUI-only commands, run as their in-app
///   equivalent (they touch no shared-service state).
///
/// The "implementing agent's call" commands from the issue are deliberately
/// **not** in the catalog: each is left out of the menu because it has no
/// meaningful in-app equivalent today (the per-command decision):
///
/// - `/editor` — left out: it opens the host's `$EDITOR` on the TUI prompt;
///   the app's prompt field is already the in-app editor, so the command
///   would only duplicate typing.
/// - `/themes` — left out: the app has no theme setting yet (a dark theme is
///   planned long-term); revisit once it exists.
/// - `/highlights` — left out: the release notes are embedded in the TUI
///   build; the app has no source for them.
/// - `/update` — left out: it updates the opencode binary on the host, which
///   the bridge runs but does not own.
/// - `/restart` — left out: it restarts the shared opencode service on the
///   host, which the bridge runs as the same user but does not own.
library;

import '../model/command.dart';

/// The family of a command, which decides how the screen executes it.
enum CommandFamily { service, custom, local }

/// The scope of a command: which session it runs against.
enum CommandScope {
  /// Runs against the open session (the `sessionId` the view is showing).
  session,

  /// Not tied to the open session (a global service or app action).
  global,
}

/// One entry in the `/` command menu.
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.title,
    required this.family,
    required this.scope,
    this.aliases = const [],
    this.takesArg = false,
    this.argHint,
    this.description,
  });

  /// The canonical command name (without the leading slash), e.g. `models`.
  final String name;

  /// The short human label, shown as the row's subtitle (the TUI title for
  /// service/local commands).
  final String title;

  /// The command family (service / custom / local).
  final CommandFamily family;

  /// The command scope (session / global).
  final CommandScope scope;

  /// Extra names that trigger this command (the TUI's `aliases`), e.g.
  /// `thinking` and `effort` for `variants`.
  final List<String> aliases;

  /// True when the command takes an argument typed after the name
  /// (`/rename <title>`); the argument is the input text after the name.
  final bool takesArg;

  /// A hint for the argument, e.g. `<title>`; `null` when [takesArg] is false.
  final String? argHint;

  /// A longer description (the custom command's markdown `description`);
  /// `null` for the built-in commands.
  final String? description;

  /// The subtitle the menu shows for this row: the description when carried,
  /// else the title.
  String get subtitle =>
      (description != null && description!.isNotEmpty) ? description! : title;

  /// True when [query] (the typed command token, slash-less and lowercased)
  /// prefixes the command's name or any alias (case-insensitive). An empty
  /// query matches every command.
  bool matches(String query) {
    final q = query.toLowerCase();
    if (q.isEmpty) return true;
    if (name.toLowerCase().startsWith(q)) return true;
    return aliases.any((a) => a.toLowerCase().startsWith(q));
  }

  @override
  bool operator ==(Object other) =>
      other is SlashCommand &&
      other.name == name &&
      other.title == title &&
      other.family == family &&
      other.scope == scope &&
      _same(other.aliases, aliases) &&
      other.takesArg == takesArg &&
      other.argHint == argHint &&
      other.description == description;

  @override
  int get hashCode => Object.hash(
    name,
    title,
    family,
    scope,
    Object.hashAll(aliases),
    takesArg,
    argHint,
    description,
  );

  @override
  String toString() => 'SlashCommand(/$name, $family, $scope)';
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The static catalog: every service command (the issue's tables) plus the
/// local in-app commands. Custom commands are merged in at runtime (they
/// depend on the project), so they are not here.
class SlashCommands {
  const SlashCommands._();

  /// The built-in commands, in menu order (service session commands, service
  /// global commands, then the local in-app commands).
  static const List<SlashCommand> catalog = [
    // Service — session scope.
    SlashCommand(
      name: 'models',
      title: 'Switch model',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'agents',
      title: 'Switch agent',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'variants',
      title: 'Switch model variant',
      aliases: ['thinking', 'effort'],
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'compact',
      title: 'Compact session',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'undo',
      title: 'Undo previous message',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'redo',
      title: 'Redo',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'fork',
      title: 'Fork session',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'rename',
      title: 'Rename session',
      takesArg: true,
      argHint: '<title>',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'export',
      title: 'Export session transcript',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'cd',
      title: 'Change working directory',
      takesArg: true,
      argHint: '<path>',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'skills',
      title: 'Skills',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'btw',
      title: 'Ask a side question',
      takesArg: true,
      argHint: '<question>',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'diff',
      title: 'Open diff viewer',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'stats',
      title: 'Usage statistics',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'terminal',
      title: 'New terminal',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    SlashCommand(
      name: 'worktrees',
      title: 'Manage workspaces',
      family: CommandFamily.service,
      scope: CommandScope.session,
    ),
    // Service — global scope.
    SlashCommand(
      name: 'sessions',
      title: 'Switch session',
      aliases: ['resume', 'continue'],
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'new',
      title: 'New session',
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'open',
      title: 'Open session or project',
      aliases: ['projects', 'project'],
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'usage',
      title: 'View usage',
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'mcps',
      title: 'MCP servers',
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'connect',
      title: 'Connect an integration',
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'status',
      title: 'View status',
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'pair',
      title: 'Pair device',
      aliases: ['web'],
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'reload',
      title: 'Reload configuration',
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'plugins',
      title: 'Plugins',
      family: CommandFamily.service,
      scope: CommandScope.global,
    ),
    // Local — the in-app equivalents (no shared-service state).
    SlashCommand(
      name: 'clear',
      title: 'Clear session',
      family: CommandFamily.local,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'timeline',
      title: 'Jump to message',
      family: CommandFamily.local,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'copy',
      title: 'Copy last assistant message',
      family: CommandFamily.local,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'help',
      title: 'Help',
      family: CommandFamily.local,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'settings',
      title: 'Open settings',
      family: CommandFamily.local,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'debug',
      title: 'View debug info',
      family: CommandFamily.local,
      scope: CommandScope.global,
    ),
    SlashCommand(
      name: 'exit',
      title: 'Exit the app',
      aliases: ['quit', 'q'],
      family: CommandFamily.local,
      scope: CommandScope.global,
    ),
  ];

  /// The static catalog merged with the project's [custom] commands (family
  /// [CommandFamily.custom]), de-duplicated by name (a custom command does not
  /// replace a built-in; the built-in wins on a name collision). Each custom
  /// command becomes a menu entry whose subtitle is its description and which
  /// always takes an argument — the text typed after the name.
  static List<SlashCommand> withCustom(List<OpencodeCommand> custom) {
    final names = {for (final c in catalog) c.name};
    return [
      ...catalog,
      for (final c in custom)
        if (!names.contains(c.name))
          SlashCommand(
            name: c.name,
            title: c.description.isNotEmpty ? c.description : c.name,
            family: CommandFamily.custom,
            scope: CommandScope.session,
            takesArg: true,
            description: c.description,
          ),
    ];
  }
}
