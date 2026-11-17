// The Active decision of the structured view's turn (issue #284): is the
// turn running? The one boolean that arms the live footer's ticking clock,
// the retry-state poll, and the live flag — and what it means for the footer
// the view renders.
//
// It is a PURE derivation of (the session's detail, the loaded history),
// next to the turn-window semantics it builds on (turn_stats.dart's `idle`
// markers, the `role` / `completed` shapes). The structured view used to
// hold it as imperative state — a reconcile method re-reading the same
// shapes by hand (two of its own history walks) — so the rule could only be
// exercised through whole-panel widget tests with
// scripted event sequences. This module holds the rule on its own, pinned
// by a flat table of (detail, history) → (active, tick, poll, live) cases;
// the view keeps only the timer arming/cancelling.
//
// The detail's `active` fact is the service's authoritative word on whether
// the session is running — the service's active list — and the history is
// the durable state it persisted. The two agree when the turn is unambiguous
// (the turn is visibly in-flight, or visibly closed); where the history
// alone is ambiguous — a prompt after the newest `idle` marker could be a
// queued prompt (issue #129) or the just-started turn — the detail settles
// it.

import 'message.dart';
import 'session_detail.dart';

/// The Active decision of a turn, derived from (the session's detail, the
/// loaded history): [active] is whether the turn is running (the service's
/// `active` list, reconciled against the durable history), and [tick] /
/// [poll] / [live] are the view's timers and flags it arms from it — the
/// live footer's ticking clock (issue #122), the retry-state poll (issue
/// #156), and the live footer's flag (issue #161's activity indicator).
///
/// While [active], [tick] and [poll] and [live] are all true together;
/// while settled, all false. They are separate fields (not one) because the
/// view's timers are independent of its flag — the footer's live flag rides
/// on [live], the ticking clock on [tick], the retry poll on [poll] — and a
/// later change may split them.
typedef TurnActiveFlags = ({bool active, bool tick, bool poll, bool live});

/// The Active decision of a turn, as a pure function of (the session's
/// [detail], the loaded [history]).
///
/// - [detail.active] is the service's authoritative Active fact (its active
///   list): true, the turn is running — regardless of the history (which may
///   not have caught up, or may still end on the previous turn's closing
///   `idle` marker).
/// - Else, the history decides by its newest non-compaction row: an
///   incomplete (streaming) assistant step means the turn is in-flight; a
///   prompt means the turn is running only when a step already precedes it
///   in the window (a steer delivered into the running execution, issue
///   #123); a lone prompt after the newest `idle` marker is the
///   queued-vs-just-started ambiguity (issue #129) — the shape cannot tell,
///   so it stays settled (the detail said so); an `idle` marker means the
///   turn closed.
bool turnActive(SessionDetail detail, List<SessionMessage> history) {
  if (detail.active) return true;
  for (var i = history.length - 1; i >= 0; i--) {
    final message = history[i];
    switch (message.role) {
      case 'assistant':
        return message.completed == null;
      case 'user':
      case 'synthetic':
        for (var j = i - 1; j >= 0; j--) {
          switch (history[j].role) {
            case 'assistant':
              return true; // A steer: the turn's steps precede it.
            case 'idle':
              return false; // A lone prompt: queued or just started (#129).
            default:
              continue;
          }
        }
        return false;
      case 'idle':
        return false; // The newest marker closed the turn.
      default:
        continue; // `compaction` carries no signal.
    }
  }
  return false;
}

/// The Active decision of a turn, as a pure function of the PREVIOUS
/// decision, the freshly-read [detail], and the freshly-read [history] — the
/// one stateful reconciliation the view runs (on the initial load and on
/// every turn-boundary / gap normalize, when an authoritative read lands).
///
/// [turnActive] is stateless: it reads only the two inputs. But the
/// reconciliation is not a plain re-derivation — it has a ratchet, and the
/// ratchet is what the view was doing imperatively before:
///
/// - While the turn was ACTIVE, only the authoritative history closes it:
///   the read must end on the turn's closing `idle` marker AND the service
///   must no longer list it Active. A normalize that races just after the
///   turn started may still see the OLD closing marker, so the stale
///   detail's `active: true` keeps it armed — the footer can never tick on
///   a finished turn, and can never drop out on a turn that is running.
/// - While SETTLED, it activates on the stateless rule: the detail's Active
///   fact (the service's active list) or a mid-turn history.
///
/// The ratchet makes it idempotent: once a state settles, it stays settled
/// for the same inputs (no flapping across a repeated read).
TurnActiveFlags settleActive(
  TurnActiveFlags previous,
  SessionDetail detail,
  List<SessionMessage> history,
) {
  var active = previous.active;
  if (active) {
    // The history ends closed AND the service no longer lists the session
    // Active: only then does the re-read deactivate.
    if (historyEndsOnIdle(history) && !detail.active) active = false;
  } else {
    if (turnActive(detail, history)) active = true;
  }
  return (active: active, tick: active, poll: active, live: active);
}

/// Whether the loaded [history] ends on the `idle` marker that closed the
/// turn (skipping any trailing compaction markers that ride past it).
bool historyEndsOnIdle(List<SessionMessage> history) {
  for (var i = history.length - 1; i >= 0; i--) {
    if (history[i].role == 'compaction') continue;
    return history[i].role == 'idle';
  }
  return false;
}
