import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opencodebridge/client/docker_client.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/compose_project.dart';
import 'package:opencodebridge/model/container.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/project.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/notify/deep_link.dart';
import 'package:opencodebridge/ui/deep_link_target.dart';
import 'package:opencodebridge/ui/docker_tab.dart';
import 'package:opencodebridge/ui/sessions_tab.dart';

/// The scripted bridge API for the cold-start tests (issue #24).
final _bridge = Uri.parse('http://bridge.test/');

class _FakeSessionsClient extends SessionsClient {
  _FakeSessionsClient() : super(_bridge);

  @override
  Future<List<Session>> list() async => const [
    Session(
      id: 'ses_1',
      title: 'fix the flaky test',
      project: SessionProject(id: 'p1', name: 'app'),
      created: 100,
      location: '/code/app',
      active: false,
    ),
  ];

  @override
  Future<List<Project>> projects() async => const [];

  @override
  Future<SessionDetail> getDetail(String id) async => SessionDetail(
    id: id,
    title: 'fix the flaky test',
    location: '/code/app',
    cost: 0,
    tokens: const TokenUsage(
      input: 1,
      output: 2,
      reasoning: 0,
      cacheRead: 0,
      cacheWrite: 0,
    ),
    outcome: null,
  );

  @override
  Future<List<SessionMessage>> getMessages(String id) async => const [
    SessionMessage(id: 'm1', role: 'user', text: 'hello'),
  ];

  @override
  Future<List<PermissionRequest>> getPermissions(String id) async => const [];

  @override
  Future<List<QuestionForm>> getQuestions(String id) async => const [];

  @override
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) async {}

  @override
  Future<void> dismissQuestion(String id, String formID) async {}
}

class _FakeDockerClient extends DockerClient {
  _FakeDockerClient() : super(_bridge);

  @override
  Future<List<DockerContainer>> list() async => const [
    DockerContainer(
      name: 'probe',
      image: 'alpine',
      state: DockerState.exited,
      uptime: null,
    ),
  ];

  @override
  Future<List<ComposeProject>> compose() async => const [];
}

class _FakeEventsSource implements EventSource {
  final _controller = StreamController<BridgeEvent>.broadcast();
  final _gaps = StreamController<SessionGap>.broadcast();

  @override
  Stream<BridgeEvent> get events => _controller.stream;

  @override
  Stream<SessionGap> get gaps => _gaps.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> reconnect() async {}
}

/// The shell's deep-link wiring (the app's one, issue #287): the app holds
/// a [DeepLinkTarget] (the stable owner) and feeds it from the service's
/// stream (`deepLinks.listen(target.apply)`); the shell listens to the
/// model to switch the tab, and each tab reads its target from the model
/// and clears it through [DeepLinkTarget.consume] when it opens it.
class _Shell extends StatefulWidget {
  const _Shell({required this.links});

  final Stream<DeepLink> links;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _tab = 0;

  final _FakeSessionsClient _sessions = _FakeSessionsClient();

  final _FakeDockerClient _docker = _FakeDockerClient();

  final _FakeEventsSource _sessionEvents = _FakeEventsSource();

  final _FakeEventsSource _dockerEvents = _FakeEventsSource();

  /// The stable owner (the app's [DeepLinkTarget], issue #287): held by
  /// this state across the test, fed from the raw stream, read by the tabs.
  late final DeepLinkTarget _target = DeepLinkTarget();

  StreamSubscription<DeepLink>? _links;

  @override
  void initState() {
    super.initState();
    // The app's wiring: the service's stream feeds the model.
    _links = widget.links.listen(_target.apply);
    // The shell's wiring: listen to the model to switch the tab.
    _target.addListener(_onDeepLinkTarget);
  }

  void _onDeepLinkTarget() {
    final target = _target.target;
    if (target == null) return;
    setState(() => _tab = target.isSession ? 0 : 1);
  }

  @override
  void dispose() {
    _target.removeListener(_onDeepLinkTarget);
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _tab,
      children: [
        SessionsTab(
          apiBase: _bridge,
          client: _sessions,
          events: _sessionEvents,
          deepLinks: _target,
        ),
        DockerTab(
          apiBase: _bridge,
          client: _docker,
          events: _dockerEvents,
          deepLinks: _target,
        ),
      ],
    ),
  );
}

/// The cold-start tap (issue #24): the tapped notification is delivered to
/// the deep-link stream before the UI subscribes (it is buffered until the
/// shell attaches its listener). These tests mirror the shell's deep-link
/// wiring with scripted clients and check that the back arrow of the opened
/// view returns to the list underneath.
void main() {
  testWidgets(
    'a session link opened from cold: opens the session in the detail pane '
    'while the list stays visible (issue #131)',
    (tester) async {
      final links = StreamController<DeepLink>();
      await tester.pumpWidget(MaterialApp(home: _Shell(links: links.stream)));
      links.add(DeepLink.session('ses_1'));
      await tester.pumpAndSettle();

      // The targeted session opens in the detail pane (no navigator push):
      // the list stays visible, and there is no back navigation to the list.
      expect(find.byKey(const ValueKey('sessions-list')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sessions-detail-panel')),
        findsOneWidget,
      );
      expect(find.text('fix the flaky test'), findsWidgets);
      expect(find.text('1 session'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing);
    },
  );

  testWidgets('a container link opened from cold: back returns to the list', (
    tester,
  ) async {
    final links = StreamController<DeepLink>();
    await tester.pumpWidget(MaterialApp(home: _Shell(links: links.stream)));
    links.add(DeepLink.container('probe'));
    await tester.pumpAndSettle();

    // The container detail is up, on top of the list.
    expect(find.text('probe'), findsWidgets);

    // The back arrow returns to the list underneath.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('alpine'), findsOneWidget);
  });
}
