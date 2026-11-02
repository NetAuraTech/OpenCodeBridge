import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/ui/question_panel.dart';

const _form = QuestionForm(
  id: 'form_q',
  title: 'Questions',
  questions: [
    Question(
      header: 'Ship it?',
      question: 'Should I ship it?',
      multiple: false,
      custom: true,
      options: [
        QuestionOption(label: 'Yes', description: 'ship it'),
        QuestionOption(label: 'No', description: 'hold off'),
      ],
    ),
    Question(
      header: 'Areas',
      question: 'Which areas do you want?',
      multiple: true,
      custom: true,
      options: [
        QuestionOption(label: 'A', description: 'area A'),
        QuestionOption(label: 'B', description: 'area B'),
      ],
    ),
  ],
);
const _solo = QuestionForm(
  id: 'form_solo',
  title: 'Ship it?',
  questions: [
    Question(
      header: 'Ship it?',
      question: 'Should I ship it?',
      multiple: false,
      custom: false,
      options: [
        QuestionOption(label: 'Yes', description: 'ship it'),
      ],
    ),
  ],
);

Future<void> _pumpPanel(
  WidgetTester tester, {
  List<QuestionForm> pending = const [],
  List<(QuestionForm, List<List<String>>)> submissions = const [],
  List<QuestionForm> dismissed = const [],
  String? busyId,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: QuestionPanel(
          pending: pending,
          onSubmit: (form, answers) async {
            submissions.add((form, answers));
          },
          onDismiss: (form) async {
            dismissed.add(form);
          },
          busyId: busyId,
        ),
      ),
    ),
  );
  await tester.pump();
}

void _expectAnswers(List<List<String>> actual, List<List<String>> expected) {
  expect(actual.length, expected.length);
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i], expected[i]);
  }
}

void main() {
  group('QuestionPanel', () {
    testWidgets('renders nothing when no form is pending', (tester) async {
      await _pumpPanel(tester);

      expect(find.byType(QuestionPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('question-banner')), findsNothing);
    });

    testWidgets('renders a single question without a tab strip', (
      tester,
    ) async {
      await _pumpPanel(tester, pending: const [_solo]);

      expect(find.byKey(const ValueKey('question-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('question-row-form_solo')),
        findsOneWidget,
      );
      // One question: the body renders directly, no tabs.
      expect(find.byKey(const ValueKey('question-tab-0')), findsNothing);
      expect(find.text('Should I ship it?'), findsWidgets);
      expect(
        find.byKey(const ValueKey('question-option-form_solo-0-0')),
        findsOneWidget,
      );
      expect(find.text('Yes'), findsOneWidget);
      expect(find.text('ship it'), findsOneWidget);
    });

    testWidgets('renders one tab per question, the selected question only', (
      tester,
    ) async {
      await _pumpPanel(tester, pending: const [_form]);

      expect(find.text('Questions'), findsOneWidget);
      // A tab per question, the first selected by default.
      expect(find.byKey(const ValueKey('question-tab-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('question-tab-1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('question-option-form_q-0-0')),
        findsOneWidget,
      );
      expect(find.text('Should I ship it?'), findsOneWidget);
      expect(find.text('ship it'), findsOneWidget);
      // The second question is not rendered until its tab is selected.
      expect(find.text('Which areas do you want?'), findsNothing);
      expect(
        find.byKey(const ValueKey('question-option-form_q-1-0')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('question-tab-1')));
      await tester.pump();

      expect(find.text('Which areas do you want?'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('question-option-form_q-1-0')),
        findsOneWidget,
      );
      expect(find.text('area A'), findsOneWidget);
    });

    testWidgets('submits the selected option for a single-select question', (
      tester,
    ) async {
      final submissions = <(QuestionForm, List<List<String>>)>[];
      await _pumpPanel(
        tester,
        pending: const [_form],
        submissions: submissions,
      );

      await tester.tap(
        find.byKey(const ValueKey('question-option-form_q-0-0')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('question-submit-form_q')));
      await tester.pump();

      expect(submissions, hasLength(1));
      expect(submissions.single.$1, _form);
      _expectAnswers(
        submissions.single.$2,
        [
          ['Yes'],
          const <String>[],
        ],
      );
    });

    testWidgets('a single-select free text wins over the selected option', (
      tester,
    ) async {
      final submissions = <(QuestionForm, List<List<String>>)>[];
      await _pumpPanel(
        tester,
        pending: const [_form],
        submissions: submissions,
      );

      await tester.tap(
        find.byKey(const ValueKey('question-option-form_q-0-0')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('question-text-form_q-0')),
        'ship, but quietly',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('question-submit-form_q')));
      await tester.pump();

      expect(submissions.single.$2[0], ['ship, but quietly']);
    });

    testWidgets(
      'submits the selected options for a multiple-select question, '
      'appending its free text',
      (tester) async {
        final submissions = <(QuestionForm, List<List<String>>)>[];
        await _pumpPanel(
          tester,
          pending: const [_form],
          submissions: submissions,
        );

        await tester.tap(find.byKey(const ValueKey('question-tab-1')));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('question-option-form_q-1-0')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('question-option-form_q-1-1')),
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('question-text-form_q-1')),
          'extra',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('question-submit-form_q')));
        await tester.pump();

        _expectAnswers(
          submissions.single.$2,
          [
            const <String>[],
            ['A', 'B', 'extra'],
          ],
        );
      },
    );

    testWidgets('deselecting a multiple-select option unselects it', (
      tester,
    ) async {
      final submissions = <(QuestionForm, List<List<String>>)>[];
      await _pumpPanel(
        tester,
        pending: const [_form],
        submissions: submissions,
      );

      await tester.tap(find.byKey(const ValueKey('question-tab-1')));
      await tester.pump();
      final optionA = find.byKey(const ValueKey('question-option-form_q-1-0'));
      await tester.tap(optionA);
      await tester.pump();
      await tester.tap(optionA);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('question-submit-form_q')));
      await tester.pump();

      _expectAnswers(submissions.single.$2, [
        const <String>[],
        const <String>[],
      ]);
    });

    testWidgets('dismiss sends the form to onDismiss', (tester) async {
      final dismissed = <QuestionForm>[];
      await _pumpPanel(
        tester,
        pending: const [_form],
        dismissed: dismissed,
      );

      await tester.tap(find.byKey(const ValueKey('question-dismiss-form_q')));
      await tester.pump();

      expect(dismissed, [_form]);
    });

    testWidgets('the busy form shows progress and hides its buttons', (
      tester,
    ) async {
      await _pumpPanel(tester, pending: const [_form], busyId: 'form_q');

      expect(
        find.byKey(const ValueKey('question-submit-form_q')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('question-dismiss-form_q')),
        findsNothing,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The options and the free-text field are disabled.
      final option = tester.widget<InkWell>(
        find.descendant(
          of: find.byKey(const ValueKey('question-option-form_q-0-0')),
          matching: find.byType(InkWell),
        ),
      );
      expect(option.onTap, isNull);
      final text = tester.widget<TextField>(
        find.byKey(const ValueKey('question-text-form_q-0')),
      );
      expect(text.enabled, isFalse);
    });
  });
}
