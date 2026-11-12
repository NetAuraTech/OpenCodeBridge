import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/ui/structured_view.dart';

void main() {
  group('messagePlainText (issue #198)', () {
    test('a user message copies its body as written', () {
      const message = SessionMessage(role: 'user', text: 'fix the tests');
      expect(messagePlainText(message), 'fix the tests');
    });

    test('the markdown markup is stripped (no **, no backticks)', () {
      const message = SessionMessage(
        role: 'assistant',
        text: 'I ran `flutter test` and it is **green** now.',
      );
      expect(
        messagePlainText(message),
        'I ran flutter test and it is green now.',
      );
    });

    test('the reasoning precedes the body, in display order', () {
      const message = SessionMessage(
        role: 'assistant',
        reasoning: 'Let me think about it.',
        text: 'The answer is 42.',
      );
      final text = messagePlainText(message);
      expect(text, 'Let me think about it.\nThe answer is 42.');
      expect(
        text.indexOf('Let me think'),
        lessThan(text.indexOf('The answer')),
      );
    });

    test('the tool cards ride after the body: header, input, error', () {
      const message = SessionMessage(
        role: 'assistant',
        text: 'I will run it',
        tools: [
          ToolCall(
            name: 'shell',
            status: 'completed',
            input: {'command': 'ls -la'},
          ),
          ToolCall(
            name: 'grep',
            status: 'error',
            input: {'pattern': 'todo'},
            error: 'no match',
          ),
        ],
      );
      final text = messagePlainText(message);
      expect(
        text,
        'I will run it\n'
        'shell · completed\n'
        'ls -la\n'
        'grep · error\n'
        'todo\n'
        'no match',
      );
    });

    test('a write tool copies its patch as shown: the path, then the diff', () {
      const message = SessionMessage(
        role: 'assistant',
        tools: [
          ToolCall(
            name: 'write',
            status: 'completed',
            input: {'path': '/tmp/a.txt', 'content': 'hello\nworld\n'},
          ),
        ],
      );
      expect(
        messagePlainText(message),
        'write · completed\n'
        '/tmp/a.txt\n'
        'Index: /tmp/a.txt\n'
        '===================================================================\n'
        '--- /dev/null\n'
        '+++ /tmp/a.txt\n'
        '@@ -0,0 +1,2 @@\n'
        '+hello\n'
        '+world\n',
      );
    });

    test('a question card copies each question and the answer given', () {
      const message = SessionMessage(
        role: 'assistant',
        tools: [
          ToolCall(
            name: 'question',
            status: 'completed',
            input: {
              'questions': [
                {
                  'question': 'Which theme?',
                  'header': 'Theme',
                  'options': [
                    {'label': 'Light', 'description': 'the light one'},
                  ],
                },
              ],
            },
            answers: [
              ['light'],
            ],
          ),
        ],
      );
      expect(
        messagePlainText(message),
        'question · completed\n'
        'Which theme?\n'
        'light',
      );
    });

    test('an unanswered question copies the em-dash placeholder', () {
      const message = SessionMessage(
        role: 'assistant',
        tools: [
          ToolCall(
            name: 'question',
            status: 'running',
            input: {
              'questions': [
                {
                  'question': 'Which theme?',
                  'header': 'Theme',
                  'options': [
                    {'label': 'Light', 'description': 'the light one'},
                  ],
                },
              ],
            },
          ),
        ],
      );
      expect(
        messagePlainText(message),
        'question · running\n'
        'Which theme?\n'
        '—',
      );
    });

    test('a streaming tool card carries its partial input as shown', () {
      const message = SessionMessage(
        role: 'assistant',
        tools: [ToolCall(name: 'shell', status: 'streaming', input: '{"comm')],
      );
      expect(
        messagePlainText(message),
        'shell · streaming\n'
        '{"comm',
      );
    });

    test('a compaction marker copies its summary', () {
      const message = SessionMessage(
        role: 'compaction',
        text: 'The session fixed **two** bugs.',
      );
      expect(messagePlainText(message), 'The session fixed two bugs.');
    });

    test('an idle marker copies nothing', () {
      const message = SessionMessage(
        id: 'i1',
        role: 'idle',
        outcome: 'succeeded',
      );
      expect(messagePlainText(message), '');
    });

    test('a user message with no text copies nothing', () {
      const message = SessionMessage(role: 'user');
      expect(messagePlainText(message), '');
    });
  });
}
