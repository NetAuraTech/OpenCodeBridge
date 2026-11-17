import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The bridge's route dispatch (issue #253, C3 of the turn-outcome series).
///
/// With the outcome decisions already moved out of the handlers (C1, issue
/// #251, and C2, issue #252 — the session-lifecycle module), this module is
/// the remaining structural step: the request dispatch flattens from the
/// ~440-line sequential if-chain over method+path to the thin, ordered
/// [RouteTable] — one [RouteEntry] per route, the methods it answers and the
/// path it matches, and the one handler that serves the match.
///
/// **Adding or renaming a route touches one [RouteEntry] and its one
/// handler** — not a chain. And the table holds no wiring of its own: the
/// composition root (the bridge's start wiring) builds it, so a wiring change
/// re-builds the table without churning the dispatch, and the dispatch never
/// reaches back into the wiring (this module imports the bridge server never).

/// One entry of the [RouteTable]: the HTTP [methods] it answers, a [match]
/// that tests the request's path, and the [handler] that serves the request
/// when the method and the path both match.
class RouteEntry {
  RouteEntry({this.methods, required this.match, required this.handler});

  /// A route on a fixed [path] that answers one [method]: the [match] is a
  /// plain path equality, and the [handler] takes only the request (there are
  /// no path parameters to parse). Most of the bridge's routes are
  /// [RouteEntry.fixed].
  factory RouteEntry.fixed(
    String method,
    String path,
    Future<void> Function(HttpRequest) handler,
  ) => RouteEntry(
    methods: {method},
    match: (uri) => uri.path == path ? path : null,
    handler: (request, _) => handler(request),
  );

  /// The HTTP methods this entry answers, or `null` to answer every method.
  ///
  /// Most routes answer exactly one method (the [RouteEntry.fixed] case). Two
  /// need more than the fixed form: the messages read/write pair answers
  /// `{'GET', 'POST'}`, and the per-session command menu (the session-subpath
  /// catch-all) answers `null` — every method — because its subpath is the
  /// command and the handler decides the verb from the method.
  final Set<String>? methods;

  /// Tests the request's [uri] against this entry. Returns the entry's parsed
  /// parameters on a match (the fixed [path] itself for a
  /// [RouteEntry.fixed], the path matcher's result — a session id, an orb
  /// `(id, action)` pair, … — for a parameterised path), or `null` when the
  /// path is not this entry's.
  final Object? Function(Uri uri) match;

  /// Serves a matched [request] with the [params] that [match] parsed.
  final Future<void> Function(HttpRequest request, Object? params) handler;
}

/// The ordered method→path→handler dispatch (issue #253, C3).
///
/// [dispatch] is the closure the HTTP server listens on: it walks the entries
/// in order and serves the first whose methods include the request's and whose
/// [RouteEntry.match] accepts the path. The order is load-bearing — a fixed
/// path is matched before the parameterised matchers that would otherwise read
/// its bare path as an id — so the table mirrors the previous if-chain's order
/// exactly (behaviour is unchanged).
///
/// The table holds no wiring: the composition root builds it (the entries'
/// handlers capture the bridge's live components), so the table is the request
/// path, and the root's wiring stays in the root.
class RouteTable {
  RouteTable(this._entries);

  /// The entries in dispatch order (first match wins; see [RouteTable]).
  final List<RouteEntry> _entries;

  /// The entries in dispatch order (for introspection, e.g. the shape test).
  List<RouteEntry> get entries => List.unmodifiable(_entries);

  /// The per-request dispatch. The response defaults to JSON, as every route
  /// it does not own (the SSE streams set their own content type). A request
  /// no entry claims answers 404 `not_found`; a client that went away (a
  /// broken socket) is closed without taking the bridge down.
  Future<void> dispatch(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      for (final entry in _entries) {
        final methods = entry.methods;
        if (methods != null && !methods.contains(request.method)) continue;
        final params = entry.match(request.uri);
        if (params == null) continue;
        await entry.handler(request, params);
        return;
      }
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
      await response.close();
    } catch (_) {
      // The client went away or the socket broke; the response is unusable.
      try {
        response.close();
      } catch (_) {}
    }
  }
}
