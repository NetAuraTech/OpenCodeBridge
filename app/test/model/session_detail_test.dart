import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/session_detail.dart';

void main() {
  group('TokenUsage', () {
    test('toJson carries the flattened contract shape', () {
      const usage = TokenUsage(
        input: 1,
        output: 2,
        reasoning: 3,
        cacheRead: 4,
        cacheWrite: 5,
      );
      expect(usage.toJson(), {
        'input': 1,
        'output': 2,
        'reasoning': 3,
        'cacheRead': 4,
        'cacheWrite': 5,
      });
    });

    test('fromJson round-trips usage and is tolerant of a missing value', () {
      const usage = TokenUsage(
        input: 1,
        output: 2,
        reasoning: 3,
        cacheRead: 4,
        cacheWrite: 5,
      );
      expect(TokenUsage.fromJson(usage.toJson()), usage);
      expect(
        TokenUsage.fromJson(null),
        const TokenUsage(
          input: 0,
          output: 0,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
        ),
      );
      expect(
        TokenUsage.fromJson({'input': 9, 'output': 8}),
        const TokenUsage(
          input: 9,
          output: 8,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
        ),
      );
    });

    // The events' nested token shape (issue #285): the service's
    // `TokenUsage.Info` nests `cache.read`/`cache.write`, which the history
    // contract flattens to `cacheRead`/`cacheWrite`. `fromEventTokens` is the
    // one place the nested → flattened transform lives, so these pin the wire
    // field names (a renamed or added field breaks exactly here).
    test('fromEventTokens flattens the nested cache read/write', () {
      expect(
        TokenUsage.fromEventTokens({
          'input': 1,
          'output': 2,
          'reasoning': 3,
          'cache': {'read': 4, 'write': 5},
        }),
        const TokenUsage(
          input: 1,
          output: 2,
          reasoning: 3,
          cacheRead: 4,
          cacheWrite: 5,
        ),
      );
    });

    test('fromEventTokens is tolerant of a missing or partial cache', () {
      // A missing `cache` reads as zero reads/writes (not an error).
      expect(
        TokenUsage.fromEventTokens({'input': 7, 'output': 8}),
        const TokenUsage(
          input: 7,
          output: 8,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
        ),
      );
      // A cache with only a read, or no numeric value, is tolerant.
      expect(
        TokenUsage.fromEventTokens({
          'input': 1,
          'cache': {'read': 2},
        }),
        const TokenUsage(
          input: 1,
          output: 0,
          reasoning: 0,
          cacheRead: 2,
          cacheWrite: 0,
        ),
      );
      expect(
        TokenUsage.fromEventTokens({'cache': 'not a map'}),
        const TokenUsage(
          input: 0,
          output: 0,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
        ),
      );
      expect(
        TokenUsage.fromEventTokens(null),
        const TokenUsage(
          input: 0,
          output: 0,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
        ),
      );
    });

    // The context arithmetic (issue #285): the model call's context is its
    // input plus the prompt-cache reads and writes. The one owner of that
    // arithmetic, so the live path and the history path agree.
    test('contextTokens is input plus the cache reads and writes', () {
      expect(
        const TokenUsage(
          input: 30,
          output: 5,
          reasoning: 0,
          cacheRead: 40,
          cacheWrite: 30,
        ).contextTokens,
        100,
      );
      // No cache: the context is the input alone.
      expect(
        const TokenUsage(
          input: 12,
          output: 3,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
        ).contextTokens,
        12,
      );
    });

    test('contextTokensFrom decodes the nested payload to the context', () {
      // The same fact the history message carries as `contextTokens`.
      expect(
        TokenUsage.contextTokensFrom({
          'input': 30,
          'cache': {'read': 40, 'write': 30},
        }),
        100,
      );
      // Tolerant of a missing cache (reads as zero), and `null` when there is
      // no `input` (a step without tokens cannot feed the context).
      expect(TokenUsage.contextTokensFrom({'input': 8}), 8);
      expect(TokenUsage.contextTokensFrom({'output': 5}), isNull);
      expect(TokenUsage.contextTokensFrom(null), isNull);
    });
  });

  group('SessionDetail', () {
    test('toJson carries the full bridge contract detail', () {
      const detail = SessionDetail(
        id: 'ses_1',
        title: 'fix the flaky test',
        location: '/code/app',
        cost: 0.12,
        tokens: TokenUsage(
          input: 100,
          output: 50,
          reasoning: 0,
          cacheRead: 10,
          cacheWrite: 0,
        ),
        outcome: 'succeeded',
        contextLimit: 200000,
        model: ModelRef(id: 'flint', providerId: 'opencode', variant: 'high'),
        agent: 'build',
      );
      expect(detail.toJson(), {
        'id': 'ses_1',
        'title': 'fix the flaky test',
        'location': '/code/app',
        'cost': 0.12,
        'tokens': {
          'input': 100,
          'output': 50,
          'reasoning': 0,
          'cacheRead': 10,
          'cacheWrite': 0,
        },
        'outcome': 'succeeded',
        'contextLimit': 200000,
        'model': {'id': 'flint', 'providerID': 'opencode', 'variant': 'high'},
        'agent': 'build',
        'active': false,
        'canCancel': true,
      });
    });

    test('fromJson round-trips a detail', () {
      const detail = SessionDetail(
        id: 'ses_1',
        title: 't',
        location: '/x',
        cost: 0.5,
        tokens: TokenUsage(
          input: 1,
          output: 2,
          reasoning: 3,
          cacheRead: 4,
          cacheWrite: 5,
        ),
        model: ModelRef(id: 'flint', providerId: 'opencode', variant: 'high'),
        agent: 'plan',
      );
      expect(SessionDetail.fromJson(detail.toJson()), detail);
    });

    test('fromJson reads the service model and agent fields', () {
      final detail = SessionDetail.fromJson({
        'id': 'ses_1',
        'model': {'id': 'mod1', 'providerID': 'prov1', 'variant': 'v1'},
        'agent': 'plan',
      });
      expect(
        detail.model,
        const ModelRef(id: 'mod1', providerId: 'prov1', variant: 'v1'),
      );
      expect(detail.agent, 'plan');
    });

    test('fromJson is tolerant of a missing or partial detail', () {
      expect(
        SessionDetail.fromJson(null),
        const SessionDetail(
          id: '',
          title: '',
          location: '',
          cost: 0,
          tokens: TokenUsage(
            input: 0,
            output: 0,
            reasoning: 0,
            cacheRead: 0,
            cacheWrite: 0,
          ),
        ),
      );
      expect(
        SessionDetail.fromJson({'id': 'ses_2', 'cost': 7, 'outcome': 'failed'}),
        const SessionDetail(
          id: 'ses_2',
          title: '',
          location: '',
          cost: 7,
          tokens: TokenUsage(
            input: 0,
            output: 0,
            reasoning: 0,
            cacheRead: 0,
            cacheWrite: 0,
          ),
          outcome: 'failed',
        ),
      );
    });

    test('withUsage replaces only the usage facts', () {
      const detail = SessionDetail(
        id: 'ses_1',
        title: 't',
        location: '/x',
        cost: 0,
        tokens: TokenUsage(
          input: 0,
          output: 0,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
        ),
        outcome: 'succeeded',
        model: ModelRef(id: 'mod1', providerId: 'prov1'),
        agent: 'build',
      );
      final refreshed = detail.withUsage(
        cost: 1.5,
        tokens: const TokenUsage(
          input: 9,
          output: 8,
          reasoning: 0,
          cacheRead: 7,
          cacheWrite: 6,
        ),
      );
      expect(
        refreshed,
        const SessionDetail(
          id: 'ses_1',
          title: 't',
          location: '/x',
          cost: 1.5,
          tokens: TokenUsage(
            input: 9,
            output: 8,
            reasoning: 0,
            cacheRead: 7,
            cacheWrite: 6,
          ),
          outcome: 'succeeded',
          model: ModelRef(id: 'mod1', providerId: 'prov1'),
          agent: 'build',
        ),
      );
    });
  });
}
