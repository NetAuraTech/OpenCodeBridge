import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/message.dart';

// The captured 429 wire shape (issue #155), shared by the model and the
// HTTP-service replay tests. `message` is the provider's one-line error with
// the raw body inlined; `body` is the provider's raw `response.body`.
const _rateLimitBody =
    '{"detail":{"error":{"message":"Model API rate limit exceeded; please retry later","type":"rate_limit_error","code":"token_concurrency_rate_limit_exceeded"}}}';
const _rateLimitMessage =
    'Provider request failed with HTTP 429: '
    '{"detail":{"error":{"message":"Model API rate limit exceeded; please retry later","type":"rate_limit_error","code":"token_concurrency_rate_limit_exceeded"}}}';

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
        'patch': null,
        'answers': null,
      });
      final back = ToolCall.fromJson(tc.toJson());
      expect(back.id, 'call_1');
      expect(back.name, 'bash');
      expect(back.status, 'running');
      expect(back.input, {'command': 'ls -la'});
      expect(back.error, isNull);
    });

    test('input, error, and patch are optional on the wire', () {
      const tc = ToolCall(name: 'read', status: 'completed');
      expect(tc.toJson(), {
        'id': null,
        'name': 'read',
        'status': 'completed',
        'input': null,
        'error': null,
        'patch': null,
        'answers': null,
      });
      final back = ToolCall.fromJson(tc.toJson());
      expect(back.input, isNull);
      expect(back.error, isNull);
      expect(back.patch, isNull);
      expect(back.answers, isNull);
    });

    test('the question answers round-trip and compare by content', () {
      const tc = ToolCall(
        id: 'call_q',
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
      );
      final back = ToolCall.fromJson(tc.toJson());
      expect(back.answers, [
        ['Yes'],
        ['Staging'],
      ]);
      expect(back, tc);
    });

    test('answersFrom parses the service shape and ignores other values', () {
      expect(
        ToolCall.answersFrom([
          ['Yes'],
          ['A', 'B'],
        ]),
        [
          ['Yes'],
          ['A', 'B'],
        ],
      );
      expect(ToolCall.answersFrom(null), isNull);
      expect(ToolCall.answersFrom('nope'), isNull);
      expect(ToolCall.answersFrom([]), isNull);
    });

    test('the file patch round-trips', () {
      const patch = '--- a\n+++ a\n@@ -1 +1 @@\n-a\n+b\n';
      const tc = ToolCall(name: 'edit', status: 'completed', patch: patch);
      final back = ToolCall.fromJson(tc.toJson());
      expect(back.patch, patch);
      expect(back, tc);
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

  group('ToolCall.writePatch', () {
    const header =
        'Index: /x/a.txt\n'
        '===================================================================\n'
        '--- /dev/null\n'
        '+++ /x/a.txt\n';

    test('synthesizes a new-file diff from the write content', () {
      expect(
        ToolCall.writePatch({'path': '/x/a.txt', 'content': 'a\nb\n'}),
        '$header@@ -0,0 +1,2 @@\n+a\n+b\n',
      );
    });

    test('handles content without a trailing newline', () {
      expect(
        ToolCall.writePatch({'path': '/x/a.txt', 'content': 'a\nb'}),
        '$header@@ -0,0 +1,2 @@\n+a\n+b\n',
      );
    });

    test('keeps the content lines own leading signs', () {
      expect(
        ToolCall.writePatch({'path': 'p', 'content': '-x\n+ y\n z\n'}),
        'Index: p\n'
        '===================================================================\n'
        '--- /dev/null\n'
        '+++ p\n'
        '@@ -0,0 +1,3 @@\n'
        '+-x\n'
        '++ y\n'
        '+ z\n',
      );
    });

    test('empty content yields a header-only patch', () {
      expect(
        ToolCall.writePatch({'path': 'p', 'content': ''}),
        'Index: p\n'
        '===================================================================\n'
        '--- /dev/null\n'
        '+++ p\n'
        '@@ -0,0 +1,0 @@\n',
      );
    });

    test('null when the input carries no content', () {
      expect(ToolCall.writePatch({'path': 'p', 'command': 'ls'}), isNull);
      expect(ToolCall.writePatch({'path': 'p', 'content': 42}), isNull);
      expect(ToolCall.writePatch(null), isNull);
      expect(ToolCall.writePatch('not a map'), isNull);
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
            'patch': null,
            'answers': null,
          },
        ],
        'created': null,
        'streamed': null,
        'completed': null,
        'outputTokens': null,
        'reasoningTokens': null,
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
        'created': null,
        'streamed': null,
        'completed': null,
        'outputTokens': null,
        'reasoningTokens': null,
      });
    });

    test('the turn timestamps and token counts round-trip', () {
      const msg = SessionMessage(
        id: 'msg_2',
        role: 'assistant',
        created: 10,
        streamed: 20,
        completed: 30,
        outputTokens: 7,
        reasoningTokens: 3,
      );
      final back = SessionMessage.fromJson(msg.toJson());
      expect(back.created, 10);
      expect(back.streamed, 20);
      expect(back.completed, 30);
      expect(back.outputTokens, 7);
      expect(back.reasoningTokens, 3);
      expect(back, msg);
    });

    test('parses an empty tool list', () {
      final msg = SessionMessage.fromJson({'role': 'assistant', 'tools': []});
      expect(msg.tools, isEmpty);
    });
  });

  group('StructuredError round-trip', () {
    test('a full 429 error round-trips, nested wire shape flattened', () {
      // The wire nests the provider's raw body as `response.body`; the
      // contract flattens it to `body` (documented flattening, issue #155).
      final err = StructuredError.fromJson({
        'type': 'provider.rate-limit',
        'message': _rateLimitMessage,
        'status': 429,
        'response': {'body': _rateLimitBody},
        'retryAfterMs': 1000,
      });
      expect(
        err,
        const StructuredError(
          type: 'provider.rate-limit',
          message: _rateLimitMessage,
          status: 429,
          body: _rateLimitBody,
          retryAfterMs: 1000,
        ),
      );
      // Omitted fields drop from the wire (no null churn).
      expect(err.toJson(), {
        'type': 'provider.rate-limit',
        'message': _rateLimitMessage,
        'status': 429,
        'body': _rateLimitBody,
        'retryAfterMs': 1000,
      });
      expect(StructuredError.fromJson(err.toJson()), err);
      // A row decoded twice is equal, and a differing field is not.
      expect(err, StructuredError.fromJson(err.toJson()));
      expect(
        err,
        isNot(
          const StructuredError(
            type: 'provider.no-route',
            message: 'Model unavailable: amd/qwen3.8-flash-next',
          ),
        ),
      );
      expect(err.hashCode, StructuredError.fromJson(err.toJson()).hashCode);
    });

    test(
      'a minimal error (no status/body/retryAfterMs) keeps only the keys',
      () {
        const err = StructuredError(
          type: 'provider.no-route',
          message: 'Model unavailable: amd/qwen3.8-flash-next',
        );
        expect(err.toJson(), {
          'type': 'provider.no-route',
          'message': 'Model unavailable: amd/qwen3.8-flash-next',
        });
        expect(StructuredError.fromJson(err.toJson()), err);
      },
    );
  });

  group('MessageRetry round-trip', () {
    test('attempt, at and the structured error round-trip by content', () {
      final retry = MessageRetry.fromJson({
        'attempt': 2,
        'at': 1794332643505,
        'error': {
          'type': 'provider.rate-limit',
          'message': _rateLimitMessage,
          'status': 429,
          'response': {'body': _rateLimitBody},
          'retryAfterMs': 1000,
        },
      });
      expect(
        retry,
        const MessageRetry(
          attempt: 2,
          at: 1794332643505,
          error: StructuredError(
            type: 'provider.rate-limit',
            message: _rateLimitMessage,
            status: 429,
            body: _rateLimitBody,
            retryAfterMs: 1000,
          ),
        ),
      );
      expect(retry.toJson(), {
        'attempt': 2,
        'at': 1794332643505,
        'error': {
          'type': 'provider.rate-limit',
          'message': _rateLimitMessage,
          'status': 429,
          'body': _rateLimitBody,
          'retryAfterMs': 1000,
        },
      });
      expect(MessageRetry.fromJson(retry.toJson()), retry);
    });
  });

  group('SessionMessage retry / terminal error / outcome (issue #155)', () {
    test(
      'a retried assistant message carries retry (no error, no outcome)',
      () {
        final msg = SessionMessage(
          id: 'msg_x',
          role: 'assistant',
          created: 1794332639945,
          retry: const MessageRetry(
            attempt: 2,
            at: 1794332643505,
            error: StructuredError(
              type: 'provider.rate-limit',
              message: _rateLimitMessage,
              status: 429,
              body: _rateLimitBody,
              retryAfterMs: 1000,
            ),
          ),
        );
        final json = msg.toJson();
        // Exactly one of retry / error; outcome omitted.
        expect(json.containsKey('retry'), isTrue);
        expect(json.containsKey('error'), isFalse);
        expect(json.containsKey('outcome'), isFalse);
        final back = SessionMessage.fromJson(json);
        expect(back, msg); // decoded twice is equal
        expect(back.retry!.attempt, 2);
        expect(back.retry!.at, 1794332643505);
        expect(back.retry!.error.type, 'provider.rate-limit');
        expect(back.retry!.error.body, _rateLimitBody);
        expect(back.error, isNull);
        expect(back.outcome, isNull);
      },
    );

    test('a terminal assistant error carries error (no retry)', () {
      final msg = SessionMessage(
        id: 'msg_x',
        role: 'assistant',
        error: const StructuredError(
          type: 'provider.no-route',
          message: 'Model unavailable: amd/qwen3.8-flash-next',
        ),
      );
      final json = msg.toJson();
      expect(json.containsKey('error'), isTrue);
      expect(json.containsKey('retry'), isFalse);
      expect(json.containsKey('outcome'), isFalse);
      expect(SessionMessage.fromJson(json), msg);
    });

    test('an idle row carries the outcome verdict', () {
      const msg = SessionMessage(id: 'm5', role: 'idle', outcome: 'succeeded');
      final json = msg.toJson();
      expect(json['outcome'], 'succeeded');
      expect(json.containsKey('retry'), isFalse);
      expect(json.containsKey('error'), isFalse);
      expect(SessionMessage.fromJson(json), msg);
    });

    test('a failed idle row carries outcome failed and its error', () {
      final msg = SessionMessage(
        id: 'm6',
        role: 'idle',
        outcome: 'failed',
        error: const StructuredError(
          type: 'provider.no-route',
          message: 'Model unavailable: amd/qwen3.8-flash-next',
        ),
      );
      final json = msg.toJson();
      expect(json['outcome'], 'failed');
      expect(json['error'], {
        'type': 'provider.no-route',
        'message': 'Model unavailable: amd/qwen3.8-flash-next',
      });
      expect(json.containsKey('retry'), isFalse);
      expect(SessionMessage.fromJson(json), msg);
    });

    test('an ordinary message keeps its exact current JSON shape', () {
      // No null churn (issue #155): a message with no retry / terminal error
      // / verdict serialises with exactly the keys it did before — omitted,
      // not null.
      const msg = SessionMessage(id: 'm1', role: 'user', text: 'hello');
      expect(msg.toJson(), {
        'id': 'm1',
        'role': 'user',
        'text': 'hello',
        'reasoning': null,
        'contextTokens': null,
        'tools': <Object?>[],
        'created': null,
        'streamed': null,
        'completed': null,
        'outputTokens': null,
        'reasoningTokens': null,
      });
      expect(msg.toJson().containsKey('retry'), isFalse);
      expect(msg.toJson().containsKey('error'), isFalse);
      expect(msg.toJson().containsKey('outcome'), isFalse);
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
      'reasoning: null, contextTokens: null, tools: [], created: null, '
      'streamed: null, completed: null, outputTokens: null, '
      'reasoningTokens: null, retry: null, error: null, outcome: null)',
    );
  });

  test('toString prints the retry / terminal error / outcome by content', () {
    const message = SessionMessage(
      id: 'm1',
      role: 'assistant',
      text: 'working',
      retry: MessageRetry(
        attempt: 2,
        at: 1794332643505,
        error: StructuredError(
          type: 'provider.rate-limit',
          message: 'HTTP 429',
        ),
      ),
    );
    expect(
      message.toString(),
      'SessionMessage(id: m1, role: assistant, text: working, '
      'reasoning: null, contextTokens: null, tools: [], created: null, '
      'streamed: null, completed: null, outputTokens: null, '
      'reasoningTokens: null, '
      'retry: MessageRetry(attempt: 2, at: 1794332643505, '
      'error: StructuredError(type: provider.rate-limit, message: HTTP 429, '
      'status: null, body: null, retryAfterMs: null)), '
      'error: null, outcome: null)',
    );

    final failed = SessionMessage(
      id: 'm6',
      role: 'idle',
      outcome: 'failed',
      error: const StructuredError(
        type: 'provider.no-route',
        message: 'Model unavailable: amd/qwen3.8-flash-next',
      ),
    );
    expect(
      failed.toString(),
      'SessionMessage(id: m6, role: idle, text: null, reasoning: null, '
      'contextTokens: null, tools: [], created: null, streamed: null, '
      'completed: null, outputTokens: null, reasoningTokens: null, '
      'retry: null, error: StructuredError(type: provider.no-route, '
      'message: Model unavailable: amd/qwen3.8-flash-next, status: null, '
      'body: null, retryAfterMs: null), outcome: failed)',
    );
  });
}
