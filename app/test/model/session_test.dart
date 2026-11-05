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
      );
      expect(session.toJson(), {
        'id': 'ses_1',
        'title': 'Implement PR #15',
        'project': {'id': 'proj_1', 'name': 'opencodebridge'},
        'created': 1793233781396,
        'location': '/run/media/x/opencodebridge',
        'active': true,
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
      );
      expect(Session.fromJson(session.toJson()), session);
    });

    test('toJson omits the optional orb field for a host session', () {
      const session = Session(
        id: 'ses_1',
        title: 't',
        project: SessionProject(id: 'p', name: 'n'),
        created: 42,
        location: '/x',
        active: false,
      );
      expect(session.toJson().containsKey('orb'), isFalse);
    });

    test('an orb session round-trips its orb id', () {
      const session = Session(
        id: 'ses_2',
        title: 't',
        project: SessionProject(id: 'p', name: 'n'),
        created: 42,
        location: '/x',
        active: false,
        orb: 'orb_1',
      );
      expect(session.toJson()['orb'], 'orb_1');
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
        ),
      );
      // A row carrying the orb id parses it; one without it stays null.
      expect(Session.fromJson({'id': 'ses_3', 'orb': 'orb_9'}).orb, 'orb_9');
    });
  });
}
