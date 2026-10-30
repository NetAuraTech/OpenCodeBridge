import 'package:flutter_test/flutter_test.dart';
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
      );
      expect(SessionDetail.fromJson(detail.toJson()), detail);
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
        ),
      );
    });
  });
}
