import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/compose_project.dart';
import 'package:opencodebridge/model/container.dart';

void main() {
  group('ComposeAction.fromWire', () {
    test('parses the two actions', () {
      expect(ComposeAction.fromWire('up'), ComposeAction.up);
      expect(ComposeAction.fromWire('stop'), ComposeAction.stop);
    });

    test('an unknown value is a client error', () {
      expect(() => ComposeAction.fromWire('restart'), throwsArgumentError);
      expect(() => ComposeAction.fromWire(null), throwsArgumentError);
      expect(() => ComposeAction.fromWire('Up'), throwsArgumentError);
    });

    test('the wire values match the contract', () {
      expect(ComposeAction.up.wire, 'up');
      expect(ComposeAction.stop.wire, 'stop');
    });
  });

  group('ComposeService', () {
    test('a service that has never been created carries no live state', () {
      const service = ComposeService(name: 'web', state: null);
      expect(service.isCreated, isFalse);
      expect(service.isRunning, isFalse);
      expect(service.image, isNull);
      expect(service.container, isNull);
    });

    test('a created service carries its docker state', () {
      const service = ComposeService(
        name: 'db',
        state: DockerState.exited,
        image: 'postgres:16',
        container: 'proj-db-1',
      );
      expect(service.isCreated, isTrue);
      expect(service.isRunning, isFalse);
    });

    test('toJson / fromJson round-trip', () {
      const service = ComposeService(
        name: 'db',
        state: DockerState.running,
        image: 'postgres:16',
        container: 'proj-db-1',
      );
      final decoded = ComposeService.fromJson(service.toJson());
      expect(decoded, service);

      final never = ComposeService.fromJson({'name': 'web', 'state': null});
      expect(never.name, 'web');
      expect(never.state, isNull);
      expect(never.image, isNull);
      expect(never.container, isNull);
    });
  });

  group('ComposeProject', () {
    test('anyRunning / anyNotRunning reflect the services', () {
      final project = ComposeProject(
        id: 'x',
        project: 'proj',
        path: '/repo',
        composeFile: '/repo/docker-compose.yml',
        services: [
          ComposeService(name: 'web', state: DockerState.running),
          ComposeService(name: 'db', state: null),
        ],
      );
      expect(project.anyRunning, isTrue);
      expect(project.anyNotRunning, isTrue);
    });

    test('toJson / fromJson round-trip', () {
      final project = ComposeProject(
        id: '%2Frepo',
        project: 'proj',
        path: '/repo',
        composeFile: '/repo/docker-compose.yml',
        services: [
          ComposeService(name: 'web', state: DockerState.running),
          ComposeService(name: 'db', state: null),
        ],
      );
      final decoded = ComposeProject.fromJson(project.toJson());
      expect(decoded, project);
    });

    test('the id is the URL-encoded directory, and decodes back', () {
      const path = '/home/aymeric/repo';
      expect(ComposeProject.encodeId(path), Uri.encodeComponent(path));
      expect(ComposeProject.decodeId(ComposeProject.encodeId(path)), path);
    });
  });
}
