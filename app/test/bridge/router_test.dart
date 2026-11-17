import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/router.dart';

/// The route dispatch (issue #253, C3 of the turn-outcome series).
///
/// Two seams are tested:
///
/// - the **dispatch mechanics** — [RouteTable] / [RouteEntry]: the thin,
///   ordered method→path→closure that replaced the ~440-line if-chain. The
///   order is load-bearing (a fixed path is matched before the parameterised
///   matchers that would read its bare path as an id), the method filter is
///   per entry (one method, several, or any), and a request no entry claims
///   answers 404.
/// - the **shape of the real table** — the table the bridge serves
///   ([BridgeServer.routes], built by the composition root's start wiring from
///   the bridge's live components). Adding or renaming a route touches one
///   [RouteEntry] there and its one handler — the pinned entry count and the
///   per-route method→path checks are the seam that forces that.

void main() {
  group('RouteTable dispatch mechanics (issue #253, C3)', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
    });

    tearDown(() async {
      await server.close(force: true);
    });

    Future<(int, String)> request(
      String method,
      String path, {
      String? body,
    }) async {
      final client = HttpClient();
      try {
        final req = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:$port$path'),
        );
        if (body != null) req.write(body);
        final resp = await req.close();
        final status = resp.statusCode;
        final text = await resp.transform(const Utf8Decoder()).join();
        return (status, text);
      } finally {
        client.close(force: true);
      }
    }

    void listen(RouteTable table) {
      server.listen(table.dispatch);
    }

    test('serves the first matching entry in order (a fixed path wins over a '
        'broader matcher that would read it as an id)', () async {
      final table = RouteTable([
        // The fixed path, checked first (as the if-chain did).
        RouteEntry.fixed('GET', '/api/specific', (request) async {
          final response = request.response;
          response.statusCode = HttpStatus.ok;
          response.write('specific');
          await response.close();
        }),
        // A broader matcher that would otherwise read `/api/specific` as a
        // bare id; it is second, so it only wins when the fixed path missed.
        RouteEntry(
          match: (uri) => uri.path.startsWith('/api/') ? uri.path : null,
          handler: (request, params) async {
            final response = request.response;
            response.statusCode = HttpStatus.ok;
            response.write('any:${params as String}');
            await response.close();
          },
        ),
      ]);
      listen(table);
      expect((await request('GET', '/api/specific')).$2, 'specific');
      expect((await request('GET', '/api/other')).$2, 'any:/api/other');
    });

    test(
      'an entry answers only its methods; a wrong method falls through',
      () async {
        final table = RouteTable([
          RouteEntry.fixed('GET', '/api/get-only', (request) async {
            final response = request.response;
            response.statusCode = HttpStatus.ok;
            response.write('get');
            await response.close();
          }),
        ]);
        listen(table);
        expect((await request('GET', '/api/get-only')).$1, 200);
        // A POST to a GET-only route matches no entry: 404.
        expect((await request('POST', '/api/get-only')).$1, 404);
      },
    );

    test('an entry may answer several methods (the read/write pair)', () async {
      final table = RouteTable([
        RouteEntry(
          methods: {'GET', 'POST'},
          match: (uri) => uri.path == '/api/both' ? '/api/both' : null,
          handler: (request, _) async {
            final response = request.response;
            response.statusCode = HttpStatus.ok;
            response.write(request.method);
            await response.close();
          },
        ),
      ]);
      listen(table);
      expect((await request('GET', '/api/both')).$2, 'GET');
      expect((await request('POST', '/api/both')).$2, 'POST');
      expect((await request('DELETE', '/api/both')).$1, 404);
    });

    test('an entry with no method filter answers every method (the command '
        'menu, where the subpath is the command)', () async {
      final table = RouteTable([
        RouteEntry(
          // methods: null (any).
          match: (uri) => uri.path.startsWith('/api/sessions/')
              ? uri.path.substring('/api/sessions/'.length)
              : null,
          handler: (request, params) async {
            final response = request.response;
            response.statusCode = HttpStatus.ok;
            response.write('${request.method}:${params as String}');
            await response.close();
          },
        ),
      ]);
      listen(table);
      expect(
        (await request('GET', '/api/sessions/ses_1/commands')).$2,
        'GET:ses_1/commands',
      );
      expect(
        (await request('POST', '/api/sessions/ses_1/cancel')).$2,
        'POST:ses_1/cancel',
      );
    });

    test(
      'a parameterised entry passes its parsed params to the handler',
      () async {
        final table = RouteTable([
          RouteEntry(
            methods: {'DELETE'},
            match: (uri) {
              const prefix = '/api/items/';
              if (!uri.path.startsWith(prefix)) return null;
              final id = uri.path.substring(prefix.length);
              if (id.isEmpty || id.contains('/')) return null;
              return id;
            },
            handler: (request, params) async {
              final response = request.response;
              response.statusCode = HttpStatus.noContent;
              await response.close();
            },
          ),
        ]);
        listen(table);
        expect((await request('DELETE', '/api/items/abc')).$1, 204);
        // No id segment: not a match, 404.
        expect((await request('DELETE', '/api/items/')).$1, 404);
      },
    );

    test('a request no entry claims answers 404 not_found', () async {
      listen(
        RouteTable([
          RouteEntry.fixed('GET', '/api/known', (request) async {
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
          }),
        ]),
      );
      final (status, body) = await request('GET', '/api/unknown');
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test(
      'a handler that throws is swallowed and the server keeps serving',
      () async {
        // A handler that throws mid-response (the client went away): the
        // dispatch closes the response without surfacing the error, and the
        // server keeps serving the next request.
        final table = RouteTable([
          RouteEntry.fixed('GET', '/api/boom', (request) async {
            request.response.statusCode = HttpStatus.ok;
            throw StateError('the socket broke');
          }),
          RouteEntry.fixed('GET', '/api/ok', (request) async {
            request.response.statusCode = HttpStatus.ok;
            request.response.write('ok');
            await request.response.close();
          }),
        ]);
        listen(table);
        // The throw is swallowed by the dispatch: the request completes (some
        // status, no crash) and the server is still up.
        expect(request('GET', '/api/boom'), completes);
        // The next request is still served.
        expect((await request('GET', '/api/ok')).$2, 'ok');
      },
    );
  });

  group('BridgeServer route table (issue #253, C3)', () {
    late BridgeServer server;

    setUp(() async {
      server = await BridgeServer.start(port: 0);
    });

    tearDown(() async {
      await server.stop();
    });

    /// The table entry that [method]+[path] would dispatch to, or `null` when
    /// no entry claims it (the 404 fallthrough). This reads the dispatch table
    /// directly — the method→path→closure seam — without opening a connection,
    /// so it never hangs on the SSE streams.
    RouteEntry? routeFor(String method, String path) {
      final uri = Uri.parse('http://127.0.0.1$path');
      for (final entry in server.routes.entries) {
        final methods = entry.methods;
        if (methods != null && !methods.contains(method)) continue;
        if (entry.match(uri) != null) return entry;
      }
      return null;
    }

    test('the table is well formed: every entry has a matcher and a handler, '
        'and its methods are a valid verb set', () {
      final table = server.routes;
      expect(table.entries, isNotEmpty);
      const verbs = {
        'GET',
        'POST',
        'PUT',
        'DELETE',
        'PATCH',
        'HEAD',
        'OPTIONS',
      };
      for (final entry in table.entries) {
        expect(entry.match, isNotNull, reason: 'every route needs a matcher');
        expect(entry.handler, isNotNull, reason: 'every route needs a handler');
        final methods = entry.methods;
        if (methods != null) {
          expect(
            methods,
            isNotEmpty,
            reason: 'a filtered entry names its verbs',
          );
          expect(
            methods,
            everyElement(verbs.contains),
            reason: 'only valid HTTP verbs (null = any method)',
          );
        }
      }
    });

    test('the table has a pinned shape: adding or renaming a route changes '
        'the entry count and forces the table to be re-read', () {
      // The pinned count is the seam: a new route (or a rename that changes a
      // fixed path) changes it, so the table — not a chain — is what a route
      // change touches.
      final table = server.routes;
      expect(table.entries.length, 51);
      // The order is load-bearing (a fixed path is matched before the
      // parameterised matchers that would read its bare path as an id, and the
      // per-session command catch-all reads the bare session subpath). The
      // catch-all is the only entry with no method filter, and it is last —
      // pinning the ordering invariant a rename must not break.
      final catchAlls = [
        for (final e in table.entries)
          if (e.methods == null) e,
      ];
      expect(catchAlls, hasLength(1));
      expect(
        table.entries.last.methods,
        isNull,
        reason: 'the command catch-all (no method filter) is the last entry',
      );
    });

    test('every fixed route dispatches to an entry by its method and path '
        '(method→path→closure)', () {
      // The fixed routes the old if-chain served. A rename of a path constant
      // or a dropped entry leaves any of these unclaimed (no entry matches).
      final routes = <(String, String)>[
        ('GET', '/api/health'),
        ('GET', '/api/sessions'),
        ('POST', '/api/sessions'),
        ('GET', '/api/projects'),
        ('GET', '/api/fs/drives'),
        ('GET', '/api/fs/directories'),
        ('POST', '/api/fs/directories'),
        ('GET', '/api/docker/containers'),
        ('GET', '/api/docker/compose'),
        ('POST', '/api/orb/image/rebuild'),
        ('POST', '/api/orbs'),
        ('GET', '/api/orbs'),
        ('POST', '/api/orb/spawn'),
        ('POST', '/api/orb/wait'),
        ('POST', '/api/orb/tasks'),
        ('POST', '/api/orb/stop'),
        ('POST', '/api/orb/delete'),
        ('POST', '/api/orb/export'),
        ('GET', '/api/tunnel'),
        ('POST', '/api/tunnel/check'),
        ('POST', '/api/tunnel/start'),
        ('POST', '/api/tunnel/setup'),
        ('POST', '/api/tunnel/login'),
        ('GET', '/api/usage'),
        ('GET', '/api/mcp'),
        ('GET', '/api/integrations'),
        ('GET', '/api/status'),
        ('POST', '/api/pair'),
        ('POST', '/api/reload'),
        ('GET', '/api/worktrees'),
        ('GET', '/api/plugins'),
        ('POST', '/api/notify/device-token'),
        ('GET', '/api/events'),
      ];
      for (final (method, path) in routes) {
        expect(
          routeFor(method, path),
          isNotNull,
          reason: '$method $path is a known route',
        );
      }
    });

    test(
      'the method is part of the route: the wrong method is not claimed',
      () {
        // The method filter is per entry; a wrong method matches no entry for
        // the same path (the dispatch then answers 404, as the mechanics test
        // proves). A rename or a wrong-verb entry would claim it wrongly.
        expect(routeFor('POST', '/api/health'), isNull);
        expect(routeFor('DELETE', '/api/health'), isNull);
        expect(routeFor('GET', '/api/orb/spawn'), isNull);
        expect(routeFor('DELETE', '/api/orb/spawn'), isNull);
        expect(routeFor('PATCH', '/api/sessions'), isNull);
        expect(routeFor('PUT', '/api/projects'), isNull);
      },
    );

    test('the per-session command menu answers any method on its subpath '
        '(the subpath is the command)', () {
      // The catch-all for `/api/sessions/{id}/…` has no method filter (the
      // method is decided inside the handler, as the verb of the command).
      final get = routeFor('GET', '/api/sessions/ses_1/commands');
      final post = routeFor('POST', '/api/sessions/ses_1/cancel');
      expect(get, isNotNull);
      expect(post, isNotNull);
      // …but a bare session detail is still claimed by its own GET matcher
      // first (the catch-all's `sub` is non-empty, so it does not swallow it).
      expect(routeFor('GET', '/api/sessions/ses_1'), isNotNull);
    });
  });
}
