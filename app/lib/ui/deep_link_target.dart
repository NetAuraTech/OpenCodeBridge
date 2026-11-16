import 'package:flutter/foundation.dart';

import '../notify/deep_link.dart';

/// The one-shot deep-link target (issue #287): who a tapped notification
/// should open, and the one-shot's lifecycle — when it is consumed and when
/// it is cleared. One model owns it; before this extraction the same
/// one-shot was patched in five places (the notify layer's buffer and
/// re-listenable stream, two fields on the shell, a consume callback, and a
/// pending field on each tab), none of them a module.
///
/// The model is a stable owner: it is held by the app across shell remounts
/// (a re-login, a reconnect), so a target that arrived while the shell was
/// away is still on the model when the shell comes back — a remounted shell
/// re-reads it (and its tab opens it on its next load) instead of the link
/// being dropped or swallowed into a "quiet" stream.
///
/// The two target kinds — a session id and a container name — are exclusive:
/// a new link replaces whatever was pending, clearing the one of the other
/// kind, so the model always holds at most one target.
///
/// No widget, no `setState`, no [BuildContext]: the module is
/// unit-testable flat (set a target, consume it, assert the cleared state),
/// and the shell and the tabs read it exactly as before this extraction.
class DeepLinkTarget extends ChangeNotifier {
  /// The one-shot target to open, or `null` when there is nothing to open:
  /// set by [apply] from a tapped notification's link (the shell switches to
  /// the matching tab from the same link), consumed by the tab that opens it
  /// through [consume].
  DeepLink? get target => _target;

  DeepLink? _target;

  /// A tapped notification (issue #24): sets [target] to [link], replacing
  /// whatever was pending — a session link clears a pending container
  /// target and vice versa (the two kinds are exclusive). A link that is
  /// not a deep link is ignored (the caller parses with
  /// [DeepLink.tryParse] and passes the result through).
  void apply(DeepLink? link) {
    if (link == null) return;
    _target = link;
    notifyListeners();
  }

  /// The target was opened (its tab selected the row or pushed the detail):
  /// clears [target] so a later identical link is a new event, and notifies
  /// the listeners (the shell's rebuild settles the tab's pending read the
  /// same way the old consume callback settled the shell's field).
  void consume() {
    if (_target == null) return;
    _target = null;
    notifyListeners();
  }
}
