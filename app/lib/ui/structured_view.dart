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
/// The cost bar refreshes live on `session.usage.updated` (§8); the
/// permission banner stays live on `permission.asked` /
/// `permission.replied` (§8); the history refreshes on turn boundaries
/// (`session.execution.*`). Events arrive on the shared [EventSource] stream
/// and are filtered to this session by its durable aggregate id.
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

  StreamSubscription<BridgeEvent>? _events;

  final TextEditingController _prompt = TextEditingController();

  @override
  void initState() {
    super.initState();
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
    super.dispose();
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
      });
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

  /// Routes the live events of this session (§8) to the state they refresh:
  /// `session.usage.updated` the cost bar, `permission.asked` /
  /// `permission.replied` the banner, `session.execution.*` the history.
  void _onEvent(BridgeEvent event) {
    if (!_forSession(event)) return;
    switch (event.type) {
      case 'session.usage.updated':
        _refreshDetail();
      case 'permission.asked':
      case 'permission.replied':
        _refreshPermissions();
      case 'session.execution.started':
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.interrupted':
        _refreshMessages();
      default:
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

  /// Re-fetches the detail (endpoint 5): the live `session.usage.updated`
  /// refresh of the cost bar. A transient failure keeps the last detail.
  Future<void> _refreshDetail() async {
    try {
      final detail = await widget.client.getDetail(widget.sessionId);
      if (!mounted) return;
      setState(() => _detail = detail);
    } on SessionsClientError {
      // Transient (e.g. the service restarted): the next event or action
      // re-fetches. The last detail stays on screen.
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

  /// Re-fetches the history (endpoint 6): the turn boundary just ended or
  /// started, so the messages / tools in flight changed.
  Future<void> _refreshMessages() async {
    try {
      final messages = await widget.client.getMessages(widget.sessionId);
      if (!mounted) return;
      setState(() => _messages = messages);
    } on SessionsClientError {
      // Keep the last history on screen.
    }
  }

  /// Sends the prompt (endpoint 7), enabled at any time: the bridge forwards
  /// it with `delivery: steer` and the service queues it mid-turn.
  Future<void> _sendPrompt() async {
    final text = _prompt.text.trim();
    if (text.isEmpty || _promptBusy) return;
    setState(() => _promptBusy = true);
    try {
      await widget.client.prompt(widget.sessionId, text);
      _prompt.clear();
      await _refreshMessages();
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
                _CostBar(detail: _detail),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    children: [
                      if (_messages.isEmpty)
                        const _CenteredMessage(text: 'No messages yet.'),
                      for (final message in _messages)
                        _MessagePane(message: message),
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

/// The live cost bar: the session's cost in USD plus its token usage
/// (endpoint 5), refreshed by `session.usage.updated` (§8).
class _CostBar extends StatelessWidget {
  const _CostBar({required this.detail});

  final SessionDetail? detail;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) return const SizedBox.shrink();
    final tokens = detail.tokens;
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
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Cost \$${detail.cost.toStringAsFixed(4)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            '${tokens.input} in · ${tokens.output} out · '
            '${tokens.reasoning} reasoning · '
            '${tokens.cacheRead} cache read · ${tokens.cacheWrite} cache write',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (detail.outcome != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: Text(
                detail.outcome!,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One message of the history (endpoint 6): the text, then the assistant's
/// tool calls (in flight or finished).
class _MessagePane extends StatelessWidget {
  const _MessagePane({required this.message});

  final SessionMessage message;

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
            isUser ? 'You' : 'Assistant',
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
