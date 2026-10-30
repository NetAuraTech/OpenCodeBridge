import 'package:flutter/material.dart';

/// The kind of a unified diff line.
enum DiffKind { context, added, removed }

/// One line of a unified diff hunk, parsed with its line number (the old
/// file's for context and removed lines, the new file's for added lines).
class DiffLine {
  const DiffLine(this.kind, this.number, this.text);

  final DiffKind kind;
  final int? number;
  final String text;
}

/// Renders a unified diff patch (the file patch the opencode service
/// computes for the edit tools, the same one the terminal renders) with the
/// terminal's own diff colors: the line numbers, the `-`/`+` gutter, and
/// the added/removed/context backgrounds.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.patch});

  /// The unified diff: `Index:`/`---`/`+++` file headers, the
  /// `@@ -a,b +c,d @@` hunk headers, then the ` `/`-`/`+` lines.
  final String patch;

  static final _hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

  /// The patch's hunk lines, with the line numbers the hunk headers imply.
  /// The file headers (`Index:`, `===`, `---`, `+++`) and anything outside
  /// a hunk are skipped.
  static List<DiffLine> parse(String patch) {
    final lines = <DiffLine>[];
    var oldLine = 0;
    var newLine = 0;
    var inHunk = false;
    final rawLines = patch.split('\n');
    // The trailing newline of the patch is not a line.
    if (rawLines.isNotEmpty && rawLines.last.isEmpty) {
      rawLines.removeLast();
    }
    for (final raw in rawLines) {
      final hunk = _hunk.firstMatch(raw);
      if (hunk != null) {
        oldLine = int.parse(hunk.group(1)!);
        newLine = int.parse(hunk.group(2)!);
        inHunk = true;
        continue;
      }
      if (!inHunk) continue;
      if (raw.isEmpty) {
        // An empty line inside a hunk is an empty context line, present in
        // both files (it advances both line counters).
        lines.add(DiffLine(DiffKind.context, oldLine, ''));
        oldLine++;
        newLine++;
        continue;
      }
      final sign = raw[0];
      if (sign == ' ') {
        // Context: in both files, advance both counters.
        lines.add(DiffLine(DiffKind.context, oldLine, raw.substring(1)));
        oldLine++;
        newLine++;
      } else if (sign == '-') {
        lines.add(DiffLine(DiffKind.removed, oldLine++, raw.substring(1)));
      } else if (sign == '+') {
        lines.add(DiffLine(DiffKind.added, newLine++, raw.substring(1)));
      } else if (sign != '\\') {
        // The file headers (`Index:`, `===`, `---`, `+++`) end the hunk.
        inHunk = false;
      }
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final colors = _TuiDiffColors.resolve(Theme.of(context).brightness);
    final lines = DiffView.parse(patch);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final line in lines) _buildLine(line, colors)],
    );
  }

  Widget _buildLine(DiffLine line, _TuiDiffColors colors) {
    final (sign, signColor, textColor, lineBg, numberBg) = switch (line.kind) {
      DiffKind.added => (
        '+',
        colors.highlightAdded,
        colors.added,
        colors.addedBg,
        colors.addedNumberBg,
      ),
      DiffKind.removed => (
        '-',
        colors.highlightRemoved,
        colors.removed,
        colors.removedBg,
        colors.removedNumberBg,
      ),
      DiffKind.context => (' ', colors.context, colors.context, null, null),
    };
    return Container(
      color: lineBg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.number != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Container(
                width: 44,
                alignment: Alignment.centerRight,
                color: numberBg,
                child: Text(
                  '${line.number}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                    color: colors.lineNumber,
                  ),
                ),
              ),
            ),
          Text(
            sign,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.4,
              color: signColor,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              line.text.isEmpty ? ' ' : line.text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The diff colors of the opencode TUI theme (the `diff` section of its
/// `opencode` theme document, resolved against its light and dark hue
/// palettes): this view renders the patches the terminal renders.
class _TuiDiffColors {
  const _TuiDiffColors({
    required this.added,
    required this.removed,
    required this.context,
    required this.addedBg,
    required this.removedBg,
    required this.addedNumberBg,
    required this.removedNumberBg,
    required this.lineNumber,
    required this.highlightAdded,
    required this.highlightRemoved,
  });

  static const _light = _TuiDiffColors(
    added: Color(0xFF1E725C),
    removed: Color(0xFFC53B53),
    context: Color(0xFF7086B5),
    addedBg: Color(0xFFD5E5D5),
    removedBg: Color(0xFFF7D8DB),
    addedNumberBg: Color(0xFFC5D5C5),
    removedNumberBg: Color(0xFFE7C8CB),
    lineNumber: Color(0xFF595959),
    highlightAdded: Color(0xFF4DB380),
    highlightRemoved: Color(0xFFF52A65),
  );

  static const _dark = _TuiDiffColors(
    added: Color(0xFF4FD6BE),
    removed: Color(0xFFC53B53),
    context: Color(0xFF828BB8),
    addedBg: Color(0xFF20303B),
    removedBg: Color(0xFF37222C),
    addedNumberBg: Color(0xFF1B2B34),
    removedNumberBg: Color(0xFF2D1F26),
    lineNumber: Color(0xFF8F8F8F),
    highlightAdded: Color(0xFFB8DB87),
    highlightRemoved: Color(0xFFE26A75),
  );

  final Color added;
  final Color removed;
  final Color context;
  final Color addedBg;
  final Color removedBg;
  final Color addedNumberBg;
  final Color removedNumberBg;
  final Color lineNumber;
  final Color highlightAdded;
  final Color highlightRemoved;

  static _TuiDiffColors resolve(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;
}
