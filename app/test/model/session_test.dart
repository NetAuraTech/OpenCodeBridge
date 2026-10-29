import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/session.dart';

void main() {
  group('Session', () {
    test('toJson carries the full bridge contract row', () {
      const session = Session(
        id: 'ses_1',
        title: 'Implement PR #15',
        project: SessionProject(id: 'proj_1', name: 'opencodebridge'),
        created: 1793233781396,
        location: '/run/media/x/opencodebridge',
        active: true,
        classification: SessionClassification.appLaunchedLive,
      );
      expect(session.toJson(), {
        'id': 'ses_1',
        'title': 'Implement PR #15',
        'project': {'id': 'proj_1', 'name': 'opencodebridge'},
        'created': 1793233781396,
        'location': '/run/media/x/opencodebridge',
        'active': true,
        'classification': 'app-launched-live',
      });
    });

    test('fromJson round-trips a row', () {
      const session = Session(
        id: 'ses_1',
        title: 't',
        project: SessionProject(id: 'p', name: 'n'),
        created: 42,
        location: '/x',
        active: false,
        classification: SessionClassification.external,
      );
      expect(Session.fromJson(session.toJson()), session);
    });

    test('fromJson is tolerant of a missing or partial row', () {
      expect(
        Session.fromJson(null),
        const Session(
          id: '',
          title: '',
          project: SessionProject(id: '', name: ''),
          created: 0,
          location: '',
          active: false,
          classification: SessionClassification.external,
        ),
      );
      expect(
        Session.fromJson({'id': 'ses_2', 'created': 7}),
        const Session(
          id: 'ses_2',
          title: '',
          project: SessionProject(id: '', name: ''),
          created: 7,
          location: '',
          active: false,
          classification: SessionClassification.external,
        ),
      );
    });
  });

  group('SessionClassification', () {
    test('wire values match the bridge contract', () {
      expect(SessionClassification.external.wire, 'external');
      expect(SessionClassification.appLaunchedLive.wire, 'app-launched-live');
      expect(
        SessionClassification.appLaunchedClosed.wire,
        'app-launched-closed',
      );
    });

    test('fromWire maps known values and defaults unknown to external', () {
      expect(
        SessionClassification.fromWire('external'),
        SessionClassification.external,
      );
      expect(
        SessionClassification.fromWire('app-launched-live'),
        SessionClassification.appLaunchedLive,
      );
      expect(
        SessionClassification.fromWire('app-launched-closed'),
        SessionClassification.appLaunchedClosed,
      );
      expect(
        SessionClassification.fromWire('bogus'),
        SessionClassification.external,
      );
      expect(
        SessionClassification.fromWire(null),
        SessionClassification.external,
      );
    });
  });
}
