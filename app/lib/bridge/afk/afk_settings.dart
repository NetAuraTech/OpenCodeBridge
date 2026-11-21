import '../../model/command.dart';

/// The AFK agent's settings as the bridge holds them (spec #407, reshaped
/// from #376, "Settings").
///
/// These are the values the "AFK agent" section of Settings persists (in the
/// app's persisted settings, under the `afk.` namespace) and hands to the
/// in-process bridge: the **per-repo arming** ([armedRepos], a set of
/// `owner/repo` identities — a project is armed from its own row in a later
/// ticket, and an empty set is the inert state: no polling, no feed, no
/// admission), the parallel-orbs cap (1–10, default 5), and the model (free
/// text `provider/model[#variant]`, empty = no pin = the service's default).
/// The bridge is handed the values at startup and notified in-process on
/// change: a changed cap is effective from the next orb spawn, a changed model
/// from the next AFK session creation.
///
/// The arming is a *set* of repo identities, not a single toggle: two
/// checkouts of the same repo share one identity and thus one armed state.
/// [armedRepos] is an [LinkedHashSet] (const-constructible) that preserves
/// the persisted order, so the consumers that iterate it (the spawn gate's
/// session-id set, the arming diff, [firstArmedRepo]) see a deterministic
/// order (the persisted order, first list-order first).
class AfkSettings {
  const AfkSettings({
    this.armedRepos = const {},
    this.parallelOrbs = defaultParallelOrbs,
    this.model = defaultModel,
  });

  /// The cap's lower bound (the Settings field's minimum).
  static const int minParallelOrbs = 1;

  /// The cap's upper bound (the Settings field's maximum).
  static const int maxParallelOrbs = 10;

  /// The cap's default on a fresh install.
  static const int defaultParallelOrbs = 5;

  /// The model's default: empty — no pin, the service's default is used.
  static const String defaultModel = '';

  /// The armed repo identities (`owner/repo`), in persisted order. Empty is
  /// the inert state — no armed repo means no AFK work at all.
  final Set<String> armedRepos;

  /// The first armed repo in list order, or `null` when none is armed (spec
  /// #407). The **transitional single anchor**: the per-project poller
  /// (T2) and the run service's liveness (T4) still read the arming through
  /// this one repo until they are reshaped per repo — the session layer
  /// (T3: the session port, the spawn gate, the failure-push deep-link) is
  /// already per repo. Deterministic (first list-order armed repo).
  String? get firstArmedRepo => armedRepos.isEmpty ? null : armedRepos.first;

  /// How many AFK orbs may run in parallel (1–10). Effective from the next
  /// orb spawn (enforced at the spawn boundary by a later ticket).
  final int parallelOrbs;

  /// The model the AFK session is created with, as `provider/model[#variant]`.
  /// Empty = no pin = the opencode config's default.
  final String model;

  /// Returns a copy with the given fields replaced. A field left `null` keeps
  /// its value; [armedRepos] is replaced wholesale (pass an empty set to
  /// clear it) — a set has no natural "unset" marker, so it is always an
  /// explicit replacement.
  AfkSettings copyWith({
    Set<String>? armedRepos,
    int? parallelOrbs,
    String? model,
  }) => AfkSettings(
    armedRepos: armedRepos ?? this.armedRepos,
    parallelOrbs: parallelOrbs ?? this.parallelOrbs,
    model: model ?? this.model,
  );

  @override
  bool operator ==(Object other) =>
      other is AfkSettings &&
      _sameOrder(other.armedRepos, armedRepos) &&
      other.parallelOrbs == parallelOrbs &&
      other.model == model;

  static bool _sameOrder(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    final ai = a.iterator;
    final bi = b.iterator;
    while (ai.moveNext()) {
      if (!bi.moveNext() || ai.current != bi.current) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(armedRepos.join('\u0000'), parallelOrbs, model);

  @override
  String toString() =>
      'AfkSettings(armedRepos: $armedRepos, parallelOrbs: $parallelOrbs, '
      'model: $model)';
}

/// Parses the AFK model's free text into a [ModelRef].
///
/// The input is `provider/model` with an optional `#variant`, e.g.
/// `zhipu/glm-4.7` or `anthropic/claude-sonnet#high`. An empty (or all-
/// whitespace) value answers `null` — no pin, the session inherits the
/// service's default model (spec: "empty = no model pinned"). A value that
/// does not carry a `provider/model` split (no `/`, or an empty provider or
/// model side) also answers `null`, so a malformed pin degrades to inherit
/// rather than failing the session creation.
ModelRef? parseAfkModel(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  var body = text;
  String? variant;
  final hash = text.indexOf('#');
  if (hash >= 0) {
    body = text.substring(0, hash);
    final v = text.substring(hash + 1);
    variant = v.isEmpty ? null : v;
  }
  final slash = body.indexOf('/');
  if (slash <= 0 || slash == body.length - 1) return null;
  final provider = body.substring(0, slash);
  final id = body.substring(slash + 1);
  if (provider.isEmpty || id.isEmpty) return null;
  return ModelRef(providerId: provider, id: id, variant: variant);
}

/// Whether [raw] is an acceptable AFK model value: empty (inherit) or a
/// well-formed `provider/model[#variant]`.
bool isValidAfkModel(String raw) =>
    raw.trim().isEmpty || parseAfkModel(raw) != null;
