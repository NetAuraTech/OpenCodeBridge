import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/notify/firebase_project.dart';

Map<String, Object?> _validProject() => {
  'project_info': {
    'project_number': '123456789012',
    'project_id': 'opencodebridge-test',
    'storage_bucket': 'opencodebridge-test.appspot.com',
  },
  'client': [
    {
      'client_info': {
        'mobilesdk_app_id': '1:123456789012:android:abcdef',
        'android_client_info': {'package_name': 'com.example.app'},
      },
      'oauth_client': [
        {
          'client_id': '123456789012-xyz.apps.googleusercontent.com',
          'client_type': 3,
        },
      ],
      'api_key': [
        {'current_key': 'AIzaSyA-test-key'},
      ],
    },
  ],
};

String _raw([void Function(Map<String, Object?>)? mutate]) {
  final map = jsonDecode(jsonEncode(_validProject())) as Map<String, Object?>;
  mutate?.call(map);
  return jsonEncode(map);
}

void main() {
  group('FirebaseProject.parse', () {
    test('parses the Console export into the Firebase options', () {
      final project = FirebaseProject.parse(_raw());
      expect(project, isNotNull);
      expect(project!.options.projectId, 'opencodebridge-test');
      expect(project.options.messagingSenderId, '123456789012');
      expect(project.options.apiKey, 'AIzaSyA-test-key');
      expect(project.options.appId, '1:123456789012:android:abcdef');
      expect(
        project.options.androidClientId,
        '123456789012-xyz.apps.googleusercontent.com',
      );
    });

    test('a numeric project_number is normalized to a string', () {
      final project = FirebaseProject.parse(
        _raw((map) {
          (map['project_info'] as Map<String, Object?>)['project_number'] =
              123456789012;
        }),
      );
      expect(project!.options.messagingSenderId, '123456789012');
    });

    test('a missing project field is not a project', () {
      for (final key in ['project_id', 'project_number']) {
        final project = FirebaseProject.parse(
          _raw((map) {
            (map['project_info'] as Map<String, Object?>).remove(key);
          }),
        );
        expect(project, isNull, reason: key);
      }
    });

    test('an export without an Android client is not one', () {
      final project = FirebaseProject.parse(
        _raw((map) {
          map['client'] = [
            {
              'client_info': {
                'mobilesdk_app_id': '1:123456789012:ios:abcdef',
                'ios_client_info': {'bundle_id': 'com.example.app'},
              },
            },
          ];
        }),
      );
      expect(project, isNull);
    });

    test('a client without an api key or an app id is not one', () {
      final noKey = FirebaseProject.parse(
        _raw((map) {
          final client = (map['client'] as List)[0] as Map<String, Object?>;
          client.remove('api_key');
        }),
      );
      expect(noKey, isNull);

      final noAppId = FirebaseProject.parse(
        _raw((map) {
          final client = (map['client'] as List)[0] as Map<String, Object?>;
          (client['client_info'] as Map<String, Object?>).remove(
            'mobilesdk_app_id',
          );
        }),
      );
      expect(noAppId, isNull);
    });

    test('the android oauth client is optional', () {
      final project = FirebaseProject.parse(
        _raw((map) {
          final client = (map['client'] as List)[0] as Map<String, Object?>;
          client.remove('oauth_client');
        }),
      );
      expect(project, isNotNull);
      expect(project!.options.androidClientId, isNull);
    });

    test('anything that is not a google-services.json is null', () {
      expect(FirebaseProject.parse(''), isNull);
      expect(FirebaseProject.parse('not json'), isNull);
      expect(FirebaseProject.parse('[1, 2]'), isNull);
      expect(FirebaseProject.parse('{"project_info": {}}'), isNull);
    });
  });
}
