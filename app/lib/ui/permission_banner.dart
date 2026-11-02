import 'package:flutter/material.dart';

import '../model/permission.dart';

/// The approve/deny banner for pending permission requests (spec §6:
/// "Permissions (both views)"). One row per pending request, each with the
/// three decisions of `POST /api/sessions/{id}/permissions/{requestID}/reply`
/// (spec §5, endpoint 9): `once` / `always` / `reject`.
///
/// Rendered by both the structured view and the terminal view; the pending
/// list is the initial state (endpoint 8), kept live by
/// `permission.asked` / `permission.replied` events (§8).
class PermissionBanner extends StatelessWidget {
  const PermissionBanner({
    super.key,
    required this.pending,
    required this.onReply,
    this.replyBusyId,
  });

  /// The requests awaiting a decision (endpoint 8); empty renders nothing.
  final List<PermissionRequest> pending;

  /// Applies the decision to a request (endpoint 9).
  final Future<void> Function(PermissionRequest request, PermissionReply reply)
  onReply;

  /// The request with the reply in flight: its row shows progress instead of
  /// the decision buttons.
  final String? replyBusyId;

  @override
  Widget build(BuildContext context) {
    if (pending.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('permission-banner'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final request in pending)
            _PermissionRow(
              request: request,
              busy: replyBusyId == request.id,
              onReply: (reply) => onReply(request, reply),
            ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.request,
    required this.busy,
    required this.onReply,
  });

  final PermissionRequest request;
  final bool busy;
  final ValueChanged<PermissionReply> onReply;

  String get _resources => request.resources.join(' ');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey('permission-row-${request.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Permission requested: ${request.action}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.error,
                  ),
                ),
              ),
            ],
          ),
          if (request.resources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 4),
              child: Text(
                _resources,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 26, top: 6),
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Wrap(
                    spacing: 8,
                    children: [
                      for (final (reply, label) in const [
                        (PermissionReply.once, 'Once'),
                        (PermissionReply.always, 'Always'),
                        (PermissionReply.reject, 'Reject'),
                      ])
                        TextButton(
                          key: ValueKey(
                            'permission-${reply.wire}-${request.id}',
                          ),
                          onPressed: () => onReply(reply),
                          child: Text(label),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
