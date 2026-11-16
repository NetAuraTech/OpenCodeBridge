// The per-row projection of the structured view's history (issue #283):
// what each row of the chat list carries — its role classification, its
// in-flow lines (the neutral "Turn stopped" line of an interrupted turn,
// the in-flight provider retry line, the terminal failure block), its
// turn-stats footer and its live flag, its in-flight flags, and its
// copy-key eligibility.
//
// Computed from the history and the turn facts alone — the same pure seam
// as the per-turn derivations it composes (turn_stats.dart's footer map and
// failure blocks) — so the view's item builder renders the projection and
// classifies nothing: a new in-flow row kind is a derivation change,
// asserted by a flat test, never a new branch in build.

import 'message.dart';
import 'turn_stats.dart';

/// The role classification of one history row: what the row IS.
enum RowKind {
  /// The turn-boundary marker (the `idle` row closing a turn): it carries
  /// no content of its own — unless the Turn it closed carries an in-flow
  /// line (the neutral "Turn stopped" line of an interrupted turn, issue
  /// #206, or the terminal failure block of a failed turn whose error rides
  /// the marker, issue #157).
  idleMarker,

  /// The context-compaction marker (the `compaction` row): its summary
  /// pane, with the compaction's in-flight flag.
  compactionMarker,

  /// A message row: the message pane with the in-flow lines. Every role the
  /// classification does not single out projects here — the user prompt, the
  /// assistant step, a role the service adds later. Adding a new in-flow
  /// row kind is a case added to this derivation, asserted by a flat test.
  messageRow,
}

/// The turn facts a [RowProjection] is derived from: the structured view's
/// panel state, read once per build and passed in — the same way
/// [computeTurnFooters] receives its `active` flag and `now` clock. The
/// stateful half (the timers, the controllers, the subscriptions, the
/// live-message tracking, the turn-Active reconciliation) stays in the
/// view; only these facts cross into the derivation.
class TurnFacts {
  const TurnFacts({
    required this.messages,
    this.turnActive = false,
    this.liveMessageIds = const {},
    this.compacting = false,
    this.compactionIndex,
    this.oldestLoaded = false,
    this.now,
  });

  /// The loaded history, oldest first.
  final List<SessionMessage> messages;

  /// True while the session's turn is running (from
  /// `session.execution.started` to its end event).
  final bool turnActive;

  /// The ids of the messages the live turn is streaming into (the panel's
  /// live-message key set, a live view fact): a row is in-flight when the
  /// turn is Active and its id is in this set.
  final Set<String> liveMessageIds;

  /// True while the session's context compaction streams (from the first
  /// `session.compaction.delta` to its `session.compaction.ended`).
  final bool compacting;

  /// The index in [messages] of the session's compaction marker — the live
  /// marker while the compaction streams, the history's last compaction item
  /// otherwise — or `null` while there is none.
  final int? compactionIndex;

  /// True when the whole history is loaded (no older page remains): gates
  /// the first turn's footer (issue #124, via [computeTurnFooters]).
  final bool oldestLoaded;

  /// The wall-clock (epoch millis) the live footer's duration ticks to
  /// (issue #122); read only while [turnActive] is true.
  final int? now;
}

/// The projection of one row of the structured view's history (issue
/// #283): what the row carries — its role classification, its in-flow
/// lines, its footer, and its live flags. A pure derivation of the row and
/// the turn facts; the view's item builder renders it and contains no role
/// classification of its own, so a new in-flow row kind is a change to this
/// derivation, asserted by a flat test.
class RowProjection {
  const RowProjection({
    required this.message,
    required this.kind,
    this.stopped = false,
    this.retry,
    this.failure,
    this.footer,
    required this.live,
    this.inFlight = false,
    this.compactionInFlight = false,
    this.copyKey,
  });

  /// The row itself (the derivation reads it, the render reads it).
  final SessionMessage message;

  /// The role classification: what the row is ([RowKind]).
  final RowKind kind;

  /// The neutral "Turn stopped" in-flow line of an interrupted turn
  /// (issue #206, matching #164) — set on the idle marker whose closed
  /// turn's `outcome` is `interrupted`. A stop is not a failure, so the
  /// line is distinct from the red failure block.
  final bool stopped;

  /// The in-flight provider retry the row carries (issue #156) — the amber
  /// `Retry due · attempt N · …` line, present only while the row carries a
  /// `retry`, gone (no trace) the moment it clears.
  final MessageRetry? retry;

  /// The terminal failure block that rides this row (issue #157/#206), when
  /// the row carries one: the failed Turn's terminal error on the
  /// error-carrying assistant row (the exhausted-retry case, probe Q3), or
  /// on the closing `idle` marker (the non-retryable case, where no
  /// assistant row exists to carry it).
  final TurnFailure? failure;

  /// The turn-stats footer label that rides this row (issue #121/#124), or
  /// `null` when the row carries no footer.
  final String? footer;

  /// The LIVE footer flag (issue #161's activity indicator rides on it):
  /// true only for the newest turn's row while the turn runs; older rows
  /// keep their frozen footers.
  final bool live;

  /// The in-flight flag of a message row: true while the live turn is
  /// streaming into this row (the turn is Active and the row's id is in the
  /// panel's live-message set).
  final bool inFlight;

  /// The in-flight flag of a compaction marker row: true while the
  /// session's compaction streams into this marker.
  final bool compactionInFlight;

  /// The row's copy key (issue #198), when the row carries content:
  /// `copy-message-<row index>` — `null` for a row without (a textless user
  /// prompt, a compaction marker without a summary; an idle marker never
  /// carries content).
  final String? copyKey;

  @override
  bool operator ==(Object other) =>
      other is RowProjection &&
      other.message == message &&
      other.kind == kind &&
      other.stopped == stopped &&
      other.retry == retry &&
      other.failure == failure &&
      other.footer == footer &&
      other.live == live &&
      other.inFlight == inFlight &&
      other.compactionInFlight == compactionInFlight &&
      other.copyKey == copyKey;

  @override
  int get hashCode => Object.hashAll([
    message,
    kind,
    stopped,
    retry,
    failure,
    footer,
    live,
    inFlight,
    compactionInFlight,
    copyKey,
  ]);

  @override
  String toString() =>
      'RowProjection(kind: $kind, stopped: $stopped, '
      'retry: $retry, failure: $failure, footer: $footer, '
      'live: $live, inFlight: $inFlight, '
      'compactionInFlight: $compactionInFlight, copyKey: $copyKey)';
}

/// The row projections of the structured view's history (issue #283), one
/// per row, in order: the role classification, the in-flow lines, the
/// footer label and its live flag, the in-flight flags, and the copy-key
/// eligibility of every row.
///
/// A pure function of the [facts] — the messages list and the turn facts
/// (whether the turn is Active, the live in-flight message ids, the
/// compaction state, the clock for the live footer) — and it composes the
/// per-turn derivations at its own rank: the footer labels from
/// [computeTurnFooters] (issue #124) and the failure blocks from
/// [turnFailureAt] (issue #206: the row each failed turn's block rides on).
/// The view computes it once per build, and its item builder renders the
/// projections and classifies nothing.
List<RowProjection> computeRowProjections(TurnFacts facts) {
  final messages = facts.messages;
  // The per-turn derivations the projections compose, each walked once (the
  // walk is proportional to the loaded history, never more).
  final footers = computeTurnFooters(
    messages,
    oldestLoaded: facts.oldestLoaded,
    active: facts.turnActive,
    now: facts.now,
  );
  final failures = <int, TurnFailure>{};
  for (var i = 0; i < messages.length; i++) {
    if (messages[i].role != 'idle') continue;
    final row = turnFailureAt(messages, i);
    if (row != null) failures[row.rowIndex] = row.failure;
  }
  return [
    for (var i = 0; i < messages.length; i++)
      _projectRow(i, facts, footers, failures),
  ];
}

/// Projects the single row at [i] in [facts.messages]. [footers] and
/// [failures] are the per-turn derivations the projection composes — the
/// footer label keyed by the row, the failure block keyed by the row it
/// rides on — threaded through by [computeRowProjections] so a whole
/// history is projected in one pass.
RowProjection _projectRow(
  int i,
  TurnFacts facts,
  Map<int, String> footers,
  Map<int, TurnFailure> failures,
) {
  final message = facts.messages[i];
  // The LIVE footer (issue #161's activity indicator rides on it): only the
  // newest turn's row while the Turn runs; older rows keep their frozen
  // footers.
  final live = facts.turnActive && i == facts.messages.length - 1;
  switch (message.role) {
    case 'idle':
      // The turn-boundary marker carries no content of its own — unless the
      // Turn it closed carries an in-flow line:
      //  - a neutral "Turn stopped" line when the turn was interrupted
      //    (issue #206, matching #164) — a stop is not a failure;
      //  - the terminal error block (issue #157) when the failed Turn's
      //    error rides on the marker itself (the non-retryable case, probe
      //    Q3: no assistant row exists to carry it).
      return RowProjection(
        message: message,
        kind: RowKind.idleMarker,
        stopped: message.outcome == 'interrupted',
        failure: failures[i],
        footer: footers[i],
        live: live,
      );
    case 'compaction':
      // The marker's copy button (issue #198): only when it carries a
      // summary.
      return RowProjection(
        message: message,
        kind: RowKind.compactionMarker,
        compactionInFlight: facts.compacting && i == facts.compactionIndex,
        footer: footers[i],
        live: live,
        copyKey: message.text != null ? 'copy-message-$i' : null,
      );
    default:
      // The message rows: the user prompt, the assistant step, and every
      // other role. The in-flow status lines (issue #206) ride the row that
      // carries them — the durable state is the source of truth, so a turn
      // launched or settled by another client shows its lines as soon as
      // the history is read:
      //  - the in-flight provider retry (issue #156): present only while
      //    the row carries a `retry` — gone (no trace) the moment it
      //    clears;
      //  - the terminal error block (issue #157) when the failed Turn's
      //    terminal error rides on this row (the exhausted-retry case,
      //    probe Q3: the assistant's terminal error, content was
      //    attempted).
      // The row's copy button (issue #198): every row carries it when it
      // has content — the body, the reasoning, or a tool card — and never
      // on a row without (a textless user prompt).
      final id = message.id;
      return RowProjection(
        message: message,
        kind: RowKind.messageRow,
        retry: message.retry,
        failure: failures[i],
        inFlight:
            facts.turnActive && id != null && facts.liveMessageIds.contains(id),
        footer: footers[i],
        live: live,
        copyKey:
            message.text != null ||
                message.reasoning != null ||
                message.tools.isNotEmpty
            ? 'copy-message-$i'
            : null,
      );
  }
}
