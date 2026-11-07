// The per-Turn task stats the session view's footer shows (issue #121),
// computed from the structured-view message list alone: the bridge and the
// opencode service expose no such aggregate. The semantics follow opencode's
// own turn measurement: the Turn is the window of history between the
// previous `idle` marker and the end of the list, it starts at its first
// prompt, its duration runs to the last completed assistant step, and its
// throughput weighs every step by the provider-active streaming time.

import 'message.dart';

/// The task stats of a session's last Turn, derived from its history.
class TurnStats {
  const TurnStats({
    required this.duration,
    required this.compactions,
    required this.tokensPerSecond,
  });

  /// The Turn's wall-clock duration: the first prompt's creation to the last
  /// completed assistant step. `null` when either end is unknown.
  final Duration? duration;

  /// The compaction markers the Turn ran through.
  final int compactions;

  /// The Turn's output throughput (output + reasoning tokens over the
  /// provider-active streaming time, steps weighted by their active time).
  /// `null` while any step lacks a streamed timestamp, or no step streamed.
  final double? tokensPerSecond;

  /// The footer text: `duration · N compactions · X.X tok/s`, each segment
  /// dropped when its stat is unavailable; `null` when the footer would
  /// carry no real number (the compaction count alone is noise).
  String? get label {
    if (duration == null && tokensPerSecond == null) return null;
    final parts = <String>[
      if (duration != null) _durationText(duration!),
      '$compactions compaction${compactions == 1 ? '' : 's'}',
      if (tokensPerSecond != null)
        '${tokensPerSecond!.toStringAsFixed(1)} tok/s',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  bool operator ==(Object other) =>
      other is TurnStats &&
      other.duration == duration &&
      other.compactions == compactions &&
      other.tokensPerSecond == tokensPerSecond;

  @override
  int get hashCode => Object.hash(duration, compactions, tokensPerSecond);

  @override
  String toString() =>
      'TurnStats(duration: $duration, compactions: $compactions, '
      'tokensPerSecond: $tokensPerSecond)';
}

/// The footer text of a Turn's stats, or `null` when there are none.
String? turnStatsLabel(List<SessionMessage> messages) =>
    computeTurnStats(messages)?.label;

/// The index range `[start, end)` of the history's current (last) Turn:
/// `end` sits just past the trailing `idle` markers (the newest closes the
/// Turn when the session is idle), and `start` just past the previous `idle`
/// marker (the Turn's opener) — or at the Turn's last prompt when the history
/// carries no `idle` markers (legacy). The walk back is proportional to the
/// Turn's size, never the whole history.
(int start, int end) currentTurnRange(List<SessionMessage> messages) {
  var end = messages.length;
  while (end > 0 && messages[end - 1].role == 'idle') {
    end--;
  }
  int? lastPrompt;
  for (var i = end - 1; i >= 0; i--) {
    final role = messages[i].role;
    if (role == 'idle') {
      // The Turn is the window after the boundary; a steer prompt reuses the
      // same Turn, so its fold starts at the window's first prompt.
      return (i + 1, end);
    }
    if (role == 'user' || role == 'synthetic') lastPrompt ??= i;
  }
  // No idle marker anywhere (legacy history): every prompt was its own Turn
  // without a boundary marker, so the Turn starts at its last prompt.
  return (lastPrompt ?? 0, end);
}

/// The Turn's window `[start, end)` folded into its stats ingredients: the
/// first prompt's creation, the compaction count, and the provider-active
/// token/streaming sums (the throughput's numerator and denominator, `null`
/// while any step lacks a streamed timestamp).
class TurnStatsIngredients {
  const TurnStatsIngredients({
    required this.firstPrompt,
    required this.lastCompleted,
    required this.compactions,
    required this.tokens,
    required this.streamedMillis,
    required this.incomplete,
    required this.hasAssistant,
  });

  /// The earliest prompt's creation, or `null` when none is timestamped.
  final int? firstPrompt;

  /// The last completed assistant step's completion, or `null`.
  final int? lastCompleted;

  /// The compaction markers the Turn ran through.
  final int compactions;

  /// The summed output + reasoning tokens of the completed, timestamped
  /// steps, or `null` when no step is complete.
  final int? tokens;

  /// The summed provider-active streaming time of those steps, in
  /// milliseconds, or `null`.
  final int? streamedMillis;

  /// Whether any step lacks a streamed timestamp (which drops the
  /// throughput, even if the others streamed).
  final bool incomplete;

  /// Whether the window holds an assistant step at all.
  final bool hasAssistant;

  /// The Turn's frozen [TurnStats], or `null` when the window holds no
  /// assistant step (a turn with no output yet has no stats to show).
  TurnStats? toStats() {
    if (!hasAssistant) return null;
    final duration = firstPrompt != null && lastCompleted != null
        ? Duration(milliseconds: lastCompleted! - firstPrompt!)
        : null;
    // Aggregate before dividing so the steps are weighted by provider-active
    // time; omit the stat while any step lacks a streamed timestamp.
    final tokensPerSecond =
        !incomplete &&
            tokens != null &&
            streamedMillis != null &&
            streamedMillis! > 0
        ? tokens! / (streamedMillis! / 1000)
        : null;
    return TurnStats(
      duration: duration,
      compactions: compactions,
      tokensPerSecond: tokensPerSecond,
    );
  }
}

/// Folds the window `[start, end)` of [messages] into a
/// [TurnStatsIngredients].
TurnStatsIngredients turnStatsIngredients(
  List<SessionMessage> messages,
  int start,
  int end,
) {
  var compactions = 0;
  int? firstPrompt;
  int? lastCompleted;
  int? tokens;
  int? streamedMillis;
  var incomplete = false;
  var hasAssistant = false;
  for (var i = start; i < end; i++) {
    final message = messages[i];
    switch (message.role) {
      case 'user':
      case 'synthetic':
        firstPrompt ??= message.created;
      case 'compaction':
        compactions++;
      case 'assistant':
        hasAssistant = true;
        if (message.completed != null) lastCompleted = message.completed;
        if (message.created == null ||
            message.streamed == null ||
            message.outputTokens == null ||
            message.reasoningTokens == null) {
          incomplete = true;
        } else {
          tokens =
              (tokens ?? 0) + message.outputTokens! + message.reasoningTokens!;
          streamedMillis =
              (streamedMillis ?? 0) + (message.streamed! - message.created!);
        }
    }
  }
  return TurnStatsIngredients(
    firstPrompt: firstPrompt,
    lastCompleted: lastCompleted,
    compactions: compactions,
    tokens: tokens,
    streamedMillis: streamedMillis,
    incomplete: incomplete,
    hasAssistant: hasAssistant,
  );
}

/// The task stats of the history's last Turn (issue #121). Returns `null`
/// when the window holds no assistant step.
TurnStats? computeTurnStats(List<SessionMessage> messages) {
  final (start, end) = currentTurnRange(messages);
  return turnStatsIngredients(messages, start, end).toStats();
}

/// The per-Turn footer labels keyed by the row index the footer rides on
/// (issue #124): a completed Turn's label rides on its closing `idle` marker,
/// the newest Turn's on the history's last row. Older Turns' footers are
/// filled in as their messages page into view — a Turn's footer is shown only
/// once that Turn is fully loaded: the newest Turn always, an older Turn once
/// its opening `idle` marker has loaded (the very first Turn, which has no
/// opening marker, only once [oldestLoaded] reports the whole history is in).
/// [running] is true while the Turn is active: its content is everything after
/// the newest `idle` marker, so the closed turn that marker ended stays
/// footer-less while the running turn takes over its row. Returns only the
/// rows that carry a label.
Map<int, String> computeTurnFooters(
  List<SessionMessage> messages, {
  required bool oldestLoaded,
  bool running = false,
}) {
  final result = <int, String>{};
  if (messages.isEmpty) return result;
  final idleAt = <int>[
    for (var i = 0; i < messages.length; i++)
      if (messages[i].role == 'idle') i,
  ];
  final lastIdle = idleAt.isEmpty ? -1 : idleAt.last;
  // The newest (current) Turn's footer always rides on the last row: the
  // closing `idle` marker when the session is idle, the turn's last message
  // while it runs. Only its stats window differs by state.
  if (running) {
    // The running Turn is the content after the newest `idle` marker (or the
    // whole history when there is none); its footer rides on the last row.
    final start = lastIdle + 1;
    if (start < messages.length) {
      _addTurnFooter(
        result,
        messages,
        start,
        messages.length,
        footerRow: messages.length - 1,
      );
    }
  } else {
    final (start, end) = currentTurnRange(messages);
    _addTurnFooter(
      result,
      messages,
      start,
      end,
      footerRow: end == messages.length ? messages.length - 1 : end,
    );
  }
  // Every `idle` marker that does not open the running Turn closes the Turn
  // before it; its footer rides on the marker, fully loaded once its opening
  // marker (the previous `idle`) is in the window — or, for the first Turn,
  // once the history is fully loaded.
  // When running, the newest `idle` closes the previous Turn (the running one
  // is after it); when idle, it closes the current Turn (handled above).
  final lastClosed = running
      ? idleAt.length
      : (idleAt.isEmpty ? 0 : idleAt.length - 1);
  for (var k = lastClosed - 1; k >= 0; k--) {
    if (k == 0 && !oldestLoaded) continue;
    final closer = idleAt[k];
    _addTurnFooter(result, messages, (k > 0 ? idleAt[k - 1] : -1) + 1, closer);
  }
  return result;
}

void _addTurnFooter(
  Map<int, String> result,
  List<SessionMessage> messages,
  int start,
  int end, {
  int? footerRow,
}) {
  final row = footerRow ?? end;
  if (row < 0 || row >= messages.length) return;
  final label = turnStatsIngredients(messages, start, end).toStats()?.label;
  if (label != null) result[row] = label;
}

/// Reads the session's current Turn newest-first via [fetchPage], issuing at
/// most the pages needed to cover it (issue #124): the read stops once the
/// Turn's opener `idle` marker is in a page. The newest message's role decides
/// how many markers bound the Turn — an `idle` newest message closes the Turn
/// (so the opener is the next-older idle: two to see), otherwise the first
/// idle seen opens it (one to see). Returns the loaded history (oldest-first,
/// possibly one page past the Turn's opener) and the cursor to the next older
/// page (`null` when the history is exhausted).
Future<(List<SessionMessage> messages, String? nextCursor)> loadCurrentTurn({
  required Future<MessagePage> Function(String? cursor) fetchPage,
}) async {
  var loaded = const <SessionMessage>[];
  var idlesSeen = 0;
  int? target;
  String? cursor;
  String? next;
  var first = true;
  while (true) {
    final page = await fetchPage(cursor);
    // This page is older than everything already loaded: prepend it.
    loaded = [...page.messages, ...loaded];
    if (first) {
      first = false;
      final newest = page.messages.isEmpty ? null : page.messages.last.role;
      target = newest == 'idle' ? 2 : 1;
    }
    for (final message in page.messages) {
      if (message.role == 'idle') idlesSeen++;
    }
    next = page.nextCursor;
    if (idlesSeen >= (target ?? 1)) break;
    if (next == null) break; // History exhausted before the Turn was bounded.
    cursor = next;
  }
  return (loaded, next);
}

/// The duration as the footer shows it: `3.4s` under a minute, `1m 23s` at
/// or above.
String _durationText(Duration duration) {
  final millis = duration.inMilliseconds;
  if (millis < 60000) return '${(millis / 1000).toStringAsFixed(1)}s';
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds - minutes * 60;
  return '${minutes}m ${seconds}s';
}
