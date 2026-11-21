/// The app's deep links (issue #24): where a push lands on tap.
///
/// The bridge puts one in every push's `data.link`; the app opens it when
/// the notification is tapped (or the app was launched from it). One link
/// targets one place:
///
/// - `opencodebridge://session/<id>` — a session (its structured view,
///   which shows the pending-permission banner);
/// - `opencodebridge://container/<name>` — a container's detail;
/// - an external URL (`https://…`) — opened in the **external browser**
///   (spec #376, T5: an AFK run's PR deep-links to the PR's GitHub URL).
class DeepLink {
  const DeepLink._(this.target, this.id);

  /// The link target: `session`, `container`, or `external`.
  final String target;

  /// The target's id: the session id, the container name, or the external
  /// URL's string form.
  final String id;

  /// A session link.
  factory DeepLink.session(String id) => DeepLink._('session', id);

  /// A container link.
  factory DeepLink.container(String name) => DeepLink._('container', name);

  /// An external link: a URL opened in the browser (the [id] is the URL).
  factory DeepLink.external(String url) => DeepLink._('external', url);

  /// The URI form of a session link, e.g. `opencodebridge://session/ses_1`.
  static Uri sessionUri(String id) =>
      Uri(scheme: 'opencodebridge', host: 'session', path: id);

  /// The URI form of a container link,
  /// e.g. `opencodebridge://container/postgres`.
  static Uri containerUri(String name) =>
      Uri(scheme: 'opencodebridge', host: 'container', path: name);

  /// The URI form of an external link: the URL itself (an AFK run's PR is
  /// deep-linked by its GitHub URL, opened in the external browser).
  static Uri externalUri(String url) => Uri.parse(url);

  /// True when the link targets a session.
  bool get isSession => target == 'session';

  /// True when the link targets a container.
  bool get isContainer => target == 'container';

  /// True when the link is an external URL (opened in the browser).
  bool get isExternal => target == 'external';

  /// Parses [uri] into a deep link, or `null` when it is not one.
  ///
  /// An `opencodebridge://<target>/<id>` URI (the `session` and `container`
  /// targets, a single non-empty path segment) parses to that target. An
  /// `http`/`https` URI parses to an [external] link whose id is the URL —
  /// the PR's GitHub URL, opened in the external browser (spec #376, T5).
  /// Anything else (a wrong deep-link scheme, an unknown target, no id, a
  /// scheme-less string, another scheme) is not a deep link.
  static DeepLink? tryParse(Uri uri) {
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return DeepLink._('external', uri.toString());
    }
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
  String toString() => 'DeepLink($target: $id)';
}
