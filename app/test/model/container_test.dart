import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/container.dart';

void main() {
  group('DockerState.fromWire', () {
    test('parses every wire value', () {
      expect(DockerState.fromWire('created'), DockerState.created);
      expect(DockerState.fromWire('running'), DockerState.running);
      expect(DockerState.fromWire('paused'), DockerState.paused);
      expect(DockerState.fromWire('restarting'), DockerState.restarting);
      expect(DockerState.fromWire('exited'), DockerState.exited);
      expect(DockerState.fromWire('removing'), DockerState.removing);
      expect(DockerState.fromWire('dead'), DockerState.dead);
    });

    test('unknown and missing values fall back to created', () {
      expect(DockerState.fromWire('weird'), DockerState.created);
      expect(DockerState.fromWire(null), DockerState.created);
      expect(DockerState.fromWire(42), DockerState.created);
    });
  });

  group('DockerAction.fromWire', () {
    test('parses the three actions', () {
      expect(DockerAction.fromWire('start'), DockerAction.start);
      expect(DockerAction.fromWire('stop'), DockerAction.stop);
      expect(DockerAction.fromWire('restart'), DockerAction.restart);
    });

    test('an unknown value is a client error', () {
      expect(() => DockerAction.fromWire('explode'), throwsArgumentError);
      expect(() => DockerAction.fromWire(null), throwsArgumentError);
      expect(() => DockerAction.fromWire('Start'), throwsArgumentError);
    });

    test('the wire values match the contract', () {
      expect(DockerAction.start.wire, 'start');
      expect(DockerAction.stop.wire, 'stop');
      expect(DockerAction.restart.wire, 'restart');
    });
  });

  group('DockerContainer', () {
    test('fromJson reads the contract row', () {
      final row = DockerContainer.fromJson({
        'name': 'web',
        'image': 'nginx:latest',
        'state': 'running',
        'uptime': '2 hours ago',
      });
      expect(
        row,
        const DockerContainer(
          name: 'web',
          image: 'nginx:latest',
          state: DockerState.running,
          uptime: '2 hours ago',
        ),
      );
    });

    test('fromJson is tolerant of missing fields', () {
      final row = DockerContainer.fromJson({'name': 'db'});
      expect(row.name, 'db');
      expect(row.image, '');
      expect(row.state, DockerState.created);
      expect(row.uptime, isNull);
    });

    test('fromJson treats a blank uptime as not running', () {
      final row = DockerContainer.fromJson({'name': 'db', 'uptime': ''});
      expect(row.uptime, isNull);
    });

    test('toJson round-trips through fromJson', () {
      const row = DockerContainer(
        name: 'web',
        image: 'nginx:latest',
        state: DockerState.running,
        uptime: '2 hours ago',
      );
      expect(DockerContainer.fromJson(row.toJson()), row);
    });

    test('== and hashCode compare the fields', () {
      const a = DockerContainer(
        name: 'web',
        image: 'nginx:latest',
        state: DockerState.running,
        uptime: null,
      );
      const b = DockerContainer(
        name: 'web',
        image: 'nginx:latest',
        state: DockerState.running,
        uptime: null,
      );
      const c = DockerContainer(
        name: 'db',
        image: 'postgres:16',
        state: DockerState.exited,
        uptime: null,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('toString carries the fields', () {
      const row = DockerContainer(
        name: 'web',
        image: 'nginx:latest',
        state: DockerState.running,
        uptime: null,
      );
      expect(
        row.toString(),
        'DockerContainer(name: web, image: nginx:latest, state: running, '
        'uptime: null)',
      );
    });
  });
}
