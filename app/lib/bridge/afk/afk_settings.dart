import '../../model/command.dart';

/// The AFK agent's settings as the bridge holds them (spec #376, "Settings").
///
/// These are the three values the "AFK agent" section of Settings persists
/// (in the app's persisted settings, under the `afk.` namespace) and hands to
/// the in-process bridge: the arming toggle (default off — off is the inert
/// state: no polling, no feed, no admission), the parallel-orbs cap (1–10,
/// default 5), and the model (free text `provider/model[#variant]`, empty =
/// no pin = the service's default). The bridge is handed the values at
/// startup and notified in-process on change: a changed cap is effective from
/// the next orb spawn, a changed model from the next AFK session creation.
class AfkSettings {
  const AfkSettings({
    this.enabled = false,
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

  /// The arming toggle. Off is the inert state.
  final bool enabled;

  /// How many AFK orbs may run in parallel (1–10). Effective from the next
  /// orb spawn (enforced at the spawn boundary by a later ticket).
  final int parallelOrbs;

  /// The model the AFK session is created with, as `provider/model[#variant]`.
  /// Empty = no pin = the opencode config's default.
  final String model;

  AfkSettings copyWith({bool? enabled, int? parallelOrbs, String? model}) =>
      AfkSettings(
        enabled: enabled ?? this.enabled,
        parallelOrbs: parallelOrbs ?? this.parallelOrbs,
        model: model ?? this.model,
      );

  @override
  bool operator ==(Object other) =>
      other is AfkSettings &&
      other.enabled == enabled &&
      other.parallelOrbs == parallelOrbs &&
      other.model == model;

  @override
  int get hashCode => Object.hash(enabled, parallelOrbs, model);

  @override
  String toString() =>
      'AfkSettings(enabled: $enabled, parallelOrbs: $parallelOrbs, '
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
