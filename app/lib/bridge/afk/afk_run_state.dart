// The AFK run's state set and its per-action predicates (spec #376, "The
// per-issue state machine (bridge-owned)", T3): one module owns the named
// states an issue's run can be in — `idle`, `dispatched`, `pr-open`, `done`,
// and the terminal `failed` — and answers whether an action is admissible
// in a state. Pure logic: no I/O, no network. The run service (T3) and the
// reconciliation (T6) drive the store's rows through these predicates; no
// call site compares the state string ad-hoc.
//
// The [AfkRun.state] string stays the store-facing wire shape: [AfkRunState]
// wraps it, and every predicate answers for the wire string. A string
// outside the named set (a future state, a corrupted value) is `null`-kinded
// and refuses every action — the refusal, never an implicit admission.
//
// The transitions (spec #376's "Transitions"):
//   - `idle → dispatched`: the ready label + a free cap slot (the feed is
//     sent; the cap is enforced at the spawn boundary, a later ticket).
//   - `dispatched → pr-open`: a `PR opened` terminal narration, the bridge
//     confirming the PR is open and recording its number.
//   - `dispatched → dispatched`: a `FAILED` narration with retries remaining
//     (the retry is a self-transition; the counter lives on the store row).
//   - `dispatched → failed`: a `FAILED` narration with retries exhausted
//     (the issue is labelled `needs-triage` with a comment, and a bridge
//     event goes on the hub — the hand-back to the human).
//   - `failed → dispatched`: the deliberate retry (the human re-adds
//     `ready-for-agent`), the retry counter reset.
//   - `pr-open → done`: the issue closes (a PR closed unmerged also lands
//     here, recorded as such — the PR's fate is a human decision, not a
//     system error).
//
// `done` and `failed` are both **terminal**: the system stops acting on the
// run. `failed` is the hand-back to the human — only the deliberate retry
// (a human act) leaves it; `done` is the end.

/// The named states an AFK run can be in (spec #376, "The per-issue state
/// machine").
enum AfkRunStateKind {
  /// Admitted by the Ready gate (state `idle`), not yet fed to the agent.
  idle,

  /// The feed is sent (or a retry is pending): the agent is working the
  /// issue, its terminal narration not yet read.
  dispatched,

  /// The agent's `PR opened` narration landed and the bridge confirmed the
  /// PR is open (its number recorded). The run is at the human-review
  /// boundary.
  prOpen,

  /// The issue closed (or the PR closed unmerged): the run is finished.
  /// Terminal.
  done,

  /// The retries exhausted: the issue is labelled `needs-triage` with a
  /// comment and a bridge event. Terminal for the system — only the
  /// deliberate retry (the human re-adding `ready-for-agent`) re-dispatches
  /// it.
  failed,
}

/// One run's state: the wire string the store's row carries ([AfkRun
/// .state]), parsed on demand.
///
/// [kind] names the state; it is `null` for a string outside the named set —
/// every predicate answers false for it (the refusal, never an implicit
/// admission). Wrap a row's string with [AfkRunState.parse]. Equality is on
/// the wire string alone.
class AfkRunState {
  const AfkRunState(this.wire);

  /// The base states' wire strings, in their exact on-store spelling (spec
  /// #376). The ONE place the state string is produced from: the store's
  /// rows and the run service read these, so a new or renamed state is a
  /// change in this module only.
  static const String idleWire = 'idle';
  static const String dispatchedWire = 'dispatched';
  static const String prOpenWire = 'pr-open';
  static const String doneWire = 'done';
  static const String failedWire = 'failed';

  /// The wire string on the row (the store's `state` field).
  final String wire;

  /// The named state (spec #376), or `null` for a string outside the named
  /// set (a future state, a corrupted value).
  AfkRunStateKind? get kind => AfkRunState.kindOf(wire);

  /// Wraps the row's [wire] state string (a named no-op; the parse is the
  /// accessors, not the wrap).
  static AfkRunState parse(String wire) => AfkRunState(wire);

  /// The [AfkRunStateKind] of an arbitrary wire string: tolerant — anything
  /// that is not one of the named states answers `null`.
  static AfkRunStateKind? kindOf(String wire) {
    return switch (wire) {
      idleWire => AfkRunStateKind.idle,
      dispatchedWire => AfkRunStateKind.dispatched,
      prOpenWire => AfkRunStateKind.prOpen,
      doneWire => AfkRunStateKind.done,
      failedWire => AfkRunStateKind.failed,
      _ => null,
    };
  }

  // ------------------------------------------------------------------------
  // The per-state accessors (each answers on [kind]).

  /// Whether the run is `idle` (admitted, not yet fed).
  bool get isIdle => kind == AfkRunStateKind.idle;

  /// Whether the run is `dispatched` (the agent is working it).
  bool get isDispatched => kind == AfkRunStateKind.dispatched;

  /// Whether the run is `pr-open` (at the human-review boundary).
  bool get isPrOpen => kind == AfkRunStateKind.prOpen;

  /// Whether the run is `done` (the issue closed; terminal).
  bool get isDone => kind == AfkRunStateKind.done;

  /// Whether the run is `failed` (retries exhausted; terminal, the
  /// hand-back to the human).
  bool get isFailed => kind == AfkRunStateKind.failed;

  /// Whether the string is one of the named states (a string outside the set
  /// answers false — the refusal, never an implicit admission).
  bool get isKnown => kind != null;

  // ------------------------------------------------------------------------
  // The per-action predicates (spec #376's "Transitions"): the
  // admissible-state set of each action, owned here. The run service (T3)
  // and the reconciliation (T6) read these directly; no call site compares
  // the state string ad-hoc.

  /// The dispatch (the feed is sent): admissible from `idle` (the Ready
  /// gate's admission) and `failed` (the deliberate retry, the human
  /// re-adding `ready-for-agent` — the retry counter resets). Refused from
  /// `dispatched` (a run in flight is not re-fed), `pr-open` (a run at the
  /// review boundary is never retried), and `done`.
  bool get canDispatch => isIdle || isFailed;

  /// The `PR opened` narration (the bridge confirms the PR is open and
  /// records its number): admissible from `dispatched` only. A `PR opened`
  /// narration read in any other state is a no-op (the run is not in a
  /// position to open a PR — e.g. an already-`pr-open` run is left alone).
  bool get canOpenPr => isDispatched;

  /// The `FAILED` narration with retries remaining (the retry is a
  /// self-transition back to `dispatched`; the counter increments on the
  /// store row): admissible from `dispatched` only.
  bool get canRetry => isDispatched;

  /// The `FAILED` narration with retries exhausted (the terminal failure,
  /// the issue labelled `needs-triage` and the bridge event emitted):
  /// admissible from `dispatched` only. Whether retries remain is the store
  /// row's fact (the retry count), decided by the caller; this predicate
  /// answers only for the state.
  bool get canFail => isDispatched;

  /// The completion (the issue closed, or the PR closed unmerged — recorded
  /// as such): admissible from `pr-open` only.
  bool get canComplete => isPrOpen;

  /// Whether the run is terminal (the system stops acting on it): `done`
  /// (the end) and `failed` (the hand-back to the human — only the
  /// deliberate retry, a human act, leaves it).
  bool get isTerminal => isDone || isFailed;

  @override
  bool operator ==(Object other) => other is AfkRunState && other.wire == wire;

  @override
  int get hashCode => Object.hash(AfkRunState, wire);

  @override
  String toString() => 'AfkRunState($wire)';
}
