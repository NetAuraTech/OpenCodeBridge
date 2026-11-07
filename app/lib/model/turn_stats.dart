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

/// The task stats of the history's last Turn: walk back from the end to the
/// previous `idle` marker (the walk stops at the Turn's first prompt: its
/// cost is proportional to the Turn's size, never the whole history), then
/// fold the Turn's steps into duration, compactions and throughput.
///
/// Returns `null` when the history holds no assistant step at all — a turn
/// with no assistant output yet has no stats to show. A history without
/// `idle` markers is the session's undivided first Turn: every prompt in it
/// was steered into the execution that has not closed yet.
///
/// A queued prompt opens the NEXT Turn (issue #123): once the previous Turn
/// closed at its `idle` marker, the prompt waits alone in the trailing
/// window. That window has no step yet, so the frozen stats fall back to the
/// Turn the prompt has not replaced — the previous footer stays frozen until
/// the queued prompt's own Turn produces its first step (and the view's live
/// fold has taken it over while it runs). A steered prompt needs no
/// fallback: it never closed a Turn, so it sits in the same window as the
/// prompt it steers.
TurnStats? computeTurnStats(List<SessionMessage> messages) {
  var (start, end) = turnWindow(messages);
  while (true) {
    final fold = _fold(messages, start, end, live: false);
    if (fold.hasAssistant) return _statsFrom(fold);
    final previous = _previousTurnWindow(messages, start);
    if (previous == null) return null;
    (start, end) = previous;
  }
}

/// The LIVE task stats of the Turn that is running in [messages] (issue
/// #122), read at wall-clock [now] (epoch millis). It is the same fold as
/// [computeTurnStats] — the same weighted streaming-duration throughput and
/// the same compaction count — so it freezes into the identical value once
/// the Turn ends, but it is live in two ways:
///
/// - The duration runs from the Turn's first prompt to [now] (ticking), not
///   to the last completed step.
/// - The in-flight step (started but not yet completed) is still streaming:
///   it is not yet counted toward the throughput, and its still-missing
///   fields are not treated as a deficit, so the footer ticks from the first
///   prompt onward and the throughput settles in as each step completes.
///
/// Returns `null` when the footer would carry no real number (no first
/// prompt known and no throughput yet — a compaction count alone is noise).
TurnStats? liveTurnStats(List<SessionMessage> messages, {required int now}) {
  final (start, end) = turnWindow(messages);
  final fold = _fold(messages, start, end, live: true);
  final duration = fold.firstPrompt != null
      ? Duration(milliseconds: (now - fold.firstPrompt!).clamp(0, 1 << 30))
      : null;
  if (duration == null && fold.tokensPerSecond == null) return null;
  return TurnStats(
    duration: duration,
    compactions: fold.compactions,
    tokensPerSecond: fold.tokensPerSecond,
  );
}

/// The Turn's window `[start, end)` of [messages]: `end` is past the trailing
/// `idle` markers (the last one closes the Turn), and `start` is at the
/// previous `idle` marker + 1. The walk is proportional to the Turn's size,
/// never the whole history.
///
/// With no `idle` marker anywhere the session has never closed a Turn: the
/// one it shows is its first, still running (only a Turn's end writes an
/// `idle` marker), and every prompt the history holds was delivered INTO it
/// — a steer is an inbox delivery into the running execution (issue #123),
/// never a new boundary. The Turn therefore starts at its FIRST prompt. (A
/// queued prompt cannot contradict this: it reaches the history only after
/// an `idle` marker closed the Turn before it.)
(int start, int end) turnWindow(List<SessionMessage> messages) {
  var end = messages.length;
  while (end > 0 && messages[end - 1].role == 'idle') {
    end--;
  }
  for (var i = end - 1; i >= 0; i--) {
    if (messages[i].role == 'idle') {
      // The Turn is the window after the boundary; a steer prompt reuses the
      // same Turn, so the fold below starts it at its first prompt.
      return (i + 1, end);
    }
  }
  // No `idle` marker anywhere: the session's first, undivided Turn — it
  // starts at its first prompt.
  for (var i = 0; i < end; i++) {
    final role = messages[i].role;
    if (role == 'user' || role == 'synthetic') return (i, end);
  }
  return (0, end);
}

/// The Turn's window closed right before the one starting at [start], or
/// `null` when the history holds no earlier Turn. The window at [start] is
/// the one a queued prompt opened without running it (issue #123): skipping
/// the `idle` markers that close the earlier Turn, that Turn is the window
/// after the next `idle` marker back — or, with none, the whole stretch
/// before them: the session's undivided first Turn, its steers included
/// (the same read [turnWindow] gives a history without any marker).
(int start, int end)? _previousTurnWindow(
  List<SessionMessage> messages,
  int start,
) {
  if (start == 0) return null;
  var end = start;
  while (end > 0 && messages[end - 1].role == 'idle') {
    end--;
  }
  for (var i = end - 1; i >= 0; i--) {
    if (messages[i].role == 'idle') return (i + 1, end);
  }
  return (0, end);
}

/// The raw parts of the Turn's stats, folded over the window [start, end):
/// the first prompt's time, the last completed step's time, the compaction
/// count, the summed output tokens, the summed provider-active streaming
/// time, whether any finished step lacks a field, and whether the window
/// holds any assistant step at all.
class _TurnFold {
  const _TurnFold({
    required this.firstPrompt,
    required this.lastCompleted,
    required this.compactions,
    required this.tokens,
    required this.streamedMillis,
    required this.incomplete,
    required this.hasAssistant,
  });

  final int? firstPrompt;

  final int? lastCompleted;

  final int compactions;

  final int? tokens;

  final int? streamedMillis;

  /// True when a finished step lacks a field the throughput needs.
  final bool incomplete;

  final bool hasAssistant;

  /// Output + reasoning tokens over the provider-active streaming time, the
  /// steps weighted by their active time: aggregate before dividing. `null`
  /// while any finished step lacks a streamed timestamp, or no step streamed.
  double? get tokensPerSecond {
    final tokens = this.tokens;
    final streamedMillis = this.streamedMillis;
    return !incomplete &&
            tokens != null &&
            streamedMillis != null &&
            streamedMillis > 0
        ? tokens / (streamedMillis / 1000)
        : null;
  }
}

/// Folds the Turn's window `[start, end)` into a [_TurnFold].
///
/// When [live] is true the in-flight step (started but not yet completed) is
/// skipped: it is still streaming, so it neither counts toward the throughput
/// nor drops it for its still-missing fields. When [live] is false (the
/// frozen, turn-ended stats) every assistant step is a finished one and any
/// of them lacking a field drops the throughput.
_TurnFold _fold(
  List<SessionMessage> messages,
  int start,
  int end, {
  required bool live,
}) {
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
        if (live && message.completed == null) {
          // The in-flight step: still streaming, not yet a number.
          continue;
        }
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
  return _TurnFold(
    firstPrompt: firstPrompt,
    lastCompleted: lastCompleted,
    compactions: compactions,
    tokens: tokens,
    streamedMillis: streamedMillis,
    incomplete: incomplete,
    hasAssistant: hasAssistant,
  );
}

/// Builds the frozen [TurnStats] from a [_TurnFold]: the duration runs to the
/// last completed step.
TurnStats _statsFrom(_TurnFold fold) {
  final duration = fold.firstPrompt != null && fold.lastCompleted != null
      ? Duration(milliseconds: fold.lastCompleted! - fold.firstPrompt!)
      : null;
  return TurnStats(
    duration: duration,
    compactions: fold.compactions,
    tokensPerSecond: fold.tokensPerSecond,
  );
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
