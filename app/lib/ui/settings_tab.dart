import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../app_info.dart';
import '../app_mode.dart';
import '../bridge/notify/firebase_service_account.dart';
import '../client/authenticated_http.dart';
import '../client/tunnel_client.dart';
import '../model/tunnel_report.dart';
import '../notify/firebase_project.dart';
import '../settings/app_settings.dart';
import '../tunnel_url.dart';
import 'tunnel_setup_wizard.dart';

/// The Settings tab (spec: section 13): host connection (client mode: the
/// tunnel URL), the Access login (issue #23), the tunnel status (issue
/// #22), the push setup (issue #24: the Firebase project pasted once, and
/// the three per-event toggles), and the app version.
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.settings,
    required this.mode,
    this.localBridgeUri,
    this.onTunnelUrlCommitted,
    this.tunnelClient,
    this.access,
    this.auth,
    this.onNotifyToggled,
    this.onPushProjectCommitted,
    this.onServiceAccountCommitted,
    this.serviceAccountPath,
  });

  final AppSettings settings;
  final AppMode mode;

  /// Present in server mode: where the embedded bridge listens.
  final Uri? localBridgeUri;

  /// The Cloudflare Access login for the tunnel (issue #23, client mode);
  /// `null` when there is no tunnel URL yet.
  final AccessSession? access;

  /// Called when the user commits the tunnel URL (submit or focus loss), so
  /// the app can re-point its connection at the new bridge.
  final VoidCallback? onTunnelUrlCommitted;

  /// The client for the bridge's tunnel API; the default builds a real
  /// [TunnelClient] at the bridge (tests inject a fake).
  final TunnelClient? tunnelClient;

  /// The Access login's header provider (issue #23, client mode); `null` in
  /// server mode.
  final AuthHeaderProvider? auth;

  /// Called on every push-toggle change (issue #24), so the app can
  /// re-register this device with the toggles as they are now.
  final VoidCallback? onNotifyToggled;

  /// Called when the user saves the Firebase project (issue #24), so the
  /// app can re-initialize the push flow with the pasted project.
  final VoidCallback? onPushProjectCommitted;

  /// Called when the user saves the service account (issue #24, server
  /// mode), so the app can reload the running bridge's push dispatch with
  /// the freshly written file.
  final VoidCallback? onServiceAccountCommitted;

  /// Where the service account file lives ([FirebaseServiceAccount.defaultPath]
  /// by default; tests point it at a temp dir).
  final String? serviceAccountPath;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  late final TextEditingController _urlController = TextEditingController(
    text: widget.settings.tunnelUrl,
  );

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// Where the tunnel section's bridge API lives: loopback in server mode,
  /// the tunnel URL in client mode, or `null` when there is no bridge to
  /// point at.
  Uri? get _tunnelApiBase {
    if (widget.mode == AppMode.server) {
      return widget.localBridgeUri?.replace(path: '/');
    }
    final tunnel = widget.settings.tunnelUrl.trim();
    return tunnel.isEmpty ? null : parseTunnelUrl(tunnel);
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      const _SectionLabel('Host connection'),
      if (widget.mode == AppMode.client)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextField(
            controller: _urlController,
            key: const ValueKey('tunnel-url-field'),
            decoration: const InputDecoration(
              labelText: 'Tunnel URL',
              hintText: 'https://bridge.example.com',
            ),
            onChanged: (value) => widget.settings.tunnelUrl = value.trim(),
            onSubmitted: (_) => widget.onTunnelUrlCommitted?.call(),
            onEditingComplete: () => widget.onTunnelUrlCommitted?.call(),
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Local bridge: ${widget.localBridgeUri}'),
        ),
      const SizedBox(height: 8),
      if (widget.mode == AppMode.client) ...[
        const _SectionLabel('Access login'),
        _AccessSection(session: widget.access),
        const SizedBox(height: 8),
      ],
      const _SectionLabel('Tunnel'),
      _TunnelSection(
        apiBase: _tunnelApiBase,
        client: widget.tunnelClient,
        serverMode: widget.mode == AppMode.server,
        auth: widget.auth,
        access: widget.access,
      ),
      const SizedBox(height: 8),
      const _SectionLabel('Notifications'),
      SwitchListTile(
        key: const ValueKey('notify-permission-asked'),
        title: const Text('Permission requested'),
        value: widget.settings.notifyPermissionAsked,
        onChanged: (value) {
          setState(() => widget.settings.notifyPermissionAsked = value);
          widget.onNotifyToggled?.call();
        },
      ),
      SwitchListTile(
        key: const ValueKey('notify-turn-ended'),
        title: const Text('Turn ended'),
        value: widget.settings.notifyTurnEnded,
        onChanged: (value) {
          setState(() => widget.settings.notifyTurnEnded = value);
          widget.onNotifyToggled?.call();
        },
      ),
      SwitchListTile(
        key: const ValueKey('notify-docker-container'),
        title: const Text('Docker container stopped or crashed'),
        value: widget.settings.notifyDockerContainer,
        onChanged: (value) {
          setState(() => widget.settings.notifyDockerContainer = value);
          widget.onNotifyToggled?.call();
        },
      ),
      if (widget.mode == AppMode.client)
        _FirebaseProjectSection(
          settings: widget.settings,
          onCommitted: widget.onPushProjectCommitted,
        )
      else
        _ServiceAccountSection(
          onCommitted: widget.onServiceAccountCommitted,
          path: widget.serviceAccountPath,
        ),
      const SizedBox(height: 8),
      const _SectionLabel('About'),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text('OpenCodeBridge $kAppVersion'),
      ),
    ],
  );
}

/// The tunnel section (issue #22): the tunnel health from the bridge
/// (child liveness plus registered edge connections), the guided-setup
/// steps that are still missing when the tunnel is down, and the recheck /
/// manual-start actions. The status is fetched when the tab is built and
/// after every action (the bridge has no tunnel events, so this does not
/// poll).
class _TunnelSection extends StatefulWidget {
  const _TunnelSection({
    required this.apiBase,
    this.client,
    required this.serverMode,
    this.auth,
    this.access,
  });

  /// Where the bridge's tunnel API lives; `null` when this client has no
  /// bridge to point at.
  final Uri? apiBase;

  /// The client for the bridge's tunnel API; the default builds a real
  /// [TunnelClient] at [apiBase].
  final TunnelClient? client;

  /// The Access login's header provider (issue #23, client mode).
  final AuthHeaderProvider? auth;

  /// The tunnel's Access login (issue #23, client mode); `null` in server
  /// mode. The status re-fetches when the login completes: the browser
  /// bounce brought the app to the foreground before the token exchange
  /// finished, so the status fetched before the token saw a `401`
  /// (issue #41).
  final AccessSession? access;

  /// Server mode: offers the assisted-setup wizard (issue #34), a
  /// server-mode feature (client mode only connects to the hostname).
  final bool serverMode;

  @override
  State<_TunnelSection> createState() => _TunnelSectionState();
}

class _TunnelSectionState extends State<_TunnelSection> {
  TunnelClient? _client;

  /// The fetched report, `null` until the first successful load.
  TunnelReport? _report;

  /// The last load failure, if any.
  String? _error;

  /// True while the initial load is in flight.
  bool _loading = false;

  /// True while the recheck action is in flight (its button shows
  /// progress).
  bool _checking = false;

  /// True while the manual start is in flight (its button shows progress).
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _init(widget.apiBase);
    widget.access?.addListener(_onAccessState);
  }

  @override
  void didUpdateWidget(covariant _TunnelSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.access != oldWidget.access) {
      oldWidget.access?.removeListener(_onAccessState);
      widget.access?.addListener(_onAccessState);
    }
    if (widget.apiBase != oldWidget.apiBase) _init(widget.apiBase);
  }

  @override
  void dispose() {
    widget.access?.removeListener(_onAccessState);
    super.dispose();
  }

  /// The login finished (issue #41): the status fetched before the token
  /// existed saw a `401`; the token is in hand, so fetch it again.
  void _onAccessState(AccessLoginState state) {
    if (state == AccessLoginState.loggedIn) _load();
  }

  void _init(Uri? base) {
    _client = base == null
        ? null
        : (widget.client ?? TunnelClient(base, auth: widget.auth));
    _report = null;
    _error = null;
    _loading = _client != null;
    _load();
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await client.report();
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } on TunnelClientError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 0
            ? 'Cannot reach the bridge.'
            : 'The bridge could not report the tunnel '
                  '(status ${e.statusCode}).';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the tunnel status.';
        _loading = false;
      });
    }
  }

  /// Runs the recheck (the precondition pass) or the manual start, then
  /// takes the bridge's fresh report; a failed action re-fetches instead.
  Future<void> _act(bool start) async {
    final client = _client;
    if (client == null || _checking || _starting) return;
    if (start) {
      setState(() => _starting = true);
    } else {
      setState(() => _checking = true);
    }
    try {
      final report = start ? await client.start() : await client.check();
      if (!mounted) return;
      setState(() => _report = report);
    } on TunnelClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not ${start ? 'start' : 'recheck'} the tunnel '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not ${start ? 'start' : 'recheck'} the tunnel.');
      await _load();
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
          _starting = false;
        });
      }
    }
  }

  /// Opens the assisted-setup wizard (issue #34, server mode only); on
  /// success takes the bridge's fresh report.
  Future<void> _openSetup() async {
    final client = _client;
    if (client == null) return;
    final report = await TunnelSetupWizardDialog.show(
      context,
      client: client,
      initialHostname: _report?.hostname,
    );
    if (report != null) {
      setState(() => _report = report);
    }
  }

  void _snackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_client == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No bridge configured.'),
      );
    }
    if (_loading && _report == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: Text('Loading the tunnel status…')),
      );
    }
    final report = _report;
    if (report == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_error ?? 'Could not load the tunnel status.'),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('tunnel-retry'),
              onPressed: _load,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (report.status == TunnelStatus.notConfigured) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('This host does not run a tunnel.'),
      );
    }
    final up = report.status == TunnelStatus.up;
    final hostname = report.hostname;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: up ? Colors.green : Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                up ? 'Tunnel up' : 'Tunnel down',
                key: const ValueKey('tunnel-status'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (hostname != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hostname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            up
                ? '${report.registeredConnections} edge connection'
                      '${report.registeredConnections == 1 ? '' : 's'}'
                : report.running
                ? 'cloudflared runs, but holds no edge connections'
                : 'cloudflared does not run',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (report.missing.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (var i = 0; i < report.missing.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '• ${report.missingDetails[i]}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
          if (!up)
            Row(
              children: [
                OutlinedButton(
                  key: const ValueKey('tunnel-check'),
                  onPressed: _checking || _starting ? null : () => _act(false),
                  child: _checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Check now'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const ValueKey('tunnel-start'),
                  onPressed: _checking || _starting ? null : () => _act(true),
                  child: _starting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Start tunnel'),
                ),
                if (widget.serverMode) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('tunnel-setup'),
                    onPressed: _checking || _starting ? null : _openSetup,
                    child: const Text('Set up the tunnel'),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// The Cloudflare Access login state (issue #23): the tunnel's Managed
/// OAuth — connect (the browser IdP login), logged-in, logged-out, and the
/// actions to move between them.
class _AccessSection extends StatefulWidget {
  const _AccessSection({this.session});

  /// The tunnel's Access login; `null` when there is no tunnel URL yet.
  final AccessSession? session;

  @override
  State<_AccessSection> createState() => _AccessSectionState();
}

class _AccessSectionState extends State<_AccessSection> {
  AccessLoginState? _state;

  /// True while connect or logout is in flight (its button shows progress).
  bool _acting = false;

  /// The last connect failure, if any.
  String? _error;

  @override
  void initState() {
    super.initState();
    _state = widget.session?.state;
    widget.session?.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant _AccessSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.session != oldWidget.session) {
      oldWidget.session?.removeListener(_onChange);
      _state = widget.session?.state;
      _error = null;
      widget.session?.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.session?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange(AccessLoginState state) {
    if (mounted) setState(() => _state = state);
  }

  Future<void> _connect() async {
    final session = widget.session;
    if (session == null || _acting) return;
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await session.connect();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _logout() async {
    final session = widget.session;
    if (session == null || _acting) return;
    setState(() => _acting = true);
    try {
      await session.logout();
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    if (session == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Set a tunnel URL to log in to the tunnel\'s Access.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    final state = _state;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  state == AccessLoginState.connecting
                      ? 'Waiting for the browser login…'
                      : state == AccessLoginState.loggedIn
                      ? 'Logged in.'
                      : 'Not logged in.',
                  key: const ValueKey('access-state'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (state == AccessLoginState.loggedIn)
                OutlinedButton(
                  key: const ValueKey('access-logout'),
                  onPressed: _acting ? null : _logout,
                  child: const Text('Log out'),
                )
              else
                OutlinedButton(
                  key: const ValueKey('access-connect'),
                  onPressed: _acting || state == AccessLoginState.connecting
                      ? null
                      : _connect,
                  child: _acting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Connect'),
                ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The push setup step (issue #24): the user pastes the `google-services.json`
/// of their Firebase project (the Firebase Console downloads it for this
/// app's Android package). It is parsed at runtime, so one build works with
/// any project and switching projects is a Settings edit, not a rebuild;
/// saving calls [onCommitted] so the app re-initializes the push flow with
/// it.
class _FirebaseProjectSection extends StatefulWidget {
  const _FirebaseProjectSection({
    required this.settings,
    required this.onCommitted,
  });

  final AppSettings settings;
  final VoidCallback? onCommitted;

  @override
  State<_FirebaseProjectSection> createState() =>
      _FirebaseProjectSectionState();
}

class _FirebaseProjectSectionState extends State<_FirebaseProjectSection> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.settings.firebaseProjectJson,
  );

  /// The last save's validation problem, when it had one.
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final raw = _controller.text.trim();
    if (raw.isNotEmpty && FirebaseProject.parse(raw) == null) {
      setState(() => _problem = 'That is not a valid google-services.json.');
      return;
    }
    widget.settings.firebaseProjectJson = raw;
    setState(() => _problem = null);
    widget.onCommitted?.call();
  }

  @override
  Widget build(BuildContext context) {
    final stored = widget.settings.firebaseProjectJson;
    final storedProject = stored.isEmpty ? null : FirebaseProject.parse(stored);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            storedProject == null
                ? (stored.isEmpty
                      ? 'Firebase project: not configured.'
                      : 'Firebase project: saved value is not valid.')
                : 'Firebase project: ${storedProject.options.projectId}.',
            key: const ValueKey('push-project-status'),
            style: const TextStyle(fontSize: 12),
          ),
          TextField(
            controller: _controller,
            key: const ValueKey('push-project-field'),
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'google-services.json',
              helperText:
                  'Paste the JSON from the Firebase Console (Android app); '
                  'it configures push on this device only.',
            ),
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _problem!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('push-project-save'),
              onPressed: _commit,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The host's push setup step (issue #24, server mode): the user pastes the
/// Firebase service account JSON (the Firebase Console's
/// Project settings → Service accounts download), which the app writes to
/// the file the bridge reads at
/// `~/.config/opencodebridge/firebase/service-account.json`. Saving calls
/// [onCommitted] so the app reloads the running bridge's push dispatch
/// with it (the bridge stays up; no restart).
class _ServiceAccountSection extends StatefulWidget {
  const _ServiceAccountSection({required this.onCommitted, this.path});

  final VoidCallback? onCommitted;

  /// Where the service account file lives ([FirebaseServiceAccount.defaultPath]
  /// by default; tests point it at a temp dir).
  final String? path;

  @override
  State<_ServiceAccountSection> createState() => _ServiceAccountSectionState();
}

class _ServiceAccountSectionState extends State<_ServiceAccountSection> {
  late final TextEditingController _controller = TextEditingController();

  /// The installed account, read from the file on init and after each save.
  late FirebaseServiceAccount? _account;

  /// The last save's validation problem, when it had one.
  String? _problem;

  @override
  void initState() {
    super.initState();
    _account = FirebaseServiceAccount.tryLoad(path: widget.path);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _problem = 'Paste the service account JSON first.');
      return;
    }
    try {
      final account = FirebaseServiceAccount.install(raw, path: widget.path);
      _controller.clear();
      setState(() {
        _account = account;
        _problem = null;
      });
      widget.onCommitted?.call();
    } on ArgumentError {
      setState(() => _problem = 'That is not a valid service account JSON.');
    } catch (_) {
      setState(() => _problem = 'Could not write the service account file.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            account == null
                ? 'Service account: not configured.'
                : 'Service account: ${account.email}.',
            key: const ValueKey('service-account-status'),
            style: const TextStyle(fontSize: 12),
          ),
          TextField(
            controller: _controller,
            key: const ValueKey('service-account-field'),
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'service-account.json',
              helperText:
                  'Paste the JSON from the Firebase Console (Project settings → '
                  'Service accounts); it is saved on this host and lets the '
                  'bridge send push.',
            ),
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _problem!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('service-account-save'),
              onPressed: _commit,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
