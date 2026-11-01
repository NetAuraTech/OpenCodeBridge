import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/docker_client.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/compose_project.dart';
import 'package:opencodebridge/model/container.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/project.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/notify/deep_link.dart';
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
      classification: SessionClassification.external,
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

/// The shell's deep-link wiring (the [HomeShell] one, issue #24): the tabs
/// mount with their targets at `null`, the tapped notification's link
/// arrives as an update (buffered until the shell subscribes), and the
/// shell hands each tab its target, which the tab consumes.
class _Shell extends StatefulWidget {
  const _Shell({required this.links});

  final Stream<DeepLink> links;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _tab = 0;

  String? _sessionTarget;
  String? _containerTarget;
  StreamSubscription<DeepLink>? _links;

  final _FakeSessionsClient _sessions = _FakeSessionsClient();

  final _FakeDockerClient _docker = _FakeDockerClient();

  final _FakeEventsSource _sessionEvents = _FakeEventsSource();

  final _FakeEventsSource _dockerEvents = _FakeEventsSource();

  @override
  void initState() {
    super.initState();
    _links = widget.links.listen(_onDeepLink);
  }

  void _onDeepLink(DeepLink link) {
    setState(() {
      if (link.isSession) {
        _containerTarget = null;
        _sessionTarget = link.id;
        _tab = 0;
      } else {
        _sessionTarget = null;
        _containerTarget = link.id;
        _tab = 1;
      }
    });
  }

  @override
  void dispose() {
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
          deepLinkSession: _sessionTarget,
          onDeepLinkSessionConsumed: () {
            _sessionTarget = null;
          },
        ),
        DockerTab(
          apiBase: _bridge,
          client: _docker,
          events: _dockerEvents,
          deepLinkContainer: _containerTarget,
          onDeepLinkContainerConsumed: () {
            _containerTarget = null;
          },
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
  testWidgets('a session link opened from cold: back returns to the list', (
    tester,
  ) async {
    final links = StreamController<DeepLink>();
    await tester.pumpWidget(MaterialApp(home: _Shell(links: links.stream)));
    links.add(DeepLink.session('ses_1'));
    await tester.pumpAndSettle();

    // The structured view of the targeted session is up, on top of the
    // list.
    expect(find.text('fix the flaky test'), findsWidgets);

    // The back arrow returns to the list underneath.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('1 session'), findsOneWidget);
    expect(find.text('fix the flaky test'), findsOneWidget);
  });

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
