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

/// The per-Turn footer labels keyed by the row index the footer rides on
/// (issue #124): a completed Turn's label rides on its closing `idle` marker,
/// the newest Turn's on the history's last row. Older Turns' footers are
/// filled in as their messages page into view — a Turn's footer is shown only
/// once that Turn is fully loaded: the newest Turn always, an older Turn once
/// its opening `idle` marker has loaded (the very first Turn, which has no
/// opening marker, only once [oldestLoaded] reports the whole history is in).
/// [active] is true while the Turn is Active: its footer rides on the last
/// row as the LIVE label read at [now] (epoch millis, issue #122's ticking
/// duration), and the closed Turn the newest `idle` marker ends keeps its own
/// frozen footer. While Active but with [now] left null (no clock to tick
/// against), the newest Turn's label is its frozen stats so far. Returns only
/// the rows that carry a label.
Map<int, String> computeTurnFooters(
  List<SessionMessage> messages, {
  required bool oldestLoaded,
  bool active = false,
  int? now,
}) {
  final result = <int, String>{};
  if (messages.isEmpty) return result;
  final idleAt = <int>[
    for (var i = 0; i < messages.length; i++)
      if (messages[i].role == 'idle') i,
  ];
  // The newest (current) Turn's footer always rides on the last row: the
  // closing `idle` marker when the session is idle, the Turn's last message
  // while it is Active. Only its stats differ by state.
  if (active) {
    // The live label (issue #122/#124) over the live Turn's window: a
    // duration ticking from the Turn's first prompt, a throughput that
    // excludes the still-streaming step. When the loaded history still ends
    // on its `idle` marker (the Turn started but persisted nothing yet) the
    // window is empty and nothing labels the last row.
    if (now != null) {
      final label = liveTurnStats(messages, now: now)?.label;
      if (label != null) result[messages.length - 1] = label;
    } else {
      _addCurrentTurnFooter(result, messages);
    }
  } else {
    _addCurrentTurnFooter(result, messages);
  }
  // Every `idle` marker that does not open the Active Turn closes the Turn
  // before it; its footer rides on the marker, fully loaded once its opening
  // marker (the previous `idle`) is in the window — or, for the first Turn,
  // once the history is fully loaded.
  // When Active, the newest `idle` closes the previous Turn (the Active one
  // is after it); when idle, it closes the current Turn (handled above).
  final lastClosed = active
      ? idleAt.length
      : (idleAt.isEmpty ? 0 : idleAt.length - 1);
  for (var k = lastClosed - 1; k >= 0; k--) {
    if (k == 0 && !oldestLoaded) continue;
    final closer = idleAt[k];
    _addFrozenFooter(
      result,
      messages,
      (k > 0 ? idleAt[k - 1] : -1) + 1,
      closer,
    );
  }
  return result;
}

/// Adds the newest (current) Turn's frozen footer: its window is
/// [turnWindow]'s; a window that holds no assistant step falls back through
/// the earlier Turns exactly like [computeTurnStats] (a queued prompt's
/// empty window keeps the previous Turn's footer, issue #123). The label
/// rides on the window's closing `idle` marker, or the last row when the
/// window has none (a still-running or legacy window).
void _addCurrentTurnFooter(
  Map<int, String> result,
  List<SessionMessage> messages,
) {
  var (start, end) = turnWindow(messages);
  while (true) {
    final fold = _fold(messages, start, end, live: false);
    if (fold.hasAssistant) {
      final row = end == messages.length ? messages.length - 1 : end;
      final label = _statsFrom(fold).label;
      if (label != null && row >= 0 && row < messages.length) {
        result[row] = label;
      }
      return;
    }
    final previous = _previousTurnWindow(messages, start);
    if (previous == null) return;
    (start, end) = previous;
  }
}

/// A closed Turn's frozen footer, riding on its closing `idle` marker row.
void _addFrozenFooter(
  Map<int, String> result,
  List<SessionMessage> messages,
  int start,
  int end,
) {
  if (end < 0 || end >= messages.length) return;
  final fold = _fold(messages, start, end, live: false);
  if (!fold.hasAssistant) return;
  final label = _statsFrom(fold).label;
  if (label != null) result[end] = label;
}

/// Reads the session's current Turn newest-first via [fetchPage], issuing at
/// most the pages needed to cover it (issue #124). A marker-carrying history
/// stops once the Turn's opener `idle` marker is in a page; the newest
/// message's role decides how many markers bound the Turn — an `idle` newest
/// message closes the Turn (so the opener is the next-older idle: two to
/// see), otherwise the first idle seen opens it (one to see). A history no
/// marker was ever seen in (legacy) stops at the Turn's last prompt instead —
/// the window [turnWindow] gives a marker-less loaded history starts at its
/// first prompt, and a deeper Turn is served by the lazy older pages — plus
/// one overshoot page that settles the ambiguity against a just-not-yet-seen
/// opener. A deep legacy history is therefore never read whole just to open
/// the view. Returns the loaded history (oldest-first, possibly one page past
/// the Turn's opener) with the cursor to the next older page (`null` when
/// the history is exhausted).
Future<MessagePage> loadCurrentTurn({
  required Future<MessagePage> Function(String? cursor) fetchPage,
}) async {
  var loaded = const MessagePage(messages: [], nextCursor: null);
  var idlesSeen = 0;
  var prompted = false;
  var promptBound = false;
  int? idlesNeeded;
  String? cursor;
  var first = true;
  while (true) {
    final page = await fetchPage(cursor);
    // This page is older than everything already loaded: it carries the
    // older cursor, and the loaded messages append after it.
    loaded = page.appendNewer(loaded.messages);
    if (first) {
      first = false;
      // The newest loaded message bounds the Turn from above: an `idle`
      // closes it, so its opener is the next-older marker — two to see.
      idlesNeeded = page.messages.isEmpty || page.messages.last.role == 'idle'
          ? 2
          : 1;
    }
    for (final message in page.messages) {
      if (message.role == 'idle') idlesSeen++;
      if (message.role == 'user' || message.role == 'synthetic') {
        prompted = true;
      }
    }
    if (idlesSeen >= (idlesNeeded ?? 1)) break;
    if (promptBound) break; // The legacy overshoot page is in.
    if (idlesSeen == 0 && prompted) {
      // No marker anywhere yet and the Turn's last prompt is in: a legacy
      // history would end here — take one more page to tell that from an
      // opener marker sitting one page older, and stop after it.
      promptBound = true;
    }
    if (loaded.nextCursor == null) break; // History exhausted.
    cursor = loaded.nextCursor;
  }
  return loaded;
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

/// The terminal failure of the Turn closed by the `idle` marker at
/// [idleIndex] (issue #157): `null` when that Turn did not fail. Reads the
/// durable state alone — the marker's `outcome` and `error`, and the turn's
/// assistant rows — so the render is identical with or without an event
/// stream (the probe's Q3: the non-retryable failure carries the error on
/// the `idle` marker with no assistant row; the exhausted-retry failure
/// carries it on the assistant).
class TurnFailure {
  const TurnFailure({required this.error, this.attempts});

  /// The turn's terminal error (the marker's `error`, else the turn's
  /// assistant's terminal `error`), or `null` when the durable state carried
  /// no error for the failure (the block then marks the turn failed with no
  /// provider copy).
  final StructuredError? error;

  /// How many attempts the turn's provider call ran, when the durable state
  /// carries one (the turn's in-flight `retry` count); `null` otherwise. The
  /// block never invents a maximum.
  final int? attempts;
}

/// The [TurnFailure] of the Turn closed by the `idle` marker at
/// [idleIndex], or `null` when the marker is not a failed Turn (a
/// succeeded / interrupted verdict, or a marker that carries no `outcome`).
/// The Turn's window runs from the previous `idle` marker (exclusive) to
/// [idleIndex] (exclusive), so an earlier failed Turn never bleeds into it.
TurnFailure? turnFailureAt(List<SessionMessage> messages, int idleIndex) {
  final marker = messages[idleIndex];
  if (marker.role != 'idle' || marker.outcome != 'failed') return null;
  var start = 0;
  for (var i = idleIndex - 1; i >= 0; i--) {
    if (messages[i].role == 'idle') {
      start = i + 1;
      break;
    }
  }
  // The marker's own error (the non-retryable case) wins; otherwise the
  // turn's assistant row carries it (the exhausted-retry case, probe Q3).
  var error = marker.error;
  var attempts = 0;
  var hasAttempts = false;
  for (var i = idleIndex - 1; i >= start; i--) {
    final message = messages[i];
    if (message.role != 'assistant') continue;
    final retry = message.retry;
    if (retry != null && retry.attempt > 0) {
      hasAttempts = true;
      if (retry.attempt > attempts) attempts = retry.attempt;
    }
    error ??= message.error;
  }
  return TurnFailure(error: error, attempts: hasAttempts ? attempts : null);
}

/// The header outcome chip's verdict (issue #157): the outcome of the
/// NEWEST `idle` marker that closes a Turn — the service's per-turn
/// verdict, authoritative for the chip even when the session-level detail
/// `outcome` still reports the previous Turn's — falling back to
/// [detailOutcome] when the loaded history carries no verdict.
String? latestTurnOutcome(
  List<SessionMessage> messages, {
  String? detailOutcome,
}) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message.role == 'idle') {
      final outcome = message.outcome;
      return outcome ?? detailOutcome;
    }
  }
  return detailOutcome;
}
