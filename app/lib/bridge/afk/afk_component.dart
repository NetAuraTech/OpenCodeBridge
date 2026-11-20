import 'afk_session_manager.dart';
import 'afk_settings.dart';
import 'afk_spawn_gate.dart';
import 'afk_store.dart';
import '../sessions/backend.dart';

/// The bridge's AFK subsystem (spec #376, T1): the arming toggle, the
/// parallel-orbs cap, the model, the stored AFK session id, and the
/// create/reuse of the AFK session.
///
/// The app hands the component the current settings at bridge startup and
/// notifies it in-process on change ([updateSettings]) — the bridge runs in
/// the app's process in server mode, so there is no HTTP endpoint for this.
/// The cap is effective from the next orb spawn (enforced at the spawn
/// boundary by a later ticket, which reads [settings].parallelOrbs); the
/// model is effective from the next AFK session creation ([ensureSession]
/// reads it at creation time, so a changed model is picked up without a
/// restart).
///
/// The component rides the composite session service through the backend's
/// [SessionsBackend.service] (the seam already faked in the bridge's session
/// tests), and persists the AFK session id in the bridge's state area
/// ([AfkStore], the app-owned-file pattern).
///
/// The [AfkSessionManager] is the component's state: it is created once the
/// backend exists (seeded with the id persisted in the store at startup, so
/// a restart reuses the session), and it is what [ensureSession] drives. A
/// disarm ([forgetSession]) drops the id from the manager and the store —
/// but not the service — so a re-arm on the same bridge reuses the live
/// session (no duplicate) even though the stored id is gone.
class AfkComponent {
  AfkComponent({
    required SessionsBackend? backend,
    AfkStore? store,
    Future<String> Function(SessionsBackend backend)? directoryOf,
  }) : store = store ?? AfkStore(),
       _directoryOf = directoryOf ?? _defaultDirectoryOf {
    _backend = backend;
    _manager = _buildManager();
  }

  /// The bridge's sessions backend (the composite service); `null` on a
  /// machine with no shared opencode service, in which case the AFK session
  /// cannot be created (there is no host to create it on). Set once at
  /// construction.
  SessionsBackend? _backend;

  /// The component's stateful session manager (the seeded id + create/reuse);
  /// `null` when the backend is absent (no manager to drive).
  AfkSessionManager? _manager;

  /// The bridge's persisted AFK state (the session id lives here).
  final AfkStore store;

  /// Resolves the main checkout's directory — the AFK session's working
  /// directory — from the backend at creation time.
  final Future<String> Function(SessionsBackend backend) _directoryOf;

  /// The live AFK settings (the app's persisted values, handed in at startup
  /// and on change).
  AfkSettings _settings = const AfkSettings();

  /// The current AFK settings. A changed cap is effective from the next
  /// orb spawn (the spawn boundary reads this live); a changed model from
  /// the next session creation.
  AfkSettings get settings => _settings;

  /// The arming toggle. Off is the inert state (no polling, no feed, no
  /// admission); it is restored at launch from the persisted settings.
  bool get enabled => _settings.enabled;

  /// The in-process notification the app calls when an AFK setting changes in
  /// Settings: the new values are held live, so the next spawn reads the new
  /// cap and the next session creation reads the new model (no restart).
  void updateSettings(AfkSettings next) => _settings = next;

  /// The stored AFK session id (the bridge's own persisted fact), or `null`
  /// when the system is not armed (no id persisted).
  String? get sessionId => store.sessionId();

  /// The spawn-boundary view of the AFK attribution (spec #376, T4): the AFK
  /// session id (a spawn is AFK-attributed when its caller session is this
  /// one) and the parallel-orbs cap, **read live** — the cap from the current
  /// settings (effective from the next spawn, no restart), the session id
  /// fresh from the store (a restart, or a fresh arming, is picked up).
  /// `null` when no AFK session id is persisted: there is no AFK session, so
  /// no spawn is AFK-attributed and the cap never applies.
  AfkSpawnGate? spawnGate() {
    final id = store.sessionId();
    if (id == null || id.isEmpty) return null;
    return AfkSpawnGate(afkSessionId: id, cap: _settings.parallelOrbs);
  }

  /// Ensure the AFK session exists and return its id (the **arming** action).
  ///
  /// Reuses the session the manager holds — the id persisted at startup (a
  /// restart) or created earlier this bridge life (a re-arm after a disarm,
  /// which the session outlives) — when the service still has it; otherwise
  /// creates it in the main checkout with the model pinned from the current
  /// `afkModel` setting (empty = the service's default) and the agent `afk`,
  /// and stores its id. Idempotent: an already-armed system returns the same
  /// id without a second create.
  ///
  /// Returns `null` when the backend is not ready (no shared opencode
  /// service) or the main checkout cannot be resolved: the call is safe to
  /// retry once the backend resolves.
  Future<String?> ensureSession() async {
    final manager = _manager;
    if (manager == null) return null;
    final id = await manager.ensureSession(model: _settings.model);
    await store.setSessionId(id);
    return id;
  }

  /// Builds the stateful manager from the backend (seeded with the persisted
  /// id), or `null` when the backend is absent.
  AfkSessionManager? _buildManager() {
    final backend = _backend;
    if (backend == null) return null;
    return AfkSessionManager(
      sessions: backend.service,
      directory: () => _directoryOf(backend),
      initialSessionId: store.sessionId(),
    );
  }

  /// The default main-checkout resolution: the first project's canonical
  /// directory (one bridge serves one repo, so the project list is the repo's
  /// checkout(s)). A missing or empty list answers [_NoMainCheckout], which
  /// the caller treats as "not ready" (safe to retry).
  static Future<String> _defaultDirectoryOf(SessionsBackend backend) async {
    final projects = await backend.service.projects();
    for (final project in projects) {
      if (project.canonical.isNotEmpty) return project.canonical;
    }
    throw const _NoMainCheckout();
  }
}

/// The main checkout could not be resolved (no project, an empty canonical
/// directory, or the service's project list read failed): the AFK session has
/// nowhere to be created yet.
class _NoMainCheckout implements Exception {
  const _NoMainCheckout();

  @override
  String toString() => 'no main checkout (project) to place the AFK session';
}
