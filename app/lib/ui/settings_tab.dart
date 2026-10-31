import 'package:flutter/material.dart';

import '../app_info.dart';
import '../app_mode.dart';
import '../client/tunnel_client.dart';
import '../model/tunnel_report.dart';
import '../settings/app_settings.dart';
import 'tunnel_setup_wizard.dart';

/// The Settings tab (spec: section 13): host connection (client mode: the
/// tunnel URL), the tunnel status (issue #22), the three notification
/// toggles, and the app version.
///
/// The notification toggles persist now and become live with the push
/// ticket; the Cloudflare Access login state arrives with the remote-access
/// ticket.
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.settings,
    required this.mode,
    this.localBridgeUri,
    this.onTunnelUrlCommitted,
    this.tunnelClient,
  });

  final AppSettings settings;
  final AppMode mode;

  /// Present in server mode: where the embedded bridge listens.
  final Uri? localBridgeUri;

  /// Called when the user commits the tunnel URL (submit or focus loss), so
  /// the app can re-point its connection at the new bridge.
  final VoidCallback? onTunnelUrlCommitted;

  /// The client for the bridge's tunnel API; the default builds a real
  /// [TunnelClient] at the bridge (tests inject a fake).
  final TunnelClient? tunnelClient;

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
    return tunnel.isEmpty ? null : Uri.parse(tunnel);
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
      const _SectionLabel('Tunnel'),
      _TunnelSection(
        apiBase: _tunnelApiBase,
        client: widget.tunnelClient,
        serverMode: widget.mode == AppMode.server,
      ),
      const SizedBox(height: 8),
      const _SectionLabel('Notifications'),
      SwitchListTile(
        title: const Text('Permission requested'),
        value: widget.settings.notifyPermissionAsked,
        onChanged: (value) =>
            setState(() => widget.settings.notifyPermissionAsked = value),
      ),
      SwitchListTile(
        title: const Text('Turn ended'),
        value: widget.settings.notifyTurnEnded,
        onChanged: (value) =>
            setState(() => widget.settings.notifyTurnEnded = value),
      ),
      SwitchListTile(
        title: const Text('Docker container stopped or crashed'),
        value: widget.settings.notifyDockerContainer,
        onChanged: (value) =>
            setState(() => widget.settings.notifyDockerContainer = value),
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
  });

  /// Where the bridge's tunnel API lives; `null` when this client has no
  /// bridge to point at.
  final Uri? apiBase;

  /// The client for the bridge's tunnel API; the default builds a real
  /// [TunnelClient] at [apiBase].
  final TunnelClient? client;

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
  }

  @override
  void didUpdateWidget(covariant _TunnelSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.apiBase != oldWidget.apiBase) _init(widget.apiBase);
  }

  void _init(Uri? base) {
    _client = base == null ? null : (widget.client ?? TunnelClient(base));
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
