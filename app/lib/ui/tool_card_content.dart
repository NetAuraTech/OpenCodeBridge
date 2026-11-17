import 'dart:convert';

import '../model/message.dart';

/// The display content of one tool card (issue #265, the S6a expand): the
/// ONE derivation of what a tool card shows — the header, the patch (with
/// the file it changed), the `question` tool's question lines, the per-tool
/// one-line input summary (or the raw input when the tool is not known for
/// one), and the error line. Before the extraction the rule was written
/// twice in `structured_view.dart` — the copy path's `_toolCardPlainText`
/// and the `_ToolCard` widget's private getters — and the two could drift.
/// No widget, no `BuildContext`: the module is unit-testable flat (derive
/// the content, assert the values), and the two consumers render it exactly
/// as before this extraction.
///
/// What the derivation deliberately does **not** decide: *how* each consumer
/// gates one corner the two sides still disagree on (a `write` whose input
/// is a complete map but whose tool state carries no patch — hand-composed
/// only, the bridge always sets the patch for a write). The [patch] value
/// follows the copy's rule — `tool.patch ?? ToolCall.writePatch(tool.input)`
/// — so the copy keeps showing the path and the synthesized diff, while the
/// card keeps gating its diff rendering on `tool.patch != null` (it shows
/// the raw input there). The derivation serves both values; it does not
/// merge them (a later issue may, deliberately). Likewise the card's patch
/// path line does not check `isNotEmpty` while the copy's does — the
/// derivation hands out the raw [patchPath] string and each consumer keeps
/// its own gate.
class ToolCardContent {
  const ToolCardContent({
    required this.header,
    this.patch,
    this.patchPath,
    this.questions,
    this.detail,
    required this.rawInput,
    this.error,
  });

  /// Derives the display content of one tool call: the values the card and
  /// the copy render, each in exactly the place it used to be derived.
  static ToolCardContent derive(ToolCall tool) {
    return ToolCardContent(
      header: '${tool.name} · ${tool.status}',
      patch: tool.patch ?? ToolCall.writePatch(tool.input),
      patchPath: _patchPath(tool.input),
      questions: _questions(tool),
      detail: _detail(tool),
      rawInput: _rawInput(tool.input),
      error: tool.error,
    );
  }

  /// The card's header line, as shown: `'${tool.name} · ${tool.status}'`.
  final String header;

  /// The patch the card's diff view renders and the copy emits, by the copy's
  /// rule: the tool state's own patch when it carries one, else the
  /// synthesized "new file" diff of a `write`'s content
  /// (`ToolCall.writePatch(tool.input)`) — `null` when neither applies.
  /// The card's diff *rendering* still gates on `tool.patch != null` (a
  /// hand-composed write without a state patch shows its raw input on the
  /// card, path + diff on the copy — the divergence this phase preserves).
  final String? patch;

  /// The file the edit changed (the tool's `input.path`), for the patch's
  /// path line, `null` when the input is not a map carrying a string
  /// `path`. The consumers keep their own gates over it (the copy's line
  /// checks `isNotEmpty`, the card's does not).
  final String? patchPath;

  /// The `question` tool's questions with the answers given (in form order),
  /// or `null` when the input is not the map the card renders as questions
  /// (a still-streaming input is a partial JSON string, shown raw like any
  /// other input).
  final List<ToolCardQuestion>? questions;

  /// A one-line, human-readable summary of the tool's input — `shell` its
  /// command, `execute` its code, `read` its path (with `offset` / `limit`
  /// when given), `grep` its pattern (and path) — or `null` when the input
  /// carries none of the fields the tool is known for. `null` also when the
  /// input is not the map the tool is known for (a still-streaming input);
  /// then [bodyText] falls back to the raw input.
  final String? detail;

  /// The input as raw text, for the fallback: a `String` input as-is, any
  /// other input `jsonEncode`d (its `toString` when even that fails), `''`
  /// for an absent input. A still-streaming input is a partial JSON string
  /// and lands here, unchanged.
  final String rawInput;

  /// The tool's error message, when [ToolCall.status] is `error`.
  final String? error;

  /// The non-patch, non-question body line: the one-line [detail] when the
  /// tool is known for one, else the [rawInput] (`''` when the input is
  /// absent too) — the single fallback both consumers render.
  String get bodyText => detail ?? rawInput;

  /// The file the edit changed (the tool's `input.path`), `null` when the
  /// input is not a map carrying a string `path`.
  static String? _patchPath(Object? input) {
    if (input is Map<String, Object?> && input['path'] is String) {
      return input['path'] as String;
    }
    return null;
  }

  /// The agent's `question` tool (issue #50), rendered TUI-style instead of
  /// as raw JSON: each question's text, with the answer the user gave below
  /// it (the tool state's `metadata.answers`, in form order). `null` while
  /// the input is still streaming (a partial JSON string, shown raw like any
  /// other input).
  static List<ToolCardQuestion>? _questions(ToolCall tool) {
    final input = tool.input;
    if (input is! Map<String, Object?>) return null;
    final list = input['questions'];
    if (list is! List) return null;
    final answers = tool.answers;
    final lines = <ToolCardQuestion>[];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      final question =
          item is Map<String, Object?> && item['question'] is String
          ? item['question'] as String
          : null;
      if (question == null) continue;
      lines.add(
        ToolCardQuestion(
          question: question,
          answers: answers != null && i < answers.length ? answers[i] : null,
        ),
      );
    }
    return lines.isEmpty ? null : lines;
  }

  /// A one-line, human-readable summary of the tool's input, for the tools
  /// whose raw JSON input is mostly noise for what the user wants to glance
  /// at: `shell` shows its command, `read` its path (with `offset` / `limit`
  /// when given), `grep` its pattern (and path), `execute` its code. `null`
  /// when the input is not the map expected for the tool (a still-streaming
  /// input is a partial JSON string) or carries none of the fields the tool
  /// is known for — then the consumer falls back to the raw input,
  /// unchanged. Adding a known tool is a case in this one switch.
  static String? _detail(ToolCall tool) {
    final input = tool.input;
    if (input is! Map<String, Object?>) return null;
    String? str(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    switch (tool.name) {
      case 'shell':
        return str(input['command']);
      case 'execute':
        return str(input['code']);
      case 'read':
        final path = str(input['path']);
        if (path == null) return null;
        final extra = [
          if (input['offset'] is int) 'offset ${input['offset']}',
          if (input['limit'] is int) 'limit ${input['limit']}',
        ].join(', ');
        return extra.isEmpty ? path : '$path ($extra)';
      case 'grep':
        final pattern = str(input['pattern']);
        if (pattern == null) return null;
        final path = str(input['path']);
        return path == null ? pattern : '$pattern in $path';
    }
    return null;
  }

  /// The input as raw text: a `String` input as-is, any other input
  /// `jsonEncode`d (its `toString` when even that fails), `''` for an
  /// absent input.
  static String _rawInput(Object? input) {
    if (input == null) return '';
    if (input is String) return input;
    try {
      return jsonEncode(input);
    } catch (_) {
      return '$input';
    }
  }
}

/// One question of the agent's `question` tool (issue #50), in form order,
/// with the answer the user gave it (the tool state's `metadata.answers`)
/// when one was given.
class ToolCardQuestion {
  const ToolCardQuestion({required this.question, this.answers});

  /// The question's text (the form's `question` field).
  final String question;

  /// The answer the user gave, one entry per picked option, or `null` when
  /// the question is still open (the tool carries no answers) or the
  /// answers ran short of the question.
  final List<String>? answers;
}
