/// The cancelled-turn dedup, one pure per-session classifier (issue #258,
/// the dedup step of the turn-outcome series): a cancel and its follow-on
/// interrupted terminal are one outcome — the cancel announces the turn's
/// end, the service-settled `session.execution.interrupted` for that same
/// turn must be suppressed (issue #164).
///
/// This rule used to live twice, independently, as a private per-session
/// `Set<String> _cancelled` — once in the push dispatcher
/// (`PushDispatcher`), once in the sound mapper (`SessionSoundMapper`) —
/// with near-identical comments and no shared seam. This class is the one
/// home for the rule: a pure, dependency-free state machine the two paths
/// both read, answering the same-turn question — *is this
/// `session.execution.interrupted` terminal the follow-on of a cancel that
/// was already announced?*
///
/// One instance per consumer (the dispatcher keeps one, the mapper keeps
/// one), fed from each consumer's own event stream: the push and sound
/// paths observe the same events in the same order, so the two instances
/// reach the same verdicts. The marker is per session: a cancel on one
/// session never suppresses another's outcomes.
class CancelDedup {
  /// The sessions whose cancel was already announced (its terminal not yet
  /// seen). Cleared when the session's next turn starts.
  final Set<String> _cancelled = {};

  /// `session.turn.cancelled` for [sessionID]: remember the cancel, so the
  /// follow-on interrupted terminal for the same turn is recognized as the
  /// already-announced stop (issue #164).
  void cancelled(String sessionID) => _cancelled.add(sessionID);

  /// `session.execution.started` for [sessionID]: a fresh turn; clear a
  /// stale marker (its terminal missed, e.g. across a restart) so it does
  /// not suppress this turn's later outcomes.
  void started(String sessionID) => _cancelled.remove(sessionID);

  /// `session.execution.interrupted` for [sessionID]: `true` when this
  /// terminal is the follow-on of an already-announced cancel (this
  /// consumes the marker — suppress it); `false` when it is a genuine
  /// interrupt (no cancel preceded it, or the cancel's terminal already
  /// consumed the marker).
  bool isCancelledFollowOn(String sessionID) =>
      _cancelled.remove(sessionID) == true;
}
