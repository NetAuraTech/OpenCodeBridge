// The orb lifecycle's state set and its per-action predicates (issue #279,
// spec §2.1/§2.2/§2.7/§2.10/§9.4): one module owns the named states an orb
// can be in — `running`, `stopped`, `preparing`, `broken:workspace`,
// `broken:state`, `broken:shell`, `orphan`, and `cleanup_pending:<reason>` —
// answers whether an action is admissible in a state, and hides the
// host-side marker files the states are composed from.
//
// The [OrbRecord.state] string stays the app-facing wire shape: [OrbState]
// wraps it (and [OrbState.compose] reproduces it), and every predicate
// answers for the composed string. No call site reads this module yet — the
// actions still carry their own comparisons; the contract phases (#280,
// #281) switch the call sites over and delete the ad-hoc comparisons.
//
// The marker files ([OrbMarkerStore]) live in the per-orb state dir
// (`<stateRoot>/<id>/`), written by the bridge (the stop's `stopped` gate,
// the lifecycle pass's `cleanup-pending` badge), by the orb's post-commit
// hook (`push-failed`, #120), by the entrypoint's shell probe (`no-shell`,
// #149), and by the bridge's gh staging (`gh-auth-failed`, #145). Reads are
// host-side only — the list is the composite services' hot path and never
// probes a container (spec §2.2/§2.9).

import 'dart:io';

/// The named states an orb can be in (spec §2.1/§2.2). One per base, the
/// sub-state detail (the preparing stage word, the cleanup-pending reason)
/// carried on the wire string, not as a kind of its own.
enum OrbStateKind {
  /// The container is up and its service is answering (`running`).
  running,

  /// A clean, marked stop: sessions moved to the host, the `stopped`
  /// marker set (spec §2.5).
  stopped,

  /// A stopped orb the automated lifecycle pass surfaced as a guard-blocked
  /// auto-delete candidate (issue #101, spec §2.10.2): the same container
  /// state carrying the pass's reason on the `cleanup-pending` marker.
  cleanupPending,

  /// A container whose boot has not completed (docker status `created`, or
  /// `running` before its password line), the entrypoint's current stage as
  /// the sub-state (issue #96, spec §9.3).
  preparing,

  /// The workspace volume is missing: the orb's code is gone (spec §2.2).
  brokenWorkspace,

  /// The state dir is missing (the workspace volume is present): fresh-state
  /// startable — the in-orb sessions are the lost part (spec §2.2/§9.4).
  brokenState,

  /// The boot died at the shell probe (issue #149, spec §6.8): the volumes
  /// and state dir are intact, but the agent cannot run a command. The
  /// boot's fatal line rides on the record's `bootReason`, not here.
  brokenShell,

  /// Labeled volumes without a container: surfaced for explicit cleanup,
  /// never auto-deleted (spec §2.2).
  orphan,
}

/// One orb's state: the composed wire string the app-facing record carries
/// ([OrbRecord.state]), parsed on demand.
///
/// [kind] names the base state (spec §2.1/§2.2); [detail] carries the
/// sub-state (the preparing stage word, the cleanup-pending reason — `null`
/// for the base states). [kind] is `null` for a string outside the named
/// set (a future sub-state, a corrupted value): every predicate answers
/// false for it — the refusal, never an implicit admission.
///
/// Wrap a record's string with [OrbState.parse]; rebuild it from the raw
/// facts with [OrbState.compose]. Equality is on the wire string alone.
class OrbState {
  const OrbState(this.wire);

  /// The wire string on the record (`state` of [OrbRecord]): the base name
  /// for the base states, `<base>:<detail>` for preparing and
  /// cleanup-pending.
  final String wire;

  /// The named state (spec §2.1/§2.2), or `null` for a string outside the
  /// named set.
  OrbStateKind? get kind => OrbState.kindOf(wire);

  /// The sub-state detail (the preparing stage word, the cleanup-pending
  /// reason); `null` for the base states.
  String? get detail => OrbState.detailOf(wire);

  /// Wraps the record's [wire] state string (a named no-op; the parse is
  /// the accessors, not the wrap).
  static OrbState parse(String wire) => OrbState(wire);

  /// The base name of [wire]: the part before any `:` (`running`,
  /// `stopped`, `preparing`, `cleanup_pending`, `broken`, `orphan`). A
  /// tolerant read of an arbitrary string — an unknown base is returned
  /// as-is.
  static String base(String wire) {
    final cut = wire.indexOf(':');
    return cut < 0 ? wire : wire.substring(0, cut);
  }

  /// The sub-state detail of [wire]: the part after the first `:`
  /// (`null` when there is none, or it is empty).
  static String? detailOf(String wire) {
    final cut = wire.indexOf(':');
    if (cut < 0 || cut >= wire.length - 1) return null;
    return wire.substring(cut + 1);
  }

  /// The [OrbStateKind] of an arbitrary wire string: tolerant — anything
  /// that is not one of the named states (an empty `preparing:`, an unknown
  /// base, a future sub-state) answers `null`.
  static OrbStateKind? kindOf(String wire) {
    final baseName = base(wire);
    final detail = detailOf(wire);
    return switch (baseName) {
      'running' => OrbStateKind.running,
      'stopped' => OrbStateKind.stopped,
      'preparing' => OrbStateKind.preparing,
      'cleanup_pending' => OrbStateKind.cleanupPending,
      'orphan' => OrbStateKind.orphan,
      'broken' => switch (detail) {
          'workspace' => OrbStateKind.brokenWorkspace,
          'state' => OrbStateKind.brokenState,
          'shell' => OrbStateKind.brokenShell,
          _ => null,
        },
      _ => null,
    };
  }

  // ------------------------------------------------------------------------
  // The base-state accessors (each answers on [kind]).

  /// Whether the orb is `running`.
  bool get isRunning => kind == OrbStateKind.running;

  /// Whether the orb is plainly `stopped` (the `cleanup_pending:<reason>`
  /// variant has its own kind — see [isStoppedLike]).
  bool get isStopped => kind == OrbStateKind.stopped;

  /// Whether the orb is a stopped one under the lifecycle pass's badge:
  /// plain `stopped` or `cleanup_pending:<reason>` — the same container
  /// state, the marker composing the surfaced variant (issue #101, spec
  /// §2.10.2). The Wake/Update/Force-delete actions treat the two alike.
  bool get isStoppedLike =>
      kind == OrbStateKind.stopped || kind == OrbStateKind.cleanupPending;

  /// Whether the orb is still booting (`preparing` / `preparing:<stage>`).
  bool get isPreparing => kind == OrbStateKind.preparing;

  /// Whether the orb is broken in any of its three parts (missing workspace
  /// volume, missing state dir, or a shell-less boot).
  bool get isBroken =>
      kind == OrbStateKind.brokenWorkspace ||
      kind == OrbStateKind.brokenState ||
      kind == OrbStateKind.brokenShell;

  /// Whether the orb is broken at the state dir (workspace present): the
  /// fresh-state start is the exit, never a silent repair (spec §9.4).
  bool get isBrokenState => kind == OrbStateKind.brokenState;

  /// Whether the orb is a shell-less boot (issue #149, spec §6.8): the
  /// agent cannot run a command, so no code task can land.
  bool get isBrokenShell => kind == OrbStateKind.brokenShell;

  /// Whether the orb is an orphan (labeled volumes, no container).
  bool get isOrphan => kind == OrbStateKind.orphan;

  /// Whether the string is one of the named states (a string outside the set
  /// answers false — the refusal, never an implicit admission).
  bool get isKnown => kind != null;

  // ------------------------------------------------------------------------
  // The per-action predicates (spec §2.4/§2.5/§2.7/§2.8/§9.4/§9.5): the
  // admissible-state set of each action, owned here. Each call site today
  // re-encodes one of these with raw string comparisons (issue #279's
  // contract phases #280/#281 replace them with these calls).

  /// The stop (spec §2.5) is a lossless move to the host — only a `running`
  /// orb stops; a re-issue in any other state is a safe no-op (the caller
  /// returns early, it does not refuse).
  bool get isStopable => isRunning;

  /// The wake (spec §2.4) re-runs the full start path over the same
  /// container and volumes: only a stopped orb wakes — plain `stopped` or
  /// `cleanup_pending:<reason>` (the badge is the same container state). A
  /// re-issue while `running` is a safe no-op, decided by the caller.
  bool get isWakeable => isStoppedLike;

  /// The update (spec §2.8) recreates the container on the current image:
  /// only a `running` or a stopped orb updates — `preparing` (a boot in
  /// flight) and the broken states refuse (a missing state dir is decided by
  /// the action, not the state).
  bool get isUpdatable => isRunning || isStoppedLike;

  /// The fresh-state start (spec §9.4): only a `broken:state` orb (workspace
  /// volume present, state dir missing) — anything else refuses, never a
  /// silent repair.
  bool get isFreshStateStartable => isBrokenState;

  /// The spawn's wake-or-use (spec §8.2): a `running` orb is used as-is, a
  /// stopped orb is woken, anything else refuses. (A shell-less broken orb
  /// is refused on its own by the spawn before the wake — issue #149 — so it
  /// is not admissible here.)
  bool get isSpawable => isRunning || isStoppedLike;

  /// The protected/forced deletion (spec §2.7): the card carries Force delete
  /// on a running, a stopped (incl. cleanup-pending), or a broken orb — and
  /// refuses it for an orphan (its exit is the explicit Clean up) and for a
  /// preparing one (no actions yet). Absence of the record is a record-level
  /// fact, not a state, so it is not decided here.
  bool get isForceDeletable => isRunning || isStoppedLike || isBroken;

  // ------------------------------------------------------------------------
  // The composition: raw facts (docker status plus markers) → the wire
  // string.

  /// Maps the raw facts the list composes a state from to the named state's
  /// wire string (spec §2.2).
  ///
  /// - [dockerStatus]: the container's `docker inspect` `State.Status`
  ///   (`running`, `created`, `exited`, …), or `null` for the orphan
  ///   (labeled volumes without a container — spec §2.2).
  /// - [workspaceVolumePresent]: the labeled workspace volume exists
  ///   (`orb-<id>-workspace` in the volume list).
  /// - [stateDirPresent]: the per-orb state dir exists on the host
  ///   (`<stateRoot>/<id>`).
  /// - [bootStage]: the entrypoint's last `[orb] stage: <word>` word of the
  ///   container log (spec §9.3); read only for a `created`/`running`
  ///   container (the preparing derivation) — `null` otherwise.
  /// - [bootPasswordSeen]: whether the running container's log already
  ///   carries a `server password` line (the boot's completion); `null` for
  ///   a `created` container (no log to read yet).
  /// - [shellFailedReason]: the `no-shell` marker's cause (issue #149, spec
  ///   §6.8), or `null` when the last boot passed the probe.
  /// - [cleanupReason]: the `cleanup-pending` marker's reason (issue #101,
  ///   spec §2.10.2), or `null` when the pass has not (or no longer)
  ///   surfaced the orb.
  ///
  /// The precedence mirrors the list: a container that is booting
  /// (`created`, or `running` before its password line) is `preparing` with
  /// no further checks; a finished boot is `running` with no further checks;
  /// a stopped container (any other status) runs the broken checks (a
  /// missing volume/dir is the louder signal), then the shell badge, then
  /// the cleanup-pending badge, then the plain stop.
  ///
  /// The `stopped` marker is deliberately not a fact: it distinguishes a
  /// clean stop from a crash, and it is read by the wake/recover paths
  /// ([OrbMarkerStore.stopped]) — the list composes no different state from
  /// it (a marked stop and an unmarked stop are both `stopped`).
  static OrbState compose({
    required String? dockerStatus,
    required bool workspaceVolumePresent,
    required bool stateDirPresent,
    String? bootStage,
    bool? bootPasswordSeen,
    String? shellFailedReason,
    String? cleanupReason,
  }) {
    if (dockerStatus == null) return OrbState('orphan');
    // Booting: a `created` container (no log yet) or a `running` one whose
    // log does not carry this boot's password line (spec §9.3). No broken,
    // shell, or cleanup check runs on a booting container.
    if (dockerStatus == 'created' ||
        (dockerStatus == 'running' && bootPasswordSeen != true)) {
      final stage = bootStage;
      return OrbState(
        stage == null || stage.isEmpty ? 'preparing' : 'preparing:$stage',
      );
    }
    if (dockerStatus == 'running') return OrbState('running');
    // Stopped (any exited/dead/other status): the broken checks first, then
    // the shell badge (issue #149), then the lifecycle pass's badge
    // (issue #101), then the plain stop.
    if (!workspaceVolumePresent) return OrbState('broken:workspace');
    if (!stateDirPresent) return OrbState('broken:state');
    if (shellFailedReason != null) return OrbState('broken:shell');
    final reason = cleanupReason;
    if (reason != null && reason.isNotEmpty) {
      return OrbState('cleanup_pending:$reason');
    }
    return OrbState('stopped');
  }

  @override
  bool operator ==(Object other) =>
      other is OrbState && other.wire == wire;

  @override
  int get hashCode => Object.hash(OrbState, wire);

  @override
  String toString() => 'OrbState($wire)';
}

// --------------------------------------------------------------------------
// The marker-file seam (issue #279: the marker files behind the module's
// seam).

/// The host-side marker files of one orb's state dir — the facts
/// [OrbState.compose] reads and the actions write. The files live in
/// `<stateRoot>/<id>/` (spec §2.7): written by the bridge (the `stopped`
/// gate of the stop, the `cleanup-pending` badge of the lifecycle pass), by
/// the orb's post-commit hook (`push-failed`, issue #120), by the
/// entrypoint's shell probe (`no-shell`, issue #149), and by the bridge's
/// gh staging (`gh-auth-failed`, issue #145).
///
/// Reads are tolerant by construction: a missing or unreadable marker
/// answers `null` — a no-verdict beats a wrong one, and the next list reads
/// it again.
abstract class OrbMarkerStore {
  /// The per-orb state dirs' root (`<stateRoot>/`, spec §2.7).
  Directory get stateRoot;

  /// The state dir of [id] (`<stateRoot>/<id>/`).
  Directory stateDir(String id);

  // -- The stop's gate (spec §2.4/§2.5): set at the end of a successful
  // stop, removed at the end of a successful wake. The wake/recover paths
  // read it to tell a clean stop from a crash (spec §2.11).

  /// Whether the stop marker is present (a clean, marked stop).
  bool stopped(String id);

  /// Set the stop marker (the stop's last step, the wake's gate).
  Future<void> setStopped(String id);

  /// Remove the stop marker (the wake's last step, after a successful
  /// start).
  Future<void> clearStopped(String id);

  // -- The lifecycle pass's badge (issue #101, spec §2.10.2): written when
  // a stopped auto-delete candidate is guard-blocked, carrying the reason
  // the card surfaces; re-evaluated on every pass and cleared by the wake.

  /// The cleanup-pending reason, or `null` when the badge is absent (or the
  /// marker holds no reason — an empty badge is no badge).
  String? cleanupPendingReason(String id);

  /// Surface [id] as cleanup-pending with the guard's [reason] (the
  /// lifecycle pass only — the badge is the automated path's surfacing of a
  /// guard-blocked candidate, never a manual state).
  Future<void> markCleanupPending(String id, String reason);

  /// Clear the cleanup-pending badge (the pass, once the orb is no longer a
  /// guard-blocked candidate, and the wake).
  Future<void> clearCleanupPending(String id);

  // -- The push-failure marker (issue #120, spec §3.1): written by the
  // orb's post-commit hook when its push to the remote fails; a passing
  // push clears it, as does a start that re-staged the gh credentials.

  /// Whether the push-failed marker is present (the post-commit push to the
  /// remote is failing — the return channel silently rides on that push).
  bool pushFailed(String id);

  /// The push-failed marker's last-modified time (its "generation", issue
  /// #167: the mid-run gh re-stage throttles per generation — at most one
  /// re-stage + probe per backoff while the marker persists). `null` when
  /// the marker is absent.
  DateTime? pushFailedGeneration(String id);

  /// Clear the push-failed marker (a passing push, or a start that
  /// re-staged the gh credentials — the verdict is no longer known, the
  /// next push proves it).
  Future<void> clearPushFailed(String id);

  // -- The shell-probe marker (issue #149, spec §6.8): written by the
  // entrypoint when its shell probe fails (the agent cannot run a
  // command); cleared by the next passing boot.

  /// The no-shell marker's cause, or `null` when the last boot passed the
  /// probe (or the marker is absent).
  String? shellFailedReason(String id);

  // -- The gh-auth marker (issue #145, spec §4): written by the bridge's gh
  // staging when it cannot stage usable gh credentials for a start; cleared
  // by the next passing stage.

  /// The gh-auth-failed cause, or `null` when the last stage passed (or the
  /// marker is absent).
  String? ghAuthFailedReason(String id);

  /// Record that the gh staging of [id] failed with [reason] (the marker
  /// describes the credentials, not the boot — written even when the boot
  /// then fails).
  Future<void> markGhAuthFailed(String id, String reason);

  /// Clear the gh-auth-failed marker after a successful stage (issue #145:
  /// a marker describes the start that wrote it).
  Future<void> clearGhAuthFailed(String id);
}

/// The marker store over the real host filesystem (the per-orb state dirs
/// under [stateRoot]).
class FileOrbMarkerStore implements OrbMarkerStore {
  const FileOrbMarkerStore(this.stateRoot);

  @override
  final Directory stateRoot;

  @override
  Directory stateDir(String id) => Directory('${stateRoot.path}/$id');

  File _marker(String id, String name) => File('${stateRoot.path}/$id/$name');

  // -- The stop's gate.

  @override
  bool stopped(String id) => _marker(id, 'stopped').existsSync();

  @override
  Future<void> setStopped(String id) async {
    final marker = _marker(id, 'stopped');
    await marker.parent.create(recursive: true);
    await marker.writeAsString(DateTime.now().toUtc().toIso8601String());
  }

  @override
  Future<void> clearStopped(String id) async {
    final marker = _marker(id, 'stopped');
    if (marker.existsSync()) {
      await marker.delete();
    }
  }

  // -- The cleanup-pending badge.

  @override
  String? cleanupPendingReason(String id) {
    final marker = _marker(id, 'cleanup-pending');
    if (!marker.existsSync()) return null;
    try {
      final reason = marker.readAsStringSync().trim();
      return reason.isEmpty ? null : reason;
    } on FileSystemException {
      // Unreadable for a moment (the pass rewriting it): no verdict beats a
      // wrong one, and the next list reads it again.
      return null;
    }
  }

  @override
  Future<void> markCleanupPending(String id, String reason) async {
    final marker = _marker(id, 'cleanup-pending');
    await marker.parent.create(recursive: true);
    await marker.writeAsString(reason);
  }

  @override
  Future<void> clearCleanupPending(String id) async {
    final marker = _marker(id, 'cleanup-pending');
    if (marker.existsSync()) {
      await marker.delete();
    }
  }

  // -- The push-failed marker.

  @override
  bool pushFailed(String id) => _marker(id, 'push-failed').existsSync();

  @override
  DateTime? pushFailedGeneration(String id) {
    final marker = _marker(id, 'push-failed');
    if (!marker.existsSync()) return null;
    try {
      return marker.lastModifiedSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> clearPushFailed(String id) async {
    final marker = _marker(id, 'push-failed');
    if (marker.existsSync()) {
      await marker.delete();
    }
  }

  // -- The no-shell marker.

  @override
  String? shellFailedReason(String id) {
    final file = _marker(id, 'no-shell');
    if (!file.existsSync()) return null;
    try {
      final reason = file.readAsStringSync().trim();
      return reason.isEmpty ? 'no usable shell' : reason;
    } on FileSystemException {
      // Unreadable for a moment (a boot rewriting it): no verdict beats a
      // wrong one, and the next list reads it again.
      return null;
    }
  }

  // -- The gh-auth marker.

  @override
  String? ghAuthFailedReason(String id) {
    final file = _marker(id, 'gh-auth-failed');
    if (!file.existsSync()) return null;
    try {
      final reason = file.readAsStringSync().trim();
      return reason.isEmpty ? 'gh could not authenticate' : reason;
    } on FileSystemException {
      // Unreadable for a moment (a boot rewriting it): no verdict beats a
      // wrong one, and the next list reads it again.
      return null;
    }
  }

  @override
  Future<void> markGhAuthFailed(String id, String reason) async {
    final marker = _marker(id, 'gh-auth-failed');
    try {
      await marker.parent.create(recursive: true);
      await marker.writeAsString(reason);
    } on FileSystemException {
      // No writable state dir: the create's own failures surface first.
    }
  }

  @override
  Future<void> clearGhAuthFailed(String id) async {
    final marker = _marker(id, 'gh-auth-failed');
    try {
      if (marker.existsSync()) {
        await marker.delete();
      }
    } on FileSystemException {
      // A lingering marker only over-surfaces, never hides.
    }
  }
}
