import 'dart:io';

import 'afk_session_manager.dart';
import 'afk_settings.dart';
import 'afk_spawn_gate.dart';
import 'afk_store.dart';
import 'repo_identity.dart';
import '../sessions/backend.dart';

/// The bridge's AFK subsystem (spec #407, reshaped from #376, T3): the
/// per-repo arming (the set of armed repo identities), the parallel-orbs
/// cap, the model, the stored AFK session ids, and the per-repo create/reuse
/// of the AFK sessions.
///
/// The app hands the component the current settings at bridge startup and
/// notifies it in-process on change ([updateSettings]) — the bridge runs in
/// the app's process in server mode, so there is no HTTP endpoint for this.
/// The cap is effective from the next orb spawn (enforced at the spawn
/// boundary, which reads [settings].parallelOrbs); the model is effective
/// from the next AFK session creation ([ensureSession] reads it at creation
/// time, so a changed model is picked up without a restart).
///
/// Arming is **per repo identity** (a set of `owner/repo`, spec #407): each
/// armed repo gets its own AFK session in its own checkout — one
/// [AfkSessionManager] per armed repo, keyed by the repo identity in the
/// component's manager map. A disarm (the repo leaves `armedRepos`) holds
/// everything: the session outlives the disarm and the stored id stays (a
/// re-arm reuses it — no duplicate), so a disarmed repo's stored id is read
/// by the spawn gate and the failure-push deep-link like any other.
///
/// The component rides the composite session service through the backend's
/// [SessionsBackend.service] (the seam already faked in the bridge's session
/// tests), and persists the per-repo AFK session ids in the bridge's state
/// area ([AfkStore], the app-owned-file pattern).
///
/// The per-repo [AfkSessionManager]s are the component's state: each is built
/// lazily on the first [ensureSession] for its repo (seeded with that repo's
/// stored id, so a restart reuses the session), and [ensureSession] drives
/// the repo's own manager. The repo's session directory is resolved from the
/// backend at creation time (the project list and the checkouts may not be
/// resolved at bridge startup — arming happens later).
class AfkComponent {
  AfkComponent({
    required SessionsBackend? backend,
    AfkStore? store,
    Future<String> Function(SessionsBackend backend, String repo)? directoryOf,
  }) : store = store ?? AfkStore(),
       _directoryOf = directoryOf ?? _defaultDirectoryOf {
    _backend = backend;
  }

  /// The bridge's sessions backend (the composite service); `null` on a
  /// machine with no shared opencode service, in which case the AFK sessions
  /// cannot be created (there is no host to create them on). Set once at
  /// construction.
  SessionsBackend? _backend;

  /// The per-repo session managers (spec #407, T3): one [AfkSessionManager]
  /// per repo the component has ensured a session for, keyed by the repo
  /// identity (`owner/repo`). Built lazily on the repo's first [ensureSession]
  /// (seeded with the repo's stored id, so a restart reuses the session),
  /// and never evicted — a disarmed repo's manager stays, so a re-arm
  /// re-seeds from the still-stored id (no duplicate).
  final Map<String, AfkSessionManager> _managers = {};

  /// The bridge's persisted AFK state (the per-repo session ids live here).
  final AfkStore store;

  /// Resolves [repo]'s AFK session directory from the backend at creation
  /// time: the first list-order project whose resolved repo identity equals
  /// [repo] (the repo's own checkout — two checkouts of the same repo share
  /// one identity and one session, and the session lands in the first of
  /// them). The default resolution is injected as a provider so the tests
  /// can fake the checkout lookup.
  final Future<String> Function(SessionsBackend backend, String repo)
  _directoryOf;

  /// The live AFK settings (the app's persisted values, handed in at startup
  /// and on change).
  AfkSettings _settings = const AfkSettings();

  /// The current AFK settings. A changed cap is effective from the next
  /// orb spawn (the spawn boundary reads this live); a changed model from
  /// the next session creation.
  AfkSettings get settings => _settings;

  /// Whether [repo] is armed (spec #407, T3: replaces the single `enabled`
  /// flag): reads the live `armedRepos` set, so a change of arming is picked
  /// up without a restart. The consumers ask it per repo (the poller's
  /// per-repo admissions, the run's per-repo new-work gate) — a disarmed
  /// repo is inert for that repo's work only.
  bool isArmed(String repo) => _settings.armedRepos.contains(repo);

  /// The in-process notification the app calls when an AFK setting changes in
  /// Settings: the new values are held live, so the next spawn reads the new
  /// cap, the next session creation reads the new model, and the arming
  /// (which repos are armed) from the next poll (no restart). The bridge
  /// ensures the newly armed repos' sessions from this notification
  /// ([ensureSession] — the arming diff).
  void updateSettings(AfkSettings next) => _settings = next;

  /// The stored AFK session id for [repo] (the bridge's own persisted fact),
  /// or `null` when none is stored under that repo. The legacy flat
  /// `afk.sessionId` is not read (no migration, spec #407).
  String? sessionIdFor(String repo) => store.sessionIdFor(repo);

  /// The spawn-boundary view of the AFK attribution (spec #376, T4; reshaped
  /// by spec #407): the **set** of AFK session ids (every armed repo's stored
  /// session id — a spawn is AFK-attributed when its caller session is any
  /// one of them) and the parallel-orbs cap (the host total), **read live**
  /// — the cap from the current settings (effective from the next spawn, no
  /// restart), the ids fresh from the store (a restart, or a fresh arming,
  /// is picked up). `null` when no repo is armed: there is no AFK session,
  /// so no spawn is AFK-attributed and the cap never applies.
  ///
  /// (The set's counter logic — counting all AFK orbs in flight across repos
  /// against the host cap — is the spawn gate's job, T5; this ticket hands
  /// it the set of the armed repos' stored ids.)
  AfkSpawnGate? spawnGate() {
    if (_settings.armedRepos.isEmpty) return null;
    final ids = _settings.armedRepos
        .map((repo) => store.sessionIdFor(repo))
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return null;
    return AfkSpawnGate(afkSessionIds: ids, cap: _settings.parallelOrbs);
  }

  /// Ensure [repo]'s AFK session exists and return its id (the **arming**
  /// action, spec #407, T3): reuses the session the repo's manager holds —
  /// the id persisted in the store (a restart, or a re-arm after a disarm,
  /// which the session outlived) — when the service still has it; otherwise
  /// creates it in the repo's own checkout (the first list-order project
  /// carrying this repo identity) with the model pinned from the current
  /// global `afkModel` setting (empty = the service's default) and the agent
  /// `afk`, and stores its id under `afk.session.<owner/repo>`. Idempotent:
  /// an already-armed repo returns the same id without a second create (a
  /// re-arm after a disarm reuses it — no duplicate).
  ///
  /// Returns `null` when the backend is not ready (no shared opencode
  /// service), or the repo's checkout cannot be resolved (no list-order
  /// project carrying this repo identity, or its identity does not resolve):
  /// the call is safe to retry once the backend resolves. A disarm never
  /// touches the stored id — the session and its id outlive it.
  Future<String?> ensureSession(String repo) async {
    final backend = _backend;
    if (backend == null) return null;
    final manager =
        _managers[repo] ??
        AfkSessionManager(
          sessions: backend.service,
          directory: () => _directoryOf(backend, repo),
          initialSessionId: store.sessionIdFor(repo),
        );
    _managers[repo] = manager;
    final String id;
    try {
      id = await manager.ensureSession(model: _settings.model);
    } on _NoCheckout {
      // The repo's checkout cannot be resolved yet (no list-order project
      // carries the identity): not ready — the call is safe to retry once the
      // backend resolves. The stored id is untouched (a re-arm, or the next
      // arming, reuses it).
      return null;
    }
    await store.setSessionId(repo, id);
    return id;
  }

  /// The default session-directory resolution (spec #407, T1's directory
  /// resolution scoped to the repo): the **first list-order project** whose
  /// resolved repo identity equals [repo] — two checkouts of the same repo
  /// share one identity and one session, and the session lands in the first
  /// of them (deterministic). A project whose identity does not resolve (no
  /// `origin` remote) is skipped.
  ///
  /// Throws [_NoCheckout] when no list-order project carries the identity:
  /// the repo has nowhere to put its session yet — the caller treats it as
  /// "not ready" (safe to retry).
  static Future<String> _defaultDirectoryOf(
    SessionsBackend backend,
    String repo,
  ) async {
    final projects = await backend.service.projects();
    for (final project in projects) {
      if (project.canonical.isEmpty) continue;
      final identity = await repoIdentityOf(Directory(project.canonical));
      if (identity == repo) return project.canonical;
    }
    throw const _NoCheckout();
  }
}

/// [repo]'s checkout could not be resolved (no project, an empty canonical
/// directory, or no project's resolved repo identity equals [repo]): the AFK
/// session has nowhere to be created yet.
class _NoCheckout implements Exception {
  const _NoCheckout();

  @override
  String toString() =>
      'no checkout (project) found for the AFK repo — the repo identity '
      'could not be resolved from any list-order project';
}
