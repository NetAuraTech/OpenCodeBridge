import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/opencode_http_service.dart';
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

/// A detail whose service cannot cancel the turn (no interrupt route — an old
/// binary, issue #165 / ticket #2): the structured view hides the Stop on an
/// Active turn rather than offer a control that would only fail with a 502.
const _detailNoCancel = SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  canCancel: false,
);

/// A detail carrying a fixed [outcome] (issue #157's header-chip tests): the
/// service's session-level outcome, which can lag the newest turn's verdict.
SessionDetail _detailOutcome(String? outcome) => SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: outcome,
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
/// is actually on screen. It ends in an `idle` marker, so the conversation is
/// complete (idle) and the live-turn footer (and its ticking timer) is not in
/// play for these scroll tests.
final List<SessionMessage> _longHistory = [
  for (var i = 0; i < 400; i++)
    SessionMessage(
      role: i.isEven ? 'user' : 'assistant',
      text: i < 200
          ? 'message $i'
          : 'message $i ${List.filled(12, 'lorem ipsum dolor sit amet').join(' ')}',
    ),
  const SessionMessage(id: 'i-end', role: 'idle'),
];

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

  /// When set, `listCommands` awaits it before returning (the commands fetch
  /// held in flight, to sequence it against the file search — issue #202).
  Completer<void>? commandsGate;

  /// The file searches (issue #58): (sessionId, token) pairs.
  final List<(String, String)> fileQueries = [];

  int skillCalls = 0;

  /// Per-call skill lists (issue #201): the n-th call returns the n-th list,
  /// the last repeats — to script a failure (the earlier slot) followed by a
  /// success (the later one).
  List<List<SkillOption>> skillResults = const [];

  /// Thrown from `listSkills` when set (the transient service failure the
  /// `@` menu's fetch must survive, issue #201).
  Object? skillError;

  /// When set, `listSkills` awaits it before returning (the fetch held in
  /// flight, issue #201).
  Completer<void>? skillGate;

  @override
  Future<List<SkillOption>> listSkills(String id) async {
    skillCalls++;
    final error = skillError;
    if (error is Object) throw error;
    final gate = skillGate;
    if (gate != null) await gate.future;
    if (skillResults.isEmpty) return skills;
    final index = skillCalls - 1 < skillResults.length
        ? skillCalls - 1
        : skillResults.length - 1;
    return skillResults[index];
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
    final gate = commandsGate;
    if (gate != null) await gate.future;
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

  /// The cancel calls (`cancel`), in order (issue #160's Stop control).
  final List<String> cancelCalls = [];

  /// When set, `cancel` throws it (the 502 the bridge maps an unsupported
  /// service's cancel to).
  Object? cancelError;

  /// When set, `cancel` awaits it before returning (the cancel POST held in
  /// flight, to sequence it against the Stop control's busy state — issue
  /// #163's one-request-per-turn).
  Completer<void>? cancelGate;

  @override
  Future<void> cancel(String id) async {
    final gate = cancelGate;
    if (gate != null) await gate.future;
    cancelCalls.add(id);
    final error = cancelError;
    if (error is Object) throw error;
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

/// A [SessionsClient] double returning different data per session id, for the
/// in-place session-switching test (issue #131).
class _SessionSwitchClient extends SessionsClient {
  _SessionSwitchClient() : super(Uri.parse('http://bridge.test/'));

  @override
  Future<SessionDetail> getDetail(String id) async => SessionDetail(
    id: id,
    title: id,
    location: '/$id',
    cost: 0,
    tokens: const TokenUsage(
      input: 0,
      output: 0,
      reasoning: 0,
      cacheRead: 0,
      cacheWrite: 0,
    ),
    outcome: null,
  );

  @override
  Future<List<SessionMessage>> getMessages(String id) async => [
    SessionMessage(
      role: 'assistant',
      text: id == 'ses_a' ? 'alpha says hi' : 'beta says hi',
    ),
    // The Turn is closed: the panel shows the title, not the Active-turn
    // indicator (issue #161).
    const SessionMessage(id: 'i1', role: 'idle'),
  ];

  @override
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) async => MessagePage(messages: await getMessages(id), nextCursor: null);

  @override
  Future<List<PermissionRequest>> getPermissions(String id) async => const [];

  @override
  Future<List<QuestionForm>> getQuestions(String id) async => const [];
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

/// Replays the captured fixture [path] (issue #154's probe) through the REAL
/// bridge parser (`OpencodeHttpService`), so the view under test reads exactly
/// what the bridge would serve from the opencode service's raw `/message` read
/// (issue #157's "durable first" contract). A throwaway [HttpServer] stands in
/// for the service, serving the fixture body verbatim; the parse runs in
/// `runAsync` (real I/O), so it finishes before the pump.
Future<List<SessionMessage>> _parseFixture(
  WidgetTester tester,
  String path,
) async {
  final raw = (await tester.runAsync(() => File(path).readAsString()))!;
  final parsed = await tester.runAsync<List<SessionMessage>>(() async {
    // The test binding stubs every HttpClient in the suite; restore real
    // networking just for this parse so the fixture replays through the real
    // bridge parser (the widget test otherwise cannot make an HTTP request).
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      final decoded = jsonDecode(raw);
      final data = decoded is Map<String, Object?>
          ? (decoded['data'] as List)
          : <Object?>[];
      final expected = 'Basic ${base64Encode(utf8.encode('opencode:secret'))}';
      server.listen((req) async {
        final resp = req.response;
        resp.headers.contentType = ContentType.json;
        if (req.headers.value(HttpHeaders.authorizationHeader) != expected) {
          resp.statusCode = HttpStatus.unauthorized;
          await resp.close();
          return;
        }
        if (req.uri.path == '/api/session/ses_1/message') {
          resp.write(
            jsonEncode({
              'data': data,
              'cursor': {'next': null, 'previous': null},
            }),
          );
          await resp.close();
        } else {
          resp.statusCode = HttpStatus.notFound;
          await resp.close();
        }
      });
      final service = OpencodeHttpService(baseUrl: base, password: 'secret');
      try {
        return await service.getMessages('ses_1');
      } finally {
        await server.close(force: true);
      }
    } finally {
      HttpOverrides.global = previousOverrides;
    }
  });
  return parsed!;
}

/// A [SessionsClient] double whose current history is mutable (issue #156's
/// live-retry replay): every read (the initial load, the retry poll, and the
/// turn-end normalize) returns [current]. Making it mutable — instead of a
/// per-call list — keeps the tests robust to how many times the 1s retry poll
/// fires (each poll reads the same [current]), so the replay is driven by
/// changing [current] and advancing the clock to fire a poll, not by counting
/// reads. The detail is the plain idle one: the Active state is decided by
/// the history itself (the in-flight step on open, the closing `idle` on the
/// end read), so no separate "active" detail is needed.
class _RetryReplayClient extends _FakeClient {
  List<SessionMessage> current = const [];

  @override
  Future<SessionDetail> getDetail(String id) async => _detail0;

  @override
  Future<List<SessionMessage>> getMessages(String id) async {
    messageCalls++;
    return current;
  }

  @override
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) async {
    messageCalls++;
    return MessagePage(messages: current, nextCursor: null);
  }
}

Future<StreamController<BridgeEvent>> _pump(
  WidgetTester tester, {
  required _FakeClient client,
  Stream<SessionGap>? gaps,
  ClipboardImageReader? imageReader,
  DateTime Function()? clock,
  bool wireEvents = true,
}) async {
  final events = StreamController<BridgeEvent>.broadcast();
  await tester.pumpWidget(
    MaterialApp(
      home: StructuredSessionScreen(
        sessionId: 'ses_1',
        title: 'external session',
        client: client,
        // [wireEvents] false opens the view with NO event stream (the
        // durable-first render path, issue #157): the state comes from the
        // initial reads alone.
        events: wireEvents ? events.stream : null,
        gaps: gaps,
        imageReader: imageReader,
        clock: clock ?? DateTime.now,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return events;
}

/// The panel in the right-hand pane of a `Row` (the two-pane layout's
/// shape, issue #131): no route is pushed for it, and `onNewSession` /
/// `onClose` are wired through a host that records the calls.
/// [hideWhenClosed] makes the host drop the pane when the panel asks to
/// close, like the future layout's selection clear; [wired] `false` leaves
/// `onClose` unwired.
Future<StreamController<BridgeEvent>> _pumpEmbedded(
  WidgetTester tester, {
  required _FakeClient client,
  List<String>? calls,
  bool hideWhenClosed = false,
  bool wired = true,
}) async {
  final events = StreamController<BridgeEvent>.broadcast();
  var visible = true;
  await tester.pumpWidget(
    MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 200, child: Text('list pane')),
              if (visible || !hideWhenClosed)
                Expanded(
                  child: StructuredSessionPanel(
                    sessionId: 'ses_1',
                    title: 'external session',
                    client: client,
                    events: events.stream,
                    onNewSession: () => calls?.add('new-session'),
                    onClose: wired
                        ? () {
                            calls?.add('close');
                            if (hideWhenClosed) {
                              setState(() => visible = false);
                            }
                          }
                        : null,
                  ),
                ),
            ],
          ),
        ),
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
  int created = 1,
}) => BridgeEvent(
  id: 'evt_$type',
  created: created,
  type: type,
  data: data ?? const {},
  durable: aggregateID == null
      ? null
      : Durable(aggregateID: aggregateID, seq: 1),
);

const _promptInput = ValueKey('structured-prompt-input');

Finder _menuFinder() => find.byKey(const ValueKey('structured-command-menu'));

/// The chat list: the only [ListView] on screen in the in-flow panel tests
/// (the command menu is closed, so its rows' list is not built).
Finder _chatListFinder() => find.byType(ListView);

/// The in-flow pending-panels wrapper (the question panel and the permission
/// banner, stacked, between the list and the prompt bar) — issue #205.
Finder _pendingPanelsFinder() =>
    find.byKey(const ValueKey('structured-pending-panels'));

/// The prompt bar's content (its top edge is the bottom of the region the
/// list + panels fill).
Finder _promptBarFinder() => find.byKey(const ValueKey('structured-prompt'));

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

/// The mobile keyboard's IME send action (issue #203): the `TextField`'s
/// `onSubmitted` fires for the send action exactly as it does for the done
/// action. The platform the test runs on is irrelevant to the *behavior*
/// (the trim/empty/busy rules and the clear all live in [_sendPrompt]); it
/// only decides which action the IME toolbar advertises (see the
/// `textInputAction` assertions in the send-action group).
Future<void> _pressSend(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.send);
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

    testWidgets('a running turn shows its live footer; the end freezes it', (
      tester,
    ) async {
      // A completed turn (open), then the next turn as it starts (a new
      // prompt, in-flight assistant, no closing idle) and as it ends.
      const completed = [
        SessionMessage(role: 'user', text: 'go', created: 0),
        SessionMessage(
          role: 'assistant',
          text: 'done',
          created: 0,
          streamed: 1000,
          completed: 1500,
          outputTokens: 100,
          reasoningTokens: 0,
        ),
        SessionMessage(id: 'i1', role: 'idle'),
      ];
      const started = [
        ...completed,
        SessionMessage(role: 'user', text: 'again', created: 100000),
        SessionMessage(id: 'm2', role: 'assistant'),
      ];
      const ended = [
        ...completed,
        SessionMessage(role: 'user', text: 'again', created: 100000),
        SessionMessage(
          id: 'm2',
          role: 'assistant',
          text: 'done again',
          created: 100000,
          streamed: 100500,
          completed: 101000,
          outputTokens: 100,
          reasoningTokens: 0,
        ),
        SessionMessage(id: 'i2', role: 'idle'),
      ];
      final client = _FakeClient(
        details: const [_detail0],
        messageLists: const [completed, started, ended],
      );
      final events = await _pump(tester, client: client);

      // Open on a completed turn: the FROZEN footer for that turn.
      expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
      expect(find.text('1.5s · 0 compactions · 100.0 tok/s'), findsOneWidget);

      // The next turn starts: its live footer rides on the turn's own last
      // row (ticking from the new prompt), while the closed turn's frozen
      // footer stays on its marker (issue #124's per-turn footers) — two
      // footers, on two rows.
      events.add(_event('session.execution.started', aggregateID: 'ses_1'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-stats')), findsNWidgets(2));
      expect(find.text('1.5s · 0 compactions · 100.0 tok/s'), findsOneWidget);

      // The turn ends and the normalize settles the history: the live
      // footer freezes on the new turn's history-derived value, and both
      // closed turns keep their own frozen footer (issue #124).
      events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-stats')), findsNWidgets(2));
      expect(find.text('1.0s · 0 compactions · 200.0 tok/s'), findsOneWidget);
      await events.close();
    });

    testWidgets(
      'a failed Stop reports, keeps the Turn Active, and stays offered to '
      'retry (issue #163)',
      (tester) async {
        // A completed turn, then the next turn mid-flight (an in-flight
        // assistant, no closing idle): a service whose cancel the view will
        // not get through.
        const completed = [
          SessionMessage(role: 'user', text: 'go', created: 0),
          SessionMessage(
            role: 'assistant',
            text: 'done',
            created: 0,
            streamed: 1000,
            completed: 1500,
            outputTokens: 100,
            reasoningTokens: 0,
          ),
          SessionMessage(id: 'i1', role: 'idle'),
        ];
        const started = [
          ...completed,
          SessionMessage(role: 'user', text: 'again', created: 100000),
          SessionMessage(id: 'm2', role: 'assistant'),
        ];
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [completed, started],
        );
        // The service has no interrupt route: the bridge answers 502
        // opencode_unreachable for the cancel.
        client.cancelError = const SessionsClientError(
          502,
          'opencode_unreachable',
        );
        final events = await _pump(tester, client: client);
        // A fixed clock: the live footer's duration stays put across pumps.
        await tester.pumpWidget(
          MaterialApp(
            home: StructuredSessionScreen(
              sessionId: 'ses_1',
              title: 'external session',
              client: client,
              events: events.stream,
              clock: () => DateTime.fromMillisecondsSinceEpoch(200000),
            ),
          ),
        );
        await tester.pump();

        // The turn starts: Active — the Stop control is offered (the Active
        // fact is independent of cancel capability).
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        // Two footers: the closed turn's frozen one, and the in-flight
        // turn's live one (ticking from the prompt, issue #124).
        expect(find.byKey(const ValueKey('turn-stats')), findsNWidgets(2));
        // The LIVE footer splits its label (indicator between the parts).
        expect(find.text('1m 40s'), findsOneWidget);
        expect(find.text('0 compactions'), findsOneWidget);
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);

        // The first Stop on the failing service: the failure is reported and
        // the Turn stays Active (the live footer — the banner — is kept).
        // Unlike an earlier revision, the control does NOT hide itself: a
        // failed cancel is transient (a restart may fix the route), so the
        // control stays offered and the user can retry.
        await tester.tap(find.byKey(const ValueKey('structured-stop')));
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, ['ses_1']);
        expect(
          find.text('Could not stop the turn (status 502).'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        // The Turn is still Active: the live footer banner was kept.
        expect(find.byKey(const ValueKey('turn-stats')), findsNWidgets(2));
        // The LIVE footer splits its label (indicator between the parts).
        expect(find.text('1m 40s'), findsOneWidget);
        expect(find.text('0 compactions'), findsOneWidget);

        // Pressing Stop again retries: a second cancel request is sent.
        await tester.tap(find.byKey(const ValueKey('structured-stop')));
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, ['ses_1', 'ses_1']);
        // Still Active, still offered.
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        expect(find.byKey(const ValueKey('turn-stats')), findsNWidgets(2));
        // The LIVE footer splits its label (indicator between the parts).
        expect(find.text('1m 40s'), findsOneWidget);
        expect(find.text('0 compactions'), findsOneWidget);
        await events.close();
      },
    );

    testWidgets('a live turn ticks its duration from the prompt (issue #122)', (
      tester,
    ) async {
      var now = 1000; // The prompt is sent at 1000 (the live footer's origin).
      final client = _FakeClient(
        details: const [_detail0],
        messageLists: const [
          // Open: idle (the previous turn closed).
          [SessionMessage(id: 'i1', role: 'idle')],
          // Turn start: the new prompt is the window's first message.
          [
            SessionMessage(id: 'i1', role: 'idle'),
            SessionMessage(role: 'user', text: 'go', created: 1000),
          ],
          // Turn end: the step is complete and the turn closed.
          [
            SessionMessage(id: 'i1', role: 'idle'),
            SessionMessage(role: 'user', text: 'go', created: 1000),
            SessionMessage(
              id: 'm2',
              role: 'assistant',
              text: 'done',
              created: 1000,
              streamed: 2000,
              completed: 3000,
              outputTokens: 100,
              reasoningTokens: 0,
            ),
            SessionMessage(id: 'i2', role: 'idle'),
          ],
        ],
      );
      final events = await _pump(
        tester,
        client: client,
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );
      expect(find.byKey(const ValueKey('turn-stats')), findsNothing);

      // The turn starts: the live footer appears, ticking from the prompt.
      events.add(_event('session.execution.started', aggregateID: 'ses_1'));
      now = 1500;
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
      // now = 1500: 0.5s from the prompt (created 1000), no step yet. The
      // LIVE footer splits its label (the activity indicator rides between
      // the duration and the compaction count, issue #161).
      expect(find.text('0.5s'), findsOneWidget);
      expect(find.text('0 compactions'), findsOneWidget);

      // A step begins: it streams but has not finished, so it is not yet
      // counted and the duration keeps ticking.
      events.add(
        _event(
          'session.step.started',
          aggregateID: 'ses_1',
          data: const {'assistantMessageID': 'm2', 'started': 1000},
        ),
      );
      now = 2500;
      await tester.pump();
      await tester.pump();
      // now = 2500: 1.5s, the step still in flight -> no tok/s yet. The
      // LIVE footer still splits its label (indicator between the parts).
      expect(find.text('1.5s'), findsOneWidget);
      expect(find.text('0 compactions'), findsOneWidget);

      // The step streams its first token and then completes: its 100
      // tokens over 1.0s of streaming settle the live tok/s.
      events.add(
        _event(
          'session.step.streamed',
          aggregateID: 'ses_1',
          created: 2000,
          data: const {'assistantMessageID': 'm2'},
        ),
      );
      events.add(
        _event(
          'session.step.ended',
          aggregateID: 'ses_1',
          created: 3000,
          data: const {
            'assistantMessageID': 'm2',
            'tokens': {'input': 10, 'output': 100, 'reasoning': 0},
          },
        ),
      );
      now = 3000;
      await tester.pump();
      await tester.pump();
      // now = 3000: 2.0s live, 100 tokens over 1.0s -> 100.0 tok/s live.
      // The LIVE footer splits its label (indicator between the parts).
      expect(find.text('2.0s'), findsOneWidget);
      expect(find.text('0 compactions'), findsOneWidget);
      expect(find.text('100.0 tok/s'), findsOneWidget);

      // The turn ends: the frozen, history-derived value is identical — the
      // live footer freezes in place, back to a single joined label.
      events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
      await tester.pump();
      await tester.pump();
      expect(find.text('2.0s · 0 compactions · 100.0 tok/s'), findsOneWidget);
      await events.close();
    });

    testWidgets(
      'reopening mid-turn continues the live footer from the first prompt '
      '(issue #122)',
      (tester) async {
        // The turn already ran: a prompt at 0, a finished step, then a
        // second step still streaming. The duration must count from the
        // turn's first prompt (0), not from the open.
        final client = _FakeClient(
          details: const [_detail0],
          messages: const [
            SessionMessage(role: 'user', text: 'go', created: 0),
            SessionMessage(id: 'c1', role: 'compaction', created: 5),
            SessionMessage(
              id: 'm1',
              role: 'assistant',
              text: 'a',
              created: 0,
              streamed: 1000,
              completed: 2000,
              outputTokens: 100,
              reasoningTokens: 0,
            ),
            // The in-flight step (opened mid-turn): started, not completed.
            SessionMessage(id: 'm2', role: 'assistant', created: 2000),
          ],
        );
        var now = 2500;
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
        );

        // The open detects the in-flight turn (no closing idle marker) and
        // shows its live footer: 2.5s from the first prompt, the finished
        // step's throughput, and the compaction. The in-flight step does not
        // yet drop the tok/s.
        expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
        // The LIVE footer splits its label (indicator between the parts).
        expect(find.text('2.5s'), findsOneWidget);
        expect(find.text('1 compaction'), findsOneWidget);
        expect(find.text('100.0 tok/s'), findsOneWidget);

        // Time passes: the live footer's tick clock re-renders the duration,
        // continuing from the turn's first prompt (0), not the open.
        now = 3500;
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        expect(find.text('3.5s'), findsOneWidget);
        expect(find.text('1 compaction'), findsOneWidget);
        expect(find.text('100.0 tok/s'), findsOneWidget);

        // The turn ends: the footer freezes and the ticking clock is released
        // (a periodic timer must not outlive the test).
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        await events.close();
      },
    );

    testWidgets(
      'a compaction during the live turn counts, and the frozen footer keeps '
      'the count (issue #122)',
      (tester) async {
        const open = [SessionMessage(id: 'i1', role: 'idle')];
        const started = [
          ...open,
          SessionMessage(role: 'user', text: 'go', created: 1000),
        ];
        const ended = [
          ...started,
          SessionMessage(
            id: 'm2',
            role: 'assistant',
            text: 'done',
            created: 1500,
            streamed: 4500,
            completed: 4500,
            outputTokens: 100,
            reasoningTokens: 0,
          ),
          SessionMessage(id: 'c1', role: 'compaction', text: 'summary'),
          SessionMessage(id: 'i2', role: 'idle'),
        ];
        var now = 1000;
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [open, started, ended],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
        );
        expect(find.byKey(const ValueKey('turn-stats')), findsNothing);

        // The turn starts, then a step runs (still streaming — not counted).
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        events.add(
          _event(
            'session.step.started',
            aggregateID: 'ses_1',
            data: const {'assistantMessageID': 'm2', 'started': 1500},
          ),
        );
        now = 4000;
        await tester.pump();
        await tester.pump();
        // The LIVE footer splits its label (indicator between the parts).
        expect(find.text('3.0s'), findsOneWidget);
        expect(find.text('0 compactions'), findsOneWidget);

        // The compaction lands: its marker settles into the history, so the
        // live count goes up.
        events.add(
          _event(
            'session.compaction.ended',
            aggregateID: 'ses_1',
            data: const {'text': 'summary'},
          ),
        );
        now = 4000;
        await tester.pump();
        await tester.pump();
        expect(find.text('3.0s'), findsOneWidget);
        expect(find.text('1 compaction'), findsOneWidget);

        // The step completes and the turn ends: the step settles the
        // throughput and the frozen footer keeps the compaction count.
        events.add(
          _event(
            'session.step.ended',
            aggregateID: 'ses_1',
            created: 4500,
            data: const {
              'assistantMessageID': 'm2',
              'tokens': {'input': 10, 'output': 100, 'reasoning': 0},
            },
          ),
        );
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        now = 4500;
        await tester.pump();
        await tester.pump();
        // 1000 -> 4500 (3.5s); 100 tokens over 3.0s of streaming -> 33.3
        // tok/s; the compaction the turn ran through is still counted.
        expect(find.text('3.5s · 1 compaction · 33.3 tok/s'), findsOneWidget);
        // The compaction marker itself still renders.
        expect(find.text('summary'), findsOneWidget);
        await events.close();
      },
    );

    testWidgets(
      'a steered prompt keeps one live footer anchored at the original '
      'prompt (issue #123)',
      (tester) async {
        // A Turn already running, steered once: the history carries the
        // steering prompt with no idle marker closing the Turn. The live
        // footer keeps counting from the Turn's FIRST prompt, and the
        // steered prompt's steps join the throughput as they complete.
        const midTurn = [
          SessionMessage(id: 'i0', role: 'idle', created: 0),
          SessionMessage(id: 'u1', role: 'user', text: 'go', created: 1000),
          SessionMessage(
            id: 'm1',
            role: 'assistant',
            text: 'a',
            created: 1000,
            streamed: 1500,
            completed: 2000,
            outputTokens: 100,
            reasoningTokens: 0,
          ),
          // The steer, delivered mid-Turn: no idle marker between the steps.
          SessionMessage(id: 'u2', role: 'user', text: 'also', created: 2500),
        ];
        const ended = [
          ...midTurn,
          SessionMessage(
            id: 'm2',
            role: 'assistant',
            text: 'b',
            created: 2600,
            streamed: 3100,
            completed: 3600,
            outputTokens: 200,
            reasoningTokens: 0,
          ),
          SessionMessage(id: 'i1', role: 'idle', created: 3601),
        ];
        var now = 3000;
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [midTurn, ended],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
        );

        // Opened mid-Turn (no closing idle): the live footer anchors at the
        // Turn's first prompt (1000), not the steer (2500), and folds the
        // finished step (100 tokens over 0.5s). One footer, not two.
        expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
        // The LIVE footer splits its label (indicator between the parts).
        expect(find.text('2.0s'), findsOneWidget);
        expect(find.text('0 compactions'), findsOneWidget);
        expect(find.text('200.0 tok/s'), findsOneWidget);

        // The steered prompt's step runs and completes: its 200 tokens join
        // the Turn's average (300 tokens over 1.0s), the duration keeps
        // running from the first prompt.
        events.add(
          _event(
            'session.step.started',
            aggregateID: 'ses_1',
            data: const {'assistantMessageID': 'm2', 'started': 2600},
          ),
        );
        events.add(
          _event(
            'session.step.streamed',
            aggregateID: 'ses_1',
            created: 3100,
            data: const {'assistantMessageID': 'm2'},
          ),
        );
        events.add(
          _event(
            'session.step.ended',
            aggregateID: 'ses_1',
            created: 3600,
            data: const {
              'assistantMessageID': 'm2',
              'tokens': {'input': 10, 'output': 200, 'reasoning': 0},
            },
          ),
        );
        now = 3600;
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
        // Still the LIVE (split) footer; the throughput average has settled.
        expect(find.text('2.6s'), findsOneWidget);
        expect(find.text('0 compactions'), findsOneWidget);
        expect(find.text('300.0 tok/s'), findsOneWidget);

        // The Turn ends: the frozen footer settles on the same single-turn
        // window — 1000 -> 3600, 300 tokens over 1.0s, back to one label.
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
        expect(find.text('2.6s · 0 compactions · 300.0 tok/s'), findsOneWidget);
        await events.close();
      },
    );

    testWidgets(
      'a queued prompt freezes the previous footer; its own turn starts a '
      'new live footer (issue #123)',
      (tester) async {
        // The first Turn completes while a second prompt sits queued in the
        // history (the idle marker closed the first Turn before it). The
        // frozen footer keeps showing the completed Turn until the queued
        // prompt's own Turn starts.
        const completed = [
          SessionMessage(id: 'u1', role: 'user', text: 'go', created: 0),
          SessionMessage(
            id: 'm1',
            role: 'assistant',
            text: 'a',
            created: 0,
            streamed: 1000,
            completed: 2000,
            outputTokens: 200,
            reasoningTokens: 0,
          ),
          SessionMessage(id: 'i1', role: 'idle', created: 2001),
        ];
        const queued = [
          ...completed,
          SessionMessage(id: 'u2', role: 'user', text: 'next', created: 5000),
        ];
        const running = [
          ...queued,
          SessionMessage(
            id: 'm2',
            role: 'assistant',
            text: 'b',
            created: 5000,
            streamed: 5500,
            completed: 6000,
            outputTokens: 100,
            reasoningTokens: 0,
          ),
          SessionMessage(id: 'i2', role: 'idle', created: 6001),
        ];
        var now = 100;
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [completed, queued, queued, running],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
        );

        // Open on the completed Turn: its frozen footer.
        expect(find.text('2.0s · 0 compactions · 200.0 tok/s'), findsOneWidget);

        // The service settles the queued prompt into the history (the turn-
        // boundary normalize): the trailing window holds only the pending
        // prompt, so the FROZEN footer keeps the completed Turn — it does not
        // vanish while the queued Turn waits to start.
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
        expect(find.text('2.0s · 0 compactions · 200.0 tok/s'), findsOneWidget);

        // The queued prompt's Turn starts: a fresh LIVE footer begins AT the
        // queued prompt, not at the Turn before — and the completed Turn's
        // frozen footer stays on its own marker (issue #124).
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        now = 5500;
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('turn-stats')), findsNWidgets(2));
        // The fresh LIVE footer (the queued prompt's own Turn) splits its
        // label (indicator between the parts); the completed Turn's frozen
        // footer stays a single label on its own marker.
        expect(find.text('0.5s'), findsOneWidget);
        expect(find.text('0 compactions'), findsOneWidget);
        expect(find.text('2.0s · 0 compactions · 200.0 tok/s'), findsOneWidget);

        // The new Turn ends: the footer freezes on ITS window (5000 -> 6000,
        // 100 tokens over 0.5s).
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        now = 6000;
        await tester.pump();
        await tester.pump();
        expect(find.text('1.0s · 0 compactions · 200.0 tok/s'), findsOneWidget);
        await events.close();
      },
    );

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
      // Enter sends the prompt (the Send button is now the Stop control).
      await _pressEnter(tester);
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
      // Enter sends the prompt (the Send button is now the Stop control).
      await _pressEnter(tester);
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
      // The Send button is now the Stop control (issue #199): present in the
      // prompt bar's action position (the header's Stop is gone). A tool in
      // flight means the turn is Active, so the control is enabled.
      final stop = tester.widget<IconButton>(
        find.byKey(const ValueKey('structured-stop')),
      );
      expect(stop.onPressed, isNotNull);
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
        // Enter sends the prompt (the Send button is now the Stop control).
        await _pressEnter(tester);
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
        // The turn is running (opened mid-turn), so the in-flight assistant
        // shows it working.
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

  group('StructuredSessionScreen live provider retry (issue #156)', () {
    // The captured in-flight fixture values (issue #154's probe), as the
    // contract `SessionMessage`s the bridge's parser produces for them —
    // `message_429_inflight_attempt_2/3.json` and `message_429_succeeded.json`.
    // The raw service JSON is pinned through the real parser by the
    // HTTP-service tests; here the view is driven through the same three
    // states (in-flight retry → updated attempt → succeeded).
    const rateLimitBody =
        '{"detail":{"error":{"message":"Model API rate limit exceeded; please retry later","type":"rate_limit_error","code":"token_concurrency_rate_limit_exceeded"}}}';
    const rateLimitMessage =
        'Provider request failed with HTTP 429: $rateLimitBody';
    const rateLimitError = StructuredError(
      type: 'provider.rate-limit',
      message: rateLimitMessage,
      status: 429,
      body: rateLimitBody,
      retryAfterMs: 1000,
    );
    const user = SessionMessage(
      id: 'msg_1c68f428f001S3dFNmh3LTTnuU',
      role: 'user',
      text: 'Reply with exactly: one',
      created: 1794332639928,
    );

    // `message_429_inflight_attempt_2.json`: the assistant mid-retry, no content.
    const attempt2 = [
      user,
      SessionMessage(
        id: 'msg_1c68f42c7001H8MgETik6BH3y4',
        role: 'assistant',
        created: 1794332639945,
        retry: MessageRetry(
          attempt: 2,
          at: 1794332643505,
          error: rateLimitError,
        ),
      ),
    ];
    // `message_429_inflight_attempt_3.json`: the same assistant row, attempt climbed in place.
    const attempt3 = [
      user,
      SessionMessage(
        id: 'msg_1c68f42c7001H8MgETik6BH3y4',
        role: 'assistant',
        created: 1794332643517,
        retry: MessageRetry(
          attempt: 3,
          at: 1794332647492,
          error: rateLimitError,
        ),
      ),
    ];
    // `message_429_succeeded.json`: the retry landed (no retry, no error), the
    // content streamed, and the turn closed `succeeded`.
    const succeeded = [
      user,
      SessionMessage(
        id: 'msg_1c68f42c7001H8MgETik6BH3y4',
        role: 'assistant',
        text: '\n\none',
        reasoning:
            'The user is asking me to reply with exactly "one". '
            'This is a simple instruction to output exactly that text. '
            'There\'s no need to call any tool.\n',
        contextTokens: 9549,
        created: 1794332647500,
        streamed: 1794332650175,
        completed: 1794332650176,
        outputTokens: 37,
        reasoningTokens: 34,
      ),
      SessionMessage(
        id: 'msg_1c68f6ac1001IhNVGv7ax9XhHS',
        role: 'idle',
        outcome: 'succeeded',
      ),
    ];

    final noticeKey = const ValueKey('structured-retry-notice');

    /// A mutable epoch-millis clock: the panel's retry poll (1s) and the live
    /// footer's tick clock (200ms) both advance as [now] moves, so advancing
    /// [now] past the poll's period fires a poll deterministically.
    late int now;
    DateTime Function() clock() =>
        () => DateTime.fromMillisecondsSinceEpoch(now);

    /// Fires one retry poll: advances the binding's fake clock past the 1s
    /// poll period so the periodic poll timer runs, then pumps the frames the
    /// poll's async read resolves into (the HTTP microtasks and its setState).
    /// It does not advance [now] (the injected clock), so the live footer's
    /// ticking duration is unaffected by the poll.
    Future<void> firePoll(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pump();
      await tester.pump();
    }

    /// Opens the panel mid-retry: the initial read brings in the Active turn
    /// (an in-flight assistant with a `retry`), so the notice appears from the
    /// history alone. Returns the event stream (no retry event is ever added).
    Future<StreamController<BridgeEvent>> openMidRetry(
      WidgetTester tester, {
      required _RetryReplayClient client,
    }) async {
      now = 1794332645000;
      return _pump(tester, client: client, clock: clock());
    }

    testWidgets(
      'opens mid-retry (another client) and shows the verbatim notice '
      'without a retry event',
      (tester) async {
        // The session opens already mid-retry: a turn launched by another
        // client is Active (the mid-turn history decides it), so the notice
        // must appear from the initial read alone — no `session.retry.*`
        // event ever arrives (issue #156: no event plumbing dependency).
        final client = _RetryReplayClient()..current = List.of(attempt2);
        final events = await openMidRetry(tester, client: client);
        // The notice is on the active turn, verbatim (TUI's copy), N matching
        // the message's retry.attempt (2), the provider body truncated by
        // default (the full body is not rendered collapsed).
        expect(find.byKey(noticeKey), findsOneWidget);
        expect(
          find.textContaining(
            'Retry due · attempt 2 · Provider request failed with HTTP 429',
          ),
          findsOneWidget,
        );
        expect(find.textContaining(rateLimitBody), findsNothing);
        // Additive: the existing "working…" indicator is still there.
        expect(find.text('Assistant · working…'), findsOneWidget);

        // The retry lands (the service re-reads attempt cleared) and the turn
        // ends: the notice leaves, no trace in the rendered history.
        client.current = List.of(succeeded);
        await firePoll(tester);
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(noticeKey), findsNothing);
        expect(find.textContaining('Retry due'), findsNothing);
        await events.close();
      },
    );

    testWidgets(
      'replays in-flight retry → updated attempt → succeeded: appear, update '
      'in place, disappear cleanly, nothing left after normalize',
      (tester) async {
        final client = _RetryReplayClient()..current = List.of(attempt2);
        final events = await openMidRetry(tester, client: client);

        // 1. In-flight retry: the notice appears (the initial read).
        expect(find.byKey(noticeKey), findsOneWidget);
        expect(find.textContaining('Retry due · attempt 2'), findsOneWidget);

        // 2. A later attempt lands on the same message: N advances in place
        // (the poll re-reads the turn; no second notice is created).
        client.current = List.of(attempt3);
        await firePoll(tester);
        expect(find.byKey(noticeKey), findsOneWidget);
        expect(find.textContaining('Retry due · attempt 3'), findsOneWidget);
        expect(find.textContaining('Retry due · attempt 2'), findsNothing);

        // 3. The retry succeeds: the poll re-reads the message with no `retry`
        // and the notice disappears cleanly (no duplicate, no lingering text).
        client.current = List.of(succeeded);
        await firePoll(tester);
        expect(find.byKey(noticeKey), findsNothing);
        expect(find.textContaining('Retry due'), findsNothing);

        // 4. The turn ends and the normalize replaces the history: nothing is
        // left in the rendered record — the successful content shows, not a
        // retry notice.
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(noticeKey), findsNothing);
        expect(find.textContaining('Retry due'), findsNothing);
        expect(find.textContaining('one'), findsWidgets);
        await events.close();
      },
    );

    testWidgets(
      'the provider body is truncated by default and expands to the full '
      'string on tap',
      (tester) async {
        final client = _RetryReplayClient()..current = List.of(attempt2);
        final events = await openMidRetry(tester, client: client);
        expect(find.byKey(noticeKey), findsOneWidget);
        // Collapsed: the first line never wraps into a wall — the long body is
        // truncated (the full body is not present), with an expand affordance.
        expect(find.textContaining(rateLimitBody), findsNothing);
        expect(find.byIcon(Icons.expand_more), findsOneWidget);

        // Tap: the body expands to its full string.
        await tester.tap(find.byKey(noticeKey));
        await tester.pump();
        expect(find.textContaining(rateLimitBody), findsOneWidget);
        expect(find.byIcon(Icons.expand_less), findsOneWidget);

        // Collapse again: back to the truncated first line.
        await tester.tap(find.byKey(noticeKey));
        await tester.pump();
        expect(find.textContaining(rateLimitBody), findsNothing);
        expect(find.byIcon(Icons.expand_more), findsOneWidget);

        client.current = List.of(succeeded);
        await firePoll(tester);
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        await events.close();
      },
    );

    testWidgets(
      'the notice is additive: the working indicator and the live footer keep '
      'whatever they do while the turn retries',
      (tester) async {
        final client = _RetryReplayClient()..current = List.of(attempt2);
        final events = await openMidRetry(tester, client: client);
        // All three are present at once: the ambient notice, the working
        // label, and the live footer (the activity indicator rides on it).
        expect(find.byKey(noticeKey), findsOneWidget);
        expect(find.text('Assistant · working…'), findsOneWidget);
        expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('turn-activity-indicator')),
          findsOneWidget,
        );

        client.current = List.of(succeeded);
        await firePoll(tester);
        events.add(_event('session.execution.succeeded', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        // The notice is the only one that leaves; the turn settles.
        expect(find.byKey(noticeKey), findsNothing);
        expect(find.text('Assistant · working…'), findsNothing);
        await events.close();
      },
    );

    testWidgets(
      'a settled (idle) history shows no retry notice (no false positive)',
      (tester) async {
        // A closed turn whose last assistant carried no retry: the notice must
        // never appear.
        final client = _RetryReplayClient()
          ..current = const [
            user,
            SessionMessage(
              id: 'm-done',
              role: 'assistant',
              text: 'done',
              created: 1000,
              streamed: 2000,
              completed: 3000,
              outputTokens: 5,
              reasoningTokens: 0,
            ),
            SessionMessage(id: 'i1', role: 'idle', outcome: 'succeeded'),
          ];
        final events = await openMidRetry(tester, client: client);
        expect(find.byKey(noticeKey), findsNothing);
        expect(find.textContaining('Retry due'), findsNothing);
        await events.close();
      },
    );
  });

  group('StructuredSessionScreen Stop the running turn (issue #163)', () {
    // A session whose current Turn is running (an in-flight assistant, no
    // closing idle) and that stays Active across the normalize the start
    // triggers; the terminal event is what settles it.
    const running = [
      SessionMessage(role: 'user', text: 'go', created: 0),
      SessionMessage(id: 'm2', role: 'assistant'),
    ];
    const settled = [
      SessionMessage(role: 'user', text: 'go', created: 0),
      SessionMessage(id: 'm2', role: 'assistant', completed: 500),
      SessionMessage(id: 'i2', role: 'idle'),
    ];

    testWidgets(
      'the prompt bar Stop control is always visible: disabled idle, enabled '
      'on an Active turn; pressing it cancels the turn (issue #163, #199)',
      (tester) async {
        // The session opens idle (settled history), then a turn starts from
        // the event stream and is interrupted. The initial load reads the
        // settled history; the normalize each boundary triggers reads it too.
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [settled, running, settled],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        // Idle: the Stop control is visible in the prompt bar (the header's
        // Stop is gone) but disabled — the turn is not Active.
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('structured-stop')))
              .onPressed,
          isNull,
        );

        // The Turn runs: the control becomes enabled in the same position
        // (stable layout, no jump).
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('structured-stop')))
              .onPressed,
          isNotNull,
        );

        // One tap cancels that session's turn (no confirmation step) — the
        // same bridge-native cancel the header control used to send.
        await tester.tap(find.byKey(const ValueKey('structured-stop')));
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, ['ses_1']);

        // The cancel is accepted but the turn stays Active until the
        // execution's terminal event arrives (it leaves on `interrupted`
        // like any other termination): the control stays enabled.
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('structured-stop')))
              .onPressed,
          isNotNull,
        );
        events.add(
          _event('session.execution.interrupted', aggregateID: 'ses_1'),
        );
        await tester.pump();
        await tester.pump();
        // Settled: the control stays visible but is disabled again.
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('structured-stop')))
              .onPressed,
          isNull,
        );
        // The footer's activity indicator leaves with the Turn (issue #161).
        expect(
          find.byKey(const ValueKey('turn-activity-indicator')),
          findsNothing,
        );
        await events.close();
      },
    );

    testWidgets('the bridge-native cancel settles the running marker and Stop control '
        'in place (issue #164)', (tester) async {
      // The session opens idle, a turn starts, then the bridge-native cancel
      // lands (the outcome of a Stop from any panel): the running marker and
      // the Stop control settle on the event, like a terminal outcome — no
      // waiting on the service's own terminal.
      final client = _FakeClient(
        details: const [_detail0],
        messageLists: const [settled, running, settled],
      );
      final events = await _pump(
        tester,
        client: client,
        clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
      );
      // Idle: the Stop control is visible but disabled.
      expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);

      // The Turn runs: the Stop control is enabled.
      events.add(_event('session.execution.started', aggregateID: 'ses_1'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('turn-activity-indicator')),
        findsOneWidget,
      );

      // The bridge-native cancel (no durable seq; the session id in data):
      // the running marker and the Stop control settle in place (the control
      // stays visible but disabled — it is the prompt bar's, not the header's).
      events.add(
        _event(
          'session.turn.cancelled',
          data: const {'sessionID': 'ses_1', 'messageID': 'm2'},
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('turn-activity-indicator')),
        findsNothing,
      );
      await events.close();
    });

    testWidgets(
      'while the cancel is in flight the Stop control is busy and ignores '
      'further presses (one request per turn) (issue #163)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [running, running, settled],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        // Active turn: the control is enabled and shows the stop icon (not
        // the busy spinner).
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('structured-stop')))
              .onPressed,
          isNotNull,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('structured-stop')),
            matching: find.byType(Icon),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('structured-stop')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );

        // Hold the cancel POST in flight.
        final gate = Completer<void>();
        client.cancelGate = gate;
        await tester.tap(find.byKey(const ValueKey('structured-stop')));
        await tester.pump();
        // Busy: the control shows the spinner and is disabled (no onPressed)
        // — a second tap sends nothing.
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('structured-stop')))
              .onPressed,
          isNull,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('structured-stop')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('structured-stop')));
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, isEmpty); // still in flight, not landed

        // The request lands: one and only one cancel for the turn.
        gate.complete();
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, ['ses_1']);
        await events.close();
      },
    );

    testWidgets(
      'Escape with the menu closed and nothing typed cancels an Active turn; '
      'the next keystrokes type, not clear (issue #163)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [running, running, settled],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        // Focus the (empty) prompt field and start the Turn.
        await tester.tap(find.byKey(_promptInput));
        await tester.pump();
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(_promptText(tester), isEmpty);

        // Escape with the menu closed and an Active turn cancels it — it does
        // not clear the (already empty) field.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, ['ses_1']);
        expect(_promptText(tester), isEmpty);

        // The next keystrokes type normally (the turn is settled after the
        // terminal event, so Escape would now clear the field again — but a
        // character lands in the field, it is not consumed).
        events.add(
          _event('session.execution.interrupted', aggregateID: 'ses_1'),
        );
        await tester.pump();
        await tester.pump();
        await _typePrompt(tester, 'h');
        await tester.pump();
        expect(_promptText(tester), 'h');
        await events.close();
      },
    );

    testWidgets(
      'Escape while the menu is open still closes the menu (and a turn '
      'running, nothing typed in the empty field, does not cancel) '
      '(issue #163)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [running, running, settled],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();

        // Open the menu: Escape closes it (clears the field), it does not
        // cancel the turn.
        await _typePrompt(tester, '/stop');
        await tester.pump();
        await tester.pump();
        expect(_commandRowFinder('stop'), findsOneWidget);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(_promptText(tester), isEmpty);
        expect(_menuFinder(), findsNothing);
        expect(client.cancelCalls, isEmpty);
        await events.close();
      },
    );

    testWidgets(
      'Escape with the menu closed and a settled turn clears the field '
      '(issue #163)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [settled],
        );
        await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        await tester.tap(find.byKey(_promptInput));
        await tester.pump();
        await _typePrompt(tester, 'draft');
        await tester.pump();
        expect(_promptText(tester), 'draft');

        // No turn is Active: Escape clears the field (the pre-#163 action),
        // and no cancel is sent.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(_promptText(tester), isEmpty);
        expect(client.cancelCalls, isEmpty);
      },
    );

    testWidgets(
      '/stop is listed in the `/` menu and, run on Enter, cancels the Active '
      'turn and reports it (issue #163)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [running, running, settled],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();

        // It is in the catalogue (the session family), found by its name.
        await _typePrompt(tester, '/stop');
        await tester.pump();
        await tester.pump();
        expect(_commandRowFinder('stop'), findsOneWidget);

        // Enter runs it: the cancel is sent and its result is reported.
        await _pressEnter(tester);
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, ['ses_1']);
        expect(find.text('Stop requested.'), findsOneWidget);
        expect(_promptText(tester), isEmpty);
        await events.close();
      },
    );

    testWidgets(
      '/stop on an idle session says nothing was running, without an error '
      '(issue #163)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [settled],
        );
        await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        await _typePrompt(tester, '/stop');
        await tester.pump();
        await tester.pump();
        expect(_commandRowFinder('stop'), findsOneWidget);

        // Run it on the idle session: a harmless note, no request, no error.
        await _pressEnter(tester);
        await tester.pump();
        await tester.pump();
        expect(find.text('Nothing is running.'), findsOneWidget);
        expect(client.cancelCalls, isEmpty);
        expect(_promptText(tester), isEmpty);
      },
    );

    testWidgets(
      'a failing /stop reports the reason, keeps the banner on the running '
      'turn, and leaves the Stop control usable to retry (issue #163)',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          messageLists: const [running, running, settled],
        );
        client.cancelError = const SessionsClientError(404, 'not_found');
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();

        // /stop fails (unknown session): the reason is reported, the banner
        // keeps the running turn, and the Stop control is still offered.
        await _typePrompt(tester, '/stop');
        await tester.pump();
        await tester.pump();
        await _pressEnter(tester);
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, ['ses_1']);
        expect(
          find.text('Could not stop the turn (status 404).'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        // The turn is still Active: the footer's activity indicator is there
        // (issue #161).
        expect(
          find.byKey(const ValueKey('turn-activity-indicator')),
          findsOneWidget,
        );

        // The Stop control is usable again: tapping retries the cancel.
        await tester.tap(find.byKey(const ValueKey('structured-stop')));
        await tester.pump();
        await tester.pump();
        expect(client.cancelCalls, ['ses_1', 'ses_1']);
        await events.close();
      },
    );

    testWidgets(
      'a service without the interrupt route keeps the Stop disabled on an '
      'Active turn (issue #165, ticket 2)',
      (tester) async {
        // The detail's canCancel is false: the routed service (an old binary)
        // has no interrupt route, so a cancel would only fail with a 502. The
        // prompt bar's Stop (issue #199) stays visible but disabled on an
        // Active turn rather than offered as a trap.
        final client = _FakeClient(
          details: const [_detailNoCancel],
          messageLists: const [running, running, settled],
        );
        final events = await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(120000),
        );
        // The Turn runs, but the Stop stays disabled: the detail says the
        // service cannot cancel it.
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('structured-stop')), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('structured-stop')))
              .onPressed,
          isNull,
        );
        // The turn is otherwise Active (the footer's activity indicator is
        // there — the Active fact is independent of cancel capability).
        expect(
          find.byKey(const ValueKey('turn-activity-indicator')),
          findsOneWidget,
        );
        await events.close();
      },
    );
  });

  group(
    'StructuredSessionScreen active-turn footer indicator (issue #161)',
    () {
      // The Active turn's activity indicator (issue #161): a track of
      // small squares with a larger one ping-ponging across, in the footer's
      // label between the duration and the compaction count. Driven by the
      // same Active detection the live footer uses (execution events, detail
      // reconciliation, the normalized history). The header keeps the
      // session's title throughout.
      final activeModel = _detailModel.copyWithActive(true);

      /// A completed turn's history (a prompt, a finished step, an `idle`
      /// marker): its footer freezes to this label once the turn closes.
      const closed = <SessionMessage>[
        SessionMessage(role: 'user', text: 'go', created: 0),
        SessionMessage(
          id: 'm1',
          role: 'assistant',
          created: 0,
          streamed: 1000,
          completed: 1000,
          outputTokens: 100,
          reasoningTokens: 0,
        ),
        SessionMessage(id: 'i1', role: 'idle'),
      ];

      /// The in-flight (active) turn's history: a prompt at 1000 and an
      /// assistant step still streaming (no `idle` marker closes it).
      const inFlight = <SessionMessage>[
        ...closed,
        SessionMessage(role: 'user', text: 'again', created: 1000),
        SessionMessage(id: 'm2', role: 'assistant', created: 1200),
      ];

      /// The in-flight turn once it completes (its step finishes, the turn
      /// closes at an `idle` marker).
      const inFlightDone = <SessionMessage>[
        ...closed,
        SessionMessage(role: 'user', text: 'again', created: 1000),
        SessionMessage(
          id: 'm2',
          role: 'assistant',
          created: 1200,
          streamed: 2000,
          completed: 2000,
          outputTokens: 100,
          reasoningTokens: 0,
        ),
        SessionMessage(id: 'i2', role: 'idle'),
      ];

      testWidgets('opening mid-turn shows the title and the footer indicator', (
        tester,
      ) async {
        // The turn was already running when the view opened: the detail's
        // Active fact (and the in-flight step) show the footer indicator at
        // once. The header keeps the session's title.
        final client = _FakeClient(
          details: [activeModel, _detail0],
          messages: const [
            SessionMessage(role: 'user', text: 'go', created: 1000),
            SessionMessage(id: 'm1', role: 'assistant', created: 1200),
          ],
        );
        await _pump(
          tester,
          client: client,
          clock: () => DateTime.fromMillisecondsSinceEpoch(13300),
        );

        // The header keeps the session's title (issue #161's header).
        expect(find.text('external session'), findsOneWidget);
        // The footer shows the duration and the compaction count, with the
        // activity indicator riding between them.
        expect(find.text('12.3s'), findsOneWidget);
        expect(find.text('0 compactions'), findsOneWidget);
        expect(find.byKey(const ValueKey('turn-stats')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('turn-activity-indicator')),
          findsOneWidget,
        );
        // The cost bar's identity chips are unaffected.
        expect(find.byKey(const ValueKey('structured-model')), findsOneWidget);
        expect(find.text('opencode/flint-40b-free'), findsOneWidget);
        expect(find.byKey(const ValueKey('structured-mode')), findsOneWidget);
      });

      testWidgets(
        'a started turn shows the indicator; a terminal event removes it',
        (tester) async {
          // Open on a settled session (a completed turn), watch a turn start
          // from another client (an event, not a local prompt) and end.
          // Detail calls, in order: initial load (idle), one normalize per
          // boundary — active on `started`, idle on the terminal event.
          final client = _FakeClient(
            details: [
              _detail0, // idle (initial)
            ],
            messageLists: [
              [
                ...closed,
                SessionMessage(role: 'user', text: 'again', created: 1000),
                SessionMessage(id: 'm2', role: 'assistant', created: 1200),
                SessionMessage(id: 'i2', role: 'idle'),
              ],
            ],
          );
          final events = await _pump(
            tester,
            client: client,
            clock: () => DateTime.fromMillisecondsSinceEpoch(2000),
          );

          // A completed session: no indicator, the frozen footer.
          expect(
            find.byKey(const ValueKey('turn-activity-indicator')),
            findsNothing,
          );

          // The turn starts: the detail goes Active and the history goes
          // in-flight, so the indicator appears in the live footer.
          client.details.add(activeModel);
          client.messageLists.add(inFlight);
          events.add(_event('session.execution.started', aggregateID: 'ses_1'));
          await tester.pump();
          await tester.pump();
          expect(find.text('external session'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('turn-activity-indicator')),
            findsOneWidget,
          );

          // The turn succeeds: the detail settles to idle and the history
          // closes, so the indicator is removed and the footer freezes.
          client.details.add(_detail0);
          client.messageLists.add(inFlightDone);
          events.add(
            _event('session.execution.succeeded', aggregateID: 'ses_1'),
          );
          await tester.pump();
          await tester.pump();
          expect(
            find.byKey(const ValueKey('turn-activity-indicator')),
            findsNothing,
          );
          expect(find.text('external session'), findsOneWidget);
          await events.close();
        },
      );

      testWidgets(
        'a failed turn removes the indicator and freezes the footer',
        (tester) async {
          // Open on a settled session, watch a turn start, then FAIL: the
          // indicator is removed (the task is over, with an error) and the
          // footer freezes.
          final client = _FakeClient(
            details: [_detail0],
            messageLists: [closed],
          );
          final events = await _pump(
            tester,
            client: client,
            clock: () => DateTime.fromMillisecondsSinceEpoch(2000),
          );
          expect(
            find.byKey(const ValueKey('turn-activity-indicator')),
            findsNothing,
          );

          // The turn starts: Active, in-flight — the indicator shows.
          client.details.add(activeModel);
          client.messageLists.add(inFlight);
          events.add(_event('session.execution.started', aggregateID: 'ses_1'));
          await tester.pump();
          await tester.pump();
          expect(
            find.byKey(const ValueKey('turn-activity-indicator')),
            findsOneWidget,
          );

          // The turn fails: the indicator is removed and the footer freezes.
          client.details.add(_detail0);
          client.messageLists.add(inFlightDone);
          events.add(_event('session.execution.failed', aggregateID: 'ses_1'));
          await tester.pump();
          await tester.pump();
          expect(
            find.byKey(const ValueKey('turn-activity-indicator')),
            findsNothing,
          );
          expect(find.text('external session'), findsOneWidget);
          await events.close();
        },
      );

      testWidgets(
        'a settled session shows no indicator (its footer is frozen)',
        (tester) async {
          final client = _FakeClient(
            details: const [_detail0],
            messages: const [
              SessionMessage(role: 'user', text: 'go', created: 0),
              SessionMessage(
                id: 'm1',
                role: 'assistant',
                created: 0,
                streamed: 1000,
                completed: 1500,
                outputTokens: 100,
                reasoningTokens: 0,
              ),
              SessionMessage(id: 'i1', role: 'idle'),
            ],
          );
          await _pump(tester, client: client);
          expect(
            find.byKey(const ValueKey('turn-activity-indicator')),
            findsNothing,
          );
          // The frozen footer still shows the turn's full stats, as one
          // label (no indicator riding in it).
          expect(
            find.text('1.5s · 0 compactions · 100.0 tok/s'),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'a compaction during the live turn counts in the footer, and the '
        'indicator rides between the parts',
        (tester) async {
          final client = _FakeClient(
            details: [activeModel],
            messages: const [
              SessionMessage(role: 'user', text: 'go', created: 1000),
              SessionMessage(id: 'c1', role: 'compaction', text: 'summary'),
              SessionMessage(id: 'm1', role: 'assistant', created: 1200),
            ],
          );
          await _pump(
            tester,
            client: client,
            clock: () => DateTime.fromMillisecondsSinceEpoch(3000),
          );
          // The live label: the duration and the compaction count, with the
          // indicator riding between them.
          expect(find.text('2.0s'), findsOneWidget);
          expect(find.text('1 compaction'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('turn-activity-indicator')),
            findsOneWidget,
          );
        },
      );
    },
  );

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
        // A footer's label is its text under the turn-stats row. The frozen
        // footers (every turn in this test is settled) each carry one label
        // Text.
        for (final m in tester.widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('turn-stats')),
            matching: find.byType(Text),
          ),
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
      List<OpencodeCommand> commands = const [],
    }) => _FakeClient(
      details: const [_detail0],
      skills: skills,
      filesFound: files,
      commands: commands,
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

    testWidgets(
      'late-arriving skills keep the in-flight file rows for the same token',
      (tester) async {
        // The file search for the token is in flight when the session's
        // skills land: the menu re-syncs for the new skills, but the
        // in-flight file rows must still land when their query completes —
        // no re-query for the unchanged token (issue #202).
        final client = fakeClient(
          skills: const [
            SkillOption(
              id: 'main',
              name: 'Main',
              description: 'Accessibility checks',
            ),
          ],
          files: const ['src/main.dart'],
        );
        client.findFilesGate = Completer<void>();
        client.skillGate = Completer<void>();
        await _pump(tester, client: client);

        await _typePrompt(tester, '@ma');
        await tester.pump();
        await tester.pump();

        // The file search for the token is in flight: the menu keeps its
        // (empty) rows on screen until the rows land.
        expect(find.text('No matching mention'), findsOneWidget);
        expect(client.fileQueries, const [('ses_1', 'ma')]);
        expect(client.skillCalls, 1);

        // The skills land while the search is still in flight: the menu
        // re-syncs for them.
        client.skillGate!.complete();
        await tester.pump();
        await tester.pump();

        // No file rows yet (the search is in flight), and the token was not
        // re-queried by the re-sync.
        expect(_commandRowFinder('file:src/main.dart'), findsNothing);
        expect(client.fileQueries, const [('ses_1', 'ma')]);

        // The file search lands: the menu settles on the full rows — the
        // skills above the files — for the same token.
        client.findFilesGate!.complete();
        await tester.pump();
        await tester.pump();

        expect(client.fileQueries, const [
          ('ses_1', 'ma'),
        ], reason: 'the unchanged token must not be re-queried');
        expect(_commandRowFinder('skill:main'), findsOneWidget);
        expect(_commandRowFinder('file:src/main.dart'), findsOneWidget);
        expect(
          tester.getTopLeft(_commandRowFinder('skill:main')).dy,
          lessThan(
            tester.getTopLeft(_commandRowFinder('file:src/main.dart')).dy,
          ),
        );
      },
    );

    testWidgets('a menu rebuild while the search is in flight keeps the token '
        'queried once', (tester) async {
      // The project's custom commands (and then the session's skills)
      // land — the bar's menus are rebuilt — while the file search for
      // the token is in flight: each re-sync re-runs the row provider
      // for the same token — the search is awaited, never re-queried,
      // and its rows land (issue #202).
      final client = fakeClient(
        skills: const [
          SkillOption(
            id: 'main',
            name: 'Main',
            description: 'Accessibility checks',
          ),
        ],
        files: const ['src/main.dart'],
        commands: const [
          OpencodeCommand(name: 'deploy', description: 'Deploy the app'),
        ],
      );
      client.findFilesGate = Completer<void>();
      client.commandsGate = Completer<void>();
      client.skillGate = Completer<void>();
      await _pump(tester, client: client);

      await _typePrompt(tester, '@ma');
      await tester.pump();
      await tester.pump();

      // The search for the token is in flight: the menu keeps its (empty)
      // rows on screen, the token queried once.
      expect(find.text('No matching mention'), findsOneWidget);
      expect(client.fileQueries, const [('ses_1', 'ma')]);
      expect(client.skillCalls, 1);
      expect(client.commandCalls, 1);

      // The commands land: the bar re-syncs for the rebuilt menus.
      client.commandsGate!.complete();
      await tester.pump();
      await tester.pump();

      // The search for the same token was not re-fired...
      expect(client.fileQueries, const [('ses_1', 'ma')]);
      expect(_commandRowFinder('file:src/main.dart'), findsNothing);

      // The skills land: the bar re-syncs again — still no re-fire.
      client.skillGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(client.fileQueries, const [('ses_1', 'ma')]);

      // The search completes: the menu settles on the full rows, the
      // skills above the files.
      client.findFilesGate!.complete();
      await tester.pump();
      await tester.pump();

      expect(client.fileQueries, const [
        ('ses_1', 'ma'),
      ], reason: 'the unchanged token must not be re-queried');
      expect(_commandRowFinder('skill:main'), findsOneWidget);
      expect(_commandRowFinder('file:src/main.dart'), findsOneWidget);
      expect(
        tester.getTopLeft(_commandRowFinder('skill:main')).dy,
        lessThan(tester.getTopLeft(_commandRowFinder('file:src/main.dart')).dy),
      );
    });

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

      // The mention lands with a trailing space (issue #140), the cursor
      // after it.
      expect(_promptText(tester), 'please read @src/main.dart ');
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

        // The trailing space (issue #140) goes first, then the mention
        // whole — not one char at a time.
        await tester.showKeyboard(find.byKey(_promptInput));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(_promptText(tester), 'please read @src/main.dart');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(_promptText(tester), 'please read ');

        // Delete from before the mention removes it forward (its trailing
        // space is a plain character and stays).
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
        expect(_promptText(tester), 'please read  ');
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
      expect(_promptText(tester), '@a11y ');

      await _typePrompt(tester, '@a11y and @');
      await tester.pump();
      await tester.pump();
      await tester.tap(_commandRowFinder('file:src/main.dart'));
      await tester.pump();
      await tester.pump();
      expect(_promptText(tester), '@a11y and @src/main.dart ');

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

    testWidgets('a first failed skills fetch stays retryable: the @ menu '
        'shows the skills after the next open succeeds (issue #201)', (
      tester,
    ) async {
      final client = fakeClient();
      client.skillResults = const [
        [], // the first open's fetch fails...
        [
          SkillOption(id: 'a11y', name: 'A11y', description: 'Accessibility'),
        ], // ...the re-open's fetch succeeds.
      ];
      client.skillError = SessionsClientError(500, 'skill registry');
      await _pump(tester, client: client);

      // The first @ open: the fetch fails. The failure stays silent — no
      // unhandled error, no error state — and the menu shows no skill rows.
      await _typePrompt(tester, '@');
      await tester.pump();
      await tester.pump();
      expect(client.skillCalls, 1);
      expect(find.text('Could not'), findsNothing);
      expect(_commandRowFinder('skill:a11y'), findsNothing);
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsOneWidget,
      );

      // The @ leaves its token (a space closes the menu), then a fresh @
      // re-opens it: the failed fetch is retried and the skill rows land.
      await _typePrompt(tester, '@ ');
      await tester.pump();
      client.skillError = null;
      await _typePrompt(tester, '@');
      await tester.pump();
      await tester.pump();
      expect(client.skillCalls, 2);
      expect(_commandRowFinder('skill:a11y'), findsOneWidget);
    });

    testWidgets('a successful skills fetch keeps its result for the rest of '
        'the visit (issue #201)', (tester) async {
      final client = fakeClient(
        skills: const [
          SkillOption(id: 'a11y', name: 'A11y', description: 'Accessibility'),
        ],
      );
      await _pump(tester, client: client);

      // The first @ open fetches and shows the skill rows.
      await _typePrompt(tester, '@');
      await tester.pump();
      await tester.pump();
      expect(client.skillCalls, 1);
      expect(_commandRowFinder('skill:a11y'), findsOneWidget);

      // A later @ open (the token closed, then re-typed) shows the kept
      // result: no second fetch.
      await _typePrompt(tester, '@ ');
      await tester.pump();
      await _typePrompt(tester, '@');
      await tester.pump();
      await tester.pump();
      expect(client.skillCalls, 1);
      expect(_commandRowFinder('skill:a11y'), findsOneWidget);
    });

    testWidgets('while a skills fetch is in flight, further @ opens start no '
        'duplicate fetch (issue #201)', (tester) async {
      final client = fakeClient(
        skills: const [
          SkillOption(id: 'a11y', name: 'A11y', description: 'Accessibility'),
        ],
      );
      client.skillGate = Completer<void>();
      await _pump(tester, client: client);

      // The first @ open starts the fetch, held in flight.
      await _typePrompt(tester, '@');
      await tester.pump();
      expect(client.skillCalls, 1);
      expect(_commandRowFinder('skill:a11y'), findsNothing);

      // The @ leaves its token, then a fresh @ re-opens while the fetch is
      // still in flight: no duplicate fetch starts.
      await _typePrompt(tester, '@ ');
      await tester.pump();
      await _typePrompt(tester, '@');
      await tester.pump();
      await tester.pump();
      expect(client.skillCalls, 1);

      // The held fetch resolves: the single fetch's result lands on the open
      // menu.
      client.skillGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(client.skillCalls, 1);
      expect(_commandRowFinder('skill:a11y'), findsOneWidget);
    });
  });

  group('StructuredSessionScreen multiline prompt field (issue #200)', () {
    /// The prompt field's rendered height (logical pixels).
    double fieldHeight(WidgetTester tester) =>
        tester.getSize(find.byKey(_promptInput)).height;

    /// The field's inner scroll position (its internal scroll past the cap).
    ScrollPosition fieldScroll(WidgetTester tester) => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(_promptInput),
            matching: find.byType(Scrollable),
          ),
        )
        .position;

    /// Types [lines] lines of [line] into the field (a multiline prompt).
    Future<void> typeLines(WidgetTester tester, int lines, String line) async {
      await tester.enterText(
        find.byKey(_promptInput),
        List.filled(lines, line).join('\n'),
      );
      await tester.pump();
    }

    testWidgets('grows with the lines up to the cap and scrolls internally '
        'past it', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      final h1 = fieldHeight(tester);
      await typeLines(tester, 2, 'one');
      final h2 = fieldHeight(tester);
      await typeLines(tester, 3, 'one');
      final h3 = fieldHeight(tester);
      await typeLines(tester, 5, 'one');
      final h5 = fieldHeight(tester);

      // The field grows as lines are added…
      expect(h2, greaterThan(h1));
      expect(h3, greaterThan(h2));
      expect(h5, greaterThan(h3));
      // …and the cap: past five lines the height holds and the text scrolls
      // inside the field instead of growing it.
      await typeLines(tester, 10, 'one');
      final h10 = fieldHeight(tester);
      expect(
        h10,
        closeTo(h5, 0.5),
        reason: 'the height is capped at five lines',
      );
      expect(
        fieldScroll(tester).maxScrollExtent,
        greaterThan(0),
        reason: 'ten lines in a five-line field scroll internally',
      );
    });

    testWidgets(
      'Enter submits the multiline prompt; Shift+Enter inserts a newline '
      'instead',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client);
        await tester.showKeyboard(find.byKey(_promptInput));

        // Enter sends the prompt with its newlines intact, and the field
        // clears on the successful send.
        await tester.enterText(
          find.byKey(_promptInput),
          'explain\nthis in detail',
        );
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump();

        expect(client.prompts, const [
          ('ses_1', 'explain\nthis in detail', null, null),
        ]);
        expect(_promptText(tester), isEmpty);

        // Shift+Enter inserts a newline (no send, the field keeps growing).
        await tester.enterText(find.byKey(_promptInput), 'first');
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        await tester.pump();

        expect(
          client.prompts,
          hasLength(1),
          reason: 'the newline must not send',
        );
        expect(_promptText(tester), 'first\n');
      },
    );

    testWidgets('a whitespace-only field (newlines included) does not send', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);
      await tester.showKeyboard(find.byKey(_promptInput));

      await tester.enterText(find.byKey(_promptInput), ' \n  ');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(client.prompts, isEmpty);
      expect(_promptText(tester), ' \n  ');
    });

    testWidgets('a failed send keeps the multiline text in the field', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        promptError: const SessionsClientError(502, 'opencode_unreachable'),
      );
      await _pump(tester, client: client);
      await tester.showKeyboard(find.byKey(_promptInput));

      await tester.enterText(find.byKey(_promptInput), 'line one\nline two');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(client.prompts, isEmpty);
      expect(_promptText(tester), 'line one\nline two');
      expect(
        find.text('Could not send the message (status 502).'),
        findsOneWidget,
      );
    });

    testWidgets(
      'the / menu still opens and filters when the token is followed by a '
      'newline',
      (tester) async {
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client);

        // A trailing newline does not join the token: `/compact` still
        // filters to the `compact` row (the newline ends the token like a
        // space does).
        await _typePrompt(tester, '/compact\n');
        await tester.pump();

        expect(_menuFinder(), findsOneWidget);
        expect(_commandRowFinder('compact'), findsOneWidget);
        expect(_commandRowFinder('models'), findsNothing);
      },
    );

    testWidgets(
      'a newline before the @ token does not stop the menu from opening and '
      'filtering',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          skills: const [
            SkillOption(id: 'auth', name: 'Auth', description: 'Auth helpers'),
          ],
        );
        await _pump(tester, client: client);

        // The newline sits on the previous line; the @ token on the new line
        // still opens the menu and filters (the token is `auth`, not the
        // whole text).
        await _typePrompt(tester, 'check the docs\n@auth');
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const ValueKey('structured-command-menu-card')),
          findsOneWidget,
        );
        expect(_commandRowFinder('skill:auth'), findsOneWidget);
        expect(client.fileQueries, const [('ses_1', 'auth')]);
      },
    );

    testWidgets('a newline after the @ token closes the menu, like a space', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        skills: const [
          SkillOption(id: 'auth', name: 'Auth', description: 'Auth helpers'),
        ],
      );
      await _pump(tester, client: client);

      await _typePrompt(tester, '@auth');
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsOneWidget,
      );
      // The file search ran for the bare token.
      expect(client.fileQueries, const [('ses_1', 'auth')]);

      // A newline after the token ends it (like a space does): the menu
      // closes, and the token never picked up the trailing newline.
      await _typePrompt(tester, '@auth\n');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsNothing,
      );
      expect(client.fileQueries, const [('ses_1', 'auth')]);
    });
  });

  group('StructuredSessionScreen mobile keyboard send action (issue #203)', () {
    /// The action the prompt field advertises to the IME toolbar: `send` on
    /// mobile (the soft keyboard's send button), `done` on desktop (the
    /// hardware Enter/Shift+Enter handling is unchanged from issue #200).
    TextInputAction? promptAction(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(_promptInput)).textInputAction;

    testWidgets('the prompt field advertises the send action on mobile', (
      tester,
    ) async {
      // The soft keyboard's toolbar shows Send on both mobile platforms.
      for (final platform in const [
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final client = _FakeClient(details: const [_detail0]);
        final events = await _pump(tester, client: client);
        expect(
          promptAction(tester),
          TextInputAction.send,
          reason: 'the soft keyboard advertises Send on $platform',
        );
        await events.close();
      }
      // The binding verifies the foundation debug variables are reset before
      // the test's teardowns run: the override must be cleared in the body.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'tapping the send action posts the trimmed prompt and clears the '
      'field',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client);

        // The send action carries the field's current text (whitespace and
        // newlines and all); the send path trims it, and the field clears on
        // the successful POST (the same rules as the existing send path).
        await tester.enterText(find.byKey(_promptInput), '  trim me  \n');
        await tester.pump();
        await _pressSend(tester);
        await tester.pump();

        expect(client.prompts, const [('ses_1', 'trim me', null, null)]);
        expect(_promptText(tester), isEmpty, reason: 'cleared on success');
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('the send action does not post a whitespace-only prompt', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await tester.enterText(find.byKey(_promptInput), ' \n  ');
      await tester.pump();
      await _pressSend(tester);
      await tester.pump();

      expect(client.prompts, isEmpty);
      expect(_promptText(tester), ' \n  ');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a second send while one is in flight is ignored', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final promptGate = Completer<void>();
      final client = _FakeClient(
        details: const [_detail0],
        promptGate: promptGate,
      );
      await _pump(tester, client: client);

      await tester.enterText(find.byKey(_promptInput), 'keep going');
      await tester.pump();
      // The first send posts, held in flight by the gate.
      await _pressSend(tester);
      await tester.pump();
      expect(client.prompts, isEmpty, reason: 'still in flight');
      expect(_promptText(tester), 'keep going');

      // A second send while the first is in flight is ignored (the busy
      // guard): the field keeps its text and no second POST is queued.
      await tester.showKeyboard(find.byKey(_promptInput));
      await _pressSend(tester);
      await tester.pump();
      expect(client.prompts, isEmpty, reason: 'the busy send is ignored');
      expect(_promptText(tester), 'keep going');

      // The first send resolves: exactly one prompt lands and the field
      // clears.
      promptGate.complete();
      await tester.pump();
      await tester.pump();
      expect(client.prompts, const [('ses_1', 'keep going', null, null)]);
      expect(_promptText(tester), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'the mobile keyboard return key inserts a newline, it does not send',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final client = _FakeClient(details: const [_detail0]);
        await _pump(tester, client: client);
        await tester.showKeyboard(find.byKey(_promptInput));

        await tester.enterText(find.byKey(_promptInput), 'first line');
        await tester.pump();

        // The soft keyboard's return key sends the IME a newline: the
        // framework inserts it into the multiline field (the default
        // behavior) without finalizing, so nothing is sent.
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'first line\n',
            selection: TextSelection.collapsed(offset: 11),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(client.prompts, isEmpty, reason: 'the newline must not send');
        expect(_promptText(tester), 'first line\n');
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('the prompt field keeps the done action on desktop', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      // Desktop is unchanged from issue #200: the hardware Enter sends and
      // Shift+Enter inserts a newline (the existing multiline tests cover
      // both), so the IME action stays `done`.
      expect(
        promptAction(tester),
        TextInputAction.done,
        reason: 'desktop keeps the hardware key handling',
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('StructuredSessionScreen prompt menu taps keep the field focused '
      '(issue #140)', () {
    /// The prompt field's own focus node: the node a keystroke must reach.
    FocusNode promptFocus(WidgetTester tester) =>
        tester.widget<EditableText>(find.byType(EditableText)).focusNode;

    testWidgets('tapping an @ menu row inserts the mention and the field '
        'keeps the primary focus', (tester) async {
      final client = _FakeClient(
        details: const [_detail0],
        skills: const [
          SkillOption(id: 'a11y', name: 'A11y', description: 'Accessibility'),
        ],
        filesFound: const ['src/main.dart'],
      );
      await _pump(tester, client: client);

      await tester.tap(find.byKey(_promptInput));
      await tester.pump();
      await _typePrompt(tester, 'please read @sr');
      await tester.pump();
      await tester.pump();
      expect(_menuFinder(), findsOneWidget);
      expect(promptFocus(tester).hasPrimaryFocus, isTrue);

      await tester.tap(_commandRowFinder('file:src/main.dart'));
      await tester.pump();
      await tester.pump();

      // The menu closed, the mention landed with its trailing space, and the
      // field never lost focus: the soft keyboard stays up, the next
      // keystroke goes straight into the field.
      expect(_menuFinder(), findsNothing);
      expect(_promptText(tester), 'please read @src/main.dart ');
      expect(
        promptFocus(tester).hasPrimaryFocus,
        isTrue,
        reason: 'a row tap must not steal the field\'s primary focus',
      );
    });

    testWidgets('tapping an @ skill row keeps the focus and lands the cursor '
        'after the trailing space', (tester) async {
      final client = _FakeClient(
        details: const [_detail0],
        skills: const [
          SkillOption(id: 'a11y', name: 'A11y', description: 'Accessibility'),
        ],
      );
      await _pump(tester, client: client);

      await tester.tap(find.byKey(_promptInput));
      await tester.pump();
      await _typePrompt(tester, 'use the @a11');
      await tester.pump();
      await tester.pump();
      expect(_menuFinder(), findsOneWidget);

      await tester.tap(_commandRowFinder('skill:a11y'));
      await tester.pump();
      await tester.pump();

      expect(_promptText(tester), 'use the @a11y ');
      expect(_caret(tester), 'use the @a11y '.length);
      expect(promptFocus(tester).hasPrimaryFocus, isTrue);
      // The caret right after the inserted mention (and its space) is not a
      // live filter token: the suppression holds, the menu stays closed.
      expect(
        find.byKey(const ValueKey('structured-command-menu-card')),
        findsNothing,
      );
    });

    testWidgets('the trailing space goes first on Backspace, then the whole '
        'mention', (tester) async {
      final client = _FakeClient(
        details: const [_detail0],
        filesFound: const ['src/main.dart'],
      );
      await _pump(tester, client: client);

      await tester.tap(find.byKey(_promptInput));
      await tester.pump();
      await _typePrompt(tester, '@sr');
      await tester.pump();
      await tester.pump();
      await tester.tap(_commandRowFinder('file:src/main.dart'));
      await tester.pump();
      await tester.pump();

      // First Backspace: the trailing space. Next: the whole mention.
      await tester.showKeyboard(find.byKey(_promptInput));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(_promptText(tester), '@src/main.dart');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(_promptText(tester), isEmpty);
    });

    testWidgets('tapping a / menu row runs the command, clears the field, '
        'and keeps the focus', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await tester.tap(find.byKey(_promptInput));
      await tester.pump();
      await _typePrompt(tester, '/compact');
      await tester.pump();
      expect(_menuFinder(), findsOneWidget);

      await tester.tap(_commandRowFinder('compact'));
      await tester.pump();
      await tester.pump();

      expect(client.compacts, 1);
      expect(_promptText(tester), isEmpty);
      expect(
        promptFocus(tester).hasPrimaryFocus,
        isTrue,
        reason: 'after the command runs, typing goes straight back in',
      );
    });

    testWidgets('tapping a / row that waits for its argument keeps the menu '
        'held and the focus, and the argument types straight in', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await tester.tap(find.byKey(_promptInput));
      await tester.pump();
      await _typePrompt(tester, '/rename');
      await tester.pump();
      expect(_menuFinder(), findsOneWidget);

      await tester.tap(_commandRowFinder('rename'));
      await tester.pump();
      await tester.pump();

      // The command waits for its argument: the menu holds, the field keeps
      // the focus so the argument is typed without tapping again.
      expect(_menuFinder(), findsOneWidget);
      expect(client.renames, isEmpty);
      expect(promptFocus(tester).hasPrimaryFocus, isTrue);

      await _typePrompt(tester, '/rename my title');
      await tester.pump();
      await _pressEnter(tester);
      expect(client.renames, const [('ses_1', 'my title')]);
    });

    testWidgets('after a row tap the keyboard menu controls behave as if the '
        'row had been picked with Enter', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pump(tester, client: client);

      await tester.tap(find.byKey(_promptInput));
      await tester.pump();
      await _typePrompt(tester, '/re');
      await tester.pump();
      expect(_menuFinder(), findsOneWidget);

      // Tap the `rename` row: the argument is missing, so the menu holds —
      // exactly as Enter on it would.
      await tester.tap(_commandRowFinder('rename'));
      await tester.pump();
      await tester.pump();
      expect(_menuFinder(), findsOneWidget);

      // The arrows still drive the menu selection (the field owns the keys,
      // the cursor does not move): down lands on `rename`, the second row.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(
        editable.textEditingValue.selection,
        const TextSelection.collapsed(offset: 3),
        reason: 'the menu owns the arrows; the field cursor stays put',
      );
      await _pressEnter(tester);
      expect(client.renames, isEmpty); // rename holds: no argument yet
      expect(_promptText(tester), '/re');

      // Escape still dismisses the menu by clearing the field.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_promptText(tester), isEmpty);
      expect(_menuFinder(), findsNothing);
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

  group('StructuredSessionPanel embedded (issue #130)', () {
    testWidgets('renders in a Row pane with no navigator route', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        messages: const [
          SessionMessage(role: 'user', text: 'hello'),
          SessionMessage(role: 'assistant', text: 'done'),
          // The Turn is closed: the header shows the title, not the
          // Active-turn indicator (issue #161).
          SessionMessage(id: 'i1', role: 'idle'),
        ],
      );
      await _pumpEmbedded(tester, client: client);

      // The header, the cost bar, the history, and the prompt input all
      // render embedded — the same widgets the full-screen route shows.
      expect(find.text('list pane'), findsOneWidget);
      expect(find.text('external session'), findsOneWidget);
      expect(find.byKey(const ValueKey('structured-cost')), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('done'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('structured-prompt-input')),
        findsOneWidget,
      );

      // Embedded in the root route: no back button (there is nothing to
      // pop), where the pushed route shows one.
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('the prompt sends from the pane', (tester) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pumpEmbedded(tester, client: client);

      await _typePrompt(tester, 'keep going');
      // Enter sends the prompt (the Send button is now the Stop control).
      await _pressEnter(tester);
      await tester.pump();
      await tester.pump();

      expect(client.prompts, [('ses_1', 'keep going', null, null)]);
      expect(_promptText(tester), isEmpty);
      // The locally appended user message shows in the pane's history.
      expect(find.text('keep going'), findsOneWidget);
    });

    testWidgets(
      'the permission banner sits in flow above the pane\'s prompt bar, the '
      'list constrained above it (issue #205)',
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
          ],
        );
        final events = await _pumpEmbedded(tester, client: client);

        events.add(_event('permission.asked', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();

        expect(find.text('Permission requested: shell'), findsOneWidget);
        // In flow, not floating: the list meets the panel's top (no overlap)
        // and the panel meets the prompt bar's top.
        final listRect = tester.getRect(_chatListFinder());
        final panelRect = tester.getRect(_pendingPanelsFinder());
        final promptRect = tester.getRect(_promptBarFinder());
        expect(listRect.bottom, moreOrLessEquals(panelRect.top, epsilon: 0.5));
        expect(
          panelRect.bottom,
          moreOrLessEquals(promptRect.top, epsilon: 0.5),
        );

        await tester.tap(find.byKey(const ValueKey('permission-once-per_1')));
        await tester.pump();
        await tester.pump();
        expect(client.replies, const [
          ('ses_1', 'per_1', PermissionReply.once),
        ]);
        await events.close();
      },
    );

    testWidgets('a slash command opens its menu and runs from the pane', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      await _pumpEmbedded(tester, client: client);

      await _typePrompt(tester, '/compact');
      await tester.pump();
      expect(_menuFinder(), findsOneWidget);
      await _pressEnter(tester);

      expect(client.compacts, 1);
    });

    testWidgets('the navigation commands call onClose, not a navigator pop', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      final calls = <String>[];
      await _pumpEmbedded(tester, client: client, calls: calls);

      await _typePrompt(tester, '/clear');
      await tester.pump();
      await _pressEnter(tester);

      // The view asks to close (the host's callback), then the flow runs —
      // and nothing popped: the root route (and the list pane) is intact.
      expect(calls, ['close', 'new-session']);
      expect(find.text('list pane'), findsOneWidget);
      expect(find.text('external session'), findsOneWidget);
    });

    testWidgets('the flow runs without closing when onClose is not wired', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      final calls = <String>[];
      await _pumpEmbedded(tester, client: client, calls: calls, wired: false);
      // onNewSession stays wired (the test host always wires it); only
      // onClose is absent: the view cannot close itself, the flow runs.
      await _typePrompt(tester, '/clear');
      await tester.pump();
      await _pressEnter(tester);

      expect(calls, ['new-session']);
      expect(find.byType(StructuredSessionPanel), findsOneWidget);
    });

    testWidgets('onClose can drop the pane; the panel unmounts cleanly', (
      tester,
    ) async {
      final client = _FakeClient(details: const [_detail0]);
      final calls = <String>[];
      final events = await _pumpEmbedded(
        tester,
        client: client,
        calls: calls,
        hideWhenClosed: true,
      );

      await _typePrompt(tester, '/clear');
      await tester.pump();
      await _pressEnter(tester);
      await tester.pump();

      expect(calls, ['close', 'new-session']);
      expect(find.byType(StructuredSessionPanel), findsNothing);

      // The lifecycle is bound to the panel's own mount: an event after the
      // pane is gone is dropped, no exception.
      events.add(_event('permission.asked', aggregateID: 'ses_1'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'switching sessionId reloads the panel for the new session and the '
      'event stream follows it (issue #131)',
      (tester) async {
        final client = _SessionSwitchClient();
        final events = StreamController<BridgeEvent>.broadcast();
        String sessionId = 'ses_a';
        String title = 'alpha';
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: Column(
                  children: [
                    Expanded(
                      child: StructuredSessionPanel(
                        sessionId: sessionId,
                        title: title,
                        client: client,
                        events: events.stream,
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('switch'),
                      onPressed: () => setState(() {
                        sessionId = 'ses_b';
                        title = 'beta';
                      }),
                      child: const Text('switch'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('alpha'), findsOneWidget);
        expect(find.text('alpha says hi'), findsOneWidget);
        expect(find.text('beta says hi'), findsNothing);

        // An event for the selected session applies.
        events.add(
          _event(
            'session.usage.updated',
            aggregateID: 'ses_a',
            data: {
              'cost': 0.5,
              'tokens': {
                'input': 0,
                'output': 0,
                'reasoning': 0,
                'cache': {'read': 0, 'write': 0},
              },
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('Cost \$0.5000'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('switch')));
        await tester.pumpAndSettle();

        // The pane swapped in place: new session's title and history, no
        // stale content from the previous session.
        expect(find.text('beta'), findsOneWidget);
        expect(find.text('beta says hi'), findsOneWidget);
        expect(find.text('alpha says hi'), findsNothing);
        expect(find.text('Cost \$0.5000'), findsNothing);

        // Events for the old session are ignored; events for the new session
        // follow it.
        events.add(
          _event(
            'session.usage.updated',
            aggregateID: 'ses_a',
            data: {
              'cost': 0.9,
              'tokens': {
                'input': 0,
                'output': 0,
                'reasoning': 0,
                'cache': {'read': 0, 'write': 0},
              },
            },
          ),
        );
        await tester.pump();
        expect(find.text('Cost \$0.9000'), findsNothing);

        events.add(
          _event(
            'session.usage.updated',
            aggregateID: 'ses_b',
            data: {
              'cost': 0.2,
              'tokens': {
                'input': 0,
                'output': 0,
                'reasoning': 0,
                'cache': {'read': 0, 'write': 0},
              },
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('Cost \$0.2000'), findsOneWidget);
      },
    );
  });

  group('StructuredSessionScreen exhausted retry (issue #157)', () {
    /// The header outcome chip's text (its key is `structured-outcome`).
    String chipText(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('structured-outcome')),
            matching: find.byType(Text),
          ),
        )
        .data!;

    /// A previous, successful turn: its closing `idle` marker is
    /// `succeeded`.
    const previousTurn = <SessionMessage>[
      SessionMessage(role: 'user', text: 'go', created: 0),
      SessionMessage(id: 'a0', role: 'assistant', text: 'ok'),
      SessionMessage(id: 'i0', role: 'idle', outcome: 'succeeded'),
    ];

    /// The captured failed turn replayed through the real bridge parser
    /// (issue #154's probe fixture): a user prompt and an `idle` marker
    /// carrying `outcome: failed` + the provider error, no assistant row.
    /// Returns its `[user, idle(failed)]` rows.
    Future<List<SessionMessage>> parseFailedTurn(WidgetTester tester) async {
      final parsed = await _parseFixture(
        tester,
        'test/fixtures/retry/message_failed_model_unavailable.json',
      );
      expect(parsed.length, 2);
      expect(parsed.first.role, 'user');
      expect(parsed.last.role, 'idle');
      return parsed;
    }

    testWidgets(
      'a failed turn opened with no event stream shows the terminal error '
      'block and a `failed` chip (durable first)',
      (tester) async {
        final failedTurn = await parseFailedTurn(tester);
        // The detail still reports the PREVIOUS turn's `succeeded` (the
        // session-level outcome is stale); the chip must show the newest
        // turn's `failed`, and the block must render from /messages alone.
        final client = _FakeClient(
          details: [_detailOutcome('succeeded')],
          messages: failedTurn,
        );
        // Opened with NO event stream (durable-first, issue #157).
        await _pump(tester, client: client, wireEvents: false);

        // The turn-failure block renders on the turn's tail.
        expect(find.byKey(const ValueKey('turn-failure')), findsOneWidget);
        // Its main text is the TUI terminal line, verbatim (the error's
        // message) — no app-invented wording substituted.
        expect(
          find.text('Model unavailable: amd/qwen3.8-flash-next'),
          findsOneWidget,
        );
        // The provider error's type, from the bridge's /messages read.
        expect(find.byKey(const ValueKey('turn-failure-type')), findsOneWidget);
        expect(find.text('provider.no-route'), findsOneWidget);
        // The durable state carried no attempt count, so the block does not
        // invent one (and never invents a maximum).
        expect(
          find.byKey(const ValueKey('turn-failure-attempts')),
          findsNothing,
        );
        // The header outcome chip says `failed`, not the stale `succeeded`.
        expect(chipText(tester), 'failed');
      },
    );

    testWidgets(
      'live (streamed) then normalize: the chip and block settle to `failed` '
      'at the turn boundary',
      (tester) async {
        final failedTurn = await parseFailedTurn(tester);
        // Journaled state: a previous successful turn, then the turn that
        // exhausts its retries. The detail lags the turn (the service's
        // session-level outcome is `succeeded` until the failed boundary), so
        // the chip follows the newest idle marker's verdict.
        final running = [
          ...previousTurn,
          ...failedTurn.sublist(0, 1), // the failing turn's prompt
          SessionMessage(
            id: 'a2',
            role: 'assistant',
            created: 5000,
          ), // in flight
        ];
        final failed = [
          ...running,
          ...failedTurn.sublist(1), // the idle(failed) boundary
        ];
        final client = _FakeClient(
          details: [
            _detailOutcome('succeeded'), // initial
            _detailOutcome('succeeded'), // the started normalize
            _detailOutcome('failed'), // the failed normalize
          ],
          messageLists: [
            [...previousTurn], // initial open
            running, // the started normalize
            failed, // the failed normalize
          ],
        );
        final events = await _pump(tester, client: client);

        // Opened on a settled, successful turn: the chip is `succeeded`, no
        // failure block.
        expect(chipText(tester), 'succeeded');
        expect(find.byKey(const ValueKey('turn-failure')), findsNothing);

        // The turn starts (from another client): the boundary normalize
        // re-fetches; while running the new turn has no closing marker, so
        // the chip keeps the last settled verdict.
        events.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(chipText(tester), 'succeeded');
        expect(find.byKey(const ValueKey('turn-failure')), findsNothing);

        // The turn exhausts its retries: the failed boundary normalize
        // re-fetches detail + history; the chip flips to `failed` and the
        // terminal error block appears on the turn's tail.
        events.add(_event('session.execution.failed', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        expect(chipText(tester), 'failed');
        expect(find.byKey(const ValueKey('turn-failure')), findsOneWidget);
        expect(
          find.text('Model unavailable: amd/qwen3.8-flash-next'),
          findsOneWidget,
        );
        await events.close();
      },
    );

    testWidgets(
      'no state difference remains between "opened fresh and normalized" and '
      '"opened with no events" after the boundary',
      (tester) async {
        final failedTurn = await parseFailedTurn(tester);
        // (A) Opened fresh with no event stream.
        final clientA = _FakeClient(
          details: [_detailOutcome('succeeded')],
          messages: [...previousTurn, ...failedTurn],
        );
        final eventsA = await _pump(tester, client: clientA, wireEvents: false);
        final aBlock = find.byKey(const ValueKey('turn-failure')).evaluate();
        final aMain = find
            .text('Model unavailable: amd/qwen3.8-flash-next')
            .evaluate();
        final aType = find.text('provider.no-route').evaluate();
        final aChip = chipText(tester);
        expect(aBlock.length, 1);
        expect(aChip, 'failed');
        await eventsA.close();

        // (B) Opened with events, then a live turn-boundary normalize (the
        // `session.execution.*` re-fetch path) brings in the same authoritative
        // history the no-events open reads up front.
        final clientB = _FakeClient(
          details: [_detailOutcome('failed'), _detailOutcome('failed')],
          messageLists: [
            [...previousTurn], // initial (the previous turn, settled)
            [...previousTurn, ...failedTurn], // the normalize re-fetch
          ],
        );
        final eventsB = await _pump(tester, client: clientB);
        // A turn-boundary event triggers the normalize (the same path
        // `session.execution.*` uses on success); the re-fetch settles the
        // failed turn into the history.
        eventsB.add(_event('session.execution.started', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        // The turn then fails: a second boundary normalize of the identical
        // history (the live band settles on the failed marker).
        eventsB.add(_event('session.execution.failed', aggregateID: 'ses_1'));
        await tester.pump();
        await tester.pump();
        final bBlock = find.byKey(const ValueKey('turn-failure')).evaluate();
        final bMain = find
            .text('Model unavailable: amd/qwen3.8-flash-next')
            .evaluate();
        final bType = find.text('provider.no-route').evaluate();
        final bChip = chipText(tester);
        await eventsB.close();

        // After the boundary normalize the two renders agree: the block, its
        // main text, its type, and the chip all match.
        expect(bBlock.length, aBlock.length);
        expect(bMain.length, aMain.length);
        expect(bType.length, aType.length);
        expect(bChip, aChip);
        expect(bChip, 'failed');
      },
    );

    testWidgets(
      'a long provider body shows truncated and expands to the full string on '
      'tap (it cannot blow out the bubble)',
      (tester) async {
        // The provider's raw response.body, replayed from the captured
        // in-flight fixture (issue #154): a real 429 body, long enough to
        // truncate.
        final inFlight = await _parseFixture(
          tester,
          'test/fixtures/retry/message_429_inflight_attempt_3.json',
        );
        final assistant = inFlight.firstWhere((m) => m.role == 'assistant');
        final body = assistant.retry?.error.body;
        expect(body, isA<String>());
        expect((body as String).length, greaterThan(60));
        // An exhausted-429 terminal: the terminal error (carrying the
        // provider's raw response.body) lands on the assistant row, and the
        // turn's idle carries `outcome: failed` (the probe's assumption A1).
        final exhausted = <SessionMessage>[
          ...previousTurn,
          SessionMessage(role: 'user', text: 'one', created: 10000),
          SessionMessage(
            id: 'a2',
            role: 'assistant',
            error: StructuredError(
              type: 'provider.rate-limit',
              message: 'Provider request failed with HTTP 429: (see body)',
              status: 429,
              body: body,
            ),
            created: 10000,
            completed: 11000,
          ),
          SessionMessage(id: 'i2', role: 'idle', outcome: 'failed'),
        ];
        final client = _FakeClient(
          details: [_detailOutcome('failed')],
          messages: exhausted,
        );
        final events = await _pump(tester, client: client);

        // The block renders; its body is present, truncated by default.
        expect(find.byKey(const ValueKey('turn-failure')), findsOneWidget);
        final bodyKey = find.byKey(const ValueKey('turn-failure-body'));
        expect(bodyKey, findsOneWidget);
        var widget = tester.widget<Text>(
          find.descendant(of: bodyKey, matching: find.byType(Text)),
        );
        expect(widget.data, body);
        expect(widget.maxLines, 3); // clamped, ellipsized.

        // Tapping expands it to the full string (no clamp).
        await tester.tap(bodyKey);
        await tester.pump();
        widget = tester.widget<Text>(
          find.descendant(of: bodyKey, matching: find.byType(Text)),
        );
        expect(widget.data, body);
        expect(widget.maxLines, null);
        await events.close();
      },
    );

    testWidgets(
      'an interrupted turn is not styled as a failure (no block, chip '
      '`interrupted`)',
      (tester) async {
        const interrupted = <SessionMessage>[
          ...previousTurn,
          SessionMessage(role: 'user', text: 'one', created: 10000),
          SessionMessage(id: 'a2', role: 'assistant', text: 'partial'),
          SessionMessage(id: 'i2', role: 'idle', outcome: 'interrupted'),
        ];
        final client = _FakeClient(
          details: [_detailOutcome('interrupted')],
          messages: interrupted,
        );
        final events = await _pump(tester, client: client, wireEvents: false);

        // Not a failure: no terminal error block (a failed-turn style).
        expect(find.byKey(const ValueKey('turn-failure')), findsNothing);
        // The chip carries the interrupted verdict, distinct from `failed`.
        expect(chipText(tester), 'interrupted');
        await events.close();
      },
    );

    testWidgets(
      'a successful turn keeps showing no error block and a `succeeded` chip',
      (tester) async {
        final client = _FakeClient(
          details: [_detailOutcome('succeeded')],
          messages: [...previousTurn],
        );
        final events = await _pump(tester, client: client, wireEvents: false);
        expect(find.byKey(const ValueKey('turn-failure')), findsNothing);
        expect(chipText(tester), 'succeeded');
        await events.close();
      },
    );

    testWidgets(
      'the next successful turn does not inherit the failed block (it stays in '
      'history as the failed turn\'s record body)',
      (tester) async {
        final failedTurn = await parseFailedTurn(tester);
        final nextTurn = <SessionMessage>[
          SessionMessage(role: 'user', text: 'again', created: 20000),
          SessionMessage(
            id: 'a3',
            role: 'assistant',
            text: 'ok',
            created: 20000,
          ),
          SessionMessage(id: 'i3', role: 'idle', outcome: 'succeeded'),
        ];
        final client = _FakeClient(
          details: [_detailOutcome('succeeded')],
          messages: [...previousTurn, ...failedTurn, ...nextTurn],
        );
        final events = await _pump(tester, client: client, wireEvents: false);

        // Exactly ONE failure block — on the failed turn's marker, not the
        // new successful turn's (the live band's error does not persist into
        // the next turn).
        expect(find.byKey(const ValueKey('turn-failure')), findsOneWidget);
        // The failed turn's block still carries its provider copy (history).
        expect(
          find.text('Model unavailable: amd/qwen3.8-flash-next'),
          findsOneWidget,
        );
        // The newest turn succeeded: the chip follows the latest verdict.
        expect(chipText(tester), 'succeeded');
        await events.close();
      },
    );
  });

  group('StructuredSessionPanel in-flow pending panels (issue #205)', () {
    const smallForm = QuestionForm(
      id: 'form_small',
      title: 'Confirm',
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

    const stateForm = QuestionForm(
      id: 'form_state',
      title: 'State',
      questions: [
        Question(
          header: 'Ship it?',
          question: 'Should I ship it?',
          multiple: false,
          custom: true,
          options: [
            QuestionOption(label: 'Yes', description: 'ship'),
            QuestionOption(label: 'No', description: 'hold'),
          ],
        ),
        Question(
          header: 'Areas',
          question: 'Which areas?',
          multiple: true,
          custom: true,
          options: [
            QuestionOption(label: 'A', description: 'a'),
            QuestionOption(label: 'B', description: 'b'),
          ],
        ),
      ],
    );

    testWidgets(
      'the pending panels sit in the chat region flow between the list and '
      'the prompt bar — the list is constrained above them, not overlapped',
      (tester) async {
        final client = _FakeClient(
          details: const [_detail0],
          questionLists: const [
            <QuestionForm>[smallForm],
          ],
        );
        await _pump(tester, client: client);

        expect(_chatListFinder(), findsOneWidget);
        // The panel is in flow (not a floating Positioned over the list).
        expect(_pendingPanelsFinder(), findsOneWidget);
        expect(find.byKey(const ValueKey('question-banner')), findsOneWidget);

        final listRect = tester.getRect(_chatListFinder());
        final panelRect = tester.getRect(_pendingPanelsFinder());
        final promptRect = tester.getRect(_promptBarFinder());

        // The list is above the panel: its bottom meets the panel's top
        // (contiguous in the Column — the panel does not float over the
        // list, so no message text is covered).
        expect(listRect.bottom, moreOrLessEquals(panelRect.top, epsilon: 0.5));
        // The panel is above the prompt bar.
        expect(
          panelRect.bottom,
          moreOrLessEquals(promptRect.top, epsilon: 0.5),
        );
        // The panel is below the list's head (it does not cover the list's
        // top), so the list keeps its own space above it.
        expect(panelRect.top, greaterThan(listRect.top));
      },
    );

    testWidgets(
      'a tall form is capped at ~half the chat region and scrolls internally',
      (tester) async {
        final tallForm = QuestionForm(
          id: 'form_tall',
          title: 'Tall',
          questions: [
            Question(
              header: 'Pick',
              question: 'Pick one',
              multiple: false,
              custom: false,
              options: [
                for (var i = 0; i < 25; i++)
                  QuestionOption(
                    label: 'Option $i',
                    description: 'Description for option $i',
                  ),
              ],
            ),
          ],
        );
        final client = _FakeClient(
          details: const [_detail0],
          questionLists: [
            <QuestionForm>[tallForm],
          ],
        );
        await _pump(tester, client: client);

        expect(_chatListFinder(), findsOneWidget);
        expect(_pendingPanelsFinder(), findsOneWidget);

        final listRect = tester.getRect(_chatListFinder());
        final panelRect = tester.getRect(_pendingPanelsFinder());
        final promptRect = tester.getRect(_promptBarFinder());

        // The region the Column fills (list + panel + prompt bar).
        final regionHeight =
            listRect.height + panelRect.height + promptRect.height;
        // The panel is capped at ~half the region: the tall form does not grow
        // it past half, so the prompt bar and a slice of the list stay visible.
        expect(
          panelRect.height,
          moreOrLessEquals(regionHeight / 2, epsilon: 1.0),
        );
        // The list and the prompt bar keep at least the other half.
        expect(
          listRect.height + promptRect.height,
          greaterThanOrEqualTo(regionHeight / 2 - 1.0),
        );
        // The form is taller than the cap: the panel content scrolls
        // internally beyond it.
        final scroll = tester.state<ScrollableState>(
          find.descendant(
            of: _pendingPanelsFinder(),
            matching: find.byType(Scrollable),
          ),
        );
        expect(scroll.position.maxScrollExtent, greaterThan(0));
      },
    );

    testWidgets('no residual gap where the panel was once nothing is pending', (
      tester,
    ) async {
      final client = _FakeClient(
        details: const [_detail0],
        questionLists: const [
          <QuestionForm>[smallForm],
          <QuestionForm>[],
        ],
      );
      final events = await _pump(tester, client: client);

      // With the form pending, the list meets the panel's top.
      expect(_pendingPanelsFinder(), findsOneWidget);
      var listRect = tester.getRect(_chatListFinder());
      var panelRect = tester.getRect(_pendingPanelsFinder());
      expect(listRect.bottom, moreOrLessEquals(panelRect.top, epsilon: 0.5));

      // Answer the form: the panel clears.
      await tester.tap(
        find.byKey(const ValueKey('question-option-form_small-0-0')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('question-submit-form_small')),
      );
      await tester.pump();
      await tester.pump();
      await events.close();

      // No panel in flow any more…
      expect(_pendingPanelsFinder(), findsNothing);
      expect(find.byKey(const ValueKey('question-banner')), findsNothing);
      // …and the list meets the prompt bar's top directly: no empty gap
      // where the panel used to be (the list occupies the full region).
      listRect = tester.getRect(_chatListFinder());
      final promptRect = tester.getRect(_promptBarFinder());
      expect(listRect.bottom, moreOrLessEquals(promptRect.top, epsilon: 0.5));
    });

    testWidgets(
      'form state (selections, free text, active tab) survives new messages '
      'arriving while the form is pending',
      (tester) async {
        // A tall surface so the two-question form fits under the panel cap and
        // its buttons stay tappable (at the default 800×600 the cap is shorter
        // than this form, so the button row would sit below the fold).
        tester.view.physicalSize = const Size(800, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final client = _FakeClient(
          details: const [_detail0],
          questionLists: const [
            <QuestionForm>[stateForm],
          ],
        );
        final events = await _pump(tester, client: client);
        expect(_pendingPanelsFinder(), findsOneWidget);

        // On tab 0: select an option and type a free-text answer (set on the
        // controller directly — no keyboard focus, so the region does not
        // reshape mid-test).
        await tester.tap(
          find.byKey(const ValueKey('question-option-form_state-0-0')),
        );
        await tester.pump();
        tester
                .widget<TextField>(
                  find.byKey(const ValueKey('question-text-form_state-0')),
                )
                .controller!
                .text =
            'quietly';
        await tester.pump();
        // Move to tab 1 (the active tab) and select an option there.
        await tester.tap(
          find.byKey(const ValueKey('question-next-form_state')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('question-option-form_state-1-0')),
        );
        await tester.pump();
        expect(find.text('Which areas?'), findsOneWidget);
        expect(find.text('Should I ship it?'), findsNothing);

        // A new message arrives while the form is pending (the agent keeps
        // working): a streamed delta appends an in-flight assistant message.
        events.add(
          _event(
            'session.text.delta',
            aggregateID: 'ses_1',
            data: {'assistantMessageID': 'asst_live', 'delta': 'working…'},
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60)); // 48 ms flush

        // The panel is still in flow (it did not drop out on the rebuild)…
        expect(_pendingPanelsFinder(), findsOneWidget);
        // …the active tab survived (still on tab 1: Q1 shown, Q0 not)…
        expect(find.text('Which areas?'), findsOneWidget);
        expect(find.text('Should I ship it?'), findsNothing);
        // …and Q1's selection survived.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('question-option-form_state-1-0')),
            matching: find.byIcon(Icons.radio_button_checked),
          ),
          findsOneWidget,
        );

        // Back to tab 0: Q0's selection and typed free text survived too.
        await tester.tap(
          find.byKey(const ValueKey('question-back-form_state')),
        );
        await tester.pump();
        expect(find.text('Should I ship it?'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('question-option-form_state-0-0')),
            matching: find.byIcon(Icons.radio_button_checked),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('question-text-form_state-0')),
              )
              .controller!
              .text,
          'quietly',
        );
        await events.close();
      },
    );
  });
}
