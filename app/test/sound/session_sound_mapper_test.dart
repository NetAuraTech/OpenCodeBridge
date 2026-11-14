import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/sound/session_sound.dart';

/// Build a durable, session-scoped opencode event the way the wire carries
/// it (`durable.aggregateID` is the session id).
BridgeEvent opencode(String type, {String? session = 'ses_1'}) => BridgeEvent(
  id: 'evt_1',
  created: 0,
  type: type,
  data: const {},
  durable: session == null ? null : Durable(aggregateID: session, seq: 1),
);

/// Build a bridge-native event (no durable seq; the session id in `data`).
BridgeEvent bridge(
  String type, {
  String? session = 'ses_1',
  Map<String, Object?>? data,
}) => BridgeEvent(
  id: 'evt_1',
  created: 0,
  type: type,
  data: {...?data, 'sessionID': ?session},
);

/// Build a `form.created` event: its payload nests the session under
/// `data.form`.
BridgeEvent formCreated({String? session = 'ses_1'}) => BridgeEvent(
  id: 'evt_1',
  created: 0,
  type: 'form.created',
  data: {
    'form': {'sessionID': session, 'type': 'question'},
  },
);

/// Build a `permission.asked` event: no durable seq, the session in
/// `data.sessionID` (the wire's real shape for it).
BridgeEvent permissionAsked({String? session = 'ses_1'}) => BridgeEvent(
  id: 'evt_1',
  created: 0,
  type: 'permission.asked',
  data: {'sessionID': ?session, 'action': 'shell'},
);

void main() {
  late SessionSoundMapper mapper;

  setUp(() {
    mapper = SessionSoundMapper();
  });

  group('the trigger set', () {
    test('a finished turn plays the success chime', () {
      expect(
        mapper.soundFor(opencode('session.execution.succeeded')),
        SessionSound.success,
      );
    });

    test('a failed turn plays the error tone', () {
      expect(
        mapper.soundFor(opencode('session.execution.failed')),
        SessionSound.error,
      );
    });

    test('an interrupted turn plays the stopped tone', () {
      expect(
        mapper.soundFor(opencode('session.execution.interrupted')),
        SessionSound.stopped,
      );
    });

    test('a turn cancelled from a panel plays the stopped tone', () {
      expect(
        mapper.soundFor(bridge('session.turn.cancelled')),
        SessionSound.stopped,
      );
    });

    test('a permission request plays the attention tone', () {
      expect(mapper.soundFor(permissionAsked()), SessionSound.attention);
    });

    test('a new question plays the attention tone', () {
      expect(mapper.soundFor(formCreated()), SessionSound.attention);
    });

    test('the error tone is distinct from the success tone', () {
      final success = mapper.soundFor(opencode('session.execution.succeeded'));
      final error = mapper.soundFor(opencode('session.execution.failed'));
      expect(success, SessionSound.success);
      expect(error, SessionSound.error);
      expect(success, isNot(error));
      expect(success?.assetPath, isNot(error?.assetPath));
    });
  });

  group('the cancelled-turn rule (issue #164)', () {
    test(
      'a panel cancel and its follow-on terminal sound the stopped tone once',
      () {
        mapper.soundFor(bridge('session.turn.cancelled'));
        expect(
          mapper.soundFor(opencode('session.execution.interrupted')),
          isNull,
        );
      },
    );

    test('a user interrupt (no cancel) still sounds the stopped tone', () {
      expect(
        mapper.soundFor(opencode('session.execution.interrupted')),
        SessionSound.stopped,
      );
    });

    test('the suppression is per-session: another session\'s cancel does not '
        'suppress it', () {
      mapper.soundFor(bridge('session.turn.cancelled', session: 'ses_1'));
      expect(
        mapper.soundFor(
          opencode('session.execution.interrupted', session: 'ses_2'),
        ),
        SessionSound.stopped,
      );
    });

    test(
      'a stale cancel marker is cleared by the next turn start (the follow-on '
      'terminal missed across a restart does not suppress the next turn)',
      () {
        mapper.soundFor(bridge('session.turn.cancelled'));
        expect(mapper.soundFor(opencode('session.execution.started')), isNull);
        expect(
          mapper.soundFor(opencode('session.execution.interrupted')),
          SessionSound.stopped,
        );
      },
    );

    test('only the follow-on terminal is suppressed: the cancel\'s other '
        'outcomes still sound', () {
      mapper.soundFor(bridge('session.turn.cancelled'));
      // The service settles the turn as a success (not an interrupt): that
      // is a different outcome, and it sounds.
      expect(
        mapper.soundFor(opencode('session.execution.succeeded')),
        SessionSound.success,
      );
    });
  });

  group('resolutions and non-triggers are silent', () {
    test('the resolutions do not sound', () {
      expect(
        mapper.soundFor(
          BridgeEvent(
            id: 'e',
            created: 0,
            type: 'permission.replied',
            data: {'sessionID': 'ses_1', 'reply': 'allow'},
          ),
        ),
        isNull,
      );
      expect(
        mapper.soundFor(
          BridgeEvent(
            id: 'e',
            created: 0,
            type: 'form.replied',
            data: {
              'form': {'sessionID': 'ses_1'},
            },
          ),
        ),
        isNull,
      );
      expect(
        mapper.soundFor(
          BridgeEvent(
            id: 'e',
            created: 0,
            type: 'form.cancelled',
            data: {
              'form': {'sessionID': 'ses_1'},
            },
          ),
        ),
        isNull,
      );
    });

    test('every other event on the stream does not sound', () {
      for (final type in [
        'session.created',
        'session.renamed',
        'session.updated',
        'session.deleted',
        'session.closed',
        'session.execution.started',
        'message.part.updated',
        'message.updated',
        'docker.container.stopped',
        'docker.container.crashed',
      ]) {
        expect(
          mapper.soundFor(opencode(type)),
          isNull,
          reason: '$type must not sound',
        );
      }
    });

    test('a trigger without a session does not sound', () {
      expect(
        mapper.soundFor(opencode('session.execution.succeeded', session: null)),
        isNull,
      );
      expect(
        mapper.soundFor(opencode('session.execution.failed', session: null)),
        isNull,
      );
      expect(
        mapper.soundFor(
          opencode('session.execution.interrupted', session: null),
        ),
        isNull,
      );
      expect(
        mapper.soundFor(bridge('session.turn.cancelled', session: null)),
        isNull,
      );
      expect(mapper.soundFor(permissionAsked(session: null)), isNull);
      expect(mapper.soundFor(formCreated(session: null)), isNull);
    });
  });
}
