import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/ui/structured_view.dart';

/// A client that loads one settled turn: a user prompt and an assistant
/// reply carrying reasoning text, a plain body paragraph, and a table.
class _MinimalClient extends SessionsClient {
  _MinimalClient() : super(Uri.parse('http://bridge.test/'));

  @override
  Future<SessionDetail> getDetail(String id) async => SessionDetail(
    id: id,
    title: 'external',
    location: '/x',
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
  Future<List<SessionMessage>> getMessages(String id) async => const [
    SessionMessage(role: 'user', text: 'say hi'),
    SessionMessage(
      role: 'assistant',
      reasoning: 'thinking about it',
      text: 'plain body text here\n\n| one | two |\n| --- | --- |\n| three | four |',
    ),
    SessionMessage(id: 'i1', role: 'idle'),
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

/// Pumps [StructuredSessionScreen] under a material_ui `MaterialApp` in the
/// given [themeMode], settled (the two extra frames let the client's initial
/// reads land), mirroring the `_pump` helper of `structured_view_test.dart`.
Future<void> _pump(
  WidgetTester tester, {
  required ThemeData theme,
  required ThemeData darkTheme,
  required ThemeMode themeMode,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      home: StructuredSessionScreen(
        sessionId: 'ses_1',
        title: 's',
        client: _MinimalClient(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(0),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// The resolved color of the leaf span carrying [text], or null if the text
/// (or a color on its span) is not found.
Color? _spanColor(WidgetTester tester, String text) {
  final rich = tester.widget<RichText>(
    find.descendant(of: find.text(text), matching: find.byType(RichText)),
  );
  Color? found;
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text == text) found = span.style?.color;
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(rich.text);
  return found;
}

void main() {
  group('StructuredSessionScreen', () {
    // Regression for issue #423: in dark mode the markdown body text must
    // not render in the light theme's color. `material_ui`'s `Theme` widget
    // installs no `flutter/material` `Theme` in the tree, so
    // `flutter_markdown`'s fallback stylesheet (built from material's
    // `Theme.of` at parse time) resolves to the light `ThemeData.fallback()`
    // — and every style the sheet leaves colorless (the body paragraph, the
    // table cells) inherits the fallback's light `bodyMedium` color. The
    // sheet must carry the body color itself, from the real theme.

    testWidgets(
      'a dark-mode body paragraph renders in the dark theme color (issue #423)',
      (tester) async {
        final darkTheme = ThemeData.dark();
        await _pump(
          tester,
          theme: ThemeData.light(),
          darkTheme: darkTheme,
          themeMode: ThemeMode.dark,
        );
        expect(
          _spanColor(tester, 'plain body text here'),
          darkTheme.textTheme.bodyMedium!.color,
        );
      },
    );

    testWidgets(
      'dark-mode table cells render in the dark theme color (issue #423)',
      (tester) async {
        final darkTheme = ThemeData.dark();
        await _pump(
          tester,
          theme: ThemeData.light(),
          darkTheme: darkTheme,
          themeMode: ThemeMode.dark,
        );
        expect(
          _spanColor(tester, 'four'),
          darkTheme.textTheme.bodyMedium!.color,
        );
      },
    );

    testWidgets(
      'the dimmed thinking pane keeps its base color in dark mode (issue #423)',
      (tester) async {
        final darkTheme = ThemeData.dark();
        await _pump(
          tester,
          theme: ThemeData.light(),
          darkTheme: darkTheme,
          themeMode: ThemeMode.dark,
        );
        expect(
          _spanColor(tester, 'thinking about it'),
          darkTheme.colorScheme.outline,
        );
      },
    );

    testWidgets(
      'a light-mode body paragraph and table cells render in the light theme color (issue #423)',
      (tester) async {
        final lightTheme = ThemeData.light();
        await _pump(
          tester,
          theme: lightTheme,
          darkTheme: ThemeData.dark(),
          themeMode: ThemeMode.light,
        );
        expect(
          _spanColor(tester, 'plain body text here'),
          lightTheme.textTheme.bodyMedium!.color,
        );
        expect(
          _spanColor(tester, 'four'),
          lightTheme.textTheme.bodyMedium!.color,
        );
      },
    );
  });
}
