// The structured-view permission contract shared by the bridge (which
// composes it from the opencode service's pending permission requests) and
// the app (which renders the approve/deny banner). One `PermissionRequest`
// is what `GET /api/sessions/{id}/permissions` returns per pending request
// (spec section 5, endpoint 8), and [PermissionReply] is the
// `POST /api/sessions/{id}/permissions/{requestID}/reply` decision
// (endpoint 9).

/// The reply to a pending permission request (spec section 5, endpoint 9).
enum PermissionReply {
  /// Approve this one request only.
  once('once'),

  /// Approve and remember the decision for the future.
  always('always'),

  /// Deny the request.
  reject('reject');

  const PermissionReply(this.wire);

  /// The wire value on the bridge contract.
  final String wire;

  /// Parse the bridge contract's `reply` value. Unlike the tolerant
  /// [SessionClassification.fromWire] (which reads service data), this reads a
  /// user decision: an unknown value is a client error, so it throws
  /// [ArgumentError] for the bridge to map to a 400 rather than silently
  /// auto-approving.
  static PermissionReply fromWire(Object? value) => switch (value) {
    'once' => PermissionReply.once,
    'always' => PermissionReply.always,
    'reject' => PermissionReply.reject,
    _ => throw ArgumentError.value(
      value,
      'reply',
      'must be once, always, or reject',
    ),
  };
}

/// One pending permission request (spec section 5, endpoint 8).
class PermissionRequest {
  const PermissionRequest({
    required this.id,
    required this.action,
    required this.resources,
  });

  /// The request id (the service's permission request `id`).
  final String id;

  /// The action requested (the service's permission `action`, e.g. `shell`).
  final String action;

  /// What the action targets (the service's permission `resources`), e.g. the
  /// command line of a `shell` request.
  final List<String> resources;

  Map<String, Object?> toJson() => {
    'id': id,
    'action': action,
    'resources': resources,
  };

  factory PermissionRequest.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final resources = map['resources'];
    return PermissionRequest(
      id: map['id'] as String? ?? '',
      action: map['action'] as String? ?? '',
      resources: resources is List
          ? [
              for (final r in resources)
                if (r is String) r,
            ]
          : const [],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PermissionRequest &&
      other.id == id &&
      other.action == action &&
      _resourcesEqual(other.resources, resources);

  @override
  int get hashCode => Object.hash(id, action, Object.hashAll(resources));

  @override
  String toString() =>
      'PermissionRequest(id: $id, action: $action, resources: $resources)';
}

bool _resourcesEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
