import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/ui/permission_banner.dart';

const _one = PermissionRequest(
  id: 'per_1',
  action: 'shell',
  resources: ['ls -la'],
);
const _two = PermissionRequest(
  id: 'per_2',
  action: 'edit',
  resources: ['lib/main.dart'],
);

Future<void> _pumpBanner(
  WidgetTester tester, {
  List<PermissionRequest> pending = const [],
  List<(PermissionRequest, PermissionReply)> replies = const [],
  String? replyBusyId,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PermissionBanner(
          pending: pending,
          onReply: (request, reply) async {
            replies.add((request, reply));
          },
          replyBusyId: replyBusyId,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('PermissionBanner', () {
    testWidgets('renders nothing when no request is pending', (tester) async {
      await _pumpBanner(tester);

      expect(find.byType(PermissionBanner), findsOneWidget);
      expect(find.textContaining('Permission requested'), findsNothing);
    });

    testWidgets('renders one row per pending request with action and target',
        (tester) async {
      await _pumpBanner(tester, pending: const [_one, _two]);

      expect(find.text('Permission requested: shell'), findsOneWidget);
      expect(find.text('ls -la'), findsOneWidget);
      expect(find.text('Permission requested: edit'), findsOneWidget);
      expect(find.text('lib/main.dart'), findsOneWidget);
    });

    testWidgets('Once / Always / Reject apply their decision to the request',
        (tester) async {
      final replies = <(PermissionRequest, PermissionReply)>[];
      await _pumpBanner(tester, pending: const [_one], replies: replies);

      await tester.tap(find.byKey(const ValueKey('permission-once-per_1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('permission-always-per_1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('permission-reject-per_1')));
      await tester.pump();

      expect(
        replies,
        const [
          (_one, PermissionReply.once),
          (_one, PermissionReply.always),
          (_one, PermissionReply.reject),
        ],
      );
    });

    testWidgets('the request with the in-flight reply shows progress', (
      tester,
    ) async {
      await _pumpBanner(
        tester,
        pending: const [_one],
        replyBusyId: 'per_1',
      );

      expect(find.byKey(const ValueKey('permission-once-per_1')), findsNothing);
      expect(find.byKey(const ValueKey('permission-always-per_1')), findsNothing);
      expect(find.byKey(const ValueKey('permission-reject-per_1')), findsNothing);
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
      );
    });
  });
}
