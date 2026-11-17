import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/ui/tool_card_content.dart';

/// The tool card's display content (issue #265, the S6a expand), tested
/// flat: derive the content of one `ToolCall`, assert the values — no
/// widget. These pin the one derivation the card and the copy both render,
/// so the two cannot drift.

const _questionInput = {
  'questions': [
    {
      'question': 'Which theme?',
      'header': 'Theme',
      'options': [
        {'label': 'Light', 'description': 'the light one'},
      ],
    },
  ],
};

void main() {
  group('ToolCardContent.derive (issue #265)', () {
    test('the header is the name and the status, as the card shows them', () {
      final content = ToolCardContent.derive(
        const ToolCall(name: 'shell', status: 'completed', input: {'a': 1}),
      );
      expect(content.header, 'shell · completed');
    });

    test('a shell card derives its command as the one-line summary', () {
      const tool = ToolCall(
        name: 'shell',
        status: 'completed',
        input: {'command': 'ls -la'},
      );
      final content = ToolCardContent.derive(tool);
      expect(content.detail, 'ls -la');
      expect(content.bodyText, 'ls -la');
      expect(content.patch, isNull);
      expect(content.patchPath, isNull);
      expect(content.questions, isNull);
      expect(content.rawInput, '{"command":"ls -la"}');
      expect(content.error, isNull);
    });

    test('an execute card derives its code as the one-line summary', () {
      final content = ToolCardContent.derive(
        const ToolCall(
          name: 'execute',
          status: 'running',
          input: {'code': 'print(1)'},
        ),
      );
      expect(content.detail, 'print(1)');
      expect(content.bodyText, 'print(1)');
    });

    test(
      'a read card derives its path with the offset and limit when given',
      () {
        final content = ToolCardContent.derive(
          const ToolCall(
            name: 'read',
            status: 'completed',
            input: {'path': 'src/main.dart', 'offset': 5, 'limit': 20},
          ),
        );
        expect(content.detail, 'src/main.dart (offset 5, limit 20)');
        expect(content.bodyText, 'src/main.dart (offset 5, limit 20)');
      },
    );

    test(
      'a read card derives its path alone when offset and limit are out',
      () {
        final content = ToolCardContent.derive(
          const ToolCall(
            name: 'read',
            status: 'completed',
            input: {'path': 'src/main.dart'},
          ),
        );
        expect(content.detail, 'src/main.dart');
      },
    );

    test('a grep card derives its pattern in its path when both are given', () {
      final content = ToolCardContent.derive(
        const ToolCall(
          name: 'grep',
          status: 'completed',
          input: {'pattern': 'todo', 'path': 'src'},
        ),
      );
      expect(content.detail, 'todo in src');
    });

    test('a grep card derives its pattern alone when the path is out', () {
      final content = ToolCardContent.derive(
        const ToolCall(
          name: 'grep',
          status: 'completed',
          input: {'pattern': 'todo'},
        ),
      );
      expect(content.detail, 'todo');
    });

    test('an answered question card derives its question and the answer', () {
      final content = ToolCardContent.derive(
        const ToolCall(
          name: 'question',
          status: 'completed',
          input: _questionInput,
          answers: [
            ['light'],
          ],
        ),
      );
      final questions = content.questions;
      expect(questions, isNotNull);
      expect(questions, hasLength(1));
      expect(questions!.single.question, 'Which theme?');
      expect(questions.single.answers, ['light']);
      expect(content.detail, isNull);
      expect(content.patch, isNull);
    });

    test(
      'an unanswered question card derives its question without an answer',
      () {
        final content = ToolCardContent.derive(
          const ToolCall(
            name: 'question',
            status: 'running',
            input: _questionInput,
          ),
        );
        final questions = content.questions;
        expect(questions, isNotNull);
        expect(questions!.single.question, 'Which theme?');
        expect(questions.single.answers, isNull);
      },
    );

    test('a still-streaming question input is not the question map', () {
      final content = ToolCardContent.derive(
        const ToolCall(name: 'question', status: 'streaming', input: '{"quest'),
      );
      expect(content.questions, isNull);
      expect(content.detail, isNull);
      expect(content.bodyText, '{"quest');
    });

    test('a write with a state patch derives that patch and its path', () {
      const input = {'path': '/tmp/a.txt', 'content': 'hello\nworld\n'};
      final patch = ToolCall.writePatch(input);
      final content = ToolCardContent.derive(
        const ToolCall(name: 'write', status: 'completed', patch: 'a patch'),
      );
      // The state's own patch wins over the synthesized one.
      expect(content.patch, 'a patch');
      expect(content.patchPath, isNull); // no map input, no path line
      expect(content.rawInput, '');
      // The synthesized patch of the map input is the fallback the copy used.
      final fallback = ToolCardContent.derive(
        ToolCall(name: 'write', status: 'completed', input: input),
      );
      expect(fallback.patch, patch);
      expect(fallback.patchPath, '/tmp/a.txt');
    });

    test(
      'a write whose input is a map without a state patch synthesizes one',
      () {
        // The bridge always sets the patch for a write (opencode_http_service
        // sets it on success); this shape is hand-composed only. The
        // derivation keeps the copy's rule: the synthesized patch, with the
        // path. The card's rendering gate (`tool.patch != null`) stays the
        // widget's to keep (the raw input shows there).
        const input = {'path': '/tmp/a.txt', 'content': 'hello\nworld\n'};
        final content = ToolCardContent.derive(
          ToolCall(name: 'write', status: 'completed', input: input),
        );
        expect(content.patch, ToolCall.writePatch(input));
        expect(content.patchPath, '/tmp/a.txt');
        expect(content.questions, isNull);
        expect(content.detail, isNull);
        expect(
          content.rawInput,
          '{"path":"/tmp/a.txt","content":"hello\\nworld\\n"}',
        );
      },
    );

    test('a raw-string input keeps its detail null and its text as-is', () {
      final content = ToolCardContent.derive(
        const ToolCall(name: 'shell', status: 'streaming', input: '{"comm'),
      );
      expect(content.detail, isNull);
      expect(content.bodyText, '{"comm');
      expect(content.rawInput, '{"comm');
    });

    test('an unknown tool with a map input falls back to the raw JSON', () {
      final content = ToolCardContent.derive(
        const ToolCall(
          name: 'patch',
          status: 'completed',
          input: {'foo': 'bar'},
        ),
      );
      expect(content.detail, isNull);
      expect(content.bodyText, '{"foo":"bar"}');
      expect(content.rawInput, '{"foo":"bar"}');
    });

    test('a failed tool carries its error line', () {
      final content = ToolCardContent.derive(
        const ToolCall(
          name: 'shell',
          status: 'error',
          input: {'command': 'ls'},
          error: 'no match',
        ),
      );
      expect(content.error, 'no match');
      expect(content.detail, 'ls');
      expect(content.header, 'shell · error');
    });

    test('an empty input derives an empty body (no line at all)', () {
      final content = ToolCardContent.derive(
        const ToolCall(name: 'shell', status: 'running'),
      );
      expect(content.detail, isNull);
      expect(content.rawInput, '');
      expect(content.bodyText, '');
      expect(content.questions, isNull);
      expect(content.patch, isNull);
      expect(content.error, isNull);
    });

    test('a tool whose summary field is empty falls back to the raw input', () {
      // `command` present but empty: no summary (the helper needs a
      // non-empty string), so the raw input shows — as before.
      final content = ToolCardContent.derive(
        const ToolCall(
          name: 'shell',
          status: 'completed',
          input: {'command': ''},
        ),
      );
      expect(content.detail, isNull);
      expect(content.bodyText, '{"command":""}');
    });

    test('a read with only one of offset and limit shows that one', () {
      final content = ToolCardContent.derive(
        const ToolCall(
          name: 'read',
          status: 'completed',
          input: {'path': 'src/main.dart', 'offset': 3},
        ),
      );
      expect(content.detail, 'src/main.dart (offset 3)');
    });
  });
}
