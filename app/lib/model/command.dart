// The contract shared by the bridge and the app for the structured view's
// `/` command menu (issue #46). These are the list items the command menu and
// its pickers render, flattened from the shared opencode service's endpoints
// to the fields the app actually uses.

/// One of the project's custom commands (the service's `GET /api/command`
/// item): a markdown command file or a config `commands` entry. Executed via
/// the session's `command` endpoint (the body's `name` + `text`).
class OpencodeCommand {
  const OpencodeCommand({required this.name, required this.description});

  /// The command name (without the leading slash).
  final String name;

  /// The command's description (its markdown front-matter `description`),
  /// shown as the menu row's subtitle.
  final String description;

  Map<String, Object?> toJson() => {'name': name, 'description': description};

  factory OpencodeCommand.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return OpencodeCommand(
      name: map['name'] as String? ?? '',
      description: map['description'] is String
          ? map['description'] as String
          : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OpencodeCommand &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(name, description);

  @override
  String toString() => 'OpencodeCommand(name: $name)';
}

/// One model in the service's registry (`GET /api/model` item), flattened to
/// what the model / variant pickers need.
class ModelOption {
  const ModelOption({
    required this.id,
    required this.providerId,
    required this.name,
    required this.variants,
  });

  /// The model id (the service's `modelID`, else `id`) — the `id` half of a
  /// [ModelRef].
  final String id;

  /// The model's provider id (the service's `providerID`) — the
  /// [ModelRef]'s `providerID` half.
  final String providerId;

  /// The model's display name (the service's `name`, else the id).
  final String name;

  /// The model's variant ids (the service's `variants[].id`), in order.
  final List<String> variants;

  Map<String, Object?> toJson() => {
    'id': id,
    'providerID': providerId,
    'name': name,
    'variants': List<Object?>.unmodifiable(variants),
  };

  factory ModelOption.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final variants = map['variants'];
    // Accepts the service's `variants: [{id}]` maps and the bridge wire's
    // `variants: [id]` strings (what [toJson] emits).
    final variantIds = [
      for (final v in variants is List ? variants : const <Object?>[])
        if (v is Map<String, Object?> && v['id'] is String)
          v['id'] as String
        else if (v is String)
          v,
    ];
    final id = map['modelID'] is String
        ? map['modelID'] as String
        : map['id'] is String
        ? map['id'] as String
        : '';
    return ModelOption(
      id: id,
      providerId: map['providerID'] is String
          ? map['providerID'] as String
          : '',
      name: map['name'] is String && (map['name'] as String).isNotEmpty
          ? map['name'] as String
          : id,
      variants: variantIds,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ModelOption &&
      other.id == id &&
      other.providerId == providerId &&
      other.name == name &&
      _sameStrings(other.variants, variants);

  @override
  int get hashCode =>
      Object.hash(id, providerId, name, Object.hashAll(variants));

  @override
  String toString() => 'ModelOption(id: $id, providerId: $providerId)';
}

/// One agent in the service's registry (`GET /api/agent` item).
class AgentOption {
  const AgentOption({
    required this.id,
    required this.name,
    required this.description,
  });

  /// The agent id (the service's `id`) — what the `agent` endpoint takes.
  final String id;

  /// The agent's display name (the service's `name`, else the id).
  final String name;

  /// The agent's description (the service's `description`).
  final String description;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
  };

  factory AgentOption.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final id = map['id'] is String ? map['id'] as String : '';
    return AgentOption(
      id: id,
      name: map['name'] is String && (map['name'] as String).isNotEmpty
          ? map['name'] as String
          : id,
      description: map['description'] is String
          ? map['description'] as String
          : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentOption &&
      other.id == id &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);

  @override
  String toString() => 'AgentOption(id: $id)';
}

/// One skill in the service's registry (`GET /api/skill` item).
class SkillOption {
  const SkillOption({
    required this.id,
    required this.name,
    required this.description,
  });

  /// The skill id (the service's `id`) — what the activate endpoint takes.
  final String id;

  /// The skill's display name (the service's `name`, else the id).
  final String name;

  /// The skill's description (the service's `description`).
  final String description;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
  };

  factory SkillOption.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final id = map['id'] is String ? map['id'] as String : '';
    return SkillOption(
      id: id,
      name: map['name'] is String && (map['name'] as String).isNotEmpty
          ? map['name'] as String
          : id,
      description: map['description'] is String
          ? map['description'] as String
          : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SkillOption &&
      other.id == id &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);

  @override
  String toString() => 'SkillOption(id: $id)';
}

/// A model reference (the service's `Model.Ref`): what the `model` endpoint
/// takes to set the session's model.
class ModelRef {
  const ModelRef({required this.id, required this.providerId, this.variant});

  /// The model id.
  final String id;

  /// The model's provider id.
  final String providerId;

  /// The variant (reasoning effort), or `null` for the model's default.
  final String? variant;

  Map<String, Object?> toJson() => {
    'id': id,
    'providerID': providerId,
    if (variant != null) 'variant': variant,
  };

  factory ModelRef.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return ModelRef(
      id: map['id'] is String ? map['id'] as String : '',
      providerId: map['providerID'] is String
          ? map['providerID'] as String
          : '',
      variant: map['variant'] is String ? map['variant'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ModelRef &&
      other.id == id &&
      other.providerId == providerId &&
      other.variant == variant;

  @override
  int get hashCode => Object.hash(id, providerId, variant);

  @override
  String toString() =>
      'ModelRef(id: $id, providerId: $providerId, '
      'variant: $variant)';
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
