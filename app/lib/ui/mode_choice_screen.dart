import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../settings/app_settings.dart';

/// The desktop launch mode choice (spec: section 3, section 13).
///
/// Shown at every desktop launch: server or client, with the previous mode
/// preselected and persisted on Start.
class ModeChoiceScreen extends StatefulWidget {
  const ModeChoiceScreen({
    super.key,
    required this.settings,
    required this.onSelected,
    this.error,
  });

  final AppSettings settings;

  /// Called with the chosen mode when the user presses Start.
  final ValueChanged<AppMode> onSelected;

  /// Shown when the previous attempt to start server mode failed (e.g. the
  /// port is already held by another instance).
  final String? error;

  @override
  State<ModeChoiceScreen> createState() => _ModeChoiceScreenState();
}

class _ModeChoiceScreenState extends State<ModeChoiceScreen> {
  late AppMode _selected =
      widget.settings.lastMode ?? _ModeChoiceScreenState._defaultMode;

  /// First-launch default: the desktop is the host, so it serves.
  static const AppMode _defaultMode = AppMode.server;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('OpenCodeBridge')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'How do you want to run?',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Your choice is preselected at the next launch.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            RadioGroup<AppMode>(
              groupValue: _selected,
              onChanged: (value) => setState(() => _selected = value!),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<AppMode>(
                    value: AppMode.server,
                    title: const Text('Server'),
                    subtitle: const Text(
                      'Host the bridge on this machine (localhost only, remote through the tunnel).',
                    ),
                  ),
                  RadioListTile<AppMode>(
                    value: AppMode.client,
                    title: const Text('Client'),
                    subtitle: const Text(
                      'Connect to a bridge at the tunnel URL from Settings.',
                    ),
                  ),
                ],
              ),
            ),
            if (widget.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  widget.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton(onPressed: _start, child: const Text('Start')),
          ],
        ),
      ),
    ),
  );

  void _start() {
    widget.settings.lastMode = _selected;
    widget.onSelected(_selected);
  }
}
