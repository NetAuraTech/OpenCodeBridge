// The structured-view contract shared by the bridge (which composes it from
// the opencode service) and the app (which renders it). One `SessionDetail`
// is what `GET /api/sessions/{id}` returns (spec section 5, endpoint 5): the
// session's state plus its costs and token usage.

import 'command.dart';

/// One session's token usage (the service's `TokenUsage.Info`), flattened to
/// the contract's field names.
class TokenUsage {
  const TokenUsage({
    required this.input,
    required this.output,
    required this.reasoning,
    required this.cacheRead,
    required this.cacheWrite,
  });

  /// Input tokens billed.
  final int input;

  /// Output tokens billed.
  final int output;

  /// Reasoning tokens billed.
  final int reasoning;

  /// Cache-read tokens (the service's `cache.read`).
  final int cacheRead;

  /// Cache-write tokens (the service's `cache.write`).
  final int cacheWrite;

  Map<String, Object?> toJson() => {
    'input': input,
    'output': output,
    'reasoning': reasoning,
    'cacheRead': cacheRead,
    'cacheWrite': cacheWrite,
  };

  factory TokenUsage.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return TokenUsage(
      input: (map['input'] as num?)?.toInt() ?? 0,
      output: (map['output'] as num?)?.toInt() ?? 0,
      reasoning: (map['reasoning'] as num?)?.toInt() ?? 0,
      cacheRead: (map['cacheRead'] as num?)?.toInt() ?? 0,
      cacheWrite: (map['cacheWrite'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TokenUsage &&
      other.input == input &&
      other.output == output &&
      other.reasoning == reasoning &&
      other.cacheRead == cacheRead &&
      other.cacheWrite == cacheWrite;

  @override
  int get hashCode =>
      Object.hash(input, output, reasoning, cacheRead, cacheWrite);

  @override
  String toString() =>
      'TokenUsage(input: $input, output: $output, '
      'reasoning: $reasoning, cacheRead: $cacheRead, '
      'cacheWrite: $cacheWrite)';
}

/// One session's detail (spec section 5, endpoint 5): its state plus its
/// costs and usage. This is what the structured view renders the cost bar
/// from and what `session.usage.updated` refreshes live.
class SessionDetail {
  const SessionDetail({
    required this.id,
    required this.title,
    required this.location,
    required this.cost,
    required this.tokens,
    this.outcome,
    this.contextLimit,
    this.model,
    this.agent,
  });

  final String id;
  final String title;

  /// The working directory, the service's session `location.directory`.
  final String location;

  /// The session's cost in USD (the service's `Money.USD`).
  final double cost;

  /// The session's token usage.
  final TokenUsage tokens;

  /// The session's state: the service's outcome (`succeeded`, `failed`, or
  /// `interrupted`), or `null` when the service reports none yet.
  final String? outcome;

  /// The session's model's context window, in tokens (the model registry's
  /// `limit.context`), or `null` when the registry knows no limit for the
  /// model. Drives the structured view's context bar.
  final int? contextLimit;

  /// The session's model (the service's `Session.Info` `model`), or `null`
  /// when the session has none set yet. Drives the cost bar's model chip.
  final ModelRef? model;

  /// The session's agent id (the service's `agent`, e.g. `build` or `plan`),
  /// or `null` when the service reports none yet. Drives the cost bar's mode
  /// chip.
  final String? agent;

  /// This detail with [cost] and [tokens] replaced (the live
  /// `session.usage.updated` refresh keeps the other facts).
  SessionDetail withUsage({required double cost, required TokenUsage tokens}) =>
      SessionDetail(
        id: id,
        title: title,
        location: location,
        cost: cost,
        tokens: tokens,
        outcome: outcome,
        contextLimit: contextLimit,
        model: model,
        agent: agent,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'location': location,
    'cost': cost,
    'tokens': tokens.toJson(),
    'outcome': outcome,
    'contextLimit': contextLimit,
    'model': model?.toJson(),
    'agent': agent,
  };

  factory SessionDetail.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final model = map['model'];
    return SessionDetail(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      location: map['location'] as String? ?? '',
      cost: (map['cost'] as num?)?.toDouble() ?? 0,
      tokens: TokenUsage.fromJson(map['tokens']),
      outcome: map['outcome'] is String ? map['outcome'] as String : null,
      contextLimit: (map['contextLimit'] as num?)?.toInt(),
      model: model is Map<String, Object?> ? ModelRef.fromJson(model) : null,
      agent: map['agent'] is String ? map['agent'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionDetail &&
      other.id == id &&
      other.title == title &&
      other.location == location &&
      other.cost == cost &&
      other.tokens == tokens &&
      other.outcome == outcome &&
      other.contextLimit == contextLimit &&
      other.model == model &&
      other.agent == agent;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    location,
    cost,
    tokens,
    outcome,
    contextLimit,
    model,
    agent,
  );

  @override
  String toString() =>
      'SessionDetail(id: $id, title: $title, location: $location, '
      'cost: $cost, tokens: $tokens, outcome: $outcome, '
      'contextLimit: $contextLimit, model: $model, agent: $agent)';
}
