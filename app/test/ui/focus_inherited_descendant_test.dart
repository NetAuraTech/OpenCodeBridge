// Regression tests for issue #429: the debug-only
// `InheritedElement.notifyClients` assert "check that it really is our
// descendant" (Flutter 3.50.x, framework.dart 6438–6453): at notification
// time a registered dependent element is no longer a descendant of the
// provider — a stale entry in a `_FocusInheritedScope`'s `_dependents`
// (or any `InheritedNotifier`'s), i.e. an InheritedWidget dependency
// relationship torn down *while* the notification was in flight.
//
// The upstream twin is flutter/flutter#132799 (same assert, same
// `_InheritedNotifierElement` stack, plus the second exception,
// `InheritedElement.debugDeactivated`'s `assert(_dependents.isEmpty)`):
// closed not-reproducible, "one time failure only".
//
// ## Why no deterministic repro (verified on Flutter 3.50.1 — the widget
// framework is byte-identical to the reporter's 3.50.0)
//
// Every mutation site of the dependent bookkeeping is symmetric with its
// counterparty:
//
// * `Element._dependencies` is written in exactly three places: `add` in
//   `dependOnInheritedElement` during build (5093), `clear` in `activate`
//   (4780), and `= null` in `unmount` (4882).
// * The provider's `_dependents` entry for a dependent is removed by
//   `InheritedElement.removeDependent` (6409), whose only caller is the
//   dependent's own `_ensureDeactivated` (4826–4840).
// * `deactivateChild` (4650–4663) nulls the child's `_parent` and parks it
//   in `owner._inactiveElements`; `_InactiveElements.add` (2155–2165) then
//   runs `_deactivateRecursively` *synchronously* — the whole subtree is
//   deactivated (each element removed from its providers' `_dependents`)
//   and `InheritedElement.debugDeactivated` (6285–6288) asserts the
//   provider's map is empty before the frame ends.
// * `StatefulElement.deactivate` runs `state.deactivate()` — the `Focus`
//   hook's `reparent`, and the app's own `unfocus` (see below) — *before*
//   `Element.deactivate`'s removal: one atomic transition. The retake path
//   (`_retakeInactiveElement` + `inflateWidget`) re-activates the whole
//   subtree, clears `_dependencies`, rebuilds, and re-registers with the
//   new provider chain.
// * Focus *changes* cannot be applied during the build phase:
//   `FocusManager._markNeedsUpdate` (focus_manager.dart 1937–1945) defers
//   `applyFocusChangesIfNeeded` to a microtask, and `Element.rebuild`
//   (5521–5530) skips elements whose lifecycle is not active.
//
// So a stale entry is unreachable from any single-frame synchronous
// framework path — consistent with all nine candidates below passing on
// the exact framework version, and with #132799's "one time failure only".
// The assert needs a cross-frame overlap: a focus notification (the
// `_FocusInheritedScope` is an `InheritedNotifier<FocusNode>` — a focus
// change on the scope node sets the scope element's `_dirty`, and
// `_InheritedNotifierElement.build` then runs `notifyClients`) landing
// while the dependent bookkeeping is mid-teardown in the same frame.
//
// The app cannot change *which* element goes stale — the
// `_FocusInheritedScope` dependents are framework-internal `Focus` and
// scroll-view elements — only *when* focus changes fire and the lifecycles
// of app-owned focus nodes. In this tree the only droppable
// `_FocusInheritedScope` provider is `WidgetsApp`'s "Navigator Scope"
// (framework app.dart:1721), which the app never drops; the exposure is
// the overlap itself.
//
// ## What the app does about it (the fix this file pins)
//
// Two app-owned behaviors narrow the overlap window:
//
// 1. `_PromptBarState._activate` (structured_view.dart) claimed the prompt
//    field's focus back unconditionally — it now requests only when the
//    element is still `mounted` (a deferred focus request that only fires
//    when the node is attached and in the tree).
// 2. The app-owned focus nodes (`_fieldFocus`, `_selectionFocus`, the AFK
//    settings' commit-on-blur nodes) were released by `FocusNode.dispose`
//    inside the unmount sweep, where `FocusAttachment.detach` fires its own
//    `unfocus` when the node held the primary focus — a focus change deep
//    in the teardown. Each owner now releases the node in
//    `State.deactivate` (the element is still active; `unfocus` only
//    *marks* the change, which lands in the post-frame microtask), so the
//    dispose-driven detach has nothing to fire.
//
// The first group is the frame-precise campaign (all pass — the repro is
// not deterministic); the last group pins the post-fix behavior.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/bridge/events/event_frame.dart';
import 'package:opencodebridge/bridge/events/opencode_event_types.dart';
import 'package:opencodebridge/client/connection_monitor.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:opencodebridge/ui/home_shell.dart';
import 'package:opencodebridge/ui/structured_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _zero = TokenUsage(
  input: 0,
  output: 0,
  reasoning: 0,
  cacheRead: 0,
  cacheWrite: 0,
);

/// A closed session: one assistant message over a closing `idle` marker, so
/// the panel shows a settled history and a live prompt bar.
class _IdleClient extends SessionsClient {
  _IdleClient() : super(Uri.parse('http://bridge.test/'));

  @override
  Future<SessionDetail> getDetail(String id) async => SessionDetail(
    id: id,
    title: 'test session',
    location: '/x',
    cost: 0,
    tokens: _zero,
    outcome: null,
  );

  @override
  Future<List<SessionMessage>> getMessages(String id) async => [
    SessionMessage(role: 'assistant', text: 'hi there'),
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

/// Focuses the prompt bar's field: a tap requests the field's own
/// [FocusNode] through the gesture system (the user tapping the field).
Future<void> _focusPrompt(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('structured-prompt-input')));
  await tester.pump();
}

/// The real four-tab shell (Sessions first), with a connection monitor whose
/// probe always fails (the "no bridge" state the shell tests use).
Future<void> _pumpShell(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load();
  final monitor = ConnectionMonitor(probe: (Uri uri) async => false);
  monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
  addTearDown(monitor.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: HomeShell(
        monitor: monitor,
        settings: settings,
        mode: AppMode.client,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('issue #429 — InheritedElement.notifyClients descendant assert', () {
    // R1 — the detail-pane swap (the issue's prime suspect shape): the real
    // panel (prompt bar, SelectionArea scope) is focused, then dropped from
    // the tree by the host (like `sessions_tab.dart`'s `_buildDetailPane`
    // when the selection clears), a foreign focus change lands while it is
    // gone, and the panel is restored and focused again.
    testWidgets('detail pane drop/restore with the prompt field focused', (
      tester,
    ) async {
      final client = _IdleClient();
      final events = StreamController<BridgeEvent>.broadcast();
      addTearDown(events.close);
      var visible = true;
      late StateSetter setHost;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              setHost = setState;
              return Scaffold(
                body: Row(
                  children: [
                    const SizedBox(width: 200, child: Text('list pane')),
                    if (visible)
                      Expanded(
                        child: StructuredSessionPanel(
                          sessionId: 'ses_1',
                          title: 'test session',
                          client: client,
                          events: events.stream,
                          onClose: () => setHost(() => visible = false),
                        ),
                      ),
                    if (!visible)
                      FilledButton(
                        key: const ValueKey('restore'),
                        onPressed: () => setHost(() => visible = true),
                        child: const Text('restore'),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _focusPrompt(tester);
      // Drop the pane with the field focused.
      setHost(() => visible = false);
      await tester.pump();
      // A focus notification while the pane is gone.
      final foreign = FocusNode();
      addTearDown(foreign.dispose);
      foreign.requestFocus();
      await tester.pump();
      // Restore the pane; focus the fresh field.
      await tester.tap(find.byKey(const ValueKey('restore')));
      await _focusPrompt(tester);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    // R2 — the autofocus dialogs: the app's `_PickDialog` shape (an
    // AlertDialog over an `autofocus: true` search field), opened and
    // cancelled through a real `DialogRoute`.
    testWidgets('autofocus pick dialog opened and cancelled', (tester) async {
      Future<void> pickDialog() async {
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.push(
          DialogRoute<String>(
            context: tester.element(find.byType(Scaffold)),
            builder: (context) => AlertDialog(
              title: const Text('Pick a model'),
              content: TextField(
                key: const ValueKey('structured-pick-search'),
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search...'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The field has the focus; cancel through the route.
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await pickDialog();
      expect(tester.takeException(), isNull);
      await pickDialog();
      expect(tester.takeException(), isNull);
    });

    // R3 — the `IndexedStack` tab switch: `HomeShell` wraps every unselected
    // tab in an `ExcludeFocus` (a `Focus` whose `descendantsAreFocusable`
    // flips with the selection, firing focus notifications). Switch tabs
    // with a foreign focus change in flight.
    testWidgets('IndexedStack tab switch with a focus change in flight', (
      tester,
    ) async {
      await _pumpShell(tester);
      final foreign = FocusNode();
      addTearDown(foreign.dispose);
      foreign.requestFocus();
      await tester.pump();
      await tester.tap(find.text('Docker').last);
      await tester.pump();
      foreign.requestFocus();
      await tester.pump();
      await tester.tap(find.text('Settings').last);
      await tester.pump();
      await tester.tap(find.text('Sessions').last);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    // R3b — the same `IndexedStack` flip while the prompt field itself holds
    // focus: the panel lives in the visible tab, the flip moves it under
    // `ExcludeFocus`, and the focus displacement lands mid-frame.
    testWidgets(
      'IndexedStack tab switch with a focused prompt field in the stack',
      (tester) async {
        final client = _IdleClient();
        final events = StreamController<BridgeEvent>.broadcast();
        addTearDown(events.close);
        var index = 0;
        late StateSetter setIndex;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                setIndex = setState;
                return Scaffold(
                  body: Column(
                    children: [
                      Expanded(
                        child: IndexedStack(
                          index: index,
                          children: [
                            StructuredSessionPanel(
                              sessionId: 'ses_1',
                              title: 'test session',
                              client: client,
                              events: events.stream,
                            ),
                            const SizedBox(),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          for (var i = 0; i < 2; i += 1)
                            TextButton(
                              key: ValueKey('tab-$i'),
                              onPressed: () => setIndex(() => index = i),
                              child: Text('tab $i'),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
        await _focusPrompt(tester);
        // Switch tabs: the panel goes under `ExcludeFocus`.
        await tester.tap(find.byKey(const ValueKey('tab-1')));
        await tester.pump();
        // The focus displacement; switch back.
        await tester.tap(find.byKey(const ValueKey('tab-0')));
        await _focusPrompt(tester);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );

    // R4 — the root re-theme (the app's `onThemeModeChanged` root
    // `setState`): the whole `MaterialApp` rebuilds while the prompt field
    // is focused.
    testWidgets('root re-theme with the prompt field focused', (tester) async {
      final client = _IdleClient();
      final events = StreamController<BridgeEvent>.broadcast();
      addTearDown(events.close);
      late StateSetter retheme;
      var mode = ThemeMode.light;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            retheme = setState;
            return MaterialApp(
              themeMode: mode,
              home: Scaffold(
                body: StructuredSessionPanel(
                  sessionId: 'ses_1',
                  title: 'test session',
                  client: client,
                  events: events.stream,
                ),
              ),
            );
          },
        ),
      );
      await _focusPrompt(tester);
      // Re-theme the root while the field is focused.
      mode = ThemeMode.dark;
      retheme(() {});
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    // R5 — a `FocusNode` disposed while its scope is still active with
    // registered dependents (the settings `_AfkSectionState` shape): the
    // scope element's listener fires during dispose.
    testWidgets('focus node disposed while its scope still has dependents', (
      tester,
    ) async {
      final node = FocusNode(debugLabel: 'dying');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              focusNode: node,
              child: Focus(
                child: Builder(
                  builder: (context) {
                    // Register a dependent of the scope.
                    Focus.maybeOf(context);
                    return const SizedBox(height: 24);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      node.requestFocus();
      await tester.pump();
      // Dispose the node while its scope element is alive.
      node.dispose();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    // R6 — `requestFocus` on the field's node in the same event that drops
    // the panel (the `_PromptBar._activate` shape: the focus request first,
    // the teardown after).
    testWidgets('requestFocus in the same event that tears the panel down', (
      tester,
    ) async {
      final client = _IdleClient();
      final events = StreamController<BridgeEvent>.broadcast();
      addTearDown(events.close);
      var visible = true;
      late StateSetter setHost;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              setHost = setState;
              return Scaffold(
                body: Column(
                  children: [
                    if (visible)
                      Expanded(
                        child: StructuredSessionPanel(
                          sessionId: 'ses_1',
                          title: 'test session',
                          client: client,
                          events: events.stream,
                        ),
                      ),
                    FilledButton(
                      key: const ValueKey('teardown'),
                      onPressed: () {
                        // The `_activate` shape: the field's own node
                        // (read from the widget — the app passes its
                        // `_fieldFocus` there) is requested first, then the
                        // host tears the pane down in the same event.
                        tester
                            .widget<TextField>(
                              find.byKey(
                                const ValueKey('structured-prompt-input'),
                              ),
                            )
                            .focusNode
                            ?.requestFocus();
                        setHost(() => visible = false);
                      },
                      child: const Text('teardown'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('teardown')));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    // R7 — the autofocus dialog cancelled while a foreign focus change is in
    // flight (the post-frame autofocus has already registered the field on
    // the route's scope).
    testWidgets(
      'autofocus dialog cancelled with a foreign focus change in flight',
      (tester) async {
        final foreign = FocusNode();
        addTearDown(foreign.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(child: TextField(key: const ValueKey('home-field'))),
            ),
          ),
        );
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.push(
          DialogRoute<void>(
            context: tester.element(find.byType(Scaffold)),
            builder: (context) => AlertDialog(
              content: TextField(
                key: const ValueKey('autofocus-field'),
                autofocus: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(); // autofocus registered
        // Cancel while a foreign focus change is in flight.
        foreign.requestFocus();
        navigator.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );

    // R8 — the panel dropped in the same event that a bridge event lands
    // (the tab's live stream): the panel's event handler (a `setState`
    // rebuild) and the focus teardown interleave.
    testWidgets('panel dropped in the same event a bridge event lands', (
      tester,
    ) async {
      final client = _IdleClient();
      final events = StreamController<BridgeEvent>.broadcast();
      addTearDown(events.close);
      var visible = true;
      late StateSetter setHost;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              setHost = setState;
              return Scaffold(
                body: Column(
                  children: [
                    if (visible)
                      Expanded(
                        child: StructuredSessionPanel(
                          sessionId: 'ses_1',
                          title: 'test session',
                          client: client,
                          events: events.stream,
                        ),
                      ),
                    FilledButton(
                      key: const ValueKey('drop'),
                      onPressed: () => setHost(() => visible = false),
                      child: const Text('drop'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _focusPrompt(tester);
      // Fire a real session event and drop the pane in the same event.
      events.add(
        const BridgeEvent(
          id: 'e1',
          created: 1,
          type: OpencodeEventType.sessionStepStarted,
          data: {
            'sessionID': 'ses_1',
            'assistantMessageID': 'm1',
            'started': 1,
          },
        ),
      );
      setHost(() => visible = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    // P1 — the fix, post-fix behavior: the prompt field holds the primary
    // focus, the panel is dropped from the tree, and the field's node is
    // disposed. With the fix, the field's focus is released in
    // `State.deactivate` (a *marked* change — `unfocus` never applies it
    // during the frame — applied in the post-frame microtask, with the
    // bookkeeping already consistent), instead of being stuck on the node
    // being torn down: a focus change is never left pending against a dead
    // node, and later focus requests work normally.
    testWidgets(
      'fix: dropping the focused prompt bar releases its focus to a live node',
      (tester) async {
        final client = _IdleClient();
        final events = StreamController<BridgeEvent>.broadcast();
        addTearDown(events.close);
        // The foreign node lives in the tree (a `Focus` host): a bare node
        // could never take the primary focus.
        final foreign = FocusNode(debugLabel: 'foreign');
        addTearDown(foreign.dispose);
        var visible = true;
        late StateSetter setHost;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                setHost = setState;
                return Scaffold(
                  body: Column(
                    children: [
                      if (visible)
                        Expanded(
                          child: StructuredSessionPanel(
                            sessionId: 'ses_1',
                            title: 'test session',
                            client: client,
                            events: events.stream,
                          ),
                        ),
                      Focus(
                        focusNode: foreign,
                        child: const SizedBox(key: ValueKey('foreign-host')),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
        await _focusPrompt(tester);
        final manager = tester.binding.focusManager;
        final fieldFocus =
            tester
                    .widget<TextField>(
                      find.byKey(const ValueKey('structured-prompt-input')),
                    )
                    .focusNode
                as FocusNode;
        expect(manager.primaryFocus, fieldFocus);
        // Drop the panel with the field focused: the teardown frame (the
        // deactivate release, the dispose, the microtask that applies the
        // marked change) must land without an exception.
        setHost(() => visible = false);
        await tester.pump(); // teardown frame
        await tester.pump(); // microtasks: the marked change applies
        await tester.pumpAndSettle();
        // The dead field's node holds no focus: the release moved it to a
        // live node (the enclosing scope's previously-focused fallback),
        // never leaving the change pending against a disposed node.
        expect(manager.primaryFocus, isNotNull);
        expect(manager.primaryFocus, isNot(fieldFocus));
        expect(tester.takeException(), isNull);
        // And focus still works normally afterwards.
        foreign.requestFocus();
        await tester.pumpAndSettle();
        expect(manager.primaryFocus, foreign);
        expect(tester.takeException(), isNull);
      },
    );

    // P2 — the fix, post-fix behavior: the bar's `_activate` claims the
    // field's focus back when a row runs (the behavior the `requestFocus`
    // exists for, issue #140). Driven through the real path: typing the
    // trigger opens the command menu, and the row's `InkWell.onTap` is
    // `_activate`'s caller (Dart's library privacy keeps the private
    // method itself unreachable from a test). With the bar mounted, the
    // claim still fires: after the tap the field holds the primary focus,
    // no matter what the focus held before (the row is `canRequestFocus:
    // false`, so the tap itself never moves it).
    testWidgets('fix: tapping a menu row keeps the field focused', (
      tester,
    ) async {
      final client = _IdleClient();
      final events = StreamController<BridgeEvent>.broadcast();
      addTearDown(events.close);
      // The foreign node lives in the tree (a `Focus` host): a bare node
      // could never take the primary focus, so it could not stand in for
      // the competing focus of a tapped row.
      final foreign = FocusNode(debugLabel: 'foreign');
      addTearDown(foreign.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: StructuredSessionPanel(
                    sessionId: 'ses_1',
                    title: 'test session',
                    client: client,
                    events: events.stream,
                  ),
                ),
                Focus(
                  focusNode: foreign,
                  child: const SizedBox(key: ValueKey('foreign-host')),
                ),
              ],
            ),
          ),
        ),
      );
      await _focusPrompt(tester);
      final manager = tester.binding.focusManager;
      final fieldFocus =
          tester
                  .widget<TextField>(
                    find.byKey(const ValueKey('structured-prompt-input')),
                  )
                  .focusNode
              as FocusNode;
      // Open the command menu: the static catalog's first row is
      // `/models`.
      await tester.enterText(
        find.byKey(const ValueKey('structured-prompt-input')),
        '/',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('structured-command-menu')),
        findsOneWidget,
      );
      // A competing focus lands on a foreign node (e.g. the row's tap
      // gesture stealing it first), then the row is tapped: the field
      // must hold the primary focus again.
      foreign.requestFocus();
      await tester.pumpAndSettle();
      expect(manager.primaryFocus, foreign);
      await tester.tap(
        find.byKey(const ValueKey('structured-command-row-models')),
      );
      await tester.pumpAndSettle();
      expect(manager.primaryFocus, fieldFocus);
      expect(tester.takeException(), isNull);
    });
  });
}
