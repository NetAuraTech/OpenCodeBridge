import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';

/// The shared cancel contract (issue #160): every [OpencodeService] answers
/// the interrupt request — an implementation whose service has the interrupt
/// path really cancels; one whose service has no interrupt route refuses
/// with the typed [CancelUnsupportedError] (never a bare `UnimplementedError`
/// the bridge could not map), and that refusal is remembered only until the
/// next cancel re-probes it (a service restart may have upgraded the route).
///
/// Both the HTTP transport (through a fake service that serves, or withholds,
/// `/interrupt`) and the composite (routing to such a service) run this same
/// contract, so the transport's cancel and the composite's delegation are
/// covered by one shared suite rather than hand-written cases.
///
/// [label] is the full, human-readable group title for the suite it runs in
/// (the transport or composite under test, e.g. `OpencodeHttpService cancel
/// (issue #160)`).
///
/// [reset] runs before every contract test (fresh call records, route
/// installed). [setInterruptRoute] makes the backing service serve (`true`)
/// or withhold (`false`) its interrupt route, and [service] builds the
/// [OpencodeService] under test — the same instance the test continues to
/// use, so a remembered probe answer carries across its calls.
void runCancelContract(
  String label, {
  required void Function() reset,
  required void Function(bool interruptRouteAvailable) setInterruptRoute,
  required OpencodeService Function() service,
}) {
  group(label, () {
    setUp(reset);

    test('cancels a turn through the interrupt route', () async {
      setInterruptRoute(true);
      await service().cancelTurn('ses_1'); // no throw on the served route
    });

    test('a service without the interrupt route refuses with '
        'CancelUnsupportedError', () async {
      setInterruptRoute(false);
      await expectLater(
        service().cancelTurn('ses_1'),
        throwsA(isA<CancelUnsupportedError>()),
      );
    });

    test('an unsupported service is re-probed: the same client cancels once '
        'the route exists', () async {
      setInterruptRoute(false);
      final svc = service();
      await expectLater(
        svc.cancelTurn('ses_1'),
        throwsA(isA<CancelUnsupportedError>()),
      );
      // The service restarts upgraded, now serving the interrupt route.
      setInterruptRoute(true);
      await svc.cancelTurn('ses_1'); // the remembered no is not final
    });

    test('a supported service keeps answering: repeated cancels through the '
        'remembered route', () async {
      setInterruptRoute(true);
      final svc = service();
      await svc.cancelTurn('ses_1');
      await svc.cancelTurn('ses_1'); // the remembered yes skips re-probing
    });
  });
}
