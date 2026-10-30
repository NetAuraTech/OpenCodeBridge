// The structured-view message contract shared by the bridge (which composes
// it from the opencode service's session context) and the app (which renders
// it). One `List<SessionMessage>` is what
// `GET /api/sessions/{id}/messages` returns (spec section 5, endpoint 6): the
// history with the tools in flight.

/// One tool call of an assistant message (spec section 5, endpoint 6).
class ToolCall {
  const ToolCall({
    this.id,
    required this.name,
    required this.status,
    this.input,
    this.error,
    this.patch,
  });

  /// The tool call id (the service's tool part `id`). The structured view
  /// tracks the in-flight tool cards off the `session.tool.*` events by this
  /// id. `null` when the call was composed without one.
  final String? id;

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

  /// The service-computed unified diff of the file the edit changed (the
  /// tool state's `metadata.files` patch, with the hunk headers and the
  /// context lines): `@@`/`-`/`+` lines, as the terminal renders it.
  /// `null` for tools that carry no patch (or before the edit runs).
  final String? patch;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'status': status,
    'input': input,
    'error': error,
    'patch': patch,
  };

  factory ToolCall.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return ToolCall(
      id: map['id'] is String ? map['id'] as String : null,
      name: map['name'] as String? ?? '',
      status: map['status'] as String? ?? '',
      input: map['input'],
      error: map['error'] is String ? map['error'] as String : null,
      patch: map['patch'] is String ? map['patch'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ToolCall &&
      other.id == id &&
      other.name == name &&
      other.status == status &&
      other.input == input &&
      other.error == error &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(id, name, status, input, error, patch);

  @override
  String toString() =>
      'ToolCall(id: $id, name: $name, status: $status, '
      'input: $input, error: $error, patch: $patch)';
}

/// One message of a session's history (spec section 5, endpoint 6).
class SessionMessage {
  const SessionMessage({
    this.id,
    required this.role,
    this.text,
    this.reasoning,
    this.contextTokens,
    this.tools = const [],
  });

  /// The service's message id (its `Session.Message` id). The bridge sets it
  /// from the context; the structured view tracks the in-flight message off
  /// the `session.*` events by this id. `null` when the message was composed
  /// without one (a locally-appended user prompt).
  final String? id;

  /// `user`, `assistant`, or `compaction` (a context-compaction marker of
  /// the history, whose [text] is the summary the compaction wrote).
  final String role;

  /// The message's text; `null` when the message carries only tools.
  final String? text;

  /// The assistant message's reasoning (thinking) text, when the model
  /// emits one; `null` otherwise. Kept out of [text] so the structured view
  /// can render it distinctly.
  final String? reasoning;

  /// The context the model call that produced this assistant message sent
  /// to the model: its `tokens` input plus the prompt-cache reads and
  /// writes. The structured view seeds its context gauge from the last
  /// message that carries one, so an opened session shows the context the
  /// session really is in. `null` for user messages and messages composed
  /// without the service's tokens.
  final int? contextTokens;

  /// The assistant message's tool calls (in flight or finished); empty for
  /// user messages.
  final List<ToolCall> tools;

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role,
    'text': text,
    'reasoning': reasoning,
    'contextTokens': contextTokens,
    'tools': [for (final tool in tools) tool.toJson()],
  };

  factory SessionMessage.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final tools = map['tools'];
    return SessionMessage(
      id: map['id'] is String ? map['id'] as String : null,
      role: map['role'] as String? ?? '',
      text: map['text'] is String ? map['text'] as String : null,
      reasoning: map['reasoning'] is String ? map['reasoning'] as String : null,
      contextTokens: map['contextTokens'] is num
          ? (map['contextTokens'] as num).toInt()
          : null,
      tools: tools is List
          ? [for (final item in tools) ToolCall.fromJson(item)]
          : const [],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionMessage &&
      other.id == id &&
      other.role == role &&
      other.text == text &&
      other.reasoning == reasoning &&
      other.contextTokens == contextTokens &&
      _toolsEqual(other.tools, tools);

  @override
  int get hashCode => Object.hash(
    id,
    role,
    text,
    reasoning,
    contextTokens,
    Object.hashAll(tools),
  );

  @override
  String toString() =>
      'SessionMessage(id: $id, role: $role, '
      'text: $text, reasoning: $reasoning, '
      'contextTokens: $contextTokens, tools: $tools)';
}

bool _toolsEqual(List<ToolCall> a, List<ToolCall> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
