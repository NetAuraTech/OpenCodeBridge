import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../client/events_client.dart';
import '../client/sessions_client.dart';
import '../model/message.dart';
import '../model/permission.dart';
import '../model/session_detail.dart';
import 'permission_banner.dart';

/// The structured view of one session (spec §6: *External* → structured
/// view): the message history with the tools in flight, the live cost bar,
/// and the prompt input enabled at any time (spec §5, endpoint 7: a mid-turn
/// prompt is queued by the service with `delivery: steer`).
///
/// The view is event-driven (spec §8): while a turn runs,
/// `session.text.delta` / `session.reasoning.delta` grow the in-flight
/// message token by token, `session.tool.*` update its tool cards,
/// `session.usage.updated` moves the cost bar from the payload, and
/// `session.step.ended` records the context the model call used. The turn
/// boundary (`session.execution.*`) re-fetches the service's authoritative
/// state. Events arrive on the shared [EventSource] stream and are filtered
/// to this session.
class StructuredSessionScreen extends StatefulWidget {
  const StructuredSessionScreen({
    super.key,
    required this.sessionId,
    required this.title,
    required this.client,
    this.events,
  });

  /// The session to view (the bridge's `/api/sessions/{id}` family).
  final String sessionId;

  /// The session's title, shown in the app bar.
  final String title;

  /// The bridge's sessions API client (endpoints 5–9).
  final SessionsClient client;

  /// Every event off the bridge's unified stream (spec §8), or `null` for
  /// initial-state-only rendering (the initial state comes from endpoints
  /// 5, 6, and 8; the live refreshes are then skipped).
  final Stream<BridgeEvent>? events;

  @override
  State<StructuredSessionScreen> createState() =>
      _StructuredSessionScreenState();
}

class _StructuredSessionScreenState extends State<StructuredSessionScreen> {
  SessionDetail? _detail;

  List<SessionMessage> _messages = const [];

  List<PermissionRequest> _pending = const [];

  /// True until the initial load (endpoints 5, 6, 8) settles.
  bool _loading = true;

  /// The initial load failure, if any.
  String? _loadError;

  /// True while a prompt send (endpoint 7) is in flight.
  bool _promptBusy = false;

  /// The permission request whose reply (endpoint 9) is in flight.
  String? _replyBusyId;

  /// True while the session's turn is running (from
  /// `session.execution.started` to its end event): the streaming events
  /// apply to the in-flight message while it is set.
  bool _turnActive = false;

  /// The tokens the last model call sent to the model (the context the call
  /// used), from the last `session.step.ended` seen; `null` until a step
  /// ends. Kept after the turn ends (the context stays until the next
  /// prompt).
  int? _contextUsed;

  /// Assistant message id -> its index in [_messages]. Seeded with the loaded
  /// history, so a turn already running when the view opens streams into the
  /// in-flight message the service's context includes (not a duplicate);
  /// re-seeded after every load and turn-boundary normalize.
  final Map<String, int> _liveMessages = {};

  /// In-flight tool call id -> its index in its message's tool list (the
  /// list is append-only, so the index is stable).
  final Map<String, int> _liveTools = {};

  /// In-flight tool call id -> the id of the message its card lives in.
  final Map<String, String> _liveToolsOf = {};

  /// In-flight message id -> whether the next streamed part must be joined
  /// with the newline that separates the parts of the history (the same
  /// join the service's context history uses between its parts).
  final Map<String, bool> _needsSep = {};

  /// Follow the streaming content to the bottom, until the user scrolls up
  /// (re-engage by scrolling back to the bottom).
  bool _stick = true;

  final ScrollController _scroll = ScrollController();

  StreamSubscription<BridgeEvent>? _events;

  final TextEditingController _prompt = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadInitial();
    final stream = widget.events;
    if (stream != null) {
      _events = stream.listen(_onEvent);
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _stick = position.pixels >= position.maxScrollExtent - 8;
  }

  /// Keeps the history at the bottom for the next frame when [_stick] holds
  /// (the content just grew by a streamed delta).
  void _followBottomNextFrame() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _followBottom());
  }

  void _followBottom() {
    if (!mounted || !_stick || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels < position.maxScrollExtent) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  /// The initial state: detail (costs), history (tools in flight), and the
  /// pending permission requests (endpoints 5, 6, 8).
  Future<void> _loadInitial() async {
    try {
      final results = await Future.wait<Object?>([
        widget.client.getDetail(widget.sessionId),
        widget.client.getMessages(widget.sessionId),
        widget.client.getPermissions(widget.sessionId),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results.first as SessionDetail;
        _messages = results[1] as List<SessionMessage>;
        _pending = results[2] as List<PermissionRequest>;
        _loading = false;
        _seedLiveMessages();
      });
      _stick = true;
      _followBottomNextFrame();
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.statusCode == 0
            ? 'Cannot reach the bridge.'
            : 'The bridge could not load the session '
                  '(status ${e.statusCode}).';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load the session.';
        _loading = false;
      });
    }
  }

  /// (Re-)indexes the loaded history so the live maps track every message
  /// and tool call it already carries (a turn may be running when the view
  /// opens, or a normalize just replaced the history).
  void _seedLiveMessages() {
    _liveMessages.clear();
    _liveTools.clear();
    _liveToolsOf.clear();
    _needsSep.clear();
    for (var i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      final id = message.id;
      if (id == null) continue;
      _liveMessages[id] = i;
      for (var t = 0; t < message.tools.length; t++) {
        final toolId = message.tools[t].id;
        if (toolId != null) {
          _liveTools[toolId] = t;
          _liveToolsOf[toolId] = id;
        }
      }
    }
  }

  /// Routes the live events of this session (§8). The streaming events grow
  /// the in-flight message in place (no re-fetch): `session.text.delta` /
  /// `session.reasoning.delta` append the token, `session.tool.*` update the
  /// tool cards, `session.usage.updated` moves the cost bar from the
  /// payload, `session.step.ended` records the context the model call used.
  /// `permission.asked` / `permission.replied` refresh the banner, and the
  /// turn boundary (`session.execution.*`) re-fetches the service's
  /// authoritative state.
  void _onEvent(BridgeEvent event) {
    if (!_forSession(event)) return;
    switch (event.type) {
      case 'session.execution.started':
        if (mounted) setState(() => _turnActive = true);
        break;
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.interrupted':
        if (mounted) setState(() => _turnActive = false);
        _normalize();
        break;
      case 'session.usage.updated':
        _applyUsage(event.data);
        break;
      case 'session.step.ended':
        _applyStepEnded(event.data);
        break;
      case 'session.text.started':
      case 'session.reasoning.started':
        _applyPartStarted(event.data);
        break;
      case 'session.text.delta':
      case 'session.reasoning.delta':
        _applyPartDelta(event.data);
        break;
      case 'session.tool.input.started':
        _applyToolInputStarted(event.data);
        break;
      case 'session.tool.input.ended':
        _applyToolInputEnded(event.data);
        break;
      case 'session.tool.called':
        _applyToolCalled(event.data);
        break;
      case 'session.tool.success':
        _applyToolSuccess(event.data);
        break;
      case 'session.tool.failed':
        _applyToolFailed(event.data);
        break;
      case 'permission.asked':
      case 'permission.replied':
        _refreshPermissions();
        break;
    }
  }

  /// True when [event] belongs to this session: the durable aggregate id, or
  /// the payload's `sessionID` when the event carries no durable position.
  bool _forSession(BridgeEvent event) {
    final durable = event.durable;
    if (durable != null) {
      return durable.aggregateID == widget.sessionId;
    }
    return event.data['sessionID'] == widget.sessionId;
  }

  /// The in-flight assistant message id from a `session.*` payload.
  String? _messageId(Map<String, Object?> data) =>
      data['assistantMessageID'] is String
      ? data['assistantMessageID'] as String
      : null;

  /// The in-flight message at [id], appended to the history as an empty
  /// assistant message on first sight.
  int _ensureLiveMessage(String id) {
    final index = _liveMessages[id];
    if (index != null) return index;
    _messages = [..._messages, SessionMessage(id: id, role: 'assistant')];
    final created = _messages.length - 1;
    _liveMessages[id] = created;
    return created;
  }

  /// A [SessionMessage] copy with [text] and/or [tools] replaced.
  SessionMessage _rebuildMessage(
    SessionMessage message, {
    String? text,
    List<ToolCall>? tools,
  }) => SessionMessage(
    id: message.id,
    role: message.role,
    text: text ?? message.text,
    tools: tools ?? message.tools,
  );

  /// A part (`reasoning:0`, `text:1`, …) starts: from the next delta on, the
  /// streamed content is a new part, so it joins the history with the part
  /// newline whenever the message already carries content.
  void _applyPartStarted(Map<String, Object?> data) {
    final id = _messageId(data);
    if (id == null || !mounted) return;
    setState(() {
      _ensureLiveMessage(id);
      final text = _messages[_liveMessages[id]!].text;
      _needsSep[id] = text != null && text.isNotEmpty;
    });
  }

  /// Replaces the message at [index] (copy-on-write: the list may be
  /// unmodifiable, e.g. seeded from a `const` history in tests).
  void _setMessageAt(int index, SessionMessage message) {
    final list = List<SessionMessage>.of(_messages)..[index] = message;
    _messages = list;
  }

  /// A streamed token: appended to the in-flight message's text, part
  /// boundary and all (the history flattens reasoning and text parts into
  /// the same stream, in order).
  void _applyPartDelta(Map<String, Object?> data) {
    final id = _messageId(data);
    final delta = data['delta'] is String ? data['delta'] as String : null;
    if (id == null || delta == null || !mounted) return;
    setState(() {
      final index = _ensureLiveMessage(id);
      final message = _messages[index];
      final text = message.text ?? '';
      final separator = _needsSep.remove(id) == true ? '\n' : '';
      _setMessageAt(
        index,
        _rebuildMessage(message, text: text + separator + delta),
      );
    });
    _followBottomNextFrame();
  }

  /// A tool card appears (or the late event's card is created): the card is
  /// created at `session.tool.input.started`, which carries the tool name
  /// and precedes every other tool event.
  void _applyToolInputStarted(Map<String, Object?> data) {
    final id = _messageId(data);
    final toolId = data['id'] is String ? data['id'] as String : null;
    final name = data['name'] is String ? data['name'] as String : '';
    if (id == null || toolId == null || !mounted) return;
    setState(() => _ensureToolCard(id, toolId, name));
  }

  /// The tool's final input (the service's JSON string of the input object).
  void _applyToolInputEnded(Map<String, Object?> data) {
    final toolId = data['id'] is String ? data['id'] as String : null;
    if (toolId == null) return;
    final text = data['text'];
    if (text is! String) return;
    Object? input;
    try {
      input = jsonDecode(text);
    } catch (_) {
      return; // Unparseable: keep the previous input on the card.
    }
    if (!mounted) return;
    setState(
      () => _updateToolCard(toolId, (tool) => _rebuildTool(tool, input: input)),
    );
  }

  /// The tool call's input object (from `session.tool.called`).
  void _applyToolCalled(Map<String, Object?> data) {
    final id = _messageId(data);
    final toolId = data['id'] is String ? data['id'] as String : null;
    if (id == null || toolId == null || !mounted) return;
    final input = data['input'];
    setState(() {
      _ensureToolCard(id, toolId, '');
      if (input != null) {
        _updateToolCard(toolId, (tool) => _rebuildTool(tool, input: input));
      }
    });
  }

  /// The tool finished.
  void _applyToolSuccess(Map<String, Object?> data) {
    final toolId = data['id'] is String ? data['id'] as String : null;
    if (toolId == null || !mounted) return;
    setState(
      () => _updateToolCard(
        toolId,
        (tool) => _rebuildTool(tool, status: 'completed'),
      ),
    );
  }

  /// The tool failed.
  void _applyToolFailed(Map<String, Object?> data) {
    final toolId = data['id'] is String ? data['id'] as String : null;
    if (toolId == null || !mounted) return;
    final error = data['error'] is String ? data['error'] as String : null;
    setState(
      () => _updateToolCard(
        toolId,
        (tool) => _rebuildTool(tool, status: 'error', error: error),
      ),
    );
  }

  /// The session's cumulative usage (the live cost bar), from the payload —
  /// no re-fetch.
  void _applyUsage(Map<String, Object?> data) {
    final detail = _detail;
    if (detail == null) return;
    final cost = (data['cost'] as num?)?.toDouble() ?? detail.cost;
    final tokensJson = data['tokens'];
    final tokens = tokensJson == null
        ? detail.tokens
        : _tokensFromWire(tokensJson);
    if (!mounted) return;
    setState(() => _detail = detail.withUsage(cost: cost, tokens: tokens));
  }

  /// The context the model call used: the call's input tokens.
  void _applyStepEnded(Map<String, Object?> data) {
    final tokens = data['tokens'];
    if (tokens is! Map<String, Object?>) return;
    final input = (tokens['input'] as num?)?.toInt();
    if (input == null || !mounted) return;
    setState(() => _contextUsed = input);
  }

  /// A [TokenUsage] from the service's wire shape (the events' `tokens`
  /// payload, `cache.read` / `cache.write` nested), tolerant of gaps.
  static TokenUsage _tokensFromWire(Object? json) {
    final map = json is Map<String, Object?> ? json : const <String, Object?>{};
    final cache = map['cache'] is Map<String, Object?>
        ? map['cache'] as Map<String, Object?>
        : const <String, Object?>{};
    return TokenUsage(
      input: (map['input'] as num?)?.toInt() ?? 0,
      output: (map['output'] as num?)?.toInt() ?? 0,
      reasoning: (map['reasoning'] as num?)?.toInt() ?? 0,
      cacheRead: (cache['read'] as num?)?.toInt() ?? 0,
      cacheWrite: (cache['write'] as num?)?.toInt() ?? 0,
    );
  }

  /// Appends a new in-flight tool card (created at `tool.input.started`):
  /// the card is running until its success / failed event.
  void _ensureToolCard(String messageId, String toolId, String name) {
    if (_liveTools.containsKey(toolId)) return;
    final index = _ensureLiveMessage(messageId);
    final message = _messages[index];
    final tools = List<ToolCall>.of(message.tools)
      ..add(ToolCall(id: toolId, name: name, status: 'running'));
    _setMessageAt(index, _rebuildMessage(message, tools: tools));
    _liveTools[toolId] = tools.length - 1;
    _liveToolsOf[toolId] = messageId;
  }

  /// Applies [update] to the in-flight tool card [toolId].
  void _updateToolCard(String toolId, ToolCall Function(ToolCall tool) update) {
    final messageId = _liveToolsOf[toolId];
    if (messageId == null) return;
    final index = _liveMessages[messageId];
    final toolIndex = _liveTools[toolId];
    if (index == null || toolIndex == null) return;
    final message = _messages[index];
    if (toolIndex >= message.tools.length) return;
    final tools = List<ToolCall>.of(message.tools);
    tools[toolIndex] = update(tools[toolIndex]);
    _setMessageAt(index, _rebuildMessage(message, tools: tools));
  }

  /// A [ToolCall] copy with [name], [status], [input], [error] replaced.
  ToolCall _rebuildTool(
    ToolCall tool, {
    String? name,
    String? status,
    Object? input,
    String? error,
  }) => ToolCall(
    id: tool.id,
    name: name ?? tool.name,
    status: status ?? tool.status,
    input: input ?? tool.input,
    error: error ?? tool.error,
  );

  /// The turn boundary just ended (or started): re-fetch the service's
  /// authoritative state (endpoints 5, 6, 8) — the streamed in-flight
  /// content is replaced by the history, and the detail's context window
  /// follows the session's model. A transient failure keeps the screen.
  Future<void> _normalize() async {
    try {
      final results = await Future.wait<Object?>([
        widget.client.getDetail(widget.sessionId),
        widget.client.getMessages(widget.sessionId),
        widget.client.getPermissions(widget.sessionId),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results.first as SessionDetail;
        _messages = results[1] as List<SessionMessage>;
        _pending = results[2] as List<PermissionRequest>;
        _seedLiveMessages();
      });
      _followBottomNextFrame();
    } on SessionsClientError {
      // Transient (e.g. the service restarted): the next boundary
      // re-fetches.
    } catch (_) {
      // Same: a normalize failure never breaks the view.
    }
  }

  /// Re-fetches the pending permission requests (endpoint 8).
  Future<void> _refreshPermissions() async {
    try {
      final pending = await widget.client.getPermissions(widget.sessionId);
      if (!mounted) return;
      setState(() => _pending = pending);
    } on SessionsClientError {
      // Keep the last pending list on screen.
    }
  }

  /// Sends the prompt (endpoint 7), enabled at any time: the bridge forwards
  /// it with `delivery: steer` and the service queues it mid-turn. The user
  /// message is appended locally (the service's copy replaces it at the
  /// turn-boundary normalize).
  Future<void> _sendPrompt() async {
    final text = _prompt.text.trim();
    if (text.isEmpty || _promptBusy) return;
    setState(() => _promptBusy = true);
    try {
      await widget.client.prompt(widget.sessionId, text);
      _prompt.clear();
      if (!mounted) return;
      setState(() {
        _messages = [..._messages, SessionMessage(role: 'user', text: text)];
      });
      _followBottomNextFrame();
    } on SessionsClientError catch (e) {
      if (mounted) {
        _snackBar(
          'Could not send the message '
          '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
        );
      }
    } catch (_) {
      if (mounted) _snackBar('Could not send the message.');
    } finally {
      if (mounted) setState(() => _promptBusy = false);
    }
  }

  /// Applies the decision to a pending request (endpoint 9) and re-fetches
  /// the pending list: the turn continues once the service records it.
  Future<void> _reply(PermissionRequest request, PermissionReply reply) async {
    if (_replyBusyId != null) return;
    setState(() => _replyBusyId = request.id);
    try {
      await widget.client.replyPermission(widget.sessionId, request.id, reply);
      await _refreshPermissions();
    } on SessionsClientError catch (e) {
      if (mounted) {
        _snackBar(
          'Could not reply to the permission request '
          '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
        );
      }
    } catch (_) {
      if (mounted) _snackBar('Could not reply to the permission request.');
    } finally {
      if (mounted) setState(() => _replyBusyId = null);
    }
  }

  void _snackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PermissionBanner(
                  pending: _pending,
                  onReply: _reply,
                  replyBusyId: _replyBusyId,
                ),
                _CostBar(detail: _detail, contextUsed: _contextUsed),
                Expanded(
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    children: [
                      if (_messages.isEmpty)
                        const _CenteredMessage(text: 'No messages yet.'),
                      for (final message in _messages)
                        _MessagePane(
                          message: message,
                          inFlight:
                              _turnActive &&
                              message.id != null &&
                              _liveMessages.containsKey(message.id),
                        ),
                    ],
                  ),
                ),
                _PromptBar(
                  controller: _prompt,
                  busy: _promptBusy,
                  onSend: _sendPrompt,
                ),
              ],
            ),
    );
  }
}

/// The live header: the session's cost in USD and its token usage (endpoint
/// 5, moved by `session.usage.updated`), plus the model's context window —
/// the context the last model call used (`session.step.ended`) against the
/// session's model limit, with the percent used.
class _CostBar extends StatelessWidget {
  const _CostBar({required this.detail, required this.contextUsed});

  final SessionDetail? detail;

  final int? contextUsed;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) return const SizedBox.shrink();
    final tokens = detail.tokens;
    final limit = detail.contextLimit;
    final used = contextUsed;
    final fraction = used != null && limit != null && limit > 0
        ? used / limit
        : null;
    return Container(
      key: const ValueKey('structured-cost'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Cost \$${detail.cost.toStringAsFixed(4)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Flexible(
                child: Text(
                  '${tokens.input} in · ${tokens.output} out · '
                  '${tokens.reasoning} reasoning · '
                  '${tokens.cacheRead} cache read · '
                  '${tokens.cacheWrite} cache write',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              if (used != null) ...[
                const SizedBox(width: 8),
                Container(
                  key: const ValueKey('structured-context'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                  ),
                  child: Text(
                    limit == null
                        ? 'context $used'
                        : 'context $used / $limit · ${_percent(used, limit)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
              if (detail.outcome != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                  ),
                  child: Text(
                    detail.outcome!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
          if (fraction != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ClipRect(
                child: LinearProgressIndicator(
                  value: fraction.clamp(0.0, 1.0),
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _percent(int used, int limit) {
    final pct = used / limit * 100;
    final text = pct < 10 ? pct.toStringAsFixed(1) : pct.toStringAsFixed(0);
    return '$text%';
  }
}

/// One message of the history (endpoint 6): the text, then the assistant's
/// tool calls (in flight or finished).
class _MessagePane extends StatelessWidget {
  const _MessagePane({required this.message, required this.inFlight});

  final SessionMessage message;

  /// True while the session's turn is streaming into this message: the
  /// label shows it.
  final bool inFlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isUser
                ? 'You'
                : inFlight
                ? 'Assistant · working…'
                : 'Assistant',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isUser ? scheme.primary : scheme.outline,
            ),
          ),
          if (message.text != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(message.text!),
            ),
          for (final tool in message.tools) _ToolCard(tool: tool),
        ],
      ),
    );
  }
}

/// One tool call card (endpoint 6): the tool name, its state, its input, and
/// its error when it failed.
class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.tool});

  final ToolCall tool;

  String get _inputText {
    final input = tool.input;
    if (input == null) return '';
    if (input is String) return input;
    try {
      return jsonEncode(input);
    } catch (_) {
      return '$input';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, iconColor) = switch (tool.status) {
      'streaming' || 'running' => (Icons.pending, Colors.orange),
      'completed' => (Icons.check_circle, Colors.green),
      'error' => (Icons.error, scheme.error),
      _ => (Icons.build_outlined, scheme.outline),
    };
    return Container(
      key: ValueKey('tool-${tool.name}-${tool.status}'),
      margin: const EdgeInsets.only(left: 4, top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${tool.name} · ${tool.status}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (_inputText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 24),
              child: Text(
                _inputText,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: scheme.outline,
                ),
              ),
            ),
          if (tool.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 24),
              child: Text(
                tool.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// The prompt input (endpoint 7), enabled at any time: the field is never
/// disabled and the send button is only busy while a send is in flight.
/// A mid-turn prompt is queued by the service (`delivery: steer`).
class _PromptBar extends StatelessWidget {
  const _PromptBar({
    required this.controller,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool busy;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('structured-prompt'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('structured-prompt-input'),
              controller: controller,
              enabled: true,
              decoration: const InputDecoration(
                hintText: 'Send a message…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('structured-prompt-send'),
            onPressed: busy ? null : onSend,
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send'),
          ),
        ],
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.outline),
    ),
  );
}
