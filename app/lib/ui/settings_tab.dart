import 'package:flutter/material.dart';

import '../app_info.dart';
import '../app_mode.dart';
import '../settings/app_settings.dart';

/// The Settings tab (spec: section 13): host connection (client mode: the
/// tunnel URL), the three notification toggles, and the app version.
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
  });

  final AppSettings settings;
  final AppMode mode;

  /// Present in server mode: where the embedded bridge listens.
  final Uri? localBridgeUri;

  /// Called when the user commits the tunnel URL (submit or focus loss), so
  /// the app can re-point its connection at the new bridge.
  final VoidCallback? onTunnelUrlCommitted;

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
