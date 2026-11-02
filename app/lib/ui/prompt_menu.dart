/// How a menu trigger anchors to the field's text.
enum MenuAnchoring {
  /// The menu opens only when the field's text starts with the trigger
  /// (the TUI's `/` trigger). The filter token is the text after the
  /// trigger up to the first space.
  anchored,

  /// The menu opens while the caret is inside a token that starts with the
  /// trigger, wherever the token appears in the text (the TUI's `@`
  /// trigger). The filter token is the text between the trigger and the
  /// caret.
  inline,
}

/// One prompt menu (issue #56): the [trigger] character that opens it,
/// [anchoring] how the trigger binds to the field's text, [rows] the rows
/// for a filter token (the bar re-asks on every keystroke and cursor move),
/// and [emptyLabel] the line the chrome shows when [rows] yields none.
///
/// The prompt bar hosts one menu per definition, and the chrome — the
/// popup, the live filtering as the token changes, the keyboard selection
/// with the top row re-selected on a re-typed token, the scroll that
/// follows it, Escape to dismiss — is shared across triggers; a trigger
/// differs only in its character, how it anchors, and the rows it
/// provides.
class PromptMenuDefinition {
  const PromptMenuDefinition({
    required this.trigger,
    required this.anchoring,
    required this.rows,
    required this.emptyLabel,
  });

  /// The trigger character (one character).
  final String trigger;

  /// How the trigger anchors to the field's text.
  final MenuAnchoring anchoring;

  /// The rows for a filter token.
  final List<PromptMenuRow> Function(String token) rows;

  /// The line the menu chrome shows when the rows yield none.
  final String emptyLabel;
}

/// One row in a prompt menu, whichever trigger's rows produced it. The menu
/// chrome renders and activates every row the same way; a trigger decides
/// what its rows look like and what activating them does.
class PromptMenuRow {
  const PromptMenuRow({
    required this.name,
    required this.label,
    this.subtitle,
    this.hint,
    this.badge,
    this.takesArg = false,
    required this.onActivate,
  });

  /// A stable per-row identity (the menu's row key is built from it).
  final String name;

  /// The row's main line (e.g. `/models`).
  final String label;

  /// The row's secondary line (the TUI subtitle); `null` leaves the line
  /// empty (the rows keep a uniform height).
  final String? subtitle;

  /// The argument hint appended to the main line (e.g. `<title>`); `null`
  /// hides it.
  final String? hint;

  /// The trailing badge (e.g. `custom`); `null` hides it.
  final String? badge;

  /// Whether the row takes an argument typed after it: the bar holds the
  /// activation until the argument is typed (the TUI behavior).
  final bool takesArg;

  /// Runs the row with its typed argument (trimmed); the bar has already
  /// cleared the field.
  final void Function(String argument) onActivate;
}
