import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/command.dart';
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
const _detailModel = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  model: ModelRef(
    id: 'flint-40b-free',
    providerId: 'opencode',
    variant: 'medium',
  ),
  agent: 'plan',
);
const _detailAgentPlan = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  agent: 'plan',
);
const _detailAgentBuild = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  agent: 'build',
);
const _detailVarNone = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  model: ModelRef(id: 'mod1', providerId: 'prov1'),
);
const _detailVarLow = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  model: ModelRef(id: 'mod1', providerId: 'prov1', variant: 'low'),
);
const _detailVarMedium = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  model: ModelRef(id: 'mod1', providerId: 'prov1', variant: 'medium'),
);
const _detailVarHigh = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  model: ModelRef(id: 'mod1', providerId: 'prov1', variant: 'high'),
);

/// A long, uneven history (a short first half, a long second half): enough
/// to be far longer than the viewport, so the anchor (the newest message)
/// is well clear of the oldest, and the lazy list only builds the tail that
/// is actually on screen.
final List<SessionMessage> _longHistory = List.generate(
  400,
  (i) => SessionMessage(
    role: i.isEven ? 'user' : 'assistant',
    text: i < 200
        ? 'message $i'
        : 'message $i ${List.filled(12, 'lorem ipsum dolor sit amet').join(' ')}',
  ),
);

/// A scripted [SessionsClient] for the structured view tests.
class _FakeClient extends SessionsClient {
  _FakeClient({
    this.details = const [],
    this.messages = const [],
    this.messageLists = const [],
    this.permissionLists = const [],
    this.promptError,
    this.commands = const [],
    this.models = const [],
    this.runCommandError,
    this.currentModels = const <ModelRef?>[null],
  }) : super(Uri.parse('http://bridge.test/'));

  /// The project's custom commands (`listCommands`), for the `/` menu.
  final List<OpencodeCommand> commands;

  /// The model registry (`listModels`), for the `/models` picker.
  final List<ModelOption> models;

  /// Thrown from `runCommand` when set.
  Object? runCommandError;

  final List<(String, String, String)> commandsRun = [];

  final List<(String, String)> renames = [];

  final List<ModelRef> setModels = [];

  /// The agents set (the Tab mode toggle): (sessionId, agentId) pairs.
  final List<(String, String)> agents = [];

  /// Per-call current models (the Ctrl+T variant cycle): the n-th call
  /// returns the n-th ref, the last ref repeats.
  final List<ModelRef?> currentModels;

  int currentModelCalls = 0;

  int compacts = 0;
  int mcpsCalls = 0;
  int commandCalls = 0;

  @override
  Future<List<OpencodeCommand>> listCommands(String id) async {
    commandCalls++;
    return commands;
  }

  @override
  Future<void> runCommand(String id, String name, String text) async {
    final error = runCommandError;
    if (error is Object) throw error;
    commandsRun.add((id, name, text));
  }

  @override
  Future<void> rename(String id, String title) async {
    renames.add((id, title));
  }

  @override
  Future<void> compact(String id) async {
    compacts++;
  }

  @override
  Future<String> mcps() async {
    mcpsCalls++;
    return '{"servers":[]}';
  }

  @override
  Future<List<ModelOption>> listModels(String id) async => models;

  @override
  Future<void> setModel(String id, ModelRef model) async {
    setModels.add(model);
  }

  @override
  Future<void> setAgent(String id, String agentId) async {
    agents.add((id, agentId));
  }

  @override
  Future<ModelRef?> currentModel(String id) async {
    currentModelCalls++;
    final index = currentModelCalls - 1 < currentModels.length
        ? currentModelCalls - 1
        : currentModels.length - 1;
    return currentModels[index];
  }

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

const _promptInput = ValueKey('structured-prompt-input');

Finder _menuFinder() => find.byKey(const ValueKey('structured-command-menu'));

/// The menu list's scroll offset in pixels.
double _menuScrollPixels(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _menuFinder(), matching: find.byType(Scrollable)),
    )
    .position
    .pixels;

Finder _commandRowFinder(String name) =>
    find.byKey(ValueKey('structured-command-row-$name'));

Future<void> _typePrompt(WidgetTester tester, String text) =>
    tester.enterText(find.byKey(_promptInput), text);

Future<void> _pressEnter(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  await tester.pump();
}

String _promptText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_promptInput)).controller!.text;

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

    testWidgets('the header shows the llama.cpp prefill and decode speed '
        'from llama.speed, and clears it when idle', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      final events = await _pump(tester, client: client);

      expect(find.byKey(const ValueKey('structured-speed')), findsNothing);

      events.add(
        _event('llama.speed', data: const {'prefill': 1200.0, 'decode': null}),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('prefill 1200 tok/s'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('prefill 1200 tok/s')).style?.color,
        const Color(0xFF318795),
        reason: 'prefill is drawn in the TUI theme info color (light)',
      );

      events.add(
        _event('llama.speed', data: const {'prefill': null, 'decode': 45.5}),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('decode 45.5 tok/s'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('decode 45.5 tok/s')).style?.color,
        const Color(0xFF3D9A57),
        reason: 'decode is drawn in the TUI theme success color (light)',
      );

      events.add(
        _event('llama.speed', data: const {'prefill': null, 'decode': null}),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('structured-speed')), findsNothing);
    });

    testWidgets('the header shows the model, variant, and mode chips', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detailModel]);
      await _pump(tester, client: client);

      expect(find.text('opencode/flint-40b-free'), findsOneWidget);
      expect(find.text('medium'), findsOneWidget);
      expect(find.text('plan'), findsOneWidget);
      expect(find.byKey(const ValueKey('structured-model')), findsOneWidget);
      expect(find.byKey(const ValueKey('structured-variant')), findsOneWidget);
      expect(find.byKey(const ValueKey('structured-mode')), findsOneWidget);
    });

    testWidgets(
      'the header shows no model, variant, or mode chips when unset',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client);

        expect(find.byKey(const ValueKey('structured-model')), findsNothing);
        expect(find.byKey(const ValueKey('structured-variant')), findsNothing);
        expect(find.byKey(const ValueKey('structured-mode')), findsNothing);
      },
    );

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

    testWidgets('an edit tool renders its file patch like the terminal', (
      tester,
    ) async {
      const patch =
          'Index: my/file.dart\n'
          '===================================================================\n'
          '--- my/file.dart\n'
          '+++ my/file.dart\n'
          '@@ -1,2 +1,2 @@\n'
          ' keep\n'
          '-old line\n'
          '+new line\n';
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(
            id: 'm1',
            role: 'assistant',
            tools: [
              ToolCall(
                id: 't1',
                name: 'edit',
                status: 'completed',
                input: {
                  'path': 'my/file.dart',
                  'oldString': 'old line',
                  'newString': 'new line',
                },
                patch: patch,
              ),
            ],
          ),
        ],
      );
      await _pump(tester, client: client);

      expect(find.text('my/file.dart'), findsOneWidget);
      // The context line, the removed line, and the added line.
      expect(find.text('keep'), findsOneWidget);
      final removed = tester.widget<Text>(find.text('old line'));
      expect(removed.style?.color, const Color(0xFFC53B53));
      final added = tester.widget<Text>(find.text('new line'));
      expect(added.style?.color, const Color(0xFF1E725C));
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
      expect(find.text('10 in · 20 out'), findsOneWidget);
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

    testWidgets('a live write renders its content as a diff', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      final events = await _pump(tester, client: client);

      events.add(
        _event(
          'session.tool.input.started',
          aggregateID: 'ses_1',
          data: const {
            'assistantMessageID': 'msg_1',
            'id': 'w1',
            'name': 'write',
          },
        ),
      );
      events.add(
        _event(
          'session.tool.called',
          aggregateID: 'ses_1',
          data: {
            'assistantMessageID': 'msg_1',
            'id': 'w1',
            // The called event carries the input object (the write's path and
            // full content), the same shape the service returns.
            'input': <String, Object?>{
              'path': '/w.txt',
              'content': 'alpha\nbeta\n',
            },
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      events.add(
        _event(
          'session.tool.success',
          aggregateID: 'ses_1',
          data: const {'assistantMessageID': 'msg_1', 'id': 'w1'},
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('write · completed'), findsOneWidget);
      // The content renders as an added-line diff, not the raw input JSON.
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
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

    testWidgets('inline code renders in the body font size', (tester) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(role: 'assistant', text: 'see `cached_tokens` here'),
        ],
      );
      final events = await _pump(tester, client: client);
      await events.close();

      final text = tester.widget<Text>(find.text('see cached_tokens here'));
      TextStyle merged = const TextStyle();
      double? bodySize;
      double? codeSize;
      void walk(InlineSpan span) {
        if (span is! TextSpan) return;
        merged = merged.merge(span.style);
        final leaf = span.children == null || span.children!.isEmpty;
        if (leaf) {
          if (span.text == 'cached_tokens') {
            codeSize = merged.fontSize;
          } else {
            bodySize ??= merged.fontSize;
          }
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }

      walk(text.textSpan!);
      expect(codeSize, isNotNull);
      expect(codeSize, bodySize);
    });

    testWidgets('the user prompt is set off from the assistant text', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [SessionMessage(role: 'user', text: 'fix the tests')],
      );
      final events = await _pump(tester, client: client);
      await events.close();

      BoxDecoration? decoration;
      for (final element
          in find
              .ancestor(
                of: find.text('fix the tests'),
                matching: find.byType(Container),
              )
              .evaluate()) {
        final widget = element.widget as Container;
        if (widget.decoration is BoxDecoration) {
          decoration = widget.decoration as BoxDecoration;
          break;
        }
      }
      expect(decoration, isNotNull);
      final border = decoration!.border as Border;
      expect(border.left, isA<BorderSide>());
    });

    testWidgets(
      'opening a long conversation lands on the last message immediately',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messages: _longHistory,
        );
        await _pump(tester, client: client);
        // A few frames in — not a settle — the newest message is already on
        // screen: it is the list's anchor (offset 0), so the open lands on it
        // for free, with no crawl down to the bottom.
        await tester.pump();
        await tester.pump();
        expect(find.textContaining('message 399 '), findsOneWidget);
        // The oldest message is far up the history, out of the viewport.
        expect(find.textContaining('message 0'), findsNothing);
      },
    );

    testWidgets(
      'a jump-to-end button appears when scrolled up and returns to the end',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messages: _longHistory,
        );
        await _pump(tester, client: client);
        await tester.pumpAndSettle();

        final button = find.byKey(const ValueKey('structured-jump-to-end'));
        expect(button, findsNothing);
        expect(find.textContaining('message 399 '), findsOneWidget);

        await tester.drag(find.byType(ListView), const Offset(0, 600));
        await tester.pump();
        expect(button, findsOneWidget);

        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(button, findsNothing);
        expect(find.textContaining('message 399 '), findsOneWidget);
      },
    );

    testWidgets('scrolling up pulls the earlier messages into view', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: _longHistory,
      );
      await _pump(tester, client: client);
      await tester.pump();

      // At the anchor, the newest is on screen; the earliest is far away.
      expect(find.textContaining('message 399 '), findsOneWidget);
      expect(find.textContaining('message 0'), findsNothing);

      // Scroll up (read older) until the earliest message is pulled in: the
      // lazy list builds the earlier messages as the viewport advances.
      for (
        var i = 0;
        i < 80 && find.textContaining('message 0').evaluate().isEmpty;
        i++
      ) {
        await tester.drag(find.byType(ListView), const Offset(0, 1000));
        await tester.pumpAndSettle();
      }

      expect(find.textContaining('message 0'), findsOneWidget);
    });
  });

  group('StructuredSessionScreen `/` command menu (issue #46)', () {
    testWidgets('typing / at the start opens the menu with the built-ins', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      expect(_menuFinder(), findsNothing);
      await _typePrompt(tester, '/');
      await tester.pump();

      expect(_menuFinder(), findsOneWidget);
      // The menu list is lazy (max 280px): assert the rows in view, the
      // catalog's top.
      expect(_commandRowFinder('models'), findsOneWidget);
      expect(_commandRowFinder('agents'), findsOneWidget);
      expect(_commandRowFinder('compact'), findsOneWidget);
      expect(client.commandCalls, 1);

      // A further keystroke does not re-fetch the project commands.
      await _typePrompt(tester, '/mod');
      await tester.pump();
      expect(client.commandCalls, 1);
    });

    testWidgets(
      'the menu renders as a card (background, border, rounded, shadowed)',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client);
        await _typePrompt(tester, '/');
        await tester.pump();

        final card = tester.widget<Container>(
          find.byKey(const ValueKey('structured-command-menu-card')),
        );
        expect(card.decoration, isA<BoxDecoration>());
        final decoration = card.decoration! as BoxDecoration;
        expect(decoration.color, isNotNull);
        expect(decoration.border, isA<Border>());
        expect(decoration.borderRadius, isNotNull);
        expect(decoration.boxShadow, isNotEmpty);
      },
    );

    testWidgets('the empty menu keeps its card and the no-match line', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/zzz');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsOneWidget,
      );
      expect(find.text('No matching command'), findsOneWidget);
    });

    testWidgets('the menu live-filters by name and alias prefix', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/COMP');
      await tester.pump();
      expect(_commandRowFinder('compact'), findsOneWidget);
      expect(_commandRowFinder('models'), findsNothing);

      await _typePrompt(tester, '/eff');
      await tester.pump();
      expect(_commandRowFinder('variants'), findsOneWidget);
      expect(_commandRowFinder('undo'), findsNothing);
    });

    testWidgets('a slash mid-text does not open the menu', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, 'use a/b');
      await tester.pump();

      expect(_menuFinder(), findsNothing);
    });

    testWidgets('a non-matching prefix shows the note and Enter stays put', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/zzz');
      await tester.pump();
      expect(find.text('No matching command'), findsOneWidget);

      await _pressEnter(tester);

      expect(client.prompts, isEmpty);
      expect(_promptText(tester), '/zzz');
    });

    testWidgets(
      'the project commands are fetched when the menu opens and merged in',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          commands: const [
            OpencodeCommand(name: 'deploy', description: 'ship it'),
          ],
        );
        await _pump(tester, client: client);

        await _typePrompt(tester, '/deploy');
        await tester.pump();
        await tester.pump();

        expect(_commandRowFinder('deploy'), findsOneWidget);
        expect(find.text('ship it'), findsOneWidget);
        expect(find.text('custom'), findsOneWidget);
      },
    );

    testWidgets('Enter runs the selected command and clears the field', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/compact');
      await tester.pump();
      await _pressEnter(tester);

      expect(client.compacts, 1);
      expect(_promptText(tester), isEmpty);
    });

    testWidgets('an argument command waits for its argument, then runs', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/rename');
      await tester.pump();
      await _pressEnter(tester);

      expect(client.renames, isEmpty);
      expect(_promptText(tester), '/rename');

      await _typePrompt(tester, '/rename my title');
      await tester.pump();
      await _pressEnter(tester);

      expect(client.renames, const [('ses_1', 'my title')]);
      expect(find.text('my title'), findsOneWidget);
    });

    testWidgets('arrow keys move the selection; Enter runs the moved row', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/m');
      await tester.pump();
      expect(_commandRowFinder('models'), findsOneWidget);
      expect(_commandRowFinder('mcps'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await _pressEnter(tester);

      expect(client.mcpsCalls, 1);
      expect(_promptText(tester), isEmpty);
      expect(find.text('MCP servers'), findsOneWidget);
    });

    testWidgets(
      'up moves the selection up one row, without jumping to the top',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client);

        await _typePrompt(tester, '/');
        await tester.pump();
        expect(_menuFinder(), findsOneWidget);

        // Four downs select `undo` (catalog index 4)…
        for (var i = 0; i < 4; i++) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        // …one up returns to `compact` (index 3) — not the top row. The arrows
        // must not move the field's cursor: it stays at the end of the text.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();

        final editable = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        expect(
          editable.textEditingValue.selection,
          const TextSelection.collapsed(offset: 1),
          reason: 'the menu owns the arrows; the field cursor stays put',
        );

        await _pressEnter(tester);
        await tester.pump();

        expect(
          client.compacts,
          1,
          reason: 'up must land on `compact` (one up)',
        );
        expect(_promptText(tester), isEmpty);
      },
    );

    testWidgets('a down after an up moves one row, it is not swallowed', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/');
      await tester.pump();

      // Down to `compact` (index 3), up to `variants` (index 2)…
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      // …and a single down returns to `compact`: the first down after an up
      // must not be eaten by the field's cursor moving.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      await _pressEnter(tester);
      await tester.pump();

      expect(client.compacts, 1, reason: 'the down after the up must run');
      expect(_promptText(tester), isEmpty);
    });

    testWidgets('the selection highlight runs edge to edge of the card', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/');
      await tester.pump();

      // The highlight is the row's background: it spans the whole card
      // width, with no padding on either side of it.
      final row = tester.getRect(_commandRowFinder('models'));
      final list = tester.getRect(_menuFinder());
      expect(
        row.left,
        list.left,
        reason: 'no left padding around the highlight',
      );
      expect(
        row.right,
        list.right,
        reason: 'no right padding around the highlight',
      );
    });

    testWidgets('the menu scrolls to keep the keyboard selection visible', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/');
      await tester.pump();

      // Eight downs select `export` (catalog index 8) — past the visible
      // part of the menu: the list must scroll to keep it on screen.
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump(); // the post-frame scroll
      }

      expect(_menuScrollPixels(tester), greaterThan(0));

      final row = tester.getRect(_commandRowFinder('export'));
      final card = tester.getRect(
        find.byKey(const ValueKey('structured-command-menu-card')),
      );
      expect(row.top, greaterThanOrEqualTo(card.top));
      expect(row.bottom, lessThanOrEqualTo(card.bottom));
    });

    testWidgets('re-typing the token brings the menu back to the top', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        commands: const [
          OpencodeCommand(name: 'zebra', description: 'a'),
          OpencodeCommand(name: 'zoo', description: 'b'),
          OpencodeCommand(name: 'zulu', description: 'c'),
          OpencodeCommand(name: 'zero', description: 'd'),
          OpencodeCommand(name: 'zone', description: 'e'),
          OpencodeCommand(name: 'zoom', description: 'f'),
          OpencodeCommand(name: 'zest', description: 'g'),
          OpencodeCommand(name: 'zip', description: 'h'),
        ],
      );
      await _pump(tester, client: client);

      await _typePrompt(tester, '/z');
      await tester.pump();
      await tester.pump(); // the custom commands arrive

      for (var i = 0; i < 7; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump();
      }
      expect(_menuScrollPixels(tester), greaterThan(0));

      // Back to the bare slash: the selection resets to the top row, and
      // the menu scrolls back with it.
      await _typePrompt(tester, '/');
      await tester.pump();
      await tester.pump();
      expect(_menuScrollPixels(tester), 0);
    });

    testWidgets('Esc closes the menu by clearing the field', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/models');
      await tester.pump();
      expect(_menuFinder(), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(_promptText(tester), isEmpty);
      expect(_menuFinder(), findsNothing);
    });

    testWidgets('a custom command runs with the typed argument', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        commands: const [
          OpencodeCommand(name: 'deploy', description: 'ship it'),
        ],
      );
      await _pump(tester, client: client);

      await _typePrompt(tester, '/deploy prod');
      await tester.pump();
      await tester.pump();
      await _pressEnter(tester);

      expect(client.commandsRun, const [('ses_1', 'deploy', 'prod')]);
      expect(_promptText(tester), isEmpty);
      expect(find.text('Sent /deploy to the session.'), findsOneWidget);
    });

    testWidgets('a failed custom command reports the error', (tester) async {
      final client = _FakeClient(
        details: const [_detail0],
        commands: const [
          OpencodeCommand(name: 'deploy', description: 'ship it'),
        ],
        runCommandError: const SessionsClientError(404, 'not found'),
      );
      await _pump(tester, client: client);

      await _typePrompt(tester, '/deploy prod');
      await tester.pump();
      await tester.pump();
      await _pressEnter(tester);

      expect(client.commandsRun, isEmpty);
      expect(find.text('Could not run /deploy (status 404).'), findsOneWidget);
    });

    testWidgets('`/models` opens the picker; picking sets the model', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        models: const [
          ModelOption(
            id: 'mod1',
            providerId: 'prov1',
            name: 'Model One',
            variants: [],
          ),
        ],
      );
      await _pump(tester, client: client);

      await _typePrompt(tester, '/models');
      await tester.pump();
      await _pressEnter(tester);

      expect(find.text('Switch model'), findsOneWidget);
      await tester.tap(find.text('Model One'));
      await tester.pump();
      await tester.pump();

      expect(client.setModels, const [
        ModelRef(id: 'mod1', providerId: 'prov1'),
      ]);
      expect(find.text('Model set to Model One.'), findsOneWidget);
    });

    testWidgets('the pickers filter their rows with the search field', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        models: const [
          ModelOption(
            id: 'mod1',
            providerId: 'prov1',
            name: 'Model One',
            variants: [],
          ),
          ModelOption(
            id: 'mod2',
            providerId: 'prov2',
            name: 'Model Two',
            variants: [],
          ),
        ],
      );
      await _pump(tester, client: client);

      await _typePrompt(tester, '/models');
      await tester.pump();
      await _pressEnter(tester);

      expect(find.text('Switch model'), findsOneWidget);
      expect(find.text('Model One'), findsOneWidget);
      expect(find.text('Model Two'), findsOneWidget);

      // Typing filters the rows live (the label, case-insensitive).
      await tester.enterText(
        find.byKey(const ValueKey('structured-pick-search')),
        'two',
      );
      await tester.pump();
      expect(find.text('Model One'), findsNothing);
      expect(find.text('Model Two'), findsOneWidget);

      // The hint (the provider) filters too.
      await tester.enterText(
        find.byKey(const ValueKey('structured-pick-search')),
        'prov2',
      );
      await tester.pump();
      expect(find.text('Model One'), findsNothing);
      expect(find.text('Model Two'), findsOneWidget);

      // No match: the rows are replaced by the no-match line.
      await tester.enterText(
        find.byKey(const ValueKey('structured-pick-search')),
        'zzz',
      );
      await tester.pump();
      expect(find.text('Model One'), findsNothing);
      expect(find.text('Model Two'), findsNothing);
      expect(find.text('No match.'), findsOneWidget);
    });

    testWidgets('the picker search picks the first filtered row on Enter', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        models: const [
          ModelOption(
            id: 'mod1',
            providerId: 'prov1',
            name: 'Model One',
            variants: [],
          ),
          ModelOption(
            id: 'mod2',
            providerId: 'prov2',
            name: 'Model Two',
            variants: [],
          ),
        ],
      );
      await _pump(tester, client: client);

      await _typePrompt(tester, '/models');
      await tester.pump();
      await _pressEnter(tester);

      expect(find.text('Switch model'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('structured-pick-search')),
        'one',
      );
      await tester.pump();
      await _pressEnter(tester);
      await tester.pump();

      expect(client.setModels, const [
        ModelRef(id: 'mod1', providerId: 'prov1'),
      ]);
      expect(find.text('Model set to Model One.'), findsOneWidget);
    });

    testWidgets('`/help` lists the commands', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/help');
      await tester.pump();
      await _pressEnter(tester);

      expect(find.text('Commands'), findsOneWidget);
      expect(find.textContaining('/rename'), findsOneWidget);
    });

    testWidgets('`/clear` without a navigation wired reports it', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '/clear');
      await tester.pump();
      await _pressEnter(tester);

      expect(find.text('Not available from this screen.'), findsOneWidget);
    });
  });

  group('StructuredSessionScreen mode and variant keys (issue #46)', () {
    Future<void> pressControlT(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Tab toggles the mode, but not while the menu is open', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0, _detailAgentPlan, _detailAgentBuild],
      );
      await _pump(tester, client: client);

      // The menu open: Tab is the focus navigation, not a mode toggle.
      await _typePrompt(tester, '/models');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(client.agents, isEmpty);

      // Esc closes the menu and clears the field; from there on, Tab
      // toggles the mode (unset to plan, plan to build).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump();

      expect(client.agents, const [('ses_1', 'plan')]);
      expect(find.text('Mode: plan.'), findsOneWidget);
      expect(find.text('plan'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump();

      expect(client.agents, const [('ses_1', 'plan'), ('ses_1', 'build')]);
      expect(find.text('Mode: build.'), findsOneWidget);
      expect(find.text('build'), findsOneWidget);
      // The keys consumed the events: nothing was typed in the field.
      expect(_promptText(tester), isEmpty);
    });

    testWidgets('Ctrl+T cycles the current model variant, wrapping to none', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [
          _detailVarNone,
          _detailVarLow,
          _detailVarMedium,
          _detailVarHigh,
          _detailVarNone,
        ],
        models: const [
          ModelOption(
            id: 'mod1',
            providerId: 'prov1',
            name: 'Model One',
            variants: ['low', 'medium', 'high'],
          ),
        ],
        currentModels: const [
          ModelRef(id: 'mod1', providerId: 'prov1'),
          ModelRef(id: 'mod1', providerId: 'prov1', variant: 'low'),
          ModelRef(id: 'mod1', providerId: 'prov1', variant: 'medium'),
          ModelRef(id: 'mod1', providerId: 'prov1', variant: 'high'),
        ],
      );
      await _pump(tester, client: client);

      await tester.tap(find.byKey(_promptInput));
      await tester.pump();

      // A bare T is a character, not the shortcut: no cycle, no insertion.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyT);
      await tester.pump();
      expect(client.currentModelCalls, 0);
      expect(client.setModels, isEmpty);
      expect(_promptText(tester), isEmpty);

      // The model chip is the session's model from the detail.
      expect(find.text('prov1/mod1'), findsOneWidget);

      await pressControlT(tester);
      expect(find.text('Variant set to low.'), findsOneWidget);
      expect(find.text('low'), findsOneWidget);

      await pressControlT(tester);
      expect(find.text('Variant set to medium.'), findsOneWidget);
      expect(find.text('medium'), findsOneWidget);

      await pressControlT(tester);
      expect(find.text('Variant set to high.'), findsOneWidget);
      expect(find.text('high'), findsOneWidget);

      // High is the last variant: it cycles back to none (the model is set
      // without a variant).
      await pressControlT(tester);
      expect(client.setModels, const [
        ModelRef(id: 'mod1', providerId: 'prov1', variant: 'low'),
        ModelRef(id: 'mod1', providerId: 'prov1', variant: 'medium'),
        ModelRef(id: 'mod1', providerId: 'prov1', variant: 'high'),
        ModelRef(id: 'mod1', providerId: 'prov1'),
      ]);
      expect(find.text('Variant set to none.'), findsOneWidget);
      expect(find.byKey(const ValueKey('structured-variant')), findsNothing);
    });

    testWidgets('Ctrl+T with no session model reports it and sets nothing', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await tester.tap(find.byKey(_promptInput));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();

      expect(client.setModels, isEmpty);
      expect(find.text('No model set for the session.'), findsOneWidget);
    });
  });
}
