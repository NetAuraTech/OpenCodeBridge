/// The app's deep links (issue #24): where a push lands on tap.
///
/// The bridge puts one in every push's `data.link`; the app opens it when
/// the notification is tapped (or the app was launched from it). One link
/// targets one place:
///
/// - `opencodebridge://session/<id>` — a session (its structured view,
///   which shows the pending-permission banner);
/// - `opencodebridge://container/<name>` — a container's detail.
class DeepLink {
  const DeepLink._(this.target, this.id);

  /// The link target: `session` or `container`.
  final String target;

  /// The target's id (the session id or the container name).
  final String id;

  /// A session link.
  factory DeepLink.session(String id) => DeepLink._('session', id);

  /// A container link.
  factory DeepLink.container(String name) => DeepLink._('container', name);

  /// The URI form of a session link, e.g. `opencodebridge://session/ses_1`.
  static Uri sessionUri(String id) =>
      Uri(scheme: 'opencodebridge', host: 'session', path: id);

  /// The URI form of a container link,
  /// e.g. `opencodebridge://container/postgres`.
  static Uri containerUri(String name) =>
      Uri(scheme: 'opencodebridge', host: 'container', path: name);

  /// True when the link targets a session.
  bool get isSession => target == 'session';

  /// True when the link targets a container.
  bool get isContainer => target == 'container';

  /// Parses [uri] into a deep link, or `null` when it is not one (wrong
  /// scheme, unknown target, or no id).
  static DeepLink? tryParse(Uri uri) {
    if (uri.scheme != 'opencodebridge') return null;
    if (uri.host != 'session' && uri.host != 'container') return null;
    final segments = uri.pathSegments;
    if (segments.length != 1 || segments.single.isEmpty) return null;
    return DeepLink._(uri.host, segments.single);
  }

  @override
  bool operator ==(Object other) =>
      other is DeepLink && other.target == target && other.id == id;

  @override
  int get hashCode => Object.hash(target, id);

  @override
  String toString() =>
      'DeepLink($target: $id)';
}
