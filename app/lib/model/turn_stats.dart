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
/// Returns `null` when the window holds no assistant step — a turn with no
/// assistant output yet has no stats to show. A history without `idle`
/// markers (legacy) reads the Turn as starting at its last prompt.
TurnStats? computeTurnStats(List<SessionMessage> messages) {
  // The Turn's window is [boundary + 1, end): `end` past the trailing
  // `idle` markers (the last one closes the Turn), `boundary` at the
  // previous `idle` marker.
  var end = messages.length;
  while (end > 0 && messages[end - 1].role == 'idle') {
    end--;
  }
  int? lastPrompt;
  for (var i = end - 1; i >= 0; i--) {
    final role = messages[i].role;
    if (role == 'idle') {
      // The Turn is the window after the boundary; its fold below starts it
      // at its first prompt (a steer prompt reuses the same Turn, so the
      // earliest prompt in the window drives the duration).
      return _statsFor(messages, i + 1, end);
    }
    if (role == 'user' || role == 'synthetic') lastPrompt ??= i;
  }
  // No idle marker anywhere (legacy history): every prompt was its own Turn
  // without a boundary marker, so the Turn starts at its last prompt.
  return _statsFor(messages, lastPrompt ?? 0, end);
}

/// Folds the Turn's window `[start, end)` into its stats.
TurnStats? _statsFor(List<SessionMessage> messages, int start, int end) {
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
  if (!hasAssistant) return null;

  final duration = firstPrompt != null && lastCompleted != null
      ? Duration(milliseconds: lastCompleted - firstPrompt)
      : null;
  // Aggregate before dividing so the steps are weighted by provider-active
  // time; omit the stat while any step lacks a streamed timestamp.
  final tokensPerSecond =
      !incomplete &&
          tokens != null &&
          streamedMillis != null &&
          streamedMillis > 0
      ? tokens / (streamedMillis / 1000)
      : null;
  return TurnStats(
    duration: duration,
    compactions: compactions,
    tokensPerSecond: tokensPerSecond,
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
