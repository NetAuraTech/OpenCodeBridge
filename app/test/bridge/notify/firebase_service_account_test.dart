import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/notify/firebase_service_account.dart';

String _raw([void Function(Map<String, Object?>)? mutate]) {
  final map = jsonDecode(jsonEncode({
    'type': 'service_account',
    'project_id': 'opencodebridge-test',
    'private_key_id': 'key-1',
    'private_key': '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n',
    'client_email': 'svc@opencodebridge-test.iam.gserviceaccount.com',
    'client_id': '123',
    'token_uri': 'https://oauth2.googleapis.com/token',
  })) as Map<String, Object?>;
  mutate?.call(map);
  return jsonEncode(map);
}

void main() {
  group('FirebaseServiceAccount.fromJsonString', () {
    test('parses the Console download and keeps the raw JSON', () {
      final raw = _raw();
      final account = FirebaseServiceAccount.fromJsonString(raw);
      expect(account, isNotNull);
      expect(account!.projectId, 'opencodebridge-test');
      expect(
        account.email,
        'svc@opencodebridge-test.iam.gserviceaccount.com',
      );
      expect(
        account.privateKey,
        '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n',
      );
      expect(
        account.rawJson,
        raw,
        reason: 'the raw JSON is the fallback sender\'s input',
      );
    });

    test('a missing required field is not a service account', () {
      for (final key in ['project_id', 'client_email', 'private_key']) {
        final account = FirebaseServiceAccount.fromJsonString(_raw((map) {
          map.remove(key);
        }));
        expect(account, isNull, reason: key);
      }
    });

    test('a malformed JSON is not a service account', () {
      expect(FirebaseServiceAccount.fromJsonString('not json'), isNull);
      expect(FirebaseServiceAccount.fromJsonString('[1]'), isNull);
    });
  });

  group('FirebaseServiceAccount.resolvePath', () {
    test('the explicit path wins, then the environment, then the default',
        () {
      expect(
        FirebaseServiceAccount.resolvePath(
          explicitPath: '/explicit.json',
          environment: {FirebaseServiceAccount.envVar: '/env.json'},
        ),
        '/explicit.json',
      );
      expect(
        FirebaseServiceAccount.resolvePath(
          environment: {FirebaseServiceAccount.envVar: '/env.json'},
        ),
        '/env.json',
      );
      expect(
        FirebaseServiceAccount.resolvePath(environment: const {}),
        FirebaseServiceAccount.defaultPath(),
      );
    });
  });

  group('FirebaseServiceAccount.install', () {
    test('writes the file owner-only, and it reads back', () async {
      final dir = await Directory.systemTemp.createTemp(
        'opencodebridge-sa-install',
      );
      try {
        final file = File('${dir.path}/nested/service-account.json');
        final account = FirebaseServiceAccount.install(_raw(), path: file.path);
        expect(file.existsSync(), isTrue);
        expect(file.readAsStringSync(), '${_raw().trim()}\n');
        // The private key is not world-readable (0600 octal = 384 decimal;
        // Dart has no octal literals).
        expect(file.statSync().mode & 0xFFF, 384);

        final reloaded = FirebaseServiceAccount.tryLoad(path: file.path);
        expect(reloaded, isNotNull);
        expect(reloaded!.projectId, account.projectId);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('a non-service-account JSON is an ArgumentError and writes nothing',
        () async {
      final dir = await Directory.systemTemp.createTemp(
        'opencodebridge-sa-install',
      );
      try {
        final file = File('${dir.path}/service-account.json');
        expect(
          () => FirebaseServiceAccount.install('not json', path: file.path),
          throwsArgumentError,
        );
        expect(
          () => FirebaseServiceAccount.install(
            _raw((map) => map.remove('private_key')),
            path: file.path,
          ),
          throwsArgumentError,
        );
        expect(file.existsSync(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('FirebaseServiceAccount.tryLoad', () {
    test('loads a valid file and degrades to null', () async {
      final dir = await Directory.systemTemp.createTemp(
        'opencodebridge-sa',
      );
      try {
        final file = File('${dir.path}/service-account.json');
        expect(FirebaseServiceAccount.tryLoad(path: file.path), isNull);

        file.writeAsStringSync(_raw());
        expect(FirebaseServiceAccount.tryLoad(path: file.path), isNotNull);

        file.writeAsStringSync('not json');
        expect(FirebaseServiceAccount.tryLoad(path: file.path), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
