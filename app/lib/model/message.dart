// The structured-view message contract shared by the bridge (which composes
// it from the opencode service's session context) and the app (which renders
// it). One `List<SessionMessage>` is what
// `GET /api/sessions/{id}/messages` returns (spec section 5, endpoint 6): the
// history with the tools in flight.

/// One tool call of an assistant message (spec section 5, endpoint 6).
class ToolCall {
  const ToolCall({
    required this.name,
    required this.status,
    this.input,
    this.error,
  });

  /// The tool name (the service's tool `name`).
  final String name;

  /// The tool state's status (the service's tool state `status`):
  /// `streaming`, `running`, `completed`, or `error`.
  final String status;

  /// The tool's input (the service's tool state `input`), for display: a
  /// partial JSON string while streaming, the input object once running.
  final Object? input;

  /// The tool's error message, when [status] is `error`.
  final String? error;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status,
    'input': input,
    'error': error,
  };

  factory ToolCall.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return ToolCall(
      name: map['name'] as String? ?? '',
      status: map['status'] as String? ?? '',
      input: map['input'],
      error: map['error'] is String ? map['error'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ToolCall &&
      other.name == name &&
      other.status == status &&
      other.input == input &&
      other.error == error;

  @override
  int get hashCode => Object.hash(name, status, input, error);

  @override
  String toString() =>
      'ToolCall(name: $name, status: $status, input: $input, error: $error)';
}

/// One message of a session's history (spec section 5, endpoint 6).
class SessionMessage {
  const SessionMessage({
    required this.role,
    this.text,
    this.tools = const [],
  });

  /// `user` or `assistant`.
  final String role;

  /// The message's text; `null` when the message carries only tools.
  final String? text;

  /// The assistant message's tool calls (in flight or finished); empty for
  /// user messages.
  final List<ToolCall> tools;

  Map<String, Object?> toJson() => {
    'role': role,
    'text': text,
    'tools': [for (final tool in tools) tool.toJson()],
  };

  factory SessionMessage.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final tools = map['tools'];
    return SessionMessage(
      role: map['role'] as String? ?? '',
      text: map['text'] is String ? map['text'] as String : null,
      tools: tools is List
          ? [for (final item in tools) ToolCall.fromJson(item)]
          : const [],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionMessage &&
      other.role == role &&
      other.text == text &&
      _toolsEqual(other.tools, tools);

  @override
  int get hashCode =>
      Object.hash(role, text, Object.hashAll(tools));

  @override
  String toString() =>
      'SessionMessage(role: $role, text: $text, tools: $tools)';
}

bool _toolsEqual(List<ToolCall> a, List<ToolCall> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
