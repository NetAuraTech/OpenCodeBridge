import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../app_info.dart';
import '../client/events_client.dart';
import '../client/sessions_client.dart';
import '../model/command.dart';
import '../model/message.dart';
import '../model/permission.dart';
import '../model/question.dart';
import '../model/session_detail.dart';
import '../model/turn_stats.dart';
import '../settings/app_settings.dart';
import 'diff_view.dart';
import 'permission_banner.dart';
import 'prompt_menu.dart';
import 'question_panel.dart';
import 'slash_commands.dart';

/// An image read from the clipboard (issue #72): its raw bytes and mime type,
/// sent to the model as a `files` data-URI attachment.
class ClipboardImage {
  const ClipboardImage({required this.bytes, required this.mime});

  /// The image's raw bytes.
  final Uint8List bytes;

  /// The image's mime type (e.g. `image/png`).
  final String mime;
}

/// The outcome of a clipboard image read (issue #72): the clipboard's
/// image, or `null` when there is none — plus, for a read that cannot
/// produce an image, a user-visible [failureMessage] saying how to get one
/// (e.g. the read tool is not installed and how to install it).
class ClipboardImageRead {
  const ClipboardImageRead({this.image, this.failureMessage});

  /// The clipboard's image, or `null` when there is none.
  final ClipboardImage? image;

  /// How to get an image read, to show the user (issue #72), or `null` when
  /// there is nothing to report (a plain "no image").
  final String? failureMessage;
}

/// Reads the clipboard's image (issue #72): no image reads as no [image],
/// and a read that cannot produce one (e.g. the read tool is not installed)
/// reports how to enable it. Injectable so the screen's tests can fake the
/// read.
typedef ClipboardImageReader = Future<ClipboardImageRead> Function();

/// The service's per-attachment decoded image limit (issue #72): the service
/// materializes inline data URLs up to 20 MiB decoded, so an image over it
/// would be rejected — the client pre-checks and reports it instead of
/// leaving a dead token.
const int _kMaxClipboardImageBytes = 20 * 1024 * 1024;

/// The image targets the default reader looks for, most preferred first
/// (issue #72); when none of these is offered, any `image/` target is used.
const List<String> _kPreferredImageTargets = [
  'image/png',
  'image/bmp',
  'image/jpeg',
  'image/jpg',
  'image/gif',
];

/// The default clipboard image reader (issue #72): desktop Linux only, with
/// no new package dependency — X11 via `xclip`, Wayland via `wl-paste`. The
/// reader lists the clipboard's targets, picks an image one, and reads its
/// bytes; any other platform, a failing read, or a clipboard with no image
/// reads as no image. A missing tool reports how to install it, so the user
/// can enable image paste.
Future<ClipboardImageRead> _readClipboardImage() async {
  if (!Platform.isLinux || Platform.isAndroid) {
    return const ClipboardImageRead();
  }
  final env = Platform.environment;
  final wayland =
      env.containsKey('WAYLAND_DISPLAY') ||
      env['XDG_SESSION_TYPE'] == 'wayland';
  final tool = wayland ? 'wl-paste' : 'xclip';
  try {
    Future<List<int>> run(List<String> args) async {
      final result = await Process.run(tool, args, stdoutEncoding: null);
      if (result.exitCode != 0) return const <int>[];
      return result.stdout as List<int>;
    }

    final targets = utf8
        .decode(
          await run(
            wayland
                ? const ['--list']
                : const ['-selection', 'clipboard', '-t', 'TARGETS', '-o'],
          ),
        )
        .split('\n')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    String? target;
    for (final preferred in _kPreferredImageTargets) {
      if (targets.contains(preferred)) {
        target = preferred;
        break;
      }
    }
    if (target == null) {
      for (final t in targets) {
        if (t.startsWith('image/')) {
          target = t;
          break;
        }
      }
    }
    if (target == null) return const ClipboardImageRead();

    final bytes = await run(
      wayland
          ? ['--type', target]
          : ['-selection', 'clipboard', '-t', target, '-o'],
    );
    if (bytes.isEmpty) return const ClipboardImageRead();
    return ClipboardImageRead(
      image: ClipboardImage(bytes: Uint8List.fromList(bytes), mime: target),
    );
  } on ProcessException {
    // The tool is not installed: report how to enable the read.
    return ClipboardImageRead(
      failureMessage: wayland
          ? 'Clipboard image paste needs wl-paste '
                '(sudo apt install wl-clipboard).'
          : 'Clipboard image paste needs xclip (sudo apt install xclip).',
    );
  } catch (_) {
    return const ClipboardImageRead();
  }
}

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
    this.gaps,
    this.onNewSession,
    this.onOpenSettings,
    this.settings,
    this.onThemeModeChanged,
    this.imageReader,
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

  /// Durable-seq gaps for this session's source, when it reports them: a
  /// gap means events were missed (typically across a reconnect), so the
  /// view re-fetches its state and the final content is always complete.
  final Stream<SessionGap>? gaps;

  /// The `/` menu's navigation commands (`/new`, `/sessions`, `/open`,
  /// `/settings`, `/clear`): the screen closes and the app runs the flow.
  /// `null` leaves the command in the menu but a no-op (the menu still opens).
  final FutureOr<void> Function()? onNewSession;

  /// `/settings`: open the app's Settings tab.
  final FutureOr<void> Function()? onOpenSettings;

  /// The app's settings (issue #49): `/themes` reads and persists the theme
  /// choice from here. `null` leaves `/themes` a note that it is
  /// unavailable.
  final AppSettings? settings;

  /// Re-themes the whole app live after `/themes` persists the choice
  /// (issue #49); `null` leaves the choice persisted but unapplied until a
  /// relaunch.
  final VoidCallback? onThemeModeChanged;

  /// Reads the clipboard's image on Ctrl+V in the prompt bar (issue #72),
  /// or `null` for the default desktop-Linux reader (`xclip` / `wl-paste`).
  /// Injectable so the view's tests can fake the read.
  final ClipboardImageReader? imageReader;

  @override
  State<StructuredSessionScreen> createState() =>
      _StructuredSessionScreenState();
}

class _StructuredSessionScreenState extends State<StructuredSessionScreen> {
  SessionDetail? _detail;

  List<SessionMessage> _messages = const [];

  List<PermissionRequest> _pending = const [];

  /// The session's pending question forms (issue #50), the agent's
  /// `question` tool.
  List<QuestionForm> _questions = const [];

  /// The question form whose answer (or dismissal) is in flight.
  String? _answerBusyId;

  /// True until the initial load (endpoints 5, 6, 8) settles.
  bool _loading = true;

  /// The initial load failure, if any.
  String? _loadError;

  /// True while a prompt send (endpoint 7) is in flight.
  bool _promptBusy = false;

  /// True while the session's context compaction streams (from the first
  /// `session.compaction.delta` to its `session.compaction.ended`): the
  /// compaction marker pane shows it.
  bool _compacting = false;

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

  /// The local llama.cpp server's live prefill throughput (tok/s), from the
  /// last `llama.speed` bridge event; `null` while idle or decoding.
  double? _prefill;

  /// The live decode throughput (tok/s); `null` while idle or prefilling. At
  /// most one of [_prefill] / [_decode] is set at a time.
  double? _decode;

  /// Assistant message id -> its index in [_messages]. Seeded with the loaded
  /// history, so a turn already running when the view opens streams into the
  /// in-flight message the service's context includes (not a duplicate);
  /// re-seeded after every load and turn-boundary normalize.
  final Map<String, int> _liveMessages = {};

  /// The index in [_messages] of the session's compaction marker — the
  /// history's last compaction item when the history ends in one (re-seeded
  /// after every load), the live marker while the compaction streams — or
  /// `null` while there is none.
  int? _compactionIndex;

  /// In-flight tool call id -> its index in its message's tool list (the
  /// list is append-only, so the index is stable).
  final Map<String, int> _liveTools = {};

  /// In-flight tool call id -> the id of the message its card lives in.
  final Map<String, String> _liveToolsOf = {};

  /// In-flight message id -> whether the next streamed text part must be
  /// joined with the newline that separates the parts of the history (the
  /// same join the service's context history uses between its parts).
  final Map<String, bool> _needsSep = {};

  /// The same, for streamed reasoning parts.
  final Map<String, bool> _needsSepReasoning = {};

  /// Follow the streaming content to the bottom, until the user scrolls up
  /// (re-engage by scrolling back to the bottom).
  bool _stick = true;

  /// Whether the viewport sits at the bottom of the history (within the
  /// stick threshold): shows the jump-to-end button while the user has
  /// scrolled up.
  bool _atBottom = true;

  final ScrollController _scroll = ScrollController();

  StreamSubscription<BridgeEvent>? _events;

  StreamSubscription<SessionGap>? _gapsSub;

  /// Streamed text deltas waiting for the next coalesced flush, by message
  /// id (arrival order preserved; the part-boundary newline is folded in).
  final Map<String, StringBuffer> _pendingDeltas = {};

  /// The same, for streamed reasoning deltas.
  final Map<String, StringBuffer> _pendingReasoning = {};

  /// The pending-delta flush in flight, or `null` between flushes.
  Timer? _flush;

  /// How long streamed tokens buffer before one coalesced rebuild. A
  /// per-token rebuild of the whole history starved the event loop during a
  /// burst — and with it the bridge's relay of the very tokens being shown.
  static const Duration _flushPeriod = Duration(milliseconds: 48);

  /// True while a turn-boundary re-fetch (normalize) is in flight.
  bool _normalizing = false;

  /// The cursor to the next OLDER page of the history (issue #124): the
  /// bounded turn read left it where the current Turn's opener was, and the
  /// lazy loads follow it as the reader scrolls up. `null` once the oldest
  /// page is loaded.
  String? _oldestCursor;

  /// True when the whole history is loaded (no older page remains): the first
  /// Turn's footer is only shown then (its opening marker does not exist).
  bool _oldestLoaded = false;

  /// True while an older page of the history is being fetched (issue #124's
  /// lazy load as the reader scrolls up).
  bool _loadingOlder = false;

  /// The history generation (issue #124): bumped whenever an authoritative
  /// read (the initial load or a normalize) replaces the history. An older
  /// page fetched under an older generation is stale — the normalize already
  /// re-read the turn and moved the cursor — and its result is dropped rather
  /// than blindly prepended (which would duplicate messages and desync the
  /// cursor).
  int _historyGeneration = 0;

  /// The current time (epoch millis) the running turn's live footer ticks
  /// from (issue #124): refreshed by [_liveTick] while the turn is active.
  int? _liveNow;

  /// The timer that refreshes [_liveNow] (the live footer's ticking duration)
  /// while a turn is running.
  Timer? _liveTick;

  /// The small page size the bounded turn read and the lazy older loads use
  /// (issue #124): small enough that a read covers the current turn plus a
  /// little overshoot, never the whole history.
  static const int _turnPageLimit = 50;

  /// How far up from the oldest loaded message (in px) the lazy load kicks
  /// in as the reader scrolls through the history.
  static const double _olderLoadMargin = 300;

  final TextEditingController _prompt = TextEditingController();

  /// The title shown in the app bar: the route's title at first, replaced by
  /// `/rename` while the view stays open.
  String _title = '';

  /// The `/` menu's rows (issue #46): the static catalog until the project's
  /// custom commands land (fetched when the menu first opens).
  List<SlashCommand> _commands = SlashCommands.catalog;

  /// The prompt bar's menus (issue #56), one per trigger; rebuilt when the
  /// project's custom commands or the session's skills land (the bar
  /// re-filters on the change).
  late List<PromptMenuDefinition> _menus;

  /// The project's custom commands have been requested already (the menu
  /// keeps showing the static catalog when the fetch fails).
  bool _commandsFetched = false;

  /// The `@` menu's skill rows (issue #58): the session's skills, fetched
  /// when a menu first opens (`const []` until then, or when the fetch
  /// fails).
  List<SkillOption> _skills = const [];

  /// The session's skills have been requested already.
  bool _skillsFetched = false;

  /// The `@` menu's file search results, by the token they were searched
  /// for: the service's search is queried once per token (issue #58).
  String? _filesToken;

  List<String>? _files;

  /// The mentions committed to the prompt (issue #58), in pick order: the
  /// field's text carries them as typed (`@<id>` / `@<path>`); each
  /// deletes as one unit and sends as an attachment.
  List<_Mention> _mentions = const [];

  /// The images committed to the prompt by Ctrl+V pastes (issue #72), in
  /// paste order: the field's text carries their `[Image N]` tokens; each
  /// deletes as one unit and sends as a `files` data-URI attachment.
  List<_PendingImage> _images = const [];

  /// True while a `/` command runs (the prompt bar is disabled so a command
  /// cannot be double-run).
  bool _commandBusy = false;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _menus = _buildMenus();
    _prompt.addListener(_onPromptCleared);
    _scroll.addListener(_onScroll);
    _loadInitial();
    final stream = widget.events;
    if (stream != null) {
      _events = stream.listen(_onEvent);
    }
    final gaps = widget.gaps;
    if (gaps != null) {
      _gapsSub = gaps.listen(_onGap);
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _gapsSub?.cancel();
    _flush?.cancel();
    _liveTick?.cancel();
    _prompt.removeListener(_onPromptCleared);
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // The newest message is the list's anchor (offset 0): "at the end" is
    // the viewport sitting at the anchor (within the stick threshold).
    final atBottom = position.pixels <= 8;
    _stick = atBottom;
    if (atBottom != _atBottom) {
      _atBottom = atBottom;
      if (mounted) setState(() {});
    }
    // The reader has scrolled up toward the oldest loaded message: pull in
    // the next older page so the earlier Turns fill in (issue #124).
    if (position.pixels >= position.maxScrollExtent - _olderLoadMargin) {
      _loadOlder();
    }
  }

  /// After content grows at the newest end (the list's anchor at offset 0),
  /// keeps a scrolled-up reader's view stable: the growth shifts every other
  /// message up by the grown amount, so the reader's scroll follows by the
  /// same. A following reader needs nothing — the anchor is pinned at offset
  /// 0, so the newest line stays at the bottom of the viewport for free.
  void _compensateGrow(double oldScroll, double oldMax) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_stick) return; // the reader returned to the anchor meanwhile.
      final position = _scroll.position;
      final delta = position.maxScrollExtent - oldMax;
      if (delta > 0) position.jumpTo(oldScroll + delta);
    });
  }

  /// The jump-to-end button: animates back to the anchor (the newest message)
  /// and re-engages the bottom-follow. The anchor is offset 0, so the
  /// animation lands exactly — no settle pass is needed.
  void _jumpToEnd() {
    if (!_scroll.hasClients) return;
    _stick = true;
    _scroll.position.animateTo(
      0.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// The initial state: detail (costs), the current Turn's history (bounded
  /// read, issue #124 — never the whole history), and the pending permission
  /// requests (endpoints 5, 6, 8).
  Future<void> _loadInitial() async {
    try {
      final results = await Future.wait<Object?>([
        widget.client.getDetail(widget.sessionId),
        _loadTurn(),
        widget.client.getPermissions(widget.sessionId),
        widget.client.getQuestions(widget.sessionId),
      ]);
      if (!mounted) return;
      // The fetched history is authoritative: drop the streamed leftovers.
      _flush?.cancel();
      _flush = null;
      _pendingDeltas.clear();
      _pendingReasoning.clear();
      setState(() {
        _detail = results.first as SessionDetail;
        _applyTurn(results[1] as MessagePage);
        _pending = results[2] as List<PermissionRequest>;
        _questions = results[3] as List<QuestionForm>;
        _loading = false;
        _compacting = false;
        _seedLiveMessages();
        _seedContextUsed();
        _reconcileTurnActive(results.first as SessionDetail);
      });
      // The newest message is the list's anchor (offset 0), so the open
      // lands on it for free — no settle, no crawl.
      _stick = true;
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

  /// The bounded read of the session's current Turn (issue #124): the
  /// newest-first pages that cover it, oldest-first, plus the cursor to the
  /// next older page (the lazy-load continuation) — `null` once the history
  /// is exhausted.
  Future<MessagePage> _loadTurn() => loadCurrentTurn(
    fetchPage: (cursor) => widget.client.getMessagesPage(
      widget.sessionId,
      limit: _turnPageLimit,
      cursor: cursor,
    ),
  );

  /// Re-derives the Active state from a freshly-read state (issue #124).
  /// While Active, only the authoritative history closes the Turn: the
  /// re-fetch ending on its `idle` marker (the end event may have been
  /// missed across a stream gap — the live footer can never tick on a
  /// finished Turn). While settled, the detail's Active fact (the service's
  /// active list) or a mid-Turn history activates it: a Turn whose newest
  /// persisted step has just completed (shape cannot tell) still shows the
  /// live footer.
  void _reconcileTurnActive(SessionDetail detail) {
    if (_turnActive) {
      // The history ends closed AND the service no longer lists the session
      // Active: only then does a re-fetch deactivate (a normalize racing
      // just after the turn started may still see the old closing marker).
      if (_openedIdle() && !detail.active) _setTurnActive(false);
      return;
    }
    if (detail.active || _openedMidTurn()) _setTurnActive(true);
  }

  /// Whether the loaded history ends on the `idle` marker that closed the
  /// Turn.
  bool _openedIdle() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == 'compaction') continue;
      return _messages[i].role == 'idle';
    }
    return false;
  }

  /// Whether the view opened on a session mid-Turn (issue #124): the newest
  /// content row is an assistant step that has not completed (it is still
  /// streaming), or the prompt that just started the Turn — so the Turn is
  /// Active and the live footer shows immediately, with the duration
  /// measured from the Turn's first prompt (not the open time). An `idle`
  /// marker at the newest end means the Turn has settled.
  bool _openedMidTurn() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final message = _messages[i];
      switch (message.role) {
        case 'assistant':
          return message.completed == null;
        case 'user':
        case 'synthetic':
          return true;
        case 'idle':
          // The newest marker closes the Turn: the session is settled.
          return false;
        default:
          continue; // `compaction` carries no signal.
      }
    }
    return false;
  }

  /// Installs the page of an authoritative turn read (issue #124): the
  /// bounded load and the normalize both replace the history with it and
  /// rearm the lazy older-page cursor from it. Bumps the history generation
  /// so an older page still in flight is recognized as stale.
  void _applyTurn(MessagePage turn) {
    _historyGeneration++;
    _messages = turn.messages;
    _oldestCursor = turn.nextCursor;
    _oldestLoaded = turn.nextCursor == null;
  }

  /// Sets the running state, starting the live footer's ticking timer while
  /// the Turn is active and stopping it otherwise (issue #124).
  void _setTurnActive(bool active) {
    if (active && !_turnActive) _startLiveTick();
    if (!active && _turnActive) _stopLiveTick();
    if (mounted) setState(() => _turnActive = active);
  }

  void _startLiveTick() {
    _stopLiveTick();
    _liveNow = DateTime.now().millisecondsSinceEpoch;
    _liveTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _liveNow = DateTime.now().millisecondsSinceEpoch);
    });
  }

  void _stopLiveTick() {
    _liveTick?.cancel();
    _liveTick = null;
  }

  /// (Re-)indexes the loaded history so the live maps track every message
  /// and tool call it already carries (a turn may be running when the view
  /// opens, or a normalize just replaced the history).
  void _seedLiveMessages() {
    _liveMessages.clear();
    _liveTools.clear();
    _liveToolsOf.clear();
    _needsSep.clear();
    _needsSepReasoning.clear();
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
    // The last content row: the history may end in the idle marker that
    // closed the turn, past which a live compaction marker would ride.
    var last = _messages.length - 1;
    while (last >= 0 && _messages[last].role == 'idle') {
      last--;
    }
    _compactionIndex = last >= 0 && _messages[last].role == 'compaction'
        ? last
        : null;
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
    // Bridge-native, not per-session: the local llama.cpp server's
    // prefill/decode throughput, shown in the header for whichever session is
    // open.
    if (event.type == 'llama.speed') {
      _applySpeed(event.data);
      return;
    }
    if (!_forSession(event)) return;
    switch (event.type) {
      case 'session.execution.started':
        // The turn is about to run: the live footer takes over (issue #124),
        // and the service's authoritative state is re-fetched so a prompt sent
        // from another client (whose user message the service persisted before
        // the turn started) is visible here without a manual reload. The
        // streamed in-flight content that arrives after this re-fetch keeps
        // growing the message it lands in.
        _setTurnActive(true);
        _normalize();
        break;
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.interrupted':
        _setTurnActive(false);
        _normalize();
        break;
      case 'session.usage.updated':
        _applyUsage(event.data);
        break;
      case 'session.step.ended':
        _applyStepEnded(event.data);
        break;
      case 'session.compaction.delta':
        _applyCompactionDelta(event.data);
        break;
      case 'session.compaction.ended':
        _applyCompactionEnded(event.data);
        break;
      case 'session.text.started':
        _applyPartStarted(event.data, reasoning: false);
        break;
      case 'session.reasoning.started':
        _applyPartStarted(event.data, reasoning: true);
        break;
      case 'session.text.delta':
        _applyPartDelta(event.data, reasoning: false);
        break;
      case 'session.reasoning.delta':
        _applyPartDelta(event.data, reasoning: true);
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
      // The agent's `question` tool (issue #50): the form appears, is
      // answered, or is dismissed. The `form.created` payload nests the
      // session under `data.form` (matched in [_forSession]).
      case 'form.created':
      case 'form.replied':
      case 'form.cancelled':
        _refreshQuestions();
        break;
    }
  }

  /// True when [event] belongs to this session: the durable aggregate id, or
  /// the payload's `sessionID` when the event carries no durable position.
  /// `form.created` nests the session under `data.form` (the form object),
  /// so that shape is matched too.
  bool _forSession(BridgeEvent event) {
    final durable = event.durable;
    if (durable != null) {
      return durable.aggregateID == widget.sessionId;
    }
    if (event.data['sessionID'] == widget.sessionId) return true;
    final form = event.data['form'];
    return form is Map<String, Object?> &&
        form['sessionID'] == widget.sessionId;
  }

  /// A `llama.speed` payload moves the header's prefill/decode throughput.
  void _applySpeed(Map<String, Object?> data) {
    final prefill = (data['prefill'] as num?)?.toDouble();
    final decode = (data['decode'] as num?)?.toDouble();
    if (prefill == _prefill && decode == _decode) return;
    if (mounted) {
      setState(() {
        _prefill = prefill;
        _decode = decode;
      });
    }
  }

  /// A durable-seq gap for this session (events were missed, typically
  /// across a reconnect): re-fetch the service's authoritative state, so a
  /// missed stretch of the stream never leaves partial content on screen.
  void _onGap(SessionGap gap) {
    if (gap.aggregateID == widget.sessionId) _normalize();
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
    String? reasoning,
    List<ToolCall>? tools,
  }) => SessionMessage(
    id: message.id,
    role: message.role,
    text: text ?? message.text,
    reasoning: reasoning ?? message.reasoning,
    tools: tools ?? message.tools,
    created: message.created,
    streamed: message.streamed,
    completed: message.completed,
    outputTokens: message.outputTokens,
    reasoningTokens: message.reasoningTokens,
  );

  /// A part (`reasoning:0`, `text:1`, …) starts: from the next delta on, the
  /// streamed content is a new part, so it joins the history with the part
  /// newline whenever the message already carries content of the same kind
  /// (including deltas still buffered for the next flush). Reasoning and
  /// text are separate fields, so they never join each other.
  void _applyPartStarted(Map<String, Object?> data, {required bool reasoning}) {
    final id = _messageId(data);
    if (id == null || !mounted) return;
    setState(() {
      _ensureLiveMessage(id);
      final message = _messages[_liveMessages[id]!];
      final stored = reasoning ? message.reasoning : message.text;
      final pending = (reasoning ? _pendingReasoning : _pendingDeltas)[id];
      (reasoning ? _needsSepReasoning : _needsSep)[id] =
          (stored != null && stored.isNotEmpty) ||
          (pending != null && pending.isNotEmpty);
    });
  }

  /// Replaces the message at [index] (copy-on-write: the list may be
  /// unmodifiable, e.g. seeded from a `const` history in tests).
  void _setMessageAt(int index, SessionMessage message) {
    final list = List<SessionMessage>.of(_messages)..[index] = message;
    _messages = list;
  }

  /// A streamed token: buffered with the part-boundary newline, applied to
  /// the in-flight message at the next coalesced flush (reasoning deltas
  /// buffer toward [SessionMessage.reasoning], text deltas toward
  /// [SessionMessage.text]). Buffering — instead of a per-token rebuild of
  /// the whole history — is what keeps the event loop free to keep the
  /// bridge relay alive while a burst arrives.
  void _applyPartDelta(Map<String, Object?> data, {required bool reasoning}) {
    final id = _messageId(data);
    final delta = data['delta'] is String ? data['delta'] as String : null;
    if (id == null || delta == null || !mounted) return;
    _ensureLiveMessage(id);
    final pending = (reasoning ? _pendingReasoning : _pendingDeltas)[id] ??=
        StringBuffer();
    if ((reasoning ? _needsSepReasoning : _needsSep).remove(id) == true) {
      pending.write('\n');
    }
    pending.write(delta);
    _scheduleFlush();
  }

  /// Starts the pending-delta flush, if none is already running: the buffer
  /// collects at most [_flushPeriod] of tokens before one rebuild.
  void _scheduleFlush() {
    if (_flush != null) return;
    _flush = Timer(_flushPeriod, _flushPending);
  }

  /// Applies every buffered token to its in-flight message in one rebuild.
  void _flushPending() {
    _flush = null;
    if (_pendingDeltas.isEmpty && _pendingReasoning.isEmpty) return;
    if (!mounted) {
      _pendingDeltas.clear();
      _pendingReasoning.clear();
      return;
    }
    final oldScroll = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final oldMax = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    setState(() {
      for (final entry in _pendingDeltas.entries) {
        final index = _liveMessages[entry.key];
        if (index == null) continue;
        final message = _messages[index];
        _setMessageAt(
          index,
          _rebuildMessage(
            message,
            text: (message.text ?? '') + entry.value.toString(),
          ),
        );
      }
      for (final entry in _pendingReasoning.entries) {
        final index = _liveMessages[entry.key];
        if (index == null) continue;
        final message = _messages[index];
        _setMessageAt(
          index,
          _rebuildMessage(
            message,
            reasoning: (message.reasoning ?? '') + entry.value.toString(),
          ),
        );
      }
      _pendingDeltas.clear();
      _pendingReasoning.clear();
    });
    _compensateGrow(oldScroll, oldMax);
  }

  /// The session's compaction marker: the history's last compaction item
  /// (re-seeded after every load), or a fresh marker appended to the
  /// history on first sight (the service's marker id is unknown until the
  /// turn-boundary re-fetch, so the live one is keyed by a fixed id).
  int _ensureCompactionMessage() {
    final index = _compactionIndex;
    if (index != null &&
        index < _messages.length &&
        _messages[index].role == 'compaction') {
      return index;
    }
    _messages = [
      ..._messages,
      const SessionMessage(id: 'compaction', role: 'compaction'),
    ];
    _compactionIndex = _messages.length - 1;
    _liveMessages['compaction'] = _compactionIndex!;
    return _compactionIndex!;
  }

  /// A streamed token of the compaction summary. The `session.compaction`
  /// payload carries only the session's id and the token (no message id),
  /// so the marker is tracked by [_compactionIndex]; the token buffers like
  /// a text delta toward the marker's text, so the summary is visible as
  /// it is written.
  void _applyCompactionDelta(Map<String, Object?> data) {
    final text = data['text'] is String ? data['text'] as String : null;
    if (text == null || !mounted) return;
    _compacting = true;
    _ensureCompactionMessage();
    (_pendingDeltas['compaction'] ??= StringBuffer()).write(text);
    _scheduleFlush();
  }

  /// The compaction finished: the payload carries the full summary, which is
  /// authoritative and replaces the streamed one, and the marker settles.
  void _applyCompactionEnded(Map<String, Object?> data) {
    final text = data['text'] is String ? data['text'] as String : null;
    if (!mounted) return;
    _pendingDeltas.remove('compaction');
    setState(() {
      _compacting = false;
      if (text != null) {
        final index = _ensureCompactionMessage();
        final message = _messages[index];
        _setMessageAt(index, _rebuildMessage(message, text: text));
      }
    });
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

  /// The tool finished: the success payload carries the file patch (the
  /// history's tool-state shape, `metadata.files[0].patch`), so the live card
  /// shows the same diff the reopened history does. A `write` carries no
  /// service patch, so its diff is synthesized from the content the
  /// `session.tool.called` event stored on the card.
  void _applyToolSuccess(Map<String, Object?> data) {
    final toolId = data['id'] is String ? data['id'] as String : null;
    if (toolId == null || !mounted) return;
    final servicePatch = _patchFromState(data);
    final answers = _answersFromState(data);
    setState(
      () => _updateToolCard(
        toolId,
        (tool) => _rebuildTool(
          tool,
          status: 'completed',
          patch:
              servicePatch ??
              (tool.name == 'write' ? ToolCall.writePatch(tool.input) : null),
          answers: answers,
        ),
      ),
    );
  }

  /// The tool's file patch from a tool-state payload — the success event's
  /// `data`, and the history's tool `state`, both carry
  /// `metadata.files[0].patch` (the unified diff the terminal renders).
  static String? _patchFromState(Map<String, Object?> state) {
    final metadata = state['metadata'];
    final files = metadata is Map<String, Object?> ? metadata['files'] : null;
    if (files is List && files.isNotEmpty) {
      final first = files.first;
      if (first is Map<String, Object?> && first['patch'] is String) {
        return first['patch'] as String;
      }
    }
    return null;
  }

  /// The answers the user gave the agent's `question` tool (issue #50), from
  /// a tool-state payload — the success event's `data` and the history's tool
  /// `state` both carry `metadata.answers` — so the live card settles on the
  /// same question/answer lines the reopened history shows.
  static List<List<String>>? _answersFromState(Map<String, Object?> state) {
    final metadata = state['metadata'];
    return metadata is Map<String, Object?>
        ? ToolCall.answersFrom(metadata['answers'])
        : null;
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

  /// The context the model call used: the call's total input — the fresh
  /// input plus the prompt-cache reads and writes (the `input` alone is
  /// only the uncached slice, which read the context as nearly empty).
  void _applyStepEnded(Map<String, Object?> data) {
    final tokens = data['tokens'];
    if (tokens is! Map<String, Object?>) return;
    final input = (tokens['input'] as num?)?.toInt();
    if (input == null || !mounted) return;
    final cache = tokens['cache'] is Map<String, Object?>
        ? tokens['cache'] as Map<String, Object?>
        : const <String, Object?>{};
    final used =
        input +
        ((cache['read'] as num?)?.toInt() ?? 0) +
        ((cache['write'] as num?)?.toInt() ?? 0);
    setState(() => _contextUsed = used);
  }

  /// Seeds the context gauge from the history: the last assistant message
  /// that carries its tokens is the session's last model call, so an
  /// opened session shows the context the session really is in — not only
  /// the steps streamed since the open. A live `session.step.ended` is
  /// always newer, so it is never overridden.
  void _seedContextUsed() {
    if (_contextUsed != null) return;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final used = _messages[i].contextTokens;
      if (used != null) {
        _contextUsed = used;
        return;
      }
    }
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

  /// A [ToolCall] copy with [name], [status], [input], [error], [patch], and
  /// [answers] replaced.
  ToolCall _rebuildTool(
    ToolCall tool, {
    String? name,
    String? status,
    Object? input,
    String? error,
    String? patch,
    List<List<String>>? answers,
  }) => ToolCall(
    id: tool.id,
    name: name ?? tool.name,
    status: status ?? tool.status,
    input: input ?? tool.input,
    error: error ?? tool.error,
    patch: patch ?? tool.patch,
    answers: answers ?? tool.answers,
  );

  /// The turn boundary just ended (or started): re-fetch the service's
  /// authoritative state (endpoints 5, 6, 8) — the streamed in-flight
  /// content is replaced by the history, and the detail's context window
  /// follows the session's model. A transient failure keeps the screen.
  Future<void> _normalize() async {
    if (_normalizing) return; // One re-fetch at a time; it takes the latest.
    _normalizing = true;
    try {
      final results = await Future.wait<Object?>([
        widget.client.getDetail(widget.sessionId),
        _loadTurn(),
        widget.client.getPermissions(widget.sessionId),
        widget.client.getQuestions(widget.sessionId),
      ]);
      if (!mounted) return;
      // The fetched history is authoritative: drop the streamed leftovers.
      _flush?.cancel();
      _flush = null;
      _pendingDeltas.clear();
      _pendingReasoning.clear();
      setState(() {
        _detail = results.first as SessionDetail;
        _applyTurn(results[1] as MessagePage);
        _pending = results[2] as List<PermissionRequest>;
        _questions = results[3] as List<QuestionForm>;
        _compacting = false;
        _seedLiveMessages();
        _seedContextUsed();
        // The re-fetch is the authoritative word on whether the Turn is
        // still Active (issue #124): a missed end event (a stream gap)
        // cannot leave the live footer ticking on a finished Turn.
        _reconcileTurnActive(results.first as SessionDetail);
      });
      // A following reader sits on the anchor (offset 0), which is the new
      // newest message — nothing to re-settle.
    } on SessionsClientError {
      // Transient (e.g. the service restarted): the next boundary
      // re-fetches.
    } catch (_) {
      // Same: a normalize failure never breaks the view.
    } finally {
      _normalizing = false;
    }
  }

  /// The lazy load (issue #124): fetches the next older page of the history
  /// and prepends it, so the reader scrolling up sees the earlier Turns (and
  /// their footers) fill in. One page at a time keeps the scroll smooth and
  /// never re-fetches what is already loaded.
  Future<void> _loadOlder() async {
    final cursor = _oldestCursor;
    if (cursor == null || _loadingOlder) return;
    _loadingOlder = true;
    final generation = _historyGeneration;
    try {
      final page = await widget.client.getMessagesPage(
        widget.sessionId,
        limit: _turnPageLimit,
        cursor: cursor,
      );
      if (!mounted) return;
      // A normalize (turn boundary, gap) replaced the history while this
      // page was in flight: its cursor belongs to the old read — dropping
      // the page keeps the history and the cursor coherent (issue #124).
      if (generation != _historyGeneration) return;
      setState(() {
        _messages = [...page.messages, ..._messages];
        _oldestCursor = page.nextCursor;
        _oldestLoaded = page.nextCursor == null;
        _seedLiveMessages();
      });
    } on SessionsClientError {
      // Keep the history on screen; the next scroll retry.
    } catch (_) {
      // Same: a failed load never breaks the view.
    } finally {
      _loadingOlder = false;
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

  /// Re-fetches the pending question forms (issue #50); a transient failure
  /// keeps the last list on screen.
  Future<void> _refreshQuestions() async {
    try {
      final questions = await widget.client.getQuestions(widget.sessionId);
      if (!mounted) return;
      setState(() => _questions = questions);
    } on SessionsClientError {
      // Keep the last pending list on screen.
    }
  }

  /// Sends the prompt (endpoint 7), enabled at any time: the bridge forwards
  /// it with `delivery: steer` and the service queues it mid-turn. The user
  /// message is appended locally (the service's copy replaces it at the
  /// turn-boundary normalize) — unless the turn-start re-fetch already brought
  /// in the service's copy, in which case the append is skipped so the prompt
  /// is not shown twice.
  Future<void> _sendPrompt() async {
    final raw = _prompt.text;
    final text = raw.trim();
    if (text.isEmpty || _promptBusy) return;
    final (files, skills) = _attachments(raw);
    setState(() => _promptBusy = true);
    try {
      await widget.client.prompt(
        widget.sessionId,
        text,
        files: files,
        skills: skills,
      );
      _prompt.clear();
      if (!mounted) return;
      // The turn-start re-fetch may have landed between the prompt POST
      // resolving and here and already brought in the service's copy of this
      // user message (the service persists it before the turn starts): the
      // local append would then show the prompt twice. Turns run
      // sequentially, so a user message with this exact text at the tail of
      // the history is this prompt's, not a distinct earlier one.
      final alreadyPresent =
          _messages.isNotEmpty &&
          _messages.last.role == 'user' &&
          _messages.last.text == text;
      if (alreadyPresent) return;
      final oldScroll = _scroll.hasClients ? _scroll.position.pixels : 0.0;
      final oldMax = _scroll.hasClients
          ? _scroll.position.maxScrollExtent
          : 0.0;
      setState(() {
        _messages = [..._messages, SessionMessage(role: 'user', text: text)];
      });
      _compensateGrow(oldScroll, oldMax);
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

  /// The prompt's committed attachments, in text order: at each position the
  /// longest committed text that starts there wins, and every occurrence
  /// counts (one attachment per occurrence). Image tokens (issue #72) send
  /// a `files` data-URI entry (name `clipboard`); file mentions (issue #58)
  /// send a `file://` uri resolved against the session's working directory;
  /// skill mentions send the skill id.
  (List<Map<String, Object?>>?, List<Map<String, Object?>>?) _attachments(
    String text,
  ) {
    final images = [..._images]
      ..sort(
        (a, b) =>
            b.label.toString().length.compareTo(a.label.toString().length),
      );
    final mentions = [..._mentions]
      ..sort((a, b) => b.text.length.compareTo(a.text.length));
    final files = <Map<String, Object?>>[];
    final skills = <Map<String, Object?>>[];
    var index = 0;
    while (index < text.length) {
      _PendingImage? image;
      for (final pending in images) {
        final token = '[Image ${pending.label}]';
        if (text.startsWith(token, index)) {
          image = pending;
          break;
        }
      }
      if (image != null) {
        files.add({
          'uri': 'data:${image.mime};base64,${base64Encode(image.bytes)}',
          'name': 'clipboard',
        });
        index += '[Image ${image.label}]'.length;
        continue;
      }
      _Mention? found;
      for (final mention in mentions) {
        if (text.startsWith(mention.text, index)) {
          found = mention;
          break;
        }
      }
      if (found == null) {
        index++;
        continue;
      }
      if (found.isSkill) {
        skills.add({'id': found.target});
      } else {
        final location = _detail?.location ?? '';
        files.add({'uri': Uri.file('$location/${found.target}').toString()});
      }
      index += found.text.length;
    }
    return (files.isEmpty ? null : files, skills.isEmpty ? null : skills);
  }

  /// The prompt was cleared (Esc, a `/` command, a send): its committed
  /// mentions and pending images are gone with it.
  void _onPromptCleared() {
    if (_prompt.text.isEmpty && (_mentions.isNotEmpty || _images.isNotEmpty)) {
      setState(() {
        _mentions = const [];
        _images = const [];
      });
    }
  }

  /// Ctrl+V in the prompt bar (issue #72): the clipboard's image wins — it is
  /// committed and its atomic `[Image N]` token (plus a space) inserted at
  /// the caret, the clipboard's text not inserted. With no image (or a failed
  /// read) the clipboard's text is pasted exactly as before, and a read that
  /// reports why it produced no image (e.g. the read tool is missing) tells
  /// the user how to enable it.
  Future<void> _pasteFromClipboard() async {
    ClipboardImageRead read;
    try {
      read = await (widget.imageReader ?? _readClipboardImage)();
    } catch (_) {
      read = const ClipboardImageRead();
    }
    final image = read.image;
    if (image == null) {
      await _pasteClipboardText();
      final message = read.failureMessage;
      if (message != null && mounted) _snackBar(message);
      return;
    }
    if (image.bytes.length > _kMaxClipboardImageBytes) {
      // Over the service's decoded limit: report it, leave no dead token.
      if (mounted) _snackBar('The clipboard image is over the 20 MiB limit.');
      return;
    }
    if (!mounted) return;
    // Re-pasting an identical image reuses its committed label; otherwise
    // the label is the highest committed one plus one.
    int? label;
    for (final pending in _images) {
      if (_sameBytes(pending.bytes, image.bytes)) {
        label = pending.label;
        break;
      }
    }
    if (label == null) {
      var next = 1;
      for (final pending in _images) {
        if (pending.label + 1 > next) next = pending.label + 1;
      }
      label = next;
      final pending = _PendingImage(
        label: label,
        bytes: image.bytes,
        mime: image.mime,
      );
      setState(() => _images = [..._images, pending]);
    }
    _insertImageToken(label);
  }

  /// The no-image half of a Ctrl+V paste (issue #72): the clipboard's text is
  /// pasted at the caret (replacing the selection), the caret after it — the
  /// standard text paste.
  Future<void> _pasteClipboardText() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      text = null;
    }
    if (text == null || text.isEmpty || !mounted) return;
    final value = _prompt.value;
    final selection = value.selection;
    _prompt.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  /// Inserts a committed image's token at the caret, followed by a space, the
  /// caret after it (issue #72).
  void _insertImageToken(int label) {
    final token = '[Image $label] ';
    final value = _prompt.value;
    final offset = value.selection.end;
    final text = value.text;
    _prompt.value = TextEditingValue(
      text: text.replaceRange(offset, offset, token),
      selection: TextSelection.collapsed(offset: offset + token.length),
    );
  }

  /// Whether two image byte lists are identical (issue #72): re-pasting an
  /// identical image reuses its committed label.
  bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Tab in the prompt (the menu closed): toggles the session's mode,
  /// `plan` to `build` and `build` (or unset) to `plan`, via the service's
  /// `setAgent` — the session's agent is the single source of truth (the
  /// service's TUIs see the same switch), so normalize afterwards and the
  /// cost bar's mode chip follows.
  Future<void> _toggleMode() async {
    if (_promptBusy || _commandBusy) return;
    final next = _detail?.agent == 'plan' ? 'build' : 'plan';
    try {
      await widget.client.setAgent(widget.sessionId, next);
      if (!mounted) return;
      _snackBar('Mode: $next.');
      _normalize();
    } on SessionsClientError catch (e) {
      if (mounted) _snackBar('Could not switch the mode (${_describe(e)}).');
    } catch (_) {
      if (mounted) _snackBar('Could not switch the mode.');
    }
  }

  /// Ctrl+T in the prompt (the menu closed): cycles the current model's
  /// variants (the reasoning effort) — the TUI's `variant.cycle`: none to
  /// the first variant, the last back to none. The session must carry a
  /// model the registry knows and that exposes variants; otherwise it is
  /// reported, nothing is set.
  Future<void> _cycleVariant() async {
    if (_promptBusy || _commandBusy) return;
    final id = widget.sessionId;
    try {
      final current = await widget.client.currentModel(id);
      ModelOption? model;
      if (current != null) {
        for (final m in await widget.client.listModels(id)) {
          if (m.id == current.id && m.providerId == current.providerId) {
            model = m;
            break;
          }
        }
      }
      if (model == null) {
        if (!mounted) return;
        _snackBar('No model set for the session.');
        return;
      }
      final named = [
        for (final v in model.variants)
          if (v != 'default') v,
      ];
      if (named.isEmpty) {
        if (!mounted) return;
        _snackBar('No variants available.');
        return;
      }
      final variant = _nextVariant(current?.variant, named);
      await widget.client.setModel(
        id,
        ModelRef(id: model.id, providerId: model.providerId, variant: variant),
      );
      if (!mounted) return;
      _snackBar(
        variant == null ? 'Variant set to none.' : 'Variant set to $variant.',
      );
      _normalize();
    } on SessionsClientError catch (e) {
      if (mounted) _snackBar('Could not cycle the variant (${_describe(e)}).');
    } catch (_) {
      if (mounted) _snackBar('Could not cycle the variant.');
    }
  }

  /// The TUI's `cycleModelVariant` on the named variants (the ids that are
  /// not `default`): none (or an id the registry no longer carries) cycles
  /// to the first, the last cycles to none, otherwise the next.
  static String? _nextVariant(String? current, List<String> named) {
    if (named.isEmpty) return null;
    final value = current == 'default' ? null : current;
    if (value == null) return named.first;
    final index = named.indexOf(value);
    if (index == -1 || index == named.length - 1) return null;
    return named[index + 1];
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

  /// Submits the answers to a pending question form (issue #50) and
  /// re-fetches the pending list: the agent continues once the service
  /// records the reply.
  Future<void> _submitAnswers(
    QuestionForm form,
    List<List<String>> answers,
  ) async {
    if (_answerBusyId != null) return;
    setState(() => _answerBusyId = form.id);
    try {
      await widget.client.answerQuestion(widget.sessionId, form.id, answers);
      await _refreshQuestions();
    } on SessionsClientError catch (e) {
      if (mounted) {
        _snackBar(
          'Could not submit the answer '
          '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
        );
      }
    } catch (_) {
      if (mounted) _snackBar('Could not submit the answer.');
    } finally {
      if (mounted) setState(() => _answerBusyId = null);
    }
  }

  /// Dismisses a pending question form (issue #50): the agent continues
  /// without an answer.
  Future<void> _dismissQuestion(QuestionForm form) async {
    if (_answerBusyId != null) return;
    setState(() => _answerBusyId = form.id);
    try {
      await widget.client.dismissQuestion(widget.sessionId, form.id);
      await _refreshQuestions();
    } on SessionsClientError catch (e) {
      if (mounted) {
        _snackBar(
          'Could not dismiss the question '
          '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
        );
      }
    } catch (_) {
      if (mounted) _snackBar('Could not dismiss the question.');
    } finally {
      if (mounted) setState(() => _answerBusyId = null);
    }
  }

  /// The prompt bar's menus (issue #56), one per trigger: the anchored `/`
  /// command menu — its row provider filters [_commands] (the static catalog
  /// until the project's custom commands land) by the typed token — and the
  /// inline `@` mention menu (issue #58), whose row provider yields the
  /// session's skills, then the working directory's files (the TUI's
  /// skills + files).
  List<PromptMenuDefinition> _buildMenus() {
    return [
      PromptMenuDefinition(
        trigger: '/',
        anchoring: MenuAnchoring.anchored,
        emptyLabel: 'No matching command',
        rows: (token) => [
          for (final command in _commands)
            if (command.matches(token)) _commandRow(command),
        ],
      ),
      PromptMenuDefinition(
        trigger: '@',
        anchoring: MenuAnchoring.inline,
        emptyLabel: 'No matching mention',
        rows: (token) => _mentionRows(token),
      ),
    ];
  }

  /// The `@` menu's rows (issue #58): the session's skills (filtered by the
  /// typed token), then the working directory's files — the service's file
  /// search, re-queried once per token (the TUI behavior; [_filesToken] /
  /// [_files] keep it from re-querying when the row provider runs again for
  /// the same token, e.g. when the skills land).
  Future<List<PromptMenuRow>> _mentionRows(String token) async {
    if (_filesToken != token) {
      _filesToken = token;
      try {
        _files = await widget.client.findFiles(widget.sessionId, token);
      } catch (_) {
        // A failed search yields no file rows (the skill rows stay).
        _files = const [];
      }
    }
    final rows = <PromptMenuRow>[
      for (final skill in _skills)
        if (_skillMatches(skill, token))
          PromptMenuRow(
            name: 'skill:${skill.id}',
            label: '@${skill.id}',
            subtitle: skill.description.isEmpty ? null : skill.description,
            insertion: '@${skill.id}',
            onActivate: (_) => _mentionPicked(isSkill: true, target: skill.id),
          ),
    ];
    for (final path in _files ?? const <String>[]) {
      rows.add(
        PromptMenuRow(
          name: 'file:$path',
          label: '@$path',
          insertion: '@$path',
          onActivate: (_) => _mentionPicked(isSkill: false, target: path),
        ),
      );
    }
    return rows;
  }

  /// The skill rows filter client-side on the typed token (the files go
  /// through the service's search).
  static bool _skillMatches(SkillOption skill, String token) {
    if (token.isEmpty) return true;
    final needle = token.toLowerCase();
    return skill.id.toLowerCase().contains(needle) ||
        skill.name.toLowerCase().contains(needle);
  }

  /// A mention row was picked (issue #58): the mention is committed — it is
  /// tracked so it deletes as one unit and sends as an attachment.
  void _mentionPicked({required bool isSkill, required String target}) {
    setState(() {
      _mentions = [
        ..._mentions,
        _Mention(text: '@$target', isSkill: isSkill, target: target),
      ];
    });
  }

  /// One `/` menu row (issue #56): the command's display fields, and its
  /// activation — the bar clears the field, then the command runs with the
  /// typed argument.
  PromptMenuRow _commandRow(SlashCommand command) => PromptMenuRow(
    name: command.name,
    label: '/${command.name}',
    subtitle: command.subtitle == command.name ? null : command.subtitle,
    hint: command.takesArg && command.argHint != null ? command.argHint : null,
    badge: command.family == CommandFamily.custom ? 'custom' : null,
    takesArg: command.takesArg,
    onActivate: (argument) => _runCommand(command, argument),
  );

  /// A menu is open (issue #56): fetch the project's custom commands (the
  /// service's `GET /api/command`) and, for the `@` menu, the session's
  /// skills — once each — and merge them into the menus. A failed fetch
  /// keeps the static catalog (or no skill rows) on screen.
  void _onMenuOpened() {
    if (!_commandsFetched) {
      _commandsFetched = true;
      widget.client
          .listCommands(widget.sessionId)
          .then((commands) {
            if (mounted) {
              setState(() {
                _commands = SlashCommands.withCustom(commands);
                _menus = _buildMenus();
              });
            }
          })
          .catchError((Object _) {});
    }
    if (!_skillsFetched) {
      _skillsFetched = true;
      widget.client
          .listSkills(widget.sessionId)
          .then((skills) {
            if (mounted) {
              setState(() {
                _skills = skills;
                _menus = _buildMenus();
              });
            }
          })
          .catchError((Object _) {});
    }
  }

  /// Runs the row the user picked from the `/` menu (issue #46). The bar
  /// clears the field before calling; the command dispatches by family —
  /// custom commands are sent to the open session (the service queues them
  /// with `delivery: steer` mid-turn), service commands hit the bridge's
  /// command endpoints, local commands run their in-app equivalent.
  Future<void> _runCommand(SlashCommand command, String argument) async {
    if (_commandBusy) return;
    setState(() => _commandBusy = true);
    try {
      await _dispatchCommand(command, argument);
    } finally {
      if (mounted) setState(() => _commandBusy = false);
    }
  }

  Future<void> _dispatchCommand(SlashCommand command, String argument) async {
    switch (command.family) {
      case CommandFamily.custom:
        await _runCustom(command, argument);
      case CommandFamily.service:
        await _runService(command.name, argument);
      case CommandFamily.local:
        await _runLocal(command.name);
    }
  }

  /// A project custom command (issue #46): its name plus the typed argument
  /// go to the open session's `command` endpoint.
  Future<void> _runCustom(SlashCommand command, String argument) async {
    try {
      await widget.client.runCommand(widget.sessionId, command.name, argument);
      if (mounted) _snackBar('Sent /${command.name} to the session.');
    } on SessionsClientError catch (e) {
      if (mounted) {
        _snackBar('Could not run /${command.name} (${_describe(e)}).');
      }
    } catch (_) {
      if (mounted) _snackBar('Could not run /${command.name}.');
    }
  }

  /// A service command (issue #46): the bridge's command endpoints. The
  /// session commands that change the session (model, agent, variant,
  /// directory) normalize afterwards, so the view (and the service's TUIs,
  /// the single source of truth) show the new state.
  Future<void> _runService(String name, String argument) async {
    final id = widget.sessionId;
    final client = widget.client;
    try {
      switch (name) {
        case 'models':
          final models = await client.listModels(id);
          final picked = await _pick(
            'Switch model',
            models,
            (m) => m.name,
            (m) => m.providerId,
          );
          if (picked == null) return;
          await client.setModel(
            id,
            ModelRef(id: picked.id, providerId: picked.providerId),
          );
          if (!mounted) return;
          _snackBar('Model set to ${picked.name}.');
          _normalize();
          return;
        case 'agents':
          final agents = await client.listAgents(id);
          final picked = await _pick(
            'Switch agent',
            agents,
            (a) => a.name,
            (a) => a.description,
          );
          if (picked == null) return;
          await client.setAgent(id, picked.id);
          if (!mounted) return;
          _snackBar('Agent set to ${picked.name}.');
          return;
        case 'variants':
          final current = await client.currentModel(id);
          ModelOption? model;
          if (current != null) {
            for (final m in await client.listModels(id)) {
              if (m.id == current.id && m.providerId == current.providerId) {
                model = m;
                break;
              }
            }
          }
          if (model == null || model.variants.isEmpty) {
            if (!mounted) return;
            _snackBar('No variants available.');
            return;
          }
          final variants = model.variants;
          final variant = await _pick<String>(
            'Switch variant',
            variants,
            (v) => current?.variant == v ? '$v (current)' : v,
            null,
          );
          if (variant == null) return;
          await client.setModel(
            id,
            ModelRef(
              id: model.id,
              providerId: model.providerId,
              variant: variant,
            ),
          );
          if (!mounted) return;
          _snackBar('Variant set to $variant.');
          _normalize();
          return;
        case 'compact':
          await client.compact(id);
          _normalize();
          return;
        case 'undo':
          await client.undo(id);
          _normalize();
          return;
        case 'redo':
          await client.redo(id);
          _normalize();
          return;
        case 'fork':
          final forked = await client.fork(id);
          if (!mounted) return;
          _snackBar('Forked the session as $forked.');
          return;
        case 'rename':
          await client.rename(id, argument);
          if (!mounted) return;
          setState(() => _title = argument);
          _snackBar('Renamed the session.');
          return;
        case 'cd':
          await client.move(id, argument);
          if (!mounted) return;
          _snackBar('Working directory: $argument.');
          _normalize();
          return;
        case 'skills':
          final skills = await client.listSkills(id);
          final picked = await _pick(
            'Activate a skill',
            skills,
            (s) => s.name,
            (s) => s.description,
          );
          if (picked == null) return;
          await client.activateSkill(id, picked.id);
          if (!mounted) return;
          _snackBar('Skill activated: ${picked.name}.');
          return;
        case 'btw':
          final answer = await client.btw(id, argument);
          if (!mounted) return;
          _dialog('Side answer', answer);
          return;
        case 'export':
          await _payloadDialog('Export', () => client.exportSession(id));
          return;
        case 'diff':
          await _payloadDialog('Diff', () => client.diff(id));
          return;
        case 'stats':
          await _payloadDialog('Usage statistics', () => client.stats(id));
          return;
        case 'worktrees':
          await _payloadDialog('Worktrees', () => client.worktrees(id));
          return;
        // The menu's navigation commands: the app's existing "new session"
        // flow (the screen closes and the flow runs behind it).
        case 'sessions':
        case 'new':
        case 'open':
          await _goNewSession();
          return;
        case 'usage':
          await _payloadDialog('Usage', client.usage);
          return;
        case 'mcps':
          await _payloadDialog('MCP servers', client.mcps);
          return;
        case 'connect':
          await _connectFlow();
          return;
        case 'status':
          await _payloadDialog('Status', client.status);
          return;
        case 'pair':
          await _payloadDialog('Pairing code', client.pair);
          return;
        case 'reload':
          await client.reload();
          if (!mounted) return;
          _snackBar('Reloaded the configuration.');
          return;
        case 'plugins':
          await _payloadDialog('Plugins', client.plugins);
          return;
      }
    } on SessionsClientError catch (e) {
      if (mounted) _snackBar('Could not run /$name (${_describe(e)}).');
    } catch (_) {
      if (mounted) _snackBar('Could not run /$name.');
    }
  }

  /// The menu's navigation commands (`/new`, `/sessions`, `/open`, and the
  /// local `/clear`): this view closes and the app's existing "new session"
  /// flow runs behind it, or a note when the screen has no navigation wired.
  Future<void> _goNewSession() async {
    final onNewSession = widget.onNewSession;
    if (onNewSession == null) {
      if (!mounted) return;
      _snackBar('Not available from this screen.');
      return;
    }
    // Close this view first, then run the flow on the tab behind it.
    Navigator.of(context).pop();
    await onNewSession();
  }

  /// `/connect` (issue #46): the service's integrations that carry an OAuth
  /// method, a pick, then the flow's URL the service hands out.
  Future<void> _connectFlow() async {
    final client = widget.client;
    final payload = await client.integrations();
    final decoded = jsonDecode(payload);
    final items = decoded is List<Object?> ? decoded : const <Object?>[];
    final options = <(String, String, String, String)>[];
    for (final item in items) {
      if (item is! Map<String, Object?>) continue;
      final integrationId = item['id'] is String ? item['id'] as String : '';
      final integrationName = item['name'] is String
          ? item['name'] as String
          : integrationId;
      final methods = item['methods'];
      for (final method
          in methods is List<Object?> ? methods : const <Object?>[]) {
        if (method is! Map<String, Object?> || method['type'] != 'oauth') {
          continue;
        }
        final methodId = method['id'] is String ? method['id'] as String : '';
        if (methodId.isEmpty) continue;
        options.add((
          integrationId,
          integrationName,
          methodId,
          method['label'] is String
              ? method['label'] as String
              : integrationName,
        ));
      }
    }
    if (options.isEmpty) {
      if (!mounted) return;
      _snackBar('No connectable integration.');
      return;
    }
    final picked = await _pick(
      'Connect an integration',
      options,
      (o) => o.$2,
      (o) => o.$4,
    );
    if (picked == null) return;
    final result = await client.connectIntegration(picked.$1, picked.$3);
    if (!mounted) return;
    _dialog('Connect', result);
  }

  /// The menu's local commands (issue #46): their in-app equivalents; they
  /// touch no shared-service state.
  Future<void> _runLocal(String name) async {
    switch (name) {
      case 'clear':
        await _goNewSession();
        return;
      case 'timeline':
        if (!_scroll.hasClients) return;
        _stick = false;
        _scroll.position.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      case 'copy':
        String? text;
        for (var i = _messages.length - 1; i >= 0; i--) {
          final message = _messages[i];
          if (message.role == 'assistant' &&
              (message.text ?? '').trim().isNotEmpty) {
            text = message.text;
            break;
          }
        }
        if (text == null) {
          if (!mounted) return;
          _snackBar('No assistant message to copy.');
          return;
        }
        await Clipboard.setData(ClipboardData(text: text));
        if (!mounted) return;
        _snackBar('Copied the last assistant message.');
        return;
      case 'help':
        if (!mounted) return;
        final lines = [
          for (final command in _commands)
            '/${command.name}'
                '${command.aliases.isEmpty ? '' : ' (also ${command.aliases.join(', ')})'}'
                ' — ${command.subtitle}',
        ];
        _dialog('Commands', lines.join('\n'));
        return;
      case 'settings':
        final onOpenSettings = widget.onOpenSettings;
        if (onOpenSettings == null) {
          if (!mounted) return;
          _snackBar('Settings is not available from this screen.');
          return;
        }
        // Close this view, then let the shell land on the Settings tab.
        Navigator.of(context).pop();
        await onOpenSettings();
        return;
      case 'themes':
        final settings = widget.settings;
        final onThemeModeChanged = widget.onThemeModeChanged;
        if (settings == null || onThemeModeChanged == null) {
          if (!mounted) return;
          _snackBar('Theme is not available from this screen.');
          return;
        }
        final picked = await _pick<ThemeMode>(
          'Switch theme',
          ThemeMode.values,
          (mode) => _themeLabel(mode, settings.themeMode),
          null,
        );
        if (picked == null) return;
        settings.themeMode = picked;
        onThemeModeChanged();
        if (!mounted) return;
        _snackBar('Theme set to ${_themeLabel(picked, null)}.');
        return;
      case 'debug':
        String service = 'unreachable';
        try {
          final payload = await widget.client.status();
          try {
            final decoded = jsonDecode(payload);
            service =
                decoded is Map<String, Object?> || decoded is List<Object?>
                ? const JsonEncoder.withIndent('  ').convert(decoded)
                : payload;
          } catch (_) {
            service = payload;
          }
        } on SessionsClientError {
          service = 'unreachable';
        } catch (_) {
          service = 'unavailable';
        }
        if (!mounted) return;
        _dialog(
          'Debug',
          'App: OpenCode Bridge $kAppVersion\n'
              'OS: ${Platform.operatingSystem}\n\n'
              'Service:\n$service',
        );
        return;
      case 'exit':
        exit(0);
    }
  }

  /// A bridge failure in one line, for a snackbar.
  String _describe(SessionsClientError e) =>
      e.statusCode == 0 ? 'unreachable' : 'status ${e.statusCode}';

  /// The label of a theme choice (issue #49), with the current one marked
  /// in the `/themes` picker.
  String _themeLabel(ThemeMode mode, ThemeMode? current) =>
      (switch (mode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      }) +
      (mode == current ? ' (current)' : '');

  /// A plain dialog: a title over the (selectable) [text], scrollable.
  void _dialog(String title, String text, {bool mono = false}) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: mono
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  /// The menu's "info" commands (export, diff, stats, worktrees,
  /// usage, mcps, plugins, status, pair): fetch the service's payload (its
  /// decoded JSON, as a string) and show it pretty-printed.
  Future<void> _payloadDialog(
    String title,
    Future<String> Function() load,
  ) async {
    String payload;
    try {
      payload = await load();
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      _snackBar('Could not load (${_describe(e)}).');
      return;
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not load.');
      return;
    }
    if (!mounted) return;
    String text = payload;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, Object?> || decoded is List<Object?>) {
        text = const JsonEncoder.withIndent('  ').convert(decoded);
      }
    } catch (_) {
      // A non-JSON payload is shown raw.
    }
    _dialog(title, text, mono: true);
  }

  /// The menu's pickers (models, agents, variants, skills, connect): a
  /// dialog over a [_PickDialog] listing [items]; resolves the picked item,
  /// or `null` when the user cancels (or there is nothing to pick).
  Future<T?> _pick<T extends Object>(
    String title,
    List<T> items,
    String Function(T item) label,
    String? Function(T item)? hint,
  ) async {
    if (!mounted || items.isEmpty) return null;
    return showDialog<T>(
      context: context,
      builder: (dialogContext) =>
          _PickDialog<T>(title: title, items: items, label: label, hint: hint),
    );
  }

  void _snackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// The per-Turn footer labels keyed by the history row they ride on
  /// (issue #121's frozen footers, issue #124's running turn and the lazy
  /// older Turns). While a turn is active, the running turn's label is the
  /// live one (its duration ticks from the turn's first prompt, not the last
  /// completed step); the older Turns' frozen footers fill in as their
  /// messages page into view (gated by [_oldestLoaded]). The walk back is
  /// proportional to the loaded history, never more.
  Map<int, String> _turnFooters() {
    if (_messages.isEmpty) return const {};
    // The Active turn's row carries the live label (its duration ticks to
    // [_liveNow]); the settled turns keep their frozen ones.
    return computeTurnFooters(
      _messages,
      oldestLoaded: _oldestLoaded,
      active: _turnActive,
      now: _turnActive
          ? _liveNow ?? DateTime.now().millisecondsSinceEpoch
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    // The per-Turn footers, computed once per build (issue #124): the running
    // turn's live label and the loaded Turns' frozen labels, keyed by the row
    // each rides on.
    final footers = _turnFooters();
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
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
                _CostBar(
                  detail: _detail,
                  contextUsed: _contextUsed,
                  prefill: _prefill,
                  decode: _decode,
                ),
                Expanded(
                  // The chat list and the prompt bar share the height left
                  // by the cost bar: with the keyboard up on
                  // a phone, the open command menu shrinks rather than the
                  // prompt being pushed off screen. The prompt bar is capped
                  // at this height so its command menu can flex to fit (a
                  // non-flex column child otherwise gets unbounded height and
                  // its inner Flexible would never shrink).
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  // Lazy, reversed chat list: the newest message is the
                                  // anchor (offset 0, the bottom of the screen), so the
                                  // open lands on the newest for free — no settle, no
                                  // crawl. Only the visible messages build and lay out;
                                  // the earlier ones are pulled in as the user scrolls
                                  // up through the history.
                                  child: ListView.builder(
                                    controller: _scroll,
                                    reverse: true,
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      16,
                                      8,
                                    ),
                                    itemCount: _messages.isEmpty
                                        ? 1
                                        : _messages.length,
                                    itemBuilder: (context, index) {
                                      if (_messages.isEmpty) {
                                        return const _CenteredMessage(
                                          text: 'No messages yet.',
                                        );
                                      }
                                      // The list is reversed (newest at the anchor), so
                                      // map the list index back to the chronological
                                      // history index.
                                      final i = _messages.length - 1 - index;
                                      final message = _messages[i];
                                      // The completed turn's stats footer (issue
                                      // #121) rides on the history's last row —
                                      // the idle marker closing the turn when the
                                      // history carries one, else the turn's last
                                      // message (legacy history).
                                      final footer = footers[i];
                                      if (message.role == 'idle') {
                                        // The turn-boundary marker carries no
                                        // content of its own.
                                        return _TurnStatsFooter(label: footer);
                                      }
                                      if (message.role == 'compaction') {
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            _CompactionPane(
                                              message: message,
                                              inFlight:
                                                  _compacting &&
                                                  i == _compactionIndex,
                                            ),
                                            _TurnStatsFooter(label: footer),
                                          ],
                                        );
                                      }
                                      final inFlight =
                                          _turnActive &&
                                          message.id != null &&
                                          _liveMessages.containsKey(message.id);
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _MessagePane(
                                            message: message,
                                            inFlight: inFlight,
                                          ),
                                          _TurnStatsFooter(label: footer),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                // The user scrolled up (or the initial settle hasn't
                                // reached the end yet): float the jump-to-end button
                                // over the list, just above the prompt bar.
                                if (!_atBottom)
                                  Positioned(
                                    right: 12,
                                    bottom: 12,
                                    child: FloatingActionButton.small(
                                      key: const ValueKey(
                                        'structured-jump-to-end',
                                      ),
                                      tooltip: 'Go to the end',
                                      onPressed: _jumpToEnd,
                                      child: const Icon(
                                        Icons.vertical_align_bottom,
                                      ),
                                    ),
                                  ),
                                // The pending question forms (issue #50) float over the
                                // list, just above the prompt bar — like the TUI
                                // prompts above the input, so the header and the cost
                                // bar never shift. The list is lazy, so the panel
                                // scrolls when a long form is taller than the room.
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: SingleChildScrollView(
                                    child: QuestionPanel(
                                      pending: _questions,
                                      onSubmit: _submitAnswers,
                                      onDismiss: _dismissQuestion,
                                      busyId: _answerBusyId,
                                    ),
                                  ),
                                ),
                                // The pending permission requests (issue #62)
                                // float over the list, just above the prompt
                                // bar — like the TUI prompts above the input,
                                // so the header and the cost bar never shift.
                                // The banner scrolls when a pending request is
                                // taller than the room.
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: SingleChildScrollView(
                                    child: PermissionBanner(
                                      pending: _pending,
                                      onReply: _reply,
                                      replyBusyId: _replyBusyId,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight,
                            ),
                            child: _PromptBar(
                              controller: _prompt,
                              busy: _promptBusy || _commandBusy,
                              onSend: _sendPrompt,
                              menus: _menus,
                              mentions: [
                                for (final mention in _mentions) mention.text,
                                for (final image in _images)
                                  '[Image ${image.label}]',
                              ],
                              onMenuOpened: _onMenuOpened,
                              onToggleMode: _toggleMode,
                              onCycleVariant: _cycleVariant,
                              onPasteFromClipboard: _pasteFromClipboard,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// The menu's picker dialog (models, agents, variants, skills, connect): a
/// title, a search field (keyed `structured-pick-search`) that live-filters
/// the rows by label and hint, and the filtered rows. A row tap or Enter on
/// the search field (picking the first filtered row) resolves the item;
/// closing the dialog resolves `null`.
class _PickDialog<T extends Object> extends StatefulWidget {
  const _PickDialog({
    required this.title,
    required this.items,
    required this.label,
    this.hint,
  });

  final String title;
  final List<T> items;
  final String Function(T item) label;

  /// The row's secondary line (e.g. the model's provider), or `null`.
  final String? Function(T item)? hint;

  @override
  State<_PickDialog<T>> createState() => _PickDialogState<T>();
}

class _PickDialogState<T extends Object> extends State<_PickDialog<T>> {
  late final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(_searchChanged);
  }

  @override
  void dispose() {
    _search.removeListener(_searchChanged);
    _search.dispose();
    super.dispose();
  }

  void _searchChanged() => setState(() {});

  /// The rows matching the search: the label or the hint contains the query
  /// (case-insensitive); an empty query matches every row.
  List<T> get _filtered {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.items;
    return [
      for (final item in widget.items)
        if (widget.label(item).toLowerCase().contains(query) ||
            (widget.hint?.call(item) ?? '').toLowerCase().contains(query))
          item,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('structured-pick-search'),
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search...'),
              onSubmitted: (_) {
                if (filtered.isNotEmpty) {
                  Navigator.of(context).pop(filtered.first);
                }
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (filtered.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No match.'),
                      )
                    else
                      for (final item in filtered)
                        Builder(
                          builder: (itemContext) {
                            final sub = widget.hint?.call(item);
                            return ListTile(
                              dense: true,
                              title: Text(widget.label(item)),
                              subtitle: (sub == null || sub.isEmpty)
                                  ? null
                                  : Text(sub),
                              onTap: () => Navigator.of(itemContext).pop(item),
                            );
                          },
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The live header: the session's cost in USD and its token usage (endpoint
/// 5, moved by `session.usage.updated`), plus the model's context window —
/// the context the session's last model call used (seeded from the
/// history's last assistant message, moved live by
/// `session.step.ended`) against the session's model limit, with the
/// percent used.
class _CostBar extends StatelessWidget {
  const _CostBar({
    required this.detail,
    required this.contextUsed,
    this.prefill,
    this.decode,
  });

  final SessionDetail? detail;

  final int? contextUsed;

  /// The local llama.cpp server's live prefill/decode throughput (tok/s), or
  /// `null` while idle. At most one is set at a time.
  final double? prefill;

  final double? decode;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) return const SizedBox.shrink();
    final tokens = detail.tokens;
    final tokenText = _tokenText(tokens);
    final limit = detail.contextLimit;
    final used = contextUsed;
    final fraction = used != null && limit != null && limit > 0
        ? used / limit
        : null;
    final speed = _speedText(prefill, decode);
    final speedColor = _TuiSpeedColors.resolve(Theme.of(context).brightness)
        .forPhase(prefill, decode);
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
          // A Wrap (issue #41): the chips take their natural width, so at
          // phone width the bar wraps to a second line instead of
          // overflowing; at desktop width it lays out on one line, as before.
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                'Cost \$${detail.cost.toStringAsFixed(4)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              ..._identityChips(context, detail),
              if (tokenText != null)
                Text(
                  tokenText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              if (used != null)
                _chip(
                  context,
                  const ValueKey('structured-context'),
                  limit == null
                      ? 'context $used'
                      : 'context $used / $limit · ${_percent(used, limit)}',
                ),
              if (detail.outcome != null)
                _chip(
                  context,
                  const ValueKey('structured-outcome'),
                  detail.outcome!,
                ),
              if (speed != null)
                Container(
                  key: const ValueKey('structured-speed'),
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
                    speed,
                    style: TextStyle(fontSize: 12, color: speedColor),
                  ),
                ),
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

  /// The header's identity chips: the session's model
  /// (`providerID/modelID`), its variant (the reasoning effort) when set,
  /// and its mode (the agent, e.g. `build` or `plan`) — the session's
  /// `Session.Info` model/agent, or no chip when the service reports none
  /// yet.
  static List<Widget> _identityChips(
    BuildContext context,
    SessionDetail detail,
  ) {
    final model = detail.model;
    final chips = <Widget>[];
    if (model != null) {
      chips.add(
        _chip(
          context,
          const ValueKey('structured-model'),
          model.providerId.isEmpty
              ? model.id
              : '${model.providerId}/${model.id}',
        ),
      );
      if (model.variant != null) {
        chips.add(
          _chip(context, const ValueKey('structured-variant'), model.variant!),
        );
      }
    }
    if (detail.agent != null) {
      chips.add(
        _chip(context, const ValueKey('structured-mode'), detail.agent!),
      );
    }
    return chips;
  }

  /// One header chip (the rounded, elevated pill the context/outcome/speed
  /// chips use).
  static Widget _chip(BuildContext context, Key key, String text) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }

  /// The header's token counts, one field per non-zero value. Zeros are
  /// omitted: local providers (llama.cpp) report no reasoning and no
  /// cache-write tokens, and the trailing zeros would only add noise. `null`
  /// when every field is zero.
  static String? _tokenText(TokenUsage tokens) {
    final parts = <String>[];
    if (tokens.input != 0) parts.add('${tokens.input} in');
    if (tokens.output != 0) parts.add('${tokens.output} out');
    if (tokens.reasoning != 0) parts.add('${tokens.reasoning} reasoning');
    if (tokens.cacheRead != 0) parts.add('${tokens.cacheRead} cache read');
    if (tokens.cacheWrite != 0) parts.add('${tokens.cacheWrite} cache write');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The header's speed chip text, or `null` while idle: the live prefill or
  /// decode throughput (at most one is set at a time).
  static String? _speedText(double? prefill, double? decode) {
    final parts = <String>[];
    if (prefill != null) {
      parts.add('prefill ${prefill.toStringAsFixed(0)} tok/s');
    }
    if (decode != null) {
      parts.add('decode ${decode.toStringAsFixed(1)} tok/s');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _percent(int used, int limit) {
    final pct = used / limit * 100;
    final text = pct < 10 ? pct.toStringAsFixed(1) : pct.toStringAsFixed(0);
    return '$text%';
  }
}

/// The completed turn's stats footer (issue #121): `duration · N
/// compactions · X.X tok/s`, dimmed under the turn's last row. `null` or
/// empty renders nothing (an empty row keeps the lazy list's item count
/// stable).
class _TurnStatsFooter extends StatelessWidget {
  const _TurnStatsFooter({required this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    return Padding(
      // Sits under the turn's last message: the label hugs the message it
      // describes, and the pane's own bottom padding keeps the next turn
      // clear.
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        label,
        key: const ValueKey('turn-stats'),
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}

/// One message of the history (endpoint 6): the reasoning (thinking) text,
/// then the text, then the assistant's tool calls (in flight or finished).
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
          if (message.reasoning != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 16),
              child: _Markdown(
                data: message.reasoning!,
                base: TextStyle(color: scheme.outline),
                dim: true,
              ),
            ),
          if (message.text != null)
            isUser
                ? Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.08),
                      border: Border(
                        left: BorderSide(color: scheme.primary, width: 3),
                      ),
                    ),
                    child: _Markdown(data: message.text!),
                  )
                : Padding(
                    // More room below the dimmed thinking text, so the
                    // response reads as the model's answer and not a
                    // continuation of the thinking.
                    padding: EdgeInsets.only(
                      top: message.reasoning != null ? 12 : 2,
                    ),
                    child: _Markdown(data: message.text!),
                  ),
          for (final tool in message.tools) _ToolCard(tool: tool),
        ],
      ),
    );
  }
}

/// The markdown colors of the opencode TUI theme (the `markdown` section of
/// its `opencode` theme document, resolved against its light and dark hue
/// palettes): this view renders the same colors as the terminal.
class _TuiMarkdownColors {
  const _TuiMarkdownColors({
    required this.heading,
    required this.strong,
    required this.em,
    required this.code,
    required this.link,
    required this.listBullet,
    required this.blockQuote,
  });

  static const _light = _TuiMarkdownColors(
    heading: Color(0xFFD68C27),
    strong: Color(0xFFD68C27),
    em: Color(0xFFB0851F),
    code: Color(0xFF3D9A57),
    link: Color(0xFF3B7DD8),
    listBullet: Color(0xFF3B7DD8),
    blockQuote: Color(0xFFB0851F),
  );

  static const _dark = _TuiMarkdownColors(
    heading: Color(0xFF9D7CD8),
    strong: Color(0xFFF5A742),
    em: Color(0xFFE5C07B),
    code: Color(0xFF7FD88F),
    link: Color(0xFFFAB283),
    listBullet: Color(0xFFFAB283),
    blockQuote: Color(0xFFE5C07B),
  );

  final Color heading;
  final Color strong;
  final Color em;
  final Color code;
  final Color link;
  final Color listBullet;
  final Color blockQuote;

  static _TuiMarkdownColors resolve(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;
}

/// The speed chip's colors: the `text.feedback` section of the opencode TUI
/// theme document — `info` (`$hue.cyan.200`) for the prefill throughput and
/// `success` (`$hue.green.200`) for the decode throughput, the same colors
/// the `llama-speed` TUI plugin renders.
class _TuiSpeedColors {
  const _TuiSpeedColors({required this.prefill, required this.decode});

  static const _light = _TuiSpeedColors(
    prefill: Color(0xFF318795),
    decode: Color(0xFF3D9A57),
  );

  static const _dark = _TuiSpeedColors(
    prefill: Color(0xFF56B6C2),
    decode: Color(0xFF7FD88F),
  );

  final Color prefill;

  final Color decode;

  /// The color for the active phase (at most one of [prefill] / [decode] is
  /// set at a time); `null` while idle (the chip is not rendered then).
  Color? forPhase(double? prefill, double? decode) => prefill != null
      ? this.prefill
      : decode != null
      ? this.decode
      : null;

  static _TuiSpeedColors resolve(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;
}

/// Markdown text: the message bodies and the compaction summary are markdown
/// (headings, bold, lists, code) — the service stores them as written, the
/// TUI renders them as such, and so does this view, in the TUI's own colors
/// ([_TuiMarkdownColors]). With no [base] the theme's text styles apply
/// (regular message text); a [base] carries the size of the small panes or
/// the flat gray of the dimmed one (the thinking text, like the terminal's).
class _Markdown extends StatelessWidget {
  const _Markdown({required this.data, this.base, this.dim = false});

  final String data;

  /// The base style every markdown style derives from: the font size of the
  /// small panes, the gray of the dimmed pane.
  final TextStyle? base;

  /// True for the thinking text: flat gray, no palette (the terminal shows
  /// the thinking in its muted style too).
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final palette = _TuiMarkdownColors.resolve(Theme.of(context).brightness);
    final b = base ?? const TextStyle();
    // The body size the paragraph text actually renders in: the base when the
    // pane sets one, else the theme's body size (the markdown fallback
    // stylesheet merges under ours, so the code size must be set explicitly
    // to win over its shrunken default).
    final size =
        b.fontSize ?? Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14;
    TextStyle style({
      Color? color,
      double? fontSize,
      FontWeight? fontWeight,
      FontStyle? fontStyle,
      String? fontFamily,
    }) {
      final style = b.copyWith(
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        fontFamily: fontFamily,
      );
      return color == null
          ? style
          : style.copyWith(color: dim ? b.color : color);
    }

    return MarkdownBody(
      data: data,
      styleSheet: MarkdownStyleSheet(
        p: b,
        h1: style(
          fontSize: size * 1.3,
          fontWeight: FontWeight.w700,
          color: palette.heading,
        ),
        h2: style(
          fontSize: size * 1.15,
          fontWeight: FontWeight.w700,
          color: palette.heading,
        ),
        h3: style(fontWeight: FontWeight.w600, color: palette.heading),
        h4: style(fontWeight: FontWeight.w600, color: palette.heading),
        h5: style(fontWeight: FontWeight.w600, color: palette.heading),
        h6: style(fontWeight: FontWeight.w600, color: palette.heading),
        em: style(fontStyle: FontStyle.italic, color: palette.em),
        strong: style(fontWeight: FontWeight.bold, color: palette.strong),
        code: style(
          fontFamily: 'monospace',
          fontSize: size,
          color: palette.code,
        ),
        a: style(
          color: palette.link,
        ).copyWith(decoration: dim ? b.decoration : TextDecoration.underline),
        listBullet: style(color: palette.listBullet),
        blockquote: style(color: palette.blockQuote),
        // The quote's box: the theme's surface, like the code blocks — the
        // markdown default is a fixed light box the light quote color is
        // unreadable on in dark mode.
        blockquoteDecoration: BoxDecoration(
          color: dim
              ? null
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        codeblockDecoration: BoxDecoration(
          color: dim
              ? null
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// One context-compaction marker of the history (endpoint 6): a divider
/// between the compacted history and what followed, with the summary the
/// compaction wrote. While the compaction runs, its summary streams in token
/// by token (`session.compaction.delta`) and the marker shows it.
class _CompactionPane extends StatelessWidget {
  const _CompactionPane({required this.message, required this.inFlight});

  final SessionMessage message;

  /// True while the session's compaction is streaming into this marker.
  final bool inFlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Divider(height: 1, color: scheme.outlineVariant)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (inFlight)
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    else
                      Icon(Icons.compress, size: 14, color: scheme.outline),
                    const SizedBox(width: 6),
                    Text(
                      inFlight ? 'Compacting…' : 'Compacted context',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: Divider(height: 1, color: scheme.outlineVariant)),
            ],
          ),
          if (message.text != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _Markdown(
                data: message.text!,
                base: const TextStyle(fontSize: 12),
              ),
            ),
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

  /// The file the edit changed (the tool's `input.path`), `null` when the
  /// input carries none.
  String? get _path {
    final input = tool.input;
    if (input is Map<String, Object?> && input['path'] is String) {
      return input['path'] as String;
    }
    return null;
  }

  /// The agent's `question` tool (issue #50), rendered TUI-style instead of
  /// as raw JSON: each question's text, with the answer the user gave below
  /// it (the tool state's `metadata.answers`, in form order). `null` while
  /// the input is still streaming (a partial JSON string, shown raw like any
  /// other input).
  List<({String question, List<String>? answers})>? get _questions {
    final input = tool.input;
    if (input is! Map<String, Object?>) return null;
    final list = input['questions'];
    if (list is! List) return null;
    final answers = tool.answers;
    final lines = <({String question, List<String>? answers})>[];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      final question =
          item is Map<String, Object?> && item['question'] is String
          ? item['question'] as String
          : null;
      if (question == null) continue;
      lines.add((
        question: question,
        answers: answers != null && i < answers.length ? answers[i] : null,
      ));
    }
    return lines.isEmpty ? null : lines;
  }

  /// A one-line, human-readable summary of the tool's input, for the tools
  /// whose raw JSON input is mostly noise for what the user wants to glance
  /// at: `shell` shows its command, `read` its path (with `offset` / `limit`
  /// when given), `grep` its pattern (and path), `execute` its code. `null`
  /// when the input is not the map expected for the tool (a still-streaming
  /// input is a partial JSON string) or carries none of the fields the tool
  /// is known for — then the card falls back to the raw input, unchanged.
  String? get _detail {
    final input = tool.input;
    if (input is! Map<String, Object?>) return null;
    switch (tool.name) {
      case 'shell':
        return _string(input['command']);
      case 'execute':
        return _string(input['code']);
      case 'read':
        final path = _string(input['path']);
        if (path == null) return null;
        final extra = [
          if (input['offset'] is int) 'offset ${input['offset']}',
          if (input['limit'] is int) 'limit ${input['limit']}',
        ].join(', ');
        return extra.isEmpty ? path : '$path ($extra)';
      case 'grep':
        final pattern = _string(input['pattern']);
        if (pattern == null) return null;
        final path = _string(input['path']);
        return path == null ? pattern : '$pattern in $path';
    }
    return null;
  }

  /// A non-empty string field of the input, or `null` when the field is
  /// absent or not a non-empty string.
  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final questions = _questions;
    final detail = _detail;
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
          if (tool.patch != null) ...[
            if (_path != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 24),
                child: Text(
                  _path!,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: scheme.outline,
                  ),
                ),
              ),
            // The file diff, like the terminal: the removed lines, the added
            // lines, and the context, in the TUI's diff colors.
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 24),
              child: DiffView(patch: tool.patch!),
            ),
          ] else if (questions != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < questions.length; i++) ...[
                    Text(
                      questions[i].question,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    if (questions[i].answers != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, left: 8),
                        child: Text(
                          questions[i].answers!.isEmpty
                              ? '—'
                              : questions[i].answers!.join(', '),
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: scheme.outline,
                          ),
                        ),
                      ),
                    if (i + 1 < questions.length) const SizedBox(height: 8),
                  ],
                ],
              ),
            )
          else if (detail != null || _inputText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 24),
              child: Text(
                detail ?? _inputText,
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
///
/// The prompt menus (issue #56): the bar hosts one menu per [menus]
/// definition, and the chrome is shared across triggers. The `/` command
/// menu (issue #46) opens when the input starts with `/`, filtered live as
/// the user types (matching command names and their aliases, exactly like
/// the TUI). Enter runs the selected row; a row that takes an argument
/// (`takesArg`) takes the text typed after the name and keeps the menu open
/// until the argument is typed (the TUI behavior). A token that matches no
/// row stays put on Enter — it is neither run nor sent.
///
/// With no menu open, two keys take on the TUI's mode shortcuts: Tab
/// toggles the session's mode (`build`/`plan`, the TUI's `agent.cycle`)
/// and Ctrl+T cycles the current model's variant (the TUI's
/// `variant.cycle`); both are reported through the screen's handlers.
class _PromptBar extends StatefulWidget {
  const _PromptBar({
    required this.controller,
    required this.busy,
    required this.onSend,
    required this.menus,
    required this.mentions,
    required this.onMenuOpened,
    required this.onToggleMode,
    required this.onCycleVariant,
    required this.onPasteFromClipboard,
  });

  final TextEditingController controller;

  final bool busy;

  final Future<void> Function() onSend;

  /// The menus the bar hosts, one per trigger; the first definition whose
  /// trigger is active owns the menu.
  final List<PromptMenuDefinition> menus;

  /// The mentions committed to the field (issue #58): each deletes as one
  /// unit (atomic Backspace/Delete, the menu closed).
  final List<String> mentions;

  /// A menu is open; the screen may need to fetch the project's custom
  /// commands and the session's skills.
  final VoidCallback onMenuOpened;

  /// Tab (the menu closed): toggles the session's mode, `build` or `plan`.
  final VoidCallback onToggleMode;

  /// Ctrl+T (the menu closed): cycles the current model's variant (the
  /// reasoning effort), like the TUI's `variant.cycle`.
  final VoidCallback onCycleVariant;

  /// Ctrl+V (the menu closed): the clipboard's image is committed and its
  /// `[Image N]` token inserted at the caret (issue #72); with no image the
  /// clipboard's text is pasted. The screen runs the read and the insertion.
  final Future<void> Function() onPasteFromClipboard;

  @override
  State<_PromptBar> createState() => _PromptBarState();
}

class _PromptBarState extends State<_PromptBar> {
  /// The definition of the menu that is open, or `null` when no menu is.
  PromptMenuDefinition? _active;

  bool get _menuOpen => _active != null;

  /// The open menu's rows, fetched for [_rowsToken].
  List<PromptMenuRow> _matches = const [];

  /// The filter token [_matches] were fetched for; the rows are re-fetched
  /// when the open definition or the token changes, and the previous rows
  /// stay on screen until the new ones land.
  String? _rowsToken;

  /// How many row fetches have been started: a fetch completing with a stale
  /// generation (the token, or the trigger, changed meanwhile) never lands
  /// its rows.
  int _fetches = 0;

  /// The (text, caret) right after a mention insertion (issue #58): the
  /// caret sits on the mention's own tail text, which would read as a live
  /// filter token and re-open the menu; the state is consumed once.
  (String, int)? _inserted;

  /// The selected row in [_matches] (`-1` when there is no match).
  int _selected = -1;

  /// The menu list's scroll position: the keyboard keeps the selected row
  /// on screen (the TUI does the same).
  final ScrollController _menuScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncMenu);
  }

  @override
  void didUpdateWidget(covariant _PromptBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The row provider's data landed while the menu is open (the project's
    // custom commands, the session's skills): the definitions are new
    // instances, so the re-filter re-fetches and re-selects the top row, as
    // a re-typed token would.
    if (oldWidget.menus != widget.menus && _menuOpen) {
      _syncMenu();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncMenu);
    _menuScroll.dispose();
    super.dispose();
  }

  /// The filter token [definition] owns for the field's [text] and
  /// [selection] — as a (token start, token) pair, the token start being
  /// the trigger's position in the text — or `null` when its trigger is
  /// not active.
  (int, String)? _filterToken(
    PromptMenuDefinition definition,
    String text,
    TextSelection selection,
  ) {
    final trigger = definition.trigger;
    if (definition.anchoring == MenuAnchoring.anchored) {
      // The anchored trigger is active only at the start of the field; the
      // token is the text after it up to the first space (the TUI's live
      // filter).
      if (!text.startsWith(trigger)) return null;
      final space = text.indexOf(' ');
      final end = space >= 0 ? space : text.length;
      return (
        0,
        end > trigger.length ? text.substring(trigger.length, end) : '',
      );
    }
    // The inline trigger is active while the caret is inside a token that
    // starts with it, wherever the token appears; the token is the text
    // between the trigger and the caret.
    final caret = selection.isCollapsed
        ? selection.baseOffset
        : selection.extentOffset;
    var start = caret;
    while (start > 0 && text[start - 1] != ' ') {
      start--;
    }
    if (caret < start + trigger.length) return null;
    if (!text.startsWith(trigger, start)) return null;
    return (start, text.substring(start + trigger.length, caret));
  }

  /// Re-filters the menu from the field's text. The bar's definitions claim
  /// the field in turn: the first whose trigger is active owns the menu,
  /// and its row provider supplies the rows — fetched for the typed token,
  /// and the previous rows stay on screen until the new ones land (a row
  /// fetch is a generation: a stale one never lands). A change of token
  /// (or definition) re-selects the top row on the arrival, as a re-typed
  /// token would; a selection-only change (the cursor moved within the
  /// token) keeps the current row.
  void _syncMenu() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final inserted = _inserted;
    if (inserted != null &&
        text == inserted.$1 &&
        selection.isCollapsed &&
        selection.baseOffset == inserted.$2) {
      // The caret sits right after the just-inserted mention: its own tail
      // text is not a filter token; the menu stays closed.
      _inserted = null;
      _closeMenu();
      return;
    }
    PromptMenuDefinition? active;
    String? token;
    for (final definition in widget.menus) {
      final candidate = _filterToken(definition, text, selection);
      if (candidate != null) {
        active = definition;
        token = candidate.$2;
        break;
      }
    }
    if (active == null || token == null) {
      _closeMenu();
      return;
    }
    final definitionChanged = _active != active;
    if (definitionChanged) {
      setState(() => _active = active);
    }
    if (definitionChanged || token != _rowsToken) {
      final fetch = ++_fetches;
      Future.value(active.rows(token)).then((rows) {
        if (!mounted || fetch != _fetches || _active != active) return;
        setState(() {
          _rowsToken = token;
          _matches = rows;
          _selected = rows.isEmpty ? -1 : 0;
        });
        if (rows.isNotEmpty) _showMenuRow(0);
      });
    }
    widget.onMenuOpened();
  }

  /// The menu closes: its in-flight fetches are stale, its rows and
  /// selection are dropped.
  void _closeMenu() {
    _fetches++;
    if (_active != null) {
      setState(() {
        _active = null;
        _matches = const [];
        _selected = -1;
        _rowsToken = null;
      });
    }
  }

  /// Scrolls the menu so the row [index] is visible (the keyboard keeps the
  /// selection on screen, the TUI does the same). The rows have a uniform
  /// height, so the row's offset is `index × rowHeight` and the list only
  /// moves when the row is actually off screen.
  void _showMenuRow(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_menuScroll.hasClients) return;
      final position = _menuScroll.position;
      if (position.maxScrollExtent <= 0) return; // everything fits
      final content = position.maxScrollExtent + position.viewportDimension;
      final rowHeight = (content / _matches.length).toDouble();
      final top = index * rowHeight;
      final bottom = top + rowHeight;
      final offset = position.pixels;
      if (top < offset) {
        _menuScroll.jumpTo(top);
      } else if (bottom > offset + position.viewportDimension) {
        _menuScroll.jumpTo(bottom - position.viewportDimension);
      }
    });
  }

  /// Runs the tapped (or submitted) row. A row carrying an [insertion]
  /// (the `@` menu's mentions, issue #58) replaces its token — the trigger
  /// and the typed token — with the mention in place, the cursor right
  /// after it, and runs with no argument; the other rows (the `/` menu's
  /// commands) clear the field and run with the typed argument. A
  /// `takesArg` row with no argument yet keeps the menu open and waits for
  /// the argument.
  void _activate(PromptMenuRow row) {
    final insertion = row.insertion;
    final active = _active;
    if (insertion != null && active != null) {
      final value = widget.controller.value;
      final span = _filterToken(active, value.text, value.selection);
      if (span != null) {
        final text = value.text;
        final caret = value.selection.isCollapsed
            ? value.selection.baseOffset
            : value.selection.extentOffset;
        final nextCaret = span.$1 + insertion.length;
        final nextText =
            text.substring(0, span.$1) + insertion + text.substring(caret);
        // The caret lands on the mention's own tail text: [_syncMenu]
        // suppresses the re-open of the menu on that exact state.
        _inserted = (nextText, nextCaret);
        widget.controller.value = TextEditingValue(
          text: nextText,
          selection: TextSelection.collapsed(offset: nextCaret),
        );
      }
      row.onActivate('');
      return;
    }
    final text = widget.controller.text;
    final space = text.indexOf(' ');
    final argument = (space >= 0 ? text.substring(space) : '').trim();
    if (row.takesArg && argument.isEmpty) return;
    widget.controller.clear();
    row.onActivate(argument);
  }

  /// Enter in the field: the menu open runs the selected row (a prefix that
  /// matches nothing stays put); otherwise it sends the prompt.
  void _onSubmitted() {
    if (_menuOpen) {
      if (_selected >= 0 && _selected < _matches.length) {
        _activate(_matches[_selected]);
      }
      return;
    }
    widget.onSend();
  }

  /// The arrow keys move the menu selection (the TUI parity) and nothing
  /// else: they are handled here, before the app's text shortcuts can move
  /// the field's cursor — a cursor move would re-run [_syncMenu] and jump
  /// the selection back to the top row. Esc closes the menu by clearing the
  /// field. With the menu closed, Tab toggles the session's mode
  /// (`build`/`plan`) and Ctrl+T cycles the current model's variant (the
  /// TUI's `agent.cycle` / `variant.cycle`), without inserting anything in
  /// the field.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.escape) {
        widget.controller.clear();
      }
      if (_menuOpen) {
        if (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowUp) {
          if (_matches.isNotEmpty && _selected >= 0) {
            if (key == LogicalKeyboardKey.arrowDown) {
              setState(() {
                _selected = _selected + 1 < _matches.length
                    ? _selected + 1
                    : _selected;
              });
            } else {
              setState(
                () => _selected = _selected - 1 >= 0 ? _selected - 1 : 0,
              );
            }
            _showMenuRow(_selected);
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.backspace) {
        // The menu closed: a committed mention deletes as one unit.
        if (_deleteMentionBackward()) return KeyEventResult.handled;
      } else if (key == LogicalKeyboardKey.delete) {
        if (_deleteMentionForward()) return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        widget.onToggleMode();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyT &&
          HardwareKeyboard.instance.isControlPressed) {
        widget.onCycleVariant();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV &&
          HardwareKeyboard.instance.isControlPressed) {
        // The image wins over the default text paste: handled here (the read
        // is async, the insertion lands when it resolves); with no image the
        // screen pastes the clipboard's text exactly as the default would.
        widget.onPasteFromClipboard();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// The longest committed mention (issue #58) the [text] carries at
  /// [caret] — ending at it (Backspace) or starting from it (Delete) — or
  /// `null`.
  String? _atomicMention(String text, int caret, {required bool forward}) {
    String? best;
    for (final mention in widget.mentions) {
      if (best != null && mention.length <= best.length) continue;
      final match = forward
          ? caret + mention.length <= text.length &&
                text.substring(caret, caret + mention.length) == mention
          : caret >= mention.length &&
                text.substring(caret - mention.length, caret) == mention;
      if (match) best = mention;
    }
    return best;
  }

  /// Backspace (the menu closed) at the end of a committed mention deletes
  /// it whole — the mention is atomic (issue #58); `handled` only then.
  bool _deleteMentionBackward() {
    final value = widget.controller.value;
    if (!value.selection.isCollapsed) return false;
    final text = value.text;
    final caret = value.selection.baseOffset;
    final mention = _atomicMention(text, caret, forward: false);
    if (mention == null) return false;
    widget.controller.value = TextEditingValue(
      text: text.substring(0, caret - mention.length) + text.substring(caret),
      selection: TextSelection.collapsed(offset: caret - mention.length),
    );
    return true;
  }

  /// Delete (the menu closed) right before a committed mention removes it
  /// forward (issue #58); `handled` only then.
  bool _deleteMentionForward() {
    final value = widget.controller.value;
    if (!value.selection.isCollapsed) return false;
    final text = value.text;
    final caret = value.selection.baseOffset;
    final mention = _atomicMention(text, caret, forward: true);
    if (mention == null) return false;
    final end = caret + mention.length;
    widget.controller.value = TextEditingValue(
      text: text.substring(0, caret) + text.substring(end),
      selection: TextSelection.collapsed(offset: caret),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menu = _active;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (menu != null)
          // The card flexes: on a short screen (the keyboard up) it takes
          // only the height the prompt bar was given, and the list scrolls
          // inside it (the rows keep their uniform height, so the keyboard
          // scroll math still holds).
          Flexible(
            child: Container(
              key: const ValueKey('structured-command-menu-card'),
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
                boxShadow: const [
                  BoxShadow(
                    color: Color.fromRGBO(0, 0, 0, 0.16),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                // The rows run edge to edge (the selection highlight is full
                // width); the clip keeps them inside the card's rounded
                // corners.
                borderRadius: BorderRadius.circular(8),
                child: _matches.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Text(menu.emptyLabel),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: ListView.builder(
                          key: const ValueKey('structured-command-menu'),
                          controller: _menuScroll,
                          shrinkWrap: true,
                          itemCount: _matches.length,
                          itemBuilder: (context, index) {
                            final row = _matches[index];
                            final selected = index == _selected;
                            return Material(
                              color: selected
                                  ? scheme.secondaryContainer
                                  : Colors.transparent,
                              child: InkWell(
                                key: ValueKey(
                                  'structured-command-row-${row.name}',
                                ),
                                onTap: () => _activate(row),
                                child: Padding(
                                  // The text keeps its inset now that the row
                                  // (and its highlight) is full width.
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            row.label,
                                            style: TextStyle(
                                              fontWeight: selected
                                                  ? FontWeight.bold
                                                  : FontWeight.w600,
                                            ),
                                          ),
                                          if (row.hint != null)
                                            Text(
                                              ' ${row.hint}',
                                              style: TextStyle(
                                                color: scheme.outline,
                                                fontSize: 13,
                                              ),
                                            ),
                                          const Spacer(),
                                          if (row.badge != null)
                                            Text(
                                              row.badge!,
                                              style: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                        ],
                                      ),
                                      // The subtitle line is always kept so every
                                      // row has the same height: the keyboard
                                      // scroll math relies on it.
                                      Text(
                                        row.subtitle ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: scheme.outline,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ),
          ),
        Padding(
          key: const ValueKey('structured-prompt'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Focus(
            onKeyEvent: _onKeyEvent,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('structured-prompt-input'),
                    controller: widget.controller,
                    enabled: true,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'Send a message… ( / for commands )',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _onSubmitted(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('structured-prompt-send'),
                  onPressed: widget.busy ? null : widget.onSend,
                  child: widget.busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send'),
                ),
              ],
            ),
          ),
        ),
      ],
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

/// One mention committed to the prompt by the `@` menu (issue #58): its
/// text as typed in the field, and what it refers to — a skill id or a file
/// path relative to the session's working directory.
class _Mention {
  const _Mention({
    required this.text,
    required this.isSkill,
    required this.target,
  });

  /// The mention's text in the field (`@<id>` / `@<path>`).
  final String text;

  /// Whether the mention is a skill (rather than a file).
  final bool isSkill;

  /// The skill id, or the file path relative to the working directory.
  final String target;
}

/// One image committed to the prompt by a Ctrl+V paste (issue #72): the
/// number that renders as the field's atomic `[Image N]` token, and the
/// bytes + mime it refers to (sent as a `files` data-URI attachment, name
/// `clipboard`). Held until the prompt is cleared (a send, Esc, or a `/`
/// command).
class _PendingImage {
  const _PendingImage({
    required this.label,
    required this.bytes,
    required this.mime,
  });

  /// The image-part number (the `N` of the `[Image N]` token).
  final int label;

  /// The image's raw bytes.
  final Uint8List bytes;

  /// The image's mime type (e.g. `image/png`).
  final String mime;
}
