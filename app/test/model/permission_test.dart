import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/permission.dart';

void main() {
  group('PermissionReply wire mapping', () {
    test('each value maps to its wire string', () {
      expect(PermissionReply.once.wire, 'once');
      expect(PermissionReply.always.wire, 'always');
      expect(PermissionReply.reject.wire, 'reject');
    });

    test('fromWire round-trips all values', () {
      for (final value in PermissionReply.values) {
        expect(PermissionReply.fromWire(value.wire), value);
      }
    });

    test('fromWire throws on unknown values', () {
      expect(() => PermissionReply.fromWire('maybe'), throwsArgumentError);
      expect(() => PermissionReply.fromWire(''), throwsArgumentError);
    });
  });

  group('PermissionRequest round-trip', () {
    test('serializes and deserializes', () {
      const req = PermissionRequest(
        id: 'perm_1',
        action: 'bash',
        resources: ['rm -rf /'],
      );
      final json = req.toJson();
      expect(json, {
        'id': 'perm_1',
        'action': 'bash',
        'resources': ['rm -rf /'],
      });
      final back = PermissionRequest.fromJson(json);
      expect(back.id, 'perm_1');
      expect(back.action, 'bash');
      expect(back.resources, ['rm -rf /']);
    });

    test('resources are optional and default to empty', () {
      const json = {'id': 'perm_2', 'action': 'edit'};
      final req = PermissionRequest.fromJson(json);
      expect(req.resources, isEmpty);
    });
  });
}
