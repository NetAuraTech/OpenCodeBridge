import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/events_decode.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/session_detail.dart';

// The events-side decode (issue #285): the client owns the decode of the
// live event payloads and routes each shape through the model's decoder.
// These tests pin the two halves of the acceptance:
//
// 1. the one-place decode: a renamed or added wire field is a one-place
//    change — the field names below are the single choke point, and the
//    model's own decoders (which these route through) carry the value tests;
// 2. the live/history agreement: the same fact decoded on the events side
//    (the client) and the history side (the model) yields the same value.
void main() {
  group(
    'events decode — the one place the events side decodes (issue #285)',
    () {
      test('eventTokens decodes the usage payload through the model', () {
        expect(
          eventTokens(const {
            'cost': 0.0123,
            'tokens': {
              'input': 10,
              'output': 20,
              'reasoning': 0,
              'cache': {'read': 0, 'write': 0},
            },
          }),
          const TokenUsage(
            input: 10,
            output: 20,
            reasoning: 0,
            cacheRead: 0,
            cacheWrite: 0,
          ),
        );
        // The nested cache is flattened (the events' `cache.read`/`cache.write`
        // to the contract's `cacheRead`/`cacheWrite`).
        expect(
          eventTokens(const {
            'tokens': {
              'input': 1,
              'cache': {'read': 2, 'write': 3},
            },
          }),
          const TokenUsage(
            input: 1,
            output: 0,
            reasoning: 0,
            cacheRead: 2,
            cacheWrite: 3,
          ),
        );
      });

      test('eventTokens is null when the payload has no tokens', () {
        expect(eventTokens(const {'cost': 0.5}), isNull);
        expect(eventTokens(null), isNull);
        expect(eventTokens('not a payload'), isNull);
      });

      test('stepFacts decodes the step payload through the model', () {
        final facts = stepFacts(const {
          'assistantMessageID': 'm1',
          'tokens': {
            'input': 30,
            'output': 40,
            'reasoning': 50,
            'cache': {'read': 60, 'write': 70},
          },
        });
        expect(facts.outputTokens, 40);
        expect(facts.reasoningTokens, 50);
        // The context is the total input: input + cache reads and writes.
        expect(facts.contextTokens, 30 + 60 + 70);
      });

      test('stepFacts is null when the payload has no tokens', () {
        final facts = stepFacts(const {'assistantMessageID': 'm1'});
        expect(facts.outputTokens, isNull);
        expect(facts.reasoningTokens, isNull);
        expect(facts.contextTokens, isNull);
      });

      test(
        'toolStateFacts decodes the success event data through the model',
        () {
          final facts = toolStateFacts(const {
            'id': 't1',
            'metadata': {
              'files': [
                {'patch': 'P'},
              ],
              'answers': [
                ['Yes'],
              ],
            },
          });
          expect(facts.patch, 'P');
          expect(facts.answers, [
            ['Yes'],
          ]);
          // A state with no patch or answers decodes to nulls.
          final empty = toolStateFacts(const {'id': 't2'});
          expect(empty.patch, isNull);
          expect(empty.answers, isNull);
        },
      );
    },
  );

  group('the live path agrees with the history path (issue #285)', () {
    test('the token shape: the events decode equals the history decode', () {
      // The same fact in its two shapes: the events' nested `cache.read` /
      // `cache.write` payload (the live path) and the history's flattened
      // contract `cacheRead` / `cacheWrite` (the detail read).
      const nested = {
        'input': 100,
        'output': 50,
        'reasoning': 0,
        'cache': {'read': 10, 'write': 20},
      };
      const flattened = {
        'input': 100,
        'output': 50,
        'reasoning': 0,
        'cacheRead': 10,
        'cacheWrite': 20,
      };
      // The events side decodes the nested shape (via the client, which
      // routes through the model's one events decode)...
      final live = eventTokens({'tokens': nested});
      final direct = TokenUsage.fromEventTokens(nested);
      // ...and the history side decodes the flattened shape through the
      // model. Both are the same [TokenUsage] value.
      expect(live, direct);
      expect(direct, TokenUsage.fromJson(flattened));
    });

    test(
      'the context fact: the step.ended context equals the history context',
      () {
        // The same tokens the live step.ended event and the history message
        // carry.
        const tokens = {
          'input': 30,
          'output': 10,
          'reasoning': 0,
          'cache': {'read': 40, 'write': 30},
        };
        // The live path (the client's events decode)...
        final live = stepFacts({'tokens': tokens}).contextTokens;
        // ...and the history path (the model's one context owner, what the
        // bridge composes into `SessionMessage.contextTokens`) agree.
        final history = TokenUsage.contextTokensFrom(tokens);
        expect(live, 100);
        expect(history, live);
      },
    );

    test('the tool-state shape: the events data equals the history state', () {
      // The same tool state: the events' `session.tool.success` `data` (the
      // live path) and the history's tool `state` (the history path) share
      // the shape.
      const state = {
        'metadata': {
          'files': [
            {'patch': '--- a\n+++ b\n@@ -1 +1 @@\n-x\n+y\n'},
          ],
          'answers': [
            ['Yes'],
            ['Staging'],
          ],
        },
      };
      // The live path decodes through the client's events decode...
      final live = toolStateFacts(state);
      // ...and the history path decodes through the model's one tool-state
      // decoder. Both carry the same patch and answers.
      final history = ToolCall.fromToolState(state);
      expect(live.patch, history.patch);
      expect(live.patch, '--- a\n+++ b\n@@ -1 +1 @@\n-x\n+y\n');
      expect(live.answers, history.answers);
      expect(live.answers, [
        ['Yes'],
        ['Staging'],
      ]);
    });
  });
}
