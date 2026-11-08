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
    this.answers,
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

  /// The answers the user gave the agent's `question` tool (the tool state's
  /// `metadata.answers`): one list of the picked option values per question,
  /// in form order. `null` for every other tool, and for a question the user
  /// hasn't answered yet.
  final List<List<String>>? answers;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'status': status,
    'input': input,
    'error': error,
    'patch': patch,
    'answers': answers,
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
      answers: answersFrom(map['answers']),
    );
  }

  /// The tool state's `metadata.answers` (the agent's `question` tool): a
  /// list of answers, each a list of the option values the user picked, one
  /// entry per question in form order. Parsed from the service's JSON;
  /// `null` when the field is absent or not of that shape.
  static List<List<String>>? answersFrom(Object? json) {
    final list = json is List ? json : null;
    if (list == null) return null;
    final rows = <List<String>>[];
    for (final row in list) {
      if (row is List) {
        rows.add([
          for (final value in row)
            if (value is String) value,
        ]);
      } else if (row is String) {
        rows.add([row]);
      }
    }
    return rows.isEmpty ? null : rows;
  }

  /// The "new file" unified diff of a [write] tool's content (every line
  /// added): the same shape the service's edit patches take, so the diff view
  /// renders the written file the way it renders an edit. The service doesn't
  /// compute a patch for a write — it returns only the file's content — so
  /// this synthesizes one.
  ///
  /// [input] is the tool's input (`{path, content}`). The patch is `null` when
  /// the input carries no content (a tool that isn't a write, or a write
  /// before its content streams in).
  static String? writePatch(Object? input) {
    final map = input is Map<String, Object?> ? input : null;
    final content = map?['content'];
    if (content is! String) return null;
    final path = map!['path'] is String ? map['path'] as String : '';
    final lines = content.split('\n');
    // The trailing newline of the content is not a line: `a\nb\n` is two.
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    final buffer = StringBuffer()
      ..writeln('Index: $path')
      ..writeln(
        '===================================================================',
      )
      ..writeln('--- /dev/null')
      ..writeln('+++ $path')
      ..writeln('@@ -0,0 +1,${lines.length} @@');
    for (final line in lines) {
      buffer.writeln('+$line');
    }
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is ToolCall &&
      other.id == id &&
      other.name == name &&
      other.status == status &&
      other.input == input &&
      other.error == error &&
      other.patch == patch &&
      _answersEqual(other.answers, answers);

  @override
  int get hashCode =>
      Object.hash(id, name, status, input, error, patch, _answersHash(answers));

  @override
  String toString() =>
      'ToolCall(id: $id, name: $name, status: $status, '
      'input: $input, error: $error, patch: $patch, '
      'answers: $answers)';
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
    this.created,
    this.streamed,
    this.completed,
    this.outputTokens,
    this.reasoningTokens,
  });

  /// The service's message id (its `Session.Message` id). The bridge sets it
  /// from the context; the structured view tracks the in-flight message off
  /// the `session.*` events by this id. `null` when the message was composed
  /// without one (a locally-appended user prompt).
  final String? id;

  /// `user`, `assistant`, `compaction` (a context-compaction marker of
  /// the history, whose [text] is the summary the compaction wrote), or
  /// `idle` (the marker closing a turn, carrying no content).
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

  /// The message's creation (the service's `time.created`, epoch millis),
  /// or `null` when the message was composed without one. Feeds the turn
  /// stats (issue #121).
  final int? created;

  /// The assistant message's first streamed token (the service's
  /// `time.streamed`, epoch millis): the model call's streaming began.
  /// `null` while absent (a step whose provider never reported streaming).
  final int? streamed;

  /// The assistant message's completion (the service's `time.completed`,
  /// epoch millis); `null` while the step has not completed (or the message
  /// is not an assistant step).
  final int? completed;

  /// The assistant step's billed output tokens (the service's `tokens
  /// .output`), or `null` when the service carried no tokens.
  final int? outputTokens;

  /// The assistant step's billed reasoning tokens (the service's
  /// `tokens.reasoning`), or `null` when the service carried no tokens.
  final int? reasoningTokens;

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role,
    'text': text,
    'reasoning': reasoning,
    'contextTokens': contextTokens,
    'tools': [for (final tool in tools) tool.toJson()],
    'created': created,
    'streamed': streamed,
    'completed': completed,
    'outputTokens': outputTokens,
    'reasoningTokens': reasoningTokens,
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
      created: _intOrNull(map['created']),
      streamed: _intOrNull(map['streamed']),
      completed: _intOrNull(map['completed']),
      outputTokens: _intOrNull(map['outputTokens']),
      reasoningTokens: _intOrNull(map['reasoningTokens']),
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
      _toolsEqual(other.tools, tools) &&
      other.created == created &&
      other.streamed == streamed &&
      other.completed == completed &&
      other.outputTokens == outputTokens &&
      other.reasoningTokens == reasoningTokens;

  @override
  int get hashCode => Object.hash(
    id,
    role,
    text,
    reasoning,
    contextTokens,
    Object.hashAll(tools),
    created,
    streamed,
    completed,
    outputTokens,
    reasoningTokens,
  );

  @override
  String toString() =>
      'SessionMessage(id: $id, role: $role, '
      'text: $text, reasoning: $reasoning, '
      'contextTokens: $contextTokens, tools: $tools, '
      'created: $created, streamed: $streamed, completed: $completed, '
      'outputTokens: $outputTokens, reasoningTokens: $reasoningTokens)';
}

/// One page of a session's history, as the paged read serves it (issue
/// #124): the page's messages in chronological (oldest-first) order, and the
/// cursor to the next (older) page — `null` when the page is the oldest. The
/// service paginates the history newest-first, so the first fetch (no cursor)
/// is the newest page.
class MessagePage {
  const MessagePage({required this.messages, required this.nextCursor});

  /// The page's messages, oldest first.
  final List<SessionMessage> messages;

  /// The cursor to the next (older) page, or `null` at the oldest page.
  final String? nextCursor;

  /// This page with the already-loaded [newer] messages appended in
  /// chronological order, carrying this (older) page's cursor.
  MessagePage appendNewer(List<SessionMessage> newer) =>
      MessagePage(messages: [...messages, ...newer], nextCursor: nextCursor);

  @override
  bool operator ==(Object other) =>
      other is MessagePage &&
      other.nextCursor == nextCursor &&
      _sameList(other.messages, messages);

  @override
  int get hashCode => Object.hash(Object.hashAll(messages), nextCursor);

  @override
  String toString() =>
      'MessagePage(${messages.length} messages, '
      'nextCursor: $nextCursor)';
}

bool _sameList(List<SessionMessage> a, List<SessionMessage> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int? _intOrNull(Object? value) => value is num ? value.toInt() : null;

bool _toolsEqual(List<ToolCall> a, List<ToolCall> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [ToolCall.answers] compare by content (the lists are compared row by
/// row, value by value), not by identity, so two calls composed from
/// separate decodes of the same service state are equal.
bool _answersEqual(List<List<String>>? a, List<List<String>>? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].length != b[i].length) return false;
    for (var j = 0; j < a[i].length; j++) {
      if (a[i][j] != b[i][j]) return false;
    }
  }
  return true;
}

/// A stable hash of [ToolCall.answers] matching [_answersEqual]: the same
/// content always hashes the same, so equal calls share a hashCode.
int _answersHash(List<List<String>>? answers) {
  if (answers == null) return 0;
  return Object.hashAll([for (final row in answers) Object.hashAll(row)]);
}
