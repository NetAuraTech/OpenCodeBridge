import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/question.dart';

void main() {
  group('QuestionOption round-trip', () {
    test('serializes and deserializes with a description', () {
      const option = QuestionOption(label: 'Yes', description: 'Do the thing');
      final json = option.toJson();
      expect(json, {'label': 'Yes', 'description': 'Do the thing'});
      final back = QuestionOption.fromJson(json);
      expect(back, option);
    });

    test('description is optional and omitted when absent', () {
      const option = QuestionOption(label: 'No');
      expect(option.toJson(), {'label': 'No'});
      final back = QuestionOption.fromJson(option.toJson());
      expect(back, option);
      expect(back.description, isNull);
    });

    test('missing label defaults to empty', () {
      expect(QuestionOption.fromJson(const {}).label, '');
      expect(QuestionOption.fromJson(const {'label': 'X'}).label, 'X');
    });
  });

  group('Question round-trip', () {
    test('serializes a single-select question with options', () {
      const question = Question(
        header: 'Confirm',
        question: 'Proceed with the deployment?',
        multiple: false,
        custom: false,
        options: [
          QuestionOption(label: 'Yes', description: 'ship it'),
          QuestionOption(label: 'No'),
        ],
      );
      final json = question.toJson();
      expect(json, {
        'header': 'Confirm',
        'question': 'Proceed with the deployment?',
        'multiple': false,
        'options': [
          {'label': 'Yes', 'description': 'ship it'},
          {'label': 'No'},
        ],
        'custom': false,
      });
      expect(Question.fromJson(json), question);
    });

    test('multiple and custom flags survive the round-trip', () {
      const question = Question(
        header: 'Pick',
        question: 'Choose some',
        multiple: true,
        custom: true,
        options: [
          QuestionOption(label: 'A'),
          QuestionOption(label: 'B'),
        ],
      );
      final back = Question.fromJson(question.toJson());
      expect(back.multiple, isTrue);
      expect(back.custom, isTrue);
      expect(back, question);
    });

    test('options default to empty when absent', () {
      expect(
        Question.fromJson(const {'header': 'H', 'question': 'Q'}).options,
        isEmpty,
      );
    });
  });

  group('QuestionForm round-trip', () {
    test('serializes and deserializes the questions in order', () {
      const form = QuestionForm(
        id: 'form_1',
        title: 'Questions',
        questions: [
          Question(
            header: 'First',
            question: 'First question?',
            multiple: false,
            custom: false,
            options: [QuestionOption(label: 'Yes')],
          ),
          Question(
            header: 'Second',
            question: 'Second question?',
            multiple: true,
            custom: true,
            options: [
              QuestionOption(label: 'A'),
              QuestionOption(label: 'B'),
            ],
          ),
        ],
      );
      final back = QuestionForm.fromJson(form.toJson());
      expect(back, form);
      expect(back.id, 'form_1');
      expect(back.title, 'Questions');
      expect(back.questions, [form.questions.first, form.questions.last]);
    });

    test('questions default to empty when absent', () {
      expect(
        QuestionForm.fromJson(const {'id': 'f', 'title': 'T'}).questions,
        isEmpty,
      );
    });
  });
}
