import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:opencodebridge/ui/structured_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    this.promptGate,
    this.questionLists = const [],
    this.commands = const [],
    this.models = const [],
    this.skills = const [],
    this.filesFound = const [],
    this.runCommandError,
    this.currentModels = const <ModelRef?>[null],
  }) : super(Uri.parse('http://bridge.test/'));

  /// The project's custom commands (`listCommands`), for the `/` menu.
  final List<OpencodeCommand> commands;

  /// The session's skills (`listSkills`), for the `@` menu (issue #58).
  final List<SkillOption> skills;

  /// The files `findFiles` returns for every token, unless [fileResults]
  /// holds per-call lists.
  final List<String> filesFound;

  /// Per-call file lists (issue #58): the n-th call returns the n-th list,
  /// the last repeats — to hold a search in flight.
  List<List<String>> fileResults = const [];

  /// When set, `findFiles` awaits it before returning (the search held in
  /// flight).
  Completer<void>? findFilesGate;

  /// The file searches (issue #58): (sessionId, token) pairs.
  final List<(String, String)> fileQueries = [];

  int skillCalls = 0;

  @override
  Future<List<SkillOption>> listSkills(String id) async {
    skillCalls++;
    return skills;
  }

  @override
  Future<List<String>> findFiles(String id, String query) async {
    final index = fileQueries.length;
    fileQueries.add((id, query));
    final gate = findFilesGate;
    if (gate != null) await gate.future;
    if (fileResults.isEmpty) return filesFound;
    return fileResults[index < fileResults.length
        ? index
        : fileResults.length - 1];
  }

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

  /// When set, `prompt` awaits it before returning (the send POST held in
  /// flight, to sequence it against the events).
  Completer<void>? promptGate;

  final List<
    (String, String, List<Map<String, Object?>>?, List<Map<String, Object?>>?)
  >
  prompts = [];

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

  /// The paged read (issue #124): the scripted history served as a single
  /// newest page (no older page), so the view's bounded turn read takes it in
  /// one fetch. Mirrors [getMessages]' per-call behaviour and call count.
  @override
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) async {
    messageCalls++;
    final index = messageCalls - 1 < messageLists.length
        ? messageCalls - 1
        : messageLists.length - 1;
    final list = messageLists.isEmpty ? messages : messageLists[index];
    return MessagePage(messages: list, nextCursor: null);
  }

  @override
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async {
    final gate = promptGate;
    if (gate != null) await gate.future;
    final error = promptError;
    if (error is Object) throw error;
    prompts.add((id, text, files, skills));
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

  /// Per-call pending question forms (issue #50): the n-th call returns the
  /// n-th list, the last repeats.
  final List<List<QuestionForm>> questionLists;

  int questionCalls = 0;

  final List<(String, String, List<List<String>>)> questionAnswers = [];

  final List<(String, String)> questionDismissals = [];

  Object? questionError;

  @override
  Future<List<QuestionForm>> getQuestions(String id) async {
    questionCalls++;
    if (questionLists.isEmpty) return const [];
    final index = questionCalls - 1 < questionLists.length
        ? questionCalls - 1
        : questionLists.length - 1;
    return questionLists[index];
  }

  @override
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) async {
    final error = questionError;
    if (error is Object) throw error;
    questionAnswers.add((id, formID, answers));
  }

  @override
  Future<void> dismissQuestion(String id, String formID) async {
    final error = questionError;
    if (error is Object) throw error;
    questionDismissals.add((id, formID));
  }
}

/// A [SessionsClient] double serving a history newest-first in fixed pages
/// (issue #124's paged read): the view's bounded turn read and lazy older
/// loads walk the real cursor chain, counting every fetch.
class _PagedClient extends _FakeClient {
  _PagedClient({required this.history}) : super(details: const [_detail0]);

  final List<SessionMessage> history;

  /// Page size the history is served in.
  static const int pageSize = 4;

  /// Every `getMessagesPage` call, newest page first.
  int pageCalls = 0;

  @override
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) async {
    pageCalls++;
    final offset = cursor == null ? 0 : int.parse(cursor);
    final newestFirst = history.reversed.toList();
    final slice = newestFirst.skip(offset).take(pageSize).toList();
    final next = offset + pageSize < history.length
        ? '${offset + pageSize}'
        : null;
    // The page is chronological within itself (the real endpoint's contract).
    return MessagePage(messages: slice.reversed.toList(), nextCursor: next);
  }
}

Future<StreamController<BridgeEvent>> _pump(
  WidgetTester tester, {
  required _FakeClient client,
  Stream<SessionGap>? gaps,
  ClipboardImageReader? imageReader,
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
        imageReader: imageReader,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return events;
}

/// The app's root (issue #49): the MaterialApp follows the persisted theme
/// choice and re-themes in place when the choice changes — the callback
/// re-runs this build, exactly like `OpenCodeBridgeApp`.
class _ThemedRoot extends StatefulWidget {
  const _ThemedRoot({
    required this.client,
    required this.settings,
    required this.events,
    required this.onThemeModeChanged,
  });

  final SessionsClient client;
  final AppSettings settings;
  final Stream<BridgeEvent> events;
  final VoidCallback onThemeModeChanged;

  @override
  State<_ThemedRoot> createState() => _ThemedRootState();
}

class _ThemedRootState extends State<_ThemedRoot> {
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.light(),
    darkTheme: ThemeData.dark(),
    themeMode: widget.settings.themeMode,
    home: StructuredSessionScreen(
      sessionId: 'ses_1',
      title: 'external session',
      client: widget.client,
      events: widget.events,
      settings: widget.settings,
      onThemeModeChanged: () {
        widget.onThemeModeChanged();
        setState(() {});
      },
    ),
  );
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

/// Moves the field's caret to [offset] without changing the text.
void _setCaret(WidgetTester tester, int offset) {
  tester.widget<TextField>(find.byKey(_promptInput)).controller!.selection =
      TextSelection.collapsed(offset: offset);
}

/// The field's caret offset.
int _caret(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(_promptInput))
    .controller!
    .selection
    .baseOffset;

Future<void> _pressEnter(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  await tester.pump();
}

String _promptText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_promptInput)).controller!.text;

/// A faked clipboard image reader (issue #72): the n-th read returns the
/// n-th queued image, the last repeats; [error], when set, is thrown
/// instead. [failureMessage], when set, is reported on the no-image read.
/// Pass [read] to the screen as its [ClipboardImageReader].
class _FakeImageReader {
  _FakeImageReader(this.images);

  final List<ClipboardImage?> images;

  /// Thrown from the read when set.
  Object? error;

  /// The no-image read's [ClipboardImageRead.failureMessage] when set.
  String? failureMessage;

  int calls = 0;

  Future<ClipboardImageRead> read() async {
    calls++;
    final error = this.error;
    if (error is Object) throw error;
    return ClipboardImageRead(
      image: images.isEmpty
          ? null
          : images[calls - 1 < images.length ? calls - 1 : images.length - 1],
      failureMessage: failureMessage,
    );
  }
}

/// Mocks the platform clipboard's text (issue #72): `Clipboard.getData`
/// reads `{'text': text}`; the mock is cleared after the test.
void _setClipboardText(WidgetTester tester, String text) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') {
      return <String, String>{'text': text};
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

/// Ctrl+V on the focused prompt field (issue #72): the screen reads the
/// clipboard and inserts; the pumps flush the async read and the insertion.
Future<void> _pasteControlV(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  await tester.pump();
}

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

    testWidgets('a completed turn shows its stats footer (issue #121)', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(role: 'user', text: 'fix it', created: 0),
          SessionMessage(
            role: 'assistant',
            text: 'done',
            created: 0,
            streamed: 1000,
            completed: 1500,
            outputTokens: 80,
            reasoningTokens: 20,
          ),
          SessionMessage(id: 'i1', role: 'idle'),
        ],
      );
      await _pump(tester, client: client);

      // 0 -> 1500 is 1.5s; 100 tokens over 1s of streaming: 100.0 tok/s.
      expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
      expect(find.text('1.5s · 0 compactions · 100.0 tok/s'), findsOneWidget);
    });

    testWidgets('a turn with a compaction counts it in the footer', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(role: 'user', text: 'fix it', created: 0),
          SessionMessage(id: 'c1', role: 'compaction', text: 'the summary'),
          SessionMessage(
            role: 'assistant',
            text: 'done',
            created: 0,
            streamed: 1000,
            completed: 2000,
            outputTokens: 100,
            reasoningTokens: 0,
          ),
          SessionMessage(id: 'i1', role: 'idle'),
        ],
      );
      await _pump(tester, client: client);

      expect(find.text('2.0s · 1 compaction · 100.0 tok/s'), findsOneWidget);
      // The compaction marker itself keeps rendering.
      expect(find.text('the summary'), findsOneWidget);
    });

    testWidgets('a running turn shows no footer; the end brings it back', (
      tester,
    ) async {
      const history = [
        SessionMessage(role: 'user', text: 'go', created: 0),
        SessionMessage(
          role: 'assistant',
          text: 'done',
          created: 0,
          streamed: 1000,
          completed: 1500,
          outputTokens: 100,
        ),
        SessionMessage(id: 'i1', role: 'idle'),
      ];
      final client = _FakeClient(details: const [_detail0], messages: history);
      final events = await _pump(tester, client: client);
      expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);

      // The next turn starts: the frozen stats disappear while the agent
      // works (the live footer is issue #122).
      events.add(_event('session.execution.started', aggregateID: 'ses_1'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-stats')), findsNothing);

      // The turn ends and the normalize settles the history: the footer
      // comes back.
      events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
      await events.close();
    });

    testWidgets('a history without stats timestamps shows no footer', (
      tester,
    ) async {
      // A history whose steps carry no timestamps (a composed/legacy
      // history): the footer has nothing real to show.
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(role: 'user', text: 'no stats here'),
          SessionMessage(role: 'assistant', text: 'sure'),
        ],
      );
      await _pump(tester, client: client);
      expect(find.byKey(const ValueKey('turn-stats')), findsNothing);
    });

    testWidgets('a phone-sized screen shows the pending banner without '
        'overflowing', (tester) async {
      // A phone with the soft keyboard up: the body is squeezed to about
      // 360x487 (the VOG L29 log).
      tester.view.physicalSize = const Size(360, 543);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const request = PermissionRequest(
        id: 'per_1',
        action: 'shell',
        resources: ['rm -rf node_modules'],
      );
      final client = _FakeClient(
        details: const [_detail0],
        permissionLists: const [
          <PermissionRequest>[request],
        ],
      );
      await _pump(tester, client: client);

      // The banner's decision buttons wrap rather than run off the edge.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('permission-banner')), findsOneWidget);
    });

    testWidgets('a phone-sized screen with the keyboard up does not '
        'overflow', (tester) async {
      // A phone with the soft keyboard up: the body is squeezed to about
      // 360x487 (the VOG L29 log).
      tester.view.physicalSize = const Size(360, 543);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const request = PermissionRequest(
        id: 'per_1',
        action: 'shell',
        resources: ['rm -rf node_modules'],
      );
      final client = _FakeClient(
        details: const [_detail0],
        permissionLists: const [
          <PermissionRequest>[request],
        ],
      );
      await _pump(tester, client: client);

      expect(tester.takeException(), isNull);

      // The densest state: the pending banner, the cost bar, the open `/`
      // menu and the input row, all with the keyboard up: the menu must
      // shrink, and the input row must stay on screen.
      await _typePrompt(tester, '/');
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(_menuFinder(), findsOneWidget);
      expect(
        tester.getRect(find.byKey(_promptInput)).bottom,
        lessThan(543.0 + 1),
      );
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

    testWidgets(
      'a question tool renders each question with the answer below it '
      '(issue #50)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messages: const [
            SessionMessage(
              id: 'm1',
              role: 'assistant',
              tools: [
                ToolCall(
                  id: 't1',
                  name: 'question',
                  status: 'completed',
                  input: {
                    'questions': [
                      {'question': 'Ship it?'},
                      {'question': 'Which environment?'},
                    ],
                  },
                  answers: [
                    ['Yes'],
                    ['Staging'],
                  ],
                ),
              ],
            ),
          ],
        );
        await _pump(tester, client: client);

        expect(find.text('question · completed'), findsOneWidget);
        // Each question's text with the user's answer below it — not the
        // input's raw JSON.
        expect(find.text('Ship it?'), findsOneWidget);
        expect(find.text('Yes'), findsOneWidget);
        expect(find.text('Which environment?'), findsOneWidget);
        expect(find.text('Staging'), findsOneWidget);
        expect(find.textContaining('"questions"'), findsNothing);
      },
    );

    testWidgets('a running question shows its questions before the answers', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(
            id: 'm1',
            role: 'assistant',
            tools: [
              ToolCall(
                id: 't1',
                name: 'question',
                status: 'running',
                input: {
                  'questions': [
                    {'question': 'Ship it?'},
                  ],
                },
              ),
            ],
          ),
        ],
      );
      await _pump(tester, client: client);

      expect(find.text('question · running'), findsOneWidget);
      expect(find.text('Ship it?'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets(
      'a completed tool card shows a readable one-line summary (issue #63)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messages: const [
            SessionMessage(
              id: 'm1',
              role: 'assistant',
              tools: [
                ToolCall(
                  id: 't1',
                  name: 'shell',
                  status: 'completed',
                  input: {'command': 'ls -la'},
                ),
                ToolCall(
                  id: 't2',
                  name: 'read',
                  status: 'completed',
                  input: {'path': '/a/b.txt', 'offset': 10, 'limit': 50},
                ),
                ToolCall(
                  id: 't3',
                  name: 'grep',
                  status: 'completed',
                  input: {'pattern': 'TODO', 'path': 'lib'},
                ),
                ToolCall(
                  id: 't4',
                  name: 'execute',
                  status: 'completed',
                  input: {'code': 'print(1)'},
                ),
              ],
            ),
          ],
        );
        await _pump(tester, client: client);

        // Each tool's card settles on the readable line, not the raw input.
        expect(find.text('shell · completed'), findsOneWidget);
        expect(find.text('read · completed'), findsOneWidget);
        expect(find.text('grep · completed'), findsOneWidget);
        expect(find.text('execute · completed'), findsOneWidget);
        expect(find.text('ls -la'), findsOneWidget);
        expect(find.text('/a/b.txt (offset 10, limit 50)'), findsOneWidget);
        expect(find.text('TODO in lib'), findsOneWidget);
        expect(find.text('print(1)'), findsOneWidget);
        // The raw JSON input is not rendered.
        expect(find.textContaining('"command"'), findsNothing);
        expect(find.textContaining('"path"'), findsNothing);
        expect(find.textContaining('"pattern"'), findsNothing);
        expect(find.textContaining('"code"'), findsNothing);
      },
    );

    testWidgets(
      'read and grep show their bare path or pattern when the input carries no offset, limit, or path (issue #63)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messages: const [
            SessionMessage(
              id: 'm1',
              role: 'assistant',
              tools: [
                ToolCall(
                  id: 't1',
                  name: 'read',
                  status: 'completed',
                  input: {'path': '/a/b.txt'},
                ),
                ToolCall(
                  id: 't2',
                  name: 'grep',
                  status: 'completed',
                  input: {'pattern': 'TODO'},
                ),
              ],
            ),
          ],
        );
        await _pump(tester, client: client);

        expect(find.text('/a/b.txt'), findsOneWidget);
        expect(find.text('TODO'), findsOneWidget);
      },
    );

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

      expect(client.prompts, const [('ses_1', 'keep going', null, null)]);
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

    testWidgets(
      'form.created shows the question panel; answering records it and '
      'clears the panel',
      (tester) async {
        const form = QuestionForm(
          id: 'form_1',
          title: 'Questions',
          questions: [
            Question(
              header: 'Confirm',
              question: 'Proceed with the deployment?',
              multiple: false,
              custom: false,
              options: [
                QuestionOption(label: 'Yes'),
                QuestionOption(label: 'No'),
              ],
            ),
          ],
        );
        final client = _FakeClient(
          details: const [_detail0],
          questionLists: const [
            <QuestionForm>[],
            <QuestionForm>[form],
            <QuestionForm>[],
          ],
        );
        final events = await _pump(tester, client: client);

        expect(find.byKey(const ValueKey('question-banner')), findsNothing);

        // The `form.created` payload nests the session under `data.form`
        // (no top-level `sessionID`): the view still matches it.
        events.add(
          _event(
            'form.created',
            data: {
              'form': {'id': 'form_1', 'sessionID': 'ses_1'},
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byKey(const ValueKey('question-banner')), findsOneWidget);
        expect(find.text('Proceed with the deployment?'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('question-option-form_1-0-0')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('question-submit-form_1')));
        await tester.pump();
        await tester.pump();

        expect(client.questionAnswers, hasLength(1));
        final (sid, fid, answers) = client.questionAnswers.single;
        expect(sid, 'ses_1');
        expect(fid, 'form_1');
        expect(answers.single, ['Yes']);
        expect(find.byKey(const ValueKey('question-banner')), findsNothing);
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
      'session.execution.started re-fetches, so a prompt sent from another '
      'client is visible without a reload',
      (tester) async {
        // A client that did not send the prompt: its history is stale until
        // the turn-start re-fetch brings in the user message the other
        // client sent (the service persists it before the turn starts).
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [
            <SessionMessage>[],
            <SessionMessage>[
              SessionMessage(role: 'user', text: 'sent from the other client'),
            ],
          ],
        );
        final events = await _pump(tester, client: client);

        expect(find.text('No messages yet.'), findsOneWidget);
        expect(client.messageCalls, 1);

        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();

        expect(client.messageCalls, 2);
        expect(find.text('sent from the other client'), findsOneWidget);
      },
    );

    testWidgets(
      'the optimistic append is skipped when the turn-start re-fetch already '
      'brought in the user message',
      (tester) async {
        // The send POST is held in flight (promptGate) so the `started`
        // re-fetch can land between the POST resolving and the local append —
        // the race that would otherwise show the prompt twice.
        final promptGate = Completer<void>();
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [
            <SessionMessage>[],
            <SessionMessage>[SessionMessage(role: 'user', text: 'keep going')],
          ],
          promptGate: promptGate,
        );
        final events = await _pump(tester, client: client);

        await tester.enterText(find.byKey(_promptInput), 'keep going');
        await tester.tap(find.byKey(const ValueKey('structured-prompt-send')));
        await tester.pump();
        expect(client.prompts, isEmpty); // The POST is still in flight.

        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        // The re-fetch brought in the service's copy of the user message;
        // the field still carries the text until the POST resolves.
        expect(client.messageCalls, 2);
        expect(find.text('keep going').evaluate().length, 2);

        promptGate.complete();
        await tester.pump();
        await tester.pump();

        expect(client.prompts, const [('ses_1', 'keep going', null, null)]);
        expect(_promptText(tester), isEmpty);
        // The single service copy stands — the local append was skipped.
        expect(find.text('keep going'), findsOneWidget);
      },
    );

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
        // The only re-fetch is the turn-start one: the initial load plus the
        // `session.execution.started` normalize. The text deltas themselves
        // grow the in-flight message live and fetch nothing.
        expect(client.messageCalls, 2);
        expect(client.detailCalls, 2);
        expect(client.permissionCalls, 2);
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

      // The text block sits a little further below the dimmed reasoning
      // than it would without one, so the two read as separate blocks.
      final textPaddings = tester.widgetList<Padding>(
        find.ancestor(of: find.text('done'), matching: find.byType(Padding)),
      );
      expect(
        textPaddings.map((p) => p.padding),
        contains(const EdgeInsets.only(top: 12)),
      );
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
        // The loaded step has no `completed` timestamp: the view opens mid-turn,
        // so the live footer ticks beside the header.
        expect(find.text('Assistant · working…'), findsOneWidget);
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
      // The input is decoded to a map, so the card settles on the readable
      // line (issue #63), not the raw JSON.
      expect(find.text('ls'), findsOneWidget);
      expect(find.textContaining('"command"'), findsNothing);

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
      'a question tool settles on the answers from its success event',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        final events = await _pump(tester, client: client);

        events.add(
          _event(
            'session.tool.input.started',
            aggregateID: 'ses_1',
            data: const {
              'assistantMessageID': 'msg_1',
              'id': 'q1',
              'name': 'question',
            },
          ),
        );
        events.add(
          _event(
            'session.tool.input.ended',
            aggregateID: 'ses_1',
            data: const {
              'assistantMessageID': 'msg_1',
              'id': 'q1',
              'text': '{"questions":[{"question":"Ship it?"}]}',
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('question · running'), findsOneWidget);
        expect(find.text('Ship it?'), findsOneWidget);

        events.add(
          _event(
            'session.tool.success',
            aggregateID: 'ses_1',
            data: {
              'assistantMessageID': 'msg_1',
              'id': 'q1',
              // The success payload carries the tool state: the answers the
              // user gave, one list per question in form order.
              'metadata': {
                'answers': [
                  ['Yes'],
                ],
              },
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('question · completed'), findsOneWidget);
        expect(find.text('Yes'), findsOneWidget);
      },
    );

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

  group('StructuredSessionScreen lazy turn pages (issue #124)', () {
    /// A settled five-turn history: each turn is a prompt, a completed step
    /// and an `idle` marker; every turn's duration is distinct (turn i runs
    /// i*10000 -> i*10000 + 5500 + i*100, so the footers read 5.5s…5.9s,
    /// always 100.0 tok/s).
    List<SessionMessage> fiveTurns() => [
      for (var i = 0; i < 5; i++) ...[
        SessionMessage(
          id: 'u$i',
          role: 'user',
          text: 'q$i',
          created: i * 10000,
        ),
        SessionMessage(
          id: 'a$i',
          role: 'assistant',
          // Long enough that one loaded page overshoots the viewport: the
          // lazy list has a real scroll extent to hit the older-load edge.
          // The first turn stays short so its footer row fits on screen once
          // the reader is at the oldest end.
          text: i == 0
              ? 'a0 done'
              : List.filled(40, 'lorem ipsum dolor sit amet').join(' '),
          created: i * 10000,
          streamed: i * 10000 + 1000,
          completed: i * 10000 + 5500 + i * 100,
          outputTokens: 100,
          reasoningTokens: 0,
        ),
        SessionMessage(id: 'i$i', role: 'idle', created: i * 10000 + 5501),
      ],
    ];

    testWidgets('opening loads one page: only the current turn has a footer', (
      tester,
    ) async {
      final client = _PagedClient(history: fiveTurns());
      await _pump(tester, client: client);

      // The bounded read stopped once the turn's opener `idle` was in.
      expect(client.pageCalls, 1);
      // The current turn's frozen footer is on screen at once.
      expect(find.text('5.9s · 0 compactions · 100.0 tok/s'), findsOneWidget);
      // The older turns are not loaded: no footers, no messages.
      expect(find.text('5.8s · 0 compactions · 100.0 tok/s'), findsNothing);
      expect(find.textContaining('a3 '), findsNothing);
      expect(find.text('q0'), findsNothing);
    });

    testWidgets('scrolling up pages the history in: frozen footers fill in', (
      tester,
    ) async {
      final client = _PagedClient(history: fiveTurns());
      await _pump(tester, client: client);
      await tester.pumpAndSettle();

      expect(find.text('5.5s · 0 compactions · 100.0 tok/s'), findsNothing);

      // Scroll up toward the oldest loaded message; each edge pulls the
      // next older page until the history is exhausted. The list is lazy,
      // so a footer is on screen only while its row is: track what each
      // step revealed.
      final seen = <String>{};
      void recordFooters() {
        for (final m in tester.widgetList<Text>(
          find.byKey(const ValueKey('turn-stats')),
        )) {
          seen.add(m.data!);
        }
      }

      recordFooters();
      for (var i = 0; i < 40 && find.text('q0').evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, 400));
        await tester.pumpAndSettle();
        recordFooters();
      }

      // The whole history is in: the first turn's prompt is on screen.
      expect(find.text('q0'), findsOneWidget);

      // Sweep the remaining scroll range so every footer row passes through
      // the viewport (a tall step can hide the row between two stops).
      final pos = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      for (var p = pos.pixels; p >= 0; p -= 100) {
        pos.jumpTo(p);
        await tester.pumpAndSettle();
        recordFooters();
      }

      // Every turn's frozen footer filled in as its opener loaded.
      expect(
        seen,
        containsAll(<String>[
          '5.5s · 0 compactions · 100.0 tok/s',
          '5.6s · 0 compactions · 100.0 tok/s',
          '5.7s · 0 compactions · 100.0 tok/s',
          '5.8s · 0 compactions · 100.0 tok/s',
          '5.9s · 0 compactions · 100.0 tok/s',
        ]),
      );

      // The oldest page settled: further scrolls fetch nothing more.
      final calls = client.pageCalls;
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await tester.pumpAndSettle();
      expect(client.pageCalls, calls);
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

    testWidgets('`/themes` picks the theme, persists it, and re-themes', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      var themeChanges = 0;
      final client = _FakeClient(details: const [_detail0]);
      final events = StreamController<BridgeEvent>.broadcast();

      // The app's root (issue #49): the MaterialApp follows the persisted
      // choice and re-themes in place — the callback re-runs the build,
      // exactly like OpenCodeBridgeApp.
      await tester.pumpWidget(
        _ThemedRoot(
          client: client,
          settings: settings,
          events: events.stream,
          onThemeModeChanged: () {
            themeChanges++;
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        Theme.of(tester.element(find.text('external session'))).brightness,
        Brightness.light,
      );

      // The alias filters the menu to the one row; Enter runs it.
      await _typePrompt(tester, '/theme');
      await tester.pump();
      await _pressEnter(tester);
      await tester.pump();

      expect(find.text('Switch theme'), findsOneWidget);
      expect(find.text('Light (current)'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);

      await tester.tap(find.text('Dark'));
      await tester.pump();
      await tester.pump();

      // The choice is persisted, the callback fired once...
      expect(settings.themeMode, ThemeMode.dark);
      expect(themeChanges, 1);
      expect(find.text('Theme set to Dark.'), findsOneWidget);
      // ...and it is a local command: nothing reached the shared service,
      // the prompt field is cleared.
      expect(client.commandsRun, isEmpty);
      expect(client.prompts, isEmpty);
      expect(_promptText(tester), '');

      // The callback's rebuild re-themes the visible screen live.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        Theme.of(tester.element(find.text('external session'))).brightness,
        Brightness.dark,
      );
    });

    testWidgets('a dark-mode blockquote keeps a readable box', (tester) async {
      // The markdown default boxes quotes in a fixed light color — in dark
      // mode the TUI's light quote color is unreadable on it: the box takes
      // the theme's surface instead, like the code blocks.
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(role: 'assistant', text: 'done\n\n> Note: the note.'),
        ],
      );
      final events = StreamController<BridgeEvent>.broadcast();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: StructuredSessionScreen(
            sessionId: 'ses_1',
            title: 'external session',
            client: client,
            events: events.stream,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final box = tester.widget<DecoratedBox>(
        find.ancestor(
          of: find.textContaining('the note.'),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(
        (box.decoration as BoxDecoration).color,
        ThemeData.dark().colorScheme.surfaceContainerHighest,
      );
    });
  });

  group('StructuredSessionScreen `@` menu trigger (issue #56)', () {
    testWidgets('typing @ at the start opens the menu with no rows', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '@');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsOneWidget,
      );
      // The row provider yields no rows yet: the chrome keeps its card and
      // shows its empty line instead of a list.
      expect(_menuFinder(), findsNothing);
      expect(find.text('No matching mention'), findsOneWidget);
      // Opening any menu fetches the project commands once.
      expect(client.commandCalls, 1);
    });

    testWidgets(
      'an @ mid-text opens the menu while the caret is in its token',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client);

        await _typePrompt(tester, 'How is auth handled in @packages/functions');
        await tester.pump();
        // The caret is at the end of the token.
        expect(
          find.byKey(const ValueKey('structured-command-menu-card')),
          findsOneWidget,
        );

        // The caret moves to the middle of the token: the menu stays open.
        _setCaret(tester, 'How is auth handled in @pack'.length);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('structured-command-menu-card')),
          findsOneWidget,
        );

        // The caret lands before the token: the menu closes.
        _setCaret(tester, 'How is auth handled in '.length);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('structured-command-menu-card')),
          findsNothing,
        );
      },
    );

    testWidgets('a token that does not start with @ does not open the menu', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, 'use a@b');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsNothing,
      );
    });

    testWidgets('a space after the @ closes the menu', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '@ ');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsNothing,
      );
    });

    testWidgets('the / menu does not open for @ text and vice versa', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '@');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsOneWidget,
      );
      expect(_commandRowFinder('models'), findsNothing);

      await _typePrompt(tester, '/');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsOneWidget,
      );
      expect(_commandRowFinder('models'), findsOneWidget);
      expect(find.text('No matching mention'), findsNothing);
    });

    testWidgets('Enter with the @ menu open and no rows stays put', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, '@');
      await tester.pump();
      await _pressEnter(tester);

      expect(client.prompts, isEmpty);
      expect(_promptText(tester), '@');
    });

    testWidgets('a prompt with @ sends the raw text once the menu is closed', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, 'use @x');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsOneWidget,
      );

      // The caret leaves the token: the menu closes, the text stays.
      _setCaret(tester, 'use '.length);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsNothing,
      );

      await _pressEnter(tester);

      expect(client.prompts, const [('ses_1', 'use @x', null, null)]);
      expect(_promptText(tester), isEmpty);
    });

    testWidgets('Esc closes the @ menu by clearing the field', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await _typePrompt(tester, 'use @x');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsOneWidget,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(_promptText(tester), isEmpty);
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsNothing,
      );
    });
  });

  group('StructuredSessionScreen `@` mention menu (issue #58)', () {
    _FakeClient fakeClient({
      List<SkillOption> skills = const [],
      List<String> files = const [],
    }) => _FakeClient(
      details: const [_detail0],
      skills: skills,
      filesFound: files,
    );

    testWidgets('a bare @ lists the session skills, then the working '
        "directory's files", (tester) async {
      final client = fakeClient(
        skills: const [
          SkillOption(
            id: 'a11y',
            name: 'A11y',
            description: 'Accessibility checks',
          ),
        ],
        files: const ['src/main.dart', 'README.md'],
      );
      await _pump(tester, client: client);

      await _typePrompt(tester, '@');
      await tester.pump();
      await tester.pump();

      expect(_commandRowFinder('skill:a11y'), findsOneWidget);
      expect(find.text('Accessibility checks'), findsOneWidget);
      expect(_commandRowFinder('file:src/main.dart'), findsOneWidget);
      expect(_commandRowFinder('file:README.md'), findsOneWidget);
      // The skills sit above the files (the TUI's order).
      expect(
        tester.getTopLeft(_commandRowFinder('skill:a11y')).dy,
        lessThan(tester.getTopLeft(_commandRowFinder('file:README.md')).dy),
      );
      // The file list is the service's search, queried for the token.
      expect(client.fileQueries, const [('ses_1', '')]);
      expect(client.skillCalls, 1);
    });

    testWidgets(
      'the file rows are re-queried per token, and a stale answer never lands',
      (tester) async {
        final client = fakeClient();
        client.fileResults = const [
          ['zzz.txt'], // the '' token: stale by the end
          ['aa.txt'], // the 'a' token
        ];
        client.findFilesGate = Completer<void>();
        await _pump(tester, client: client);

        await _typePrompt(tester, '@');
        await tester.pump();

        await _typePrompt(tester, '@a');
        await tester.pump();

        client.findFilesGate!.complete();
        await tester.pump();
        await tester.pump();

        expect(client.fileQueries, const [('ses_1', ''), ('ses_1', 'a')]);
        expect(_commandRowFinder('file:aa.txt'), findsOneWidget);
        expect(_commandRowFinder('file:zzz.txt'), findsNothing);
      },
    );

    testWidgets('picking a file row inserts the mention in place of its '
        'token, the cursor after it, the menu closed', (tester) async {
      final client = fakeClient(files: const ['src/main.dart']);
      await _pump(tester, client: client);

      await _typePrompt(tester, 'please read @sr');
      await tester.pump();
      await tester.pump();

      expect(client.fileQueries, const [('ses_1', 'sr')]);
      await tester.tap(_commandRowFinder('file:src/main.dart'));
      await tester.pump();
      await tester.pump();

      expect(_promptText(tester), 'please read @src/main.dart');
      expect(_caret(tester), _promptText(tester).length);
      // The mention's own tail text is not a filter token: the menu stays
      // closed.
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsNothing,
      );
    });

    testWidgets(
      'a committed mention deletes as one unit, Backspace backward and Delete forward',
      (tester) async {
        final client = fakeClient(files: const ['src/main.dart']);
        await _pump(tester, client: client);

        await _typePrompt(tester, 'please read @sr');
        await tester.pump();
        await tester.pump();
        await tester.tap(_commandRowFinder('file:src/main.dart'));
        await tester.pump();
        await tester.pump();

        // Backspace at the mention's end deletes it whole, not one char.
        await tester.showKeyboard(find.byKey(_promptInput));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(_promptText(tester), 'please read ');

        // Delete from before the mention removes it forward.
        await _typePrompt(tester, 'please read @sr');
        await tester.pump();
        await tester.pump();
        await tester.tap(_commandRowFinder('file:src/main.dart'));
        await tester.pump();
        await tester.pump();
        _setCaret(tester, 'please read '.length);
        await tester.showKeyboard(find.byKey(_promptInput));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
        await tester.pump();
        expect(_promptText(tester), 'please read ');
      },
    );

    testWidgets('multiple mentions coexist, and each occurrence sends '
        'one attachment', (tester) async {
      final client = fakeClient(
        skills: const [
          SkillOption(
            id: 'a11y',
            name: 'A11y',
            description: 'Accessibility checks',
          ),
        ],
        files: const ['src/main.dart'],
      );
      await _pump(tester, client: client);

      // A skill mention and a file mention in one prompt.
      await _typePrompt(tester, '@');
      await tester.pump();
      await tester.pump();
      await tester.tap(_commandRowFinder('skill:a11y'));
      await tester.pump();
      await tester.pump();
      expect(_promptText(tester), '@a11y');

      await _typePrompt(tester, '@a11y and @');
      await tester.pump();
      await tester.pump();
      await tester.tap(_commandRowFinder('file:src/main.dart'));
      await tester.pump();
      await tester.pump();
      expect(_promptText(tester), '@a11y and @src/main.dart');

      await _pressEnter(tester);
      await tester.pump();

      final sent = client.prompts.single;
      expect(sent.$1, 'ses_1');
      expect(sent.$2, '@a11y and @src/main.dart');
      expect(sent.$3, [
        {'uri': 'file:///x/src/main.dart'},
      ]);
      expect(sent.$4, [
        {'id': 'a11y'},
      ]);
      expect(_promptText(tester), isEmpty);

      // The same file twice: two file attachments, no skills.
      await _typePrompt(tester, '@');
      await tester.pump();
      await tester.pump();
      await tester.tap(_commandRowFinder('file:src/main.dart'));
      await tester.pump();
      await tester.pump();
      await _typePrompt(tester, '@src/main.dart and @');
      await tester.pump();
      await tester.pump();
      await tester.tap(_commandRowFinder('file:src/main.dart'));
      await tester.pump();
      await tester.pump();

      await _pressEnter(tester);
      await tester.pump();

      expect(client.prompts.last.$3, const [
        {'uri': 'file:///x/src/main.dart'},
        {'uri': 'file:///x/src/main.dart'},
      ]);
      expect(client.prompts.last.$4, isNull);
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

  group('StructuredSessionScreen Ctrl+V image paste (issue #72)', () {
    testWidgets('the clipboard image is committed, its token inserted at '
        'the caret (the clipboard text not inserted), and every occurrence '
        'sends as a files data-URI named clipboard', (tester) async {
      final image = ClipboardImage(
        bytes: Uint8List.fromList(const [1, 2, 3]),
        mime: 'image/png',
      );
      final client = _FakeClient(details: const [_detail0]);
      await _pump(
        tester,
        client: client,
        imageReader: _FakeImageReader([image]).read,
      );
      _setClipboardText(tester, 'SENTINEL-TEXT');

      await _typePrompt(tester, 'look ');
      await tester.pump();
      await _pasteControlV(tester);

      expect(_promptText(tester), 'look [Image 1] ');
      expect(_caret(tester), 'look [Image 1] '.length);

      await _pressEnter(tester);
      await tester.pump();

      final sent = client.prompts.single;
      expect(sent.$1, 'ses_1');
      expect(sent.$2, 'look [Image 1]');
      expect(sent.$3, [
        {
          'uri': 'data:image/png;base64,${base64Encode(image.bytes)}',
          'name': 'clipboard',
        },
      ]);
      expect(sent.$4, isNull);
      expect(_promptText(tester), isEmpty);
    });

    testWidgets(
      're-pasting an image reuses its label, a new image gets the next one, and each occurrence sends its bytes',
      (tester) async {
        final a = ClipboardImage(
          bytes: Uint8List.fromList(const [1]),
          mime: 'image/png',
        );
        final b = ClipboardImage(
          bytes: Uint8List.fromList(const [2]),
          mime: 'image/jpeg',
        );
        final client = _FakeClient(details: const [_detail0]);
        await _pump(
          tester,
          client: client,
          imageReader: _FakeImageReader([a, b, a]).read,
        );

        await tester.tap(find.byKey(_promptInput));
        await tester.pump();
        await _pasteControlV(tester);
        expect(_promptText(tester), '[Image 1] ');
        await _pasteControlV(tester);
        expect(_promptText(tester), '[Image 1] [Image 2] ');
        await _pasteControlV(tester);
        expect(_promptText(tester), '[Image 1] [Image 2] [Image 1] ');

        await _pressEnter(tester);
        await tester.pump();

        final sent = client.prompts.single;
        expect(sent.$2, '[Image 1] [Image 2] [Image 1]');
        expect(sent.$3, [
          {
            'uri': 'data:image/png;base64,${base64Encode(a.bytes)}',
            'name': 'clipboard',
          },
          {
            'uri': 'data:image/jpeg;base64,${base64Encode(b.bytes)}',
            'name': 'clipboard',
          },
          {
            'uri': 'data:image/png;base64,${base64Encode(a.bytes)}',
            'name': 'clipboard',
          },
        ]);
      },
    );

    testWidgets(
      'the token deletes as one unit: Backspace at its end, Delete at its start',
      (tester) async {
        final image = ClipboardImage(
          bytes: Uint8List.fromList(const [1]),
          mime: 'image/png',
        );
        final client = _FakeClient(details: const [_detail0]);
        await _pump(
          tester,
          client: client,
          imageReader: _FakeImageReader([image]).read,
        );

        await tester.tap(find.byKey(_promptInput));
        await tester.pump();
        await _pasteControlV(tester);
        expect(_promptText(tester), '[Image 1] ');

        // Backspace at the tail: the trailing space first, then the token
        // whole, not one char at a time.
        await tester.showKeyboard(find.byKey(_promptInput));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(_promptText(tester), '[Image 1]');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(_promptText(tester), isEmpty);

        // Delete from before the token removes it forward.
        await _pasteControlV(tester);
        _setCaret(tester, 0);
        await tester.showKeyboard(find.byKey(_promptInput));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
        await tester.pump();
        expect(_promptText(tester), ' ');
      },
    );

    testWidgets(
      'the token coexists with plain text mid-sentence and deletes as one unit there',
      (tester) async {
        final image = ClipboardImage(
          bytes: Uint8List.fromList(const [1]),
          mime: 'image/png',
        );
        final client = _FakeClient(details: const [_detail0]);
        await _pump(
          tester,
          client: client,
          imageReader: _FakeImageReader([image]).read,
        );

        await tester.tap(find.byKey(_promptInput));
        await tester.pump();
        await _pasteControlV(tester);

        await _typePrompt(tester, 'A [Image 1] B');
        _setCaret(tester, 11);
        await tester.showKeyboard(find.byKey(_promptInput));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(_promptText(tester), 'A  B');
      },
    );

    testWidgets('Ctrl+V with no clipboard image pastes the clipboard text', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(
        tester,
        client: client,
        imageReader: _FakeImageReader([null]).read,
      );
      _setClipboardText(tester, 'hello world');

      await _typePrompt(tester, 'say ');
      await tester.pump();
      await _pasteControlV(tester);

      expect(_promptText(tester), 'say hello world');
      expect(_caret(tester), 'say hello world'.length);
    });

    testWidgets('a failed image read pastes the clipboard text', (
      tester,
    ) async {
      final reader = _FakeImageReader(const []);
      reader.error = Exception('the clipboard is unreachable');
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client, imageReader: reader.read);
      _setClipboardText(tester, 'fallback text');

      await _typePrompt(tester, 'x ');
      await tester.pump();
      await _pasteControlV(tester);

      expect(_promptText(tester), 'x fallback text');
      expect(reader.calls, 1);
    });

    testWidgets(
      'a read that cannot produce an image reports how to enable it',
      (tester) async {
        final reader = _FakeImageReader(const []);
        reader.failureMessage = 'Clipboard image paste needs xclip.';
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client, imageReader: reader.read);
        _setClipboardText(tester, 'fallback text');

        await _typePrompt(tester, 'x ');
        await tester.pump();
        await _pasteControlV(tester);
        await tester.pumpAndSettle();

        expect(_promptText(tester), 'x fallback text');
        expect(reader.calls, 1);
        expect(find.text('Clipboard image paste needs xclip.'), findsOneWidget);
      },
    );

    testWidgets(
      'an image over the 20 MiB limit inserts no token and reports it',
      (tester) async {
        final big = ClipboardImage(
          bytes: Uint8List.fromList(List<int>.filled(20 * 1024 * 1024 + 1, 1)),
          mime: 'image/png',
        );
        final client = _FakeClient(details: const [_detail0]);
        await _pump(
          tester,
          client: client,
          imageReader: _FakeImageReader([big]).read,
        );

        await tester.tap(find.byKey(_promptInput));
        await tester.pump();
        await _pasteControlV(tester);

        expect(_promptText(tester), isEmpty);
        expect(
          find.text('The clipboard image is over the 20 MiB limit.'),
          findsOneWidget,
        );
      },
    );
  });
}
