import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/message.dart';

void main() {
  group('ToolCall round-trip', () {
    test('serializes all fields and deserializes back', () {
      const tc = ToolCall(
        id: 'call_1',
        name: 'bash',
        status: 'running',
        input: {'command': 'ls -la'},
      );
      expect(tc.toJson(), {
        'id': 'call_1',
        'name': 'bash',
        'status': 'running',
        'input': {'command': 'ls -la'},
        'error': null,
      });
      final back = ToolCall.fromJson(tc.toJson());
      expect(back.id, 'call_1');
      expect(back.name, 'bash');
      expect(back.status, 'running');
      expect(back.input, {'command': 'ls -la'});
      expect(back.error, isNull);
    });

    test('input and error are optional on the wire', () {
      const tc = ToolCall(name: 'read', status: 'completed');
      expect(tc.toJson(), {
        'id': null,
        'name': 'read',
        'status': 'completed',
        'input': null,
        'error': null,
      });
      final back = ToolCall.fromJson(tc.toJson());
      expect(back.input, isNull);
      expect(back.error, isNull);
    });

    test('error surfaces when present', () {
      const json = {
        'name': 'write',
        'status': 'error',
        'error': 'permission denied',
      };
      expect(ToolCall.fromJson(json).error, 'permission denied');
    });
  });

  group('SessionMessage round-trip', () {
    test('assistant message with tools serializes and deserializes', () {
      const msg = SessionMessage(
        id: 'msg_1',
        role: 'assistant',
        text: 'Listing files.',
        reasoning: 'which files?',
        tools: [
          ToolCall(name: 'bash', status: 'running', input: {'command': 'ls'}),
        ],
      );
      expect(msg.toJson(), {
        'id': 'msg_1',
        'role': 'assistant',
        'text': 'Listing files.',
        'reasoning': 'which files?',
        'contextTokens': null,
        'tools': [
          {
            'id': null,
            'name': 'bash',
            'status': 'running',
            'input': {'command': 'ls'},
            'error': null,
          },
        ],
      });
      final back = SessionMessage.fromJson(msg.toJson());
      expect(back.id, 'msg_1');
      expect(back.role, 'assistant');
      expect(back.text, 'Listing files.');
      expect(back.reasoning, 'which files?');
      expect(back.tools, hasLength(1));
      expect(back.tools.single.name, 'bash');
      expect(back.tools.single.status, 'running');
    });

    test('a user message without tools serializes an empty tools list', () {
      const msg = SessionMessage(role: 'user', text: 'Hello');
      expect(msg.toJson(), {
        'id': null,
        'role': 'user',
        'text': 'Hello',
        'reasoning': null,
        'contextTokens': null,
        'tools': <Object?>[],
      });
    });

    test('parses an empty tool list', () {
      final msg = SessionMessage.fromJson({'role': 'assistant', 'tools': []});
      expect(msg.tools, isEmpty);
    });
  });

  group('Wire tolerance', () {
    test('unknown fields are ignored', () {
      final tc = ToolCall.fromJson({
        'name': 'bash',
        'status': 'running',
        'future': true,
      });
      expect(tc.name, 'bash');
      expect(tc.input, isNull);
    });

    test('missing optional message fields fall back to null/empty', () {
      final msg = SessionMessage.fromJson({'role': 'user'});
      expect(msg.text, isNull);
      expect(msg.reasoning, isNull);
      expect(msg.tools, isEmpty);
    });
  });

  test('toString identifies the model', () {
    expect(
      SessionMessage(role: 'user').toString(),
      'SessionMessage(id: null, role: user, text: null, '
      'reasoning: null, contextTokens: null, tools: [])',
    );
  });
}
