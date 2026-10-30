import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/ui/structured_view.dart';

const _zero = TokenUsage(
  input: 0,
  output: 0,
  reasoning: 0,
  cacheRead: 0,
  cacheWrite: 0,
);
const _detail0 = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
);
const _detailCtx = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  contextLimit: 100,
);

/// A scripted [SessionsClient] for the structured view tests.
class _FakeClient extends SessionsClient {
  _FakeClient({
    this.details = const [],
    this.messages = const [],
    this.messageLists = const [],
    this.permissionLists = const [],
    this.promptError,
  }) : super(Uri.parse('http://bridge.test/'));

  /// Per-call details: the n-th call returns the n-th detail, the last
  /// detail repeats.
  final List<SessionDetail> details;

  /// The history when [messageLists] is empty.
  final List<SessionMessage> messages;

  /// Per-call histories: the n-th call returns the n-th list, the last
  /// repeats.
  final List<List<SessionMessage>> messageLists;

  /// Per-call pending lists: the n-th call returns the n-th list, the last
  /// repeats.
  final List<List<PermissionRequest>> permissionLists;

  final List<(String, String)> prompts = [];

  final List<(String, String, PermissionReply)> replies = [];

  int detailCalls = 0;
  int messageCalls = 0;
  int permissionCalls = 0;

  Object? promptError;
  Object? replyError;

  @override
  Future<SessionDetail> getDetail(String id) async {
    detailCalls++;
    final index = detailCalls - 1 < details.length
        ? detailCalls - 1
        : details.length - 1;
    return details[index];
  }

  @override
  Future<List<SessionMessage>> getMessages(String id) async {
    messageCalls++;
    if (messageLists.isEmpty) return messages;
    final index = messageCalls - 1 < messageLists.length
        ? messageCalls - 1
        : messageLists.length - 1;
    return messageLists[index];
  }

  @override
  Future<void> prompt(String id, String text) async {
    final error = promptError;
    if (error is Object) throw error;
    prompts.add((id, text));
  }

  @override
  Future<List<PermissionRequest>> getPermissions(String id) async {
    permissionCalls++;
    if (permissionLists.isEmpty) return const [];
    final index = permissionCalls - 1 < permissionLists.length
        ? permissionCalls - 1
        : permissionLists.length - 1;
    return permissionLists[index];
  }

  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {
    final error = replyError;
    if (error is Object) throw error;
    replies.add((id, requestID, reply));
  }
}

Future<StreamController<BridgeEvent>> _pump(
  WidgetTester tester, {
  required _FakeClient client,
  Stream<SessionGap>? gaps,
}) async {
  final events = StreamController<BridgeEvent>.broadcast();
  await tester.pumpWidget(
    MaterialApp(
      home: StructuredSessionScreen(
        sessionId: 'ses_1',
        title: 'external session',
        client: client,
        events: events.stream,
        gaps: gaps,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return events;
}

BridgeEvent _event(
  String type, {
  String? aggregateID,
  Map<String, Object?>? data,
}) => BridgeEvent(
  id: 'evt_$type',
  created: 1,
  type: type,
  data: data ?? const {},
  durable: aggregateID == null
      ? null
      : Durable(aggregateID: aggregateID, seq: 1),
);

void main() {
  group('StructuredSessionScreen', () {
    testWidgets('renders the history, the tools in flight, and the cost bar', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(role: 'user', text: 'fix the tests'),
          SessionMessage(
            role: 'assistant',
            tools: [
              ToolCall(
                name: 'shell',
                status: 'running',
                input: {'command': 'ls'},
              ),
            ],
          ),
        ],
      );
      await _pump(tester, client: client);

      expect(find.text('You'), findsOneWidget);
      expect(find.text('fix the tests'), findsOneWidget);
      expect(find.text('Assistant'), findsOneWidget);
      expect(find.text('shell · running'), findsOneWidget);
      expect(find.text('Cost \$0.0000'), findsOneWidget);
    });

    testWidgets('renders the compaction marker with the summary it wrote', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(role: 'user', text: 'do the thing'),
          SessionMessage(
            id: 'm4',
            role: 'compaction',
            text: '## Objective\n- the compressed context',
          ),
        ],
      );
      await _pump(tester, client: client);

      expect(find.text('Compacted context'), findsOneWidget);
      // The summary is rendered as markdown: the heading and the list item
      // are separate text nodes.
      expect(find.text('Objective'), findsOneWidget);
      expect(find.text('the compressed context'), findsOneWidget);
      // The heading carries the TUI's heading color (light palette), like
      // the terminal.
      final heading = tester.widget<Text>(find.text('Objective'));
      expect(heading.textSpan?.style?.color, const Color(0xFFD68C27));
    });

    testWidgets('session.compaction.delta streams the summary live, and '
        'session.compaction.ended settles it', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      final events = await _pump(tester, client: client);

      events.add(
        _event(
          'session.compaction.delta',
          aggregateID: 'ses_1',
          data: const {'text': '## Objective'},
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('Compacting…'), findsOneWidget);
      expect(find.text('Objective'), findsOneWidget);

      events.add(
        _event(
          'session.compaction.ended',
          aggregateID: 'ses_1',
          data: const {'text': '## Objective\n- done', 'reason': 'manual'},
        ),
      );
      await tester.pump();

      expect(find.text('Compacted context'), findsOneWidget);
      expect(find.text('Objective'), findsOneWidget);
      expect(find.text('done'), findsOneWidget);
    });

    testWidgets('sends the prompt, posts only the text, and clears the input', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await tester.enterText(
        find.byKey(const ValueKey('structured-prompt-input')),
        'keep going',
      );
      await tester.tap(find.byKey(const ValueKey('structured-prompt-send')));
      await tester.pump();

      expect(client.prompts, const [('ses_1', 'keep going')]);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('structured-prompt-input')),
      );
      expect(field.controller?.text, isEmpty);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('keep going'), findsOneWidget);
    });

    testWidgets('a prompt failure keeps the text and reports it', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        promptError: const SessionsClientError(502, 'opencode_unreachable'),
      );
      await _pump(tester, client: client);

      await tester.enterText(
        find.byKey(const ValueKey('structured-prompt-input')),
        'keep going',
      );
      await tester.tap(find.byKey(const ValueKey('structured-prompt-send')));
      await tester.pump();
      await tester.pump();

      expect(client.prompts, isEmpty);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('structured-prompt-input')),
      );
      expect(field.controller?.text, 'keep going');
      expect(
        find.text('Could not send the message (status 502).'),
        findsOneWidget,
      );
    });

    testWidgets('the input stays enabled mid-turn (tools in flight)', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(
            role: 'assistant',
            tools: [ToolCall(name: 'shell', status: 'running')],
          ),
        ],
      );
      await _pump(tester, client: client);

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('structured-prompt-input')),
      );
      expect(field.enabled, isTrue);
      final send = tester.widget<FilledButton>(
        find.byKey(const ValueKey('structured-prompt-send')),
      );
      expect(send.onPressed, isNotNull);
    });

    testWidgets(
      'permission.asked shows the banner; replying once records it and '
      'clears the banner',
      (tester) async {
        const request = PermissionRequest(
          id: 'per_1',
          action: 'shell',
          resources: ['rm -rf node_modules'],
        );
        final client = _FakeClient(
          details: const [_detail0],
          permissionLists: const [
            <PermissionRequest>[],
            <PermissionRequest>[request],
            <PermissionRequest>[],
          ],
        );
        final events = await _pump(tester, client: client);

        expect(find.byKey(const ValueKey('permission-banner')), findsNothing);

        events.add(_event('permission.asked', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();

        expect(find.text('Permission requested: shell'), findsOneWidget);
        expect(find.text('rm -rf node_modules'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('permission-once-per_1')));
        await tester.pump();
        await tester.pump();

        expect(client.replies, const [
          ('ses_1', 'per_1', PermissionReply.once),
        ]);
        expect(find.byKey(const ValueKey('permission-banner')), findsNothing);
      },
    );

    testWidgets('session.usage.updated moves the cost bar from the payload, '
        'without a re-fetch', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      final events = await _pump(tester, client: client);

      expect(find.text('Cost \$0.0000'), findsOneWidget);

      events.add(
        _event(
          'session.usage.updated',
          aggregateID: 'ses_1',
          data: const {
            'sessionID': 'ses_1',
            'cost': 0.0123,
            'tokens': {
              'input': 10,
              'output': 20,
              'reasoning': 0,
              'cache': {'read': 0, 'write': 0},
            },
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Cost \$0.0123'), findsOneWidget);
      expect(
        find.text(
          '10 in · 20 out · 0 reasoning · 0 cache read · 0 cache write',
        ),
        findsOneWidget,
      );
      expect(client.detailCalls, 1);
    });

    testWidgets('session.execution.succeeded refreshes the history', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messageLists: const [
          <SessionMessage>[],
          <SessionMessage>[SessionMessage(role: 'assistant', text: 'done')],
        ],
      );
      final events = await _pump(tester, client: client);

      expect(find.text('No messages yet.'), findsOneWidget);

      events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
      await tester.pump();
      await tester.pump();

      expect(find.text('done'), findsOneWidget);
    });

    testWidgets(
      'text deltas grow the in-flight message live, without a re-fetch',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        final events = await _pump(tester, client: client);

        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        events.add(
          _event(
            'session.text.started',
            aggregateID: 'ses_1',
            data: const {'assistantMessageID': 'msg_1'},
          ),
        );
        for (final delta in ['Hel', 'lo']) {
          events.add(
            _event(
              'session.text.delta',
              aggregateID: 'ses_1',
              data: {
                'assistantMessageID': 'msg_1',
                'ordinal': 0,
                'delta': delta,
              },
            ),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));

        expect(find.text('Assistant · working…'), findsOneWidget);
        expect(find.text('Hello'), findsOneWidget);
        expect(client.messageCalls, 1);
        expect(client.detailCalls, 1);
      },
    );

    testWidgets('reasoning and text parts stream into separate fields', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      final events = await _pump(tester, client: client);

      events.add(
        _event(
          'session.reasoning.started',
          aggregateID: 'ses_1',
          data: const {'assistantMessageID': 'msg_1'},
        ),
      );
      events.add(
        _event(
          'session.reasoning.delta',
          aggregateID: 'ses_1',
          data: const {
            'assistantMessageID': 'msg_1',
            'ordinal': 0,
            'delta': 'think',
          },
        ),
      );
      events.add(
        _event(
          'session.text.started',
          aggregateID: 'ses_1',
          data: const {'assistantMessageID': 'msg_1'},
        ),
      );
      events.add(
        _event(
          'session.text.delta',
          aggregateID: 'ses_1',
          data: const {
            'assistantMessageID': 'msg_1',
            'ordinal': 0,
            'delta': 'done',
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('think'), findsOneWidget);
      expect(find.text('done'), findsOneWidget);
      expect(
        find.text('think\ndone'),
        findsNothing,
        reason: 'reasoning and text never join into one block',
      );

      // The reasoning block is styled (gray) and indented to the left;
      // the text block is not. The markdown span carries the gray.
      final reasoningText = tester.widget<Text>(find.text('think'));
      expect(reasoningText.textSpan?.style?.color, isNotNull);
      final paddings = tester.widgetList<Padding>(
        find.ancestor(of: find.text('think'), matching: find.byType(Padding)),
      );
      expect(
        paddings.map((p) => p.padding),
        contains(const EdgeInsets.only(top: 2, left: 16)),
      );
      final textBlock = tester.widget<Text>(find.text('done'));
      expect(textBlock.style, isNull);
    });

    testWidgets(
      'a turn running when the view opens streams into the loaded message',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messages: const [
            SessionMessage(id: 'msg_1', role: 'assistant', text: 'Hel'),
          ],
        );
        final events = await _pump(tester, client: client);

        events.add(
          _event(
            'session.text.delta',
            aggregateID: 'ses_1',
            data: const {
              'assistantMessageID': 'msg_1',
              'ordinal': 0,
              'delta': 'lo',
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));

        expect(find.text('Hello'), findsOneWidget);
        expect(find.text('Assistant'), findsOneWidget);
        expect(client.messageCalls, 1);
      },
    );

    testWidgets(
      'deltas coalesce: buffered until the flush, one rebuild for a burst',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        final events = await _pump(tester, client: client);

        for (final delta in ['Hel', 'lo']) {
          events.add(
            _event(
              'session.text.delta',
              aggregateID: 'ses_1',
              data: {
                'assistantMessageID': 'msg_1',
                'ordinal': 0,
                'delta': delta,
              },
            ),
          );
        }
        // No flush has run: the burst sits in the buffer, unrendered.
        await tester.pump();
        expect(find.text('Hello'), findsNothing);
        // The flush period elapses: one rebuild applies the whole burst.
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.text('Hello'), findsOneWidget);
      },
    );

    testWidgets('a durable-seq gap for this session re-fetches the state', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      final gaps = StreamController<SessionGap>.broadcast();
      await _pump(tester, client: client, gaps: gaps.stream);
      expect(client.messageCalls, 1);

      gaps.add(
        const SessionGap(aggregateID: 'ses_other', lastSeen: 1, received: 3),
      );
      await tester.pump();
      expect(client.messageCalls, 1); // Another session: ignored.

      gaps.add(
        const SessionGap(aggregateID: 'ses_1', lastSeen: 1, received: 4),
      );
      await tester.pump();
      await tester.pump();
      expect(client.messageCalls, 2);
      await gaps.close();
    });

    testWidgets('tool events update the in-flight tool card live', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      final events = await _pump(tester, client: client);

      events.add(
        _event(
          'session.tool.input.started',
          aggregateID: 'ses_1',
          data: const {
            'assistantMessageID': 'msg_1',
            'id': 't1',
            'name': 'shell',
          },
        ),
      );
      events.add(
        _event(
          'session.tool.input.ended',
          aggregateID: 'ses_1',
          data: const {
            'assistantMessageID': 'msg_1',
            'id': 't1',
            'text': '{"command":"ls"}',
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('shell · running'), findsOneWidget);
      expect(find.text('{"command":"ls"}'), findsOneWidget);

      events.add(
        _event(
          'session.tool.success',
          aggregateID: 'ses_1',
          data: const {'assistantMessageID': 'msg_1', 'id': 't1'},
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('shell · completed'), findsOneWidget);
      expect(client.messageCalls, 1);
    });

    testWidgets(
      'step.ended records the context used against the detail limit',
      (tester) async {
        final client = _FakeClient(details: const [_detailCtx]);
        final events = await _pump(tester, client: client);

        expect(find.byKey(const ValueKey('structured-context')), findsNothing);

        events.add(
          _event(
            'session.step.ended',
            aggregateID: 'ses_1',
            data: const {
              'assistantMessageID': 'msg_1',
              'tokens': {
                'input': 30,
                'cache': {'read': 40, 'write': 30},
              },
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        // The context is the total input: input + cache reads and writes.
        expect(find.text('context 100 / 100 · 100%'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
      },
    );

    testWidgets('opening a session seeds the context from its history', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detailCtx],
        messages: const [
          SessionMessage(role: 'assistant', text: 'earlier', contextTokens: 55),
          SessionMessage(role: 'user', text: 'next'),
        ],
      );
      await _pump(tester, client: client);

      expect(find.text('context 55 / 100 · 55%'), findsOneWidget);
    });

    testWidgets('events of another session are ignored', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      final events = await _pump(tester, client: client);

      events.add(_event('session.usage.updated', aggregateID: 'ses_other'));
      events.add(_event('permission.asked', aggregateID: 'ses_other'));
      await tester.pump();
      await tester.pump();

      expect(client.detailCalls, 1);
      expect(client.permissionCalls, 1);
      expect(find.text('Cost \$0.0000'), findsOneWidget);
    });

    testWidgets(
      'an event without a durable is matched by the payload sessionID',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        final events = await _pump(tester, client: client);

        events.add(
          _event('permission.asked', data: const {'sessionID': 'ses_1'}),
        );
        await tester.pump();
        await tester.pump();

        expect(client.permissionCalls, 2);
      },
    );
  });
}
