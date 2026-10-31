import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../client/tunnel_client.dart';
import '../model/tunnel_report.dart';
import '../model/tunnel_setup.dart';

/// The assisted tunnel setup wizard (issue #34, ADR-0003): collects the
/// tunnel name, the public hostname, and the credentials JSON paste,
/// validates them app-side (with the clear error messages), submits them
/// to `POST /api/tunnel/setup`, and pops with the bridge's fresh report on
/// success. The two manual dashboard steps (the DNS route, the Access
/// application) are displayed with their exact values, a copy action, and
/// a dashboard deep link.
class TunnelSetupWizardDialog extends StatefulWidget {
  const TunnelSetupWizardDialog({
    super.key,
    required this.client,
    this.initialHostname,
  });

  /// The client for the bridge's tunnel API.
  final TunnelClient client;

  /// The hostname to prefill, when the app-owned config already carries
  /// one.
  final String? initialHostname;

  /// Shows the wizard; completes with the bridge's fresh report on
  /// success, `null` when cancelled.
  static Future<TunnelReport?> show(
    BuildContext context, {
    required TunnelClient client,
    String? initialHostname,
  }) => showDialog<TunnelReport>(
    context: context,
    builder: (context) => TunnelSetupWizardDialog(
      client: client,
      initialHostname: initialHostname,
    ),
  );

  @override
  State<TunnelSetupWizardDialog> createState() =>
      _TunnelSetupWizardDialogState();
}

class _TunnelSetupWizardDialogState extends State<TunnelSetupWizardDialog> {
  late final TextEditingController _tunnelName = TextEditingController();
  late final TextEditingController _hostname = TextEditingController(
    text: widget.initialHostname ?? '',
  );
  late final TextEditingController _credentials = TextEditingController();

  /// True while the setup is being submitted.
  bool _busy = false;

  /// The last validation or bridge error, shown as-is.
  String? _error;

  /// Rebuilds on any edit: the manual-steps display and the submit button
  /// depend on the live field values, not just the text fields themselves.
  void _onEdit() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _tunnelName.addListener(_onEdit);
    _hostname.addListener(_onEdit);
    _credentials.addListener(_onEdit);
  }

  @override
  void dispose() {
    _tunnelName.removeListener(_onEdit);
    _hostname.removeListener(_onEdit);
    _credentials.removeListener(_onEdit);
    _tunnelName.dispose();
    _hostname.dispose();
    _credentials.dispose();
    super.dispose();
  }

  /// The normalized public hostname, `null` while the field does not carry
  /// a valid one (the manual steps display needs it).
  String? get _validHostname {
    try {
      return normalizeHostname(_hostname.text);
    } on TunnelSetupError {
      return null;
    }
  }

  /// The parsed credentials, `null` while the paste does not carry valid
  /// ones (the manual steps display needs the UUID and the owner fields).
  TunnelCredentials? get _validCredentials {
    try {
      return TunnelCredentials.parse(_credentials.text);
    } on TunnelSetupError {
      return null;
    }
  }

  /// Validates the three inputs app-side (the first error wins), then
  /// submits the setup to the bridge and pops with its fresh report.
  Future<void> _submit() async {
    if (_busy) return;
    String name;
    String hostname;
    TunnelCredentials credentials;
    try {
      name = normalizeTunnelName(_tunnelName.text);
      hostname = normalizeHostname(_hostname.text);
      credentials = TunnelCredentials.parse(_credentials.text);
    } on TunnelSetupError catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    var done = false;
    try {
      final report = await widget.client.setup(
        name,
        hostname,
        credentials.source,
      );
      done = true;
      if (!mounted) return;
      Navigator.of(context).pop(report);
    } on TunnelClientError catch (e) {
      if (!mounted) return;
      setState(() => _error = _bridgeError(e));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'The bridge could not apply the setup.');
    } finally {
      if (!done && mounted) setState(() => _busy = false);
    }
  }

  /// The bridge's explanation of a failed setup, when its error body
  /// carries one (the 400 `details`).
  String _bridgeError(TunnelClientError e) {
    try {
      final decoded = jsonDecode(e.message);
      if (decoded is Map<String, Object?>) {
        final details = decoded['details'];
        if (details is String && details.isNotEmpty) return details;
      }
    } catch (_) {
      // A non-JSON body: fall through to the generic message.
    }
    return 'The bridge could not apply the setup '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).';
  }

  @override
  Widget build(BuildContext context) {
    final hostname = _validHostname;
    final credentials = _validCredentials;
    final List<Widget> manual = [];
    if (hostname != null) {
      manual
        ..add(const SizedBox(height: 12))
        ..add(
          Text(
            'To finish, create in the Cloudflare dashboard:',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        )
        ..add(const SizedBox(height: 4));
      if (credentials != null) {
        manual.add(
          _ManualStep(
            title: 'DNS route (CNAME)',
            value: dnsCnameLine(hostname, credentials.tunnelId),
            copyValue: cfargotunnelTarget(credentials.tunnelId),
            link: Uri.parse(
              dashboardDeepLink(
                'dns/records',
                accountId: credentials.accountId,
              ),
            ),
          ),
        );
      }
      final access = accessAppSpec(
        hostname,
        ownerEmail: credentials?.ownerEmail,
      );
      manual.add(
        _ManualStep(
          title: 'Access application',
          value: access,
          copyValue: access,
          link: Uri.parse(
            dashboardDeepLink('access/apps', accountId: credentials?.accountId),
          ),
        ),
      );
    }
    return Dialog(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Set up the tunnel',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('setup-tunnel-name'),
                  controller: _tunnelName,
                  decoration: const InputDecoration(labelText: 'Tunnel name'),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('setup-hostname'),
                  controller: _hostname,
                  decoration: const InputDecoration(
                    labelText: 'Public hostname',
                    hintText: 'bridge.example.com',
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('setup-credentials'),
                  controller: _credentials,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Credentials (the pasted JSON)',
                    hintText: '{\n  "TunnelID": "…",\n  "APIKey": "…"\n}',
                  ),
                ),
                ...manual,
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const ValueKey('setup-cancel'),
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const ValueKey('setup-submit'),
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save & recheck'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One manual dashboard step, displayed with its exact value, a copy
/// action, and the dashboard deep link (issue #34).
class _ManualStep extends StatelessWidget {
  const _ManualStep({
    required this.title,
    required this.value,
    required this.copyValue,
    required this.link,
  });

  /// The step label, e.g. "DNS route (CNAME)".
  final String title;

  /// The exact value, displayed.
  final String value;

  /// What the copy action copies.
  final String copyValue;

  /// The dashboard deep link, displayed.
  final Uri link;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                key: ValueKey('copy-$title'),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: copyValue)),
                child: const Text('Copy'),
              ),
            ],
          ),
          Text(value, style: const TextStyle(fontSize: 12)),
          Text(
            link.toString(),
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
