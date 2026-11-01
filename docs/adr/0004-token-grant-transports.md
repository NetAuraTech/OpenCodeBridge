# ADR-0004: The Access token grant rides non-Dart transports

- **Status**: accepted (2026-10-31, ticket #41)

## Context

The client-side Cloudflare Access login (issue #23) ends with two form POSTs to the Access application's token endpoint — the authorization-code exchange and the silent refresh, together the **token grant**. A field test (Ray a534fa469e03f52a) showed that Cloudflare's beta Managed OAuth **500s the token endpoint for the Dart SDK's TLS fingerprint**: the byte-identical `application/x-www-form-urlencoded` form that `curl` completes with 200 answers 500 from the Dart VM's BoringSSL handshake. Re-verified 2026-10-31: the endpoint still 500s the Dart `HttpClient` (and still 200s the curl-identical form), while other common TLS stacks get normal OAuth responses (a bogus client answers 401, not 500). The block is at the TLS handshake, not the request: swapping the `User-Agent` changes nothing.

Discovery and dynamic registration are unaffected (they keep the Dart client), but the token grant is the heart of the login, and the original desktop workaround — spawning the system `curl` — is unavailable on Android, where there is no `curl` on the PATH. The grant therefore needs a per-platform non-Dart transport, not an app-code fix.

## Decision

- **Only the token grant rides non-Dart transports; everything else keeps the Dart client.** The two `POST /token` grants go through a transport chain; discovery, registration, and all other app traffic keep `dart:io`.
- **The chain: system `curl` → Android platform HTTP stack → Dart client.**
  - **`curl` (desktop)**: when `curl` is on the PATH, the grant is a `curl` subprocess (the form on stdin, a status marker on stdout). Its TLS fingerprint gets the 200 — the original workaround (issue #23 field test, Ray a534fa469e03f52a).
  - **Android platform (ticket #41)**: when `curl` is absent (always, on Android), the grant rides the platform's own HTTP stack through a small MethodChannel (`opencodebridge/form_post` / `postForm`: status plus raw body, whatever the status is), using the stock Android TLS (Conscrypt), which is not blocked.
  - **Dart client (fallback)**: when neither is available, the grant rides `dart:io`'s `HttpClient` — it answers as soon as Cloudflare fixes the endpoint.
- **The transports are invisible to the OAuth semantics.** Every transport returns `(status, raw body)` without throwing on non-2xx, and the client interprets the answer identically whichever transport carried it; a network-level failure from any hop surfaces as an `OAuthError('network', …)`. PKCE, the RFC 8707 resource, and the grant lifecycle are unaffected by the transport.
- **The Dart-client hop is a canary by design.** The moment the plain client gets the 200, the two shims (the `curl` spawn, the MethodChannel) are deleted and the chain collapses to the plain client.

## Considered options

- **Header spoofing** (curl's `User-Agent` on the Dart client): rejected — the 500 is at the TLS handshake, verified by re-test with the swapped header (still 500).
- **Bundling a static `curl` binary (with its `.so` dependencies) in the APK**: rejected — a supply-chain and size burden (several MB per ABI) to work around one endpoint on a platform that already has an unblocked HTTP stack.
- **Running the exchange in a WebView**: rejected — the response is not cleanly extractable, and the attack surface widens for no gain.

## Consequences

- The desktop app now has a soft dependency on a `curl` on the PATH: its absence degrades the grant to the Dart client (the 500 while Cloudflare's bug is live), never a crash.
- The Android app carries a platform channel whose only purpose is an HTTP POST (`opencodebridge/form_post` in `MainActivity`). That is not the Flutter-idiomatic way to do HTTP; it is the workaround, not an accident — do not "clean it up" into the Dart client while the fingerprint block is live.
- The three failure modes stay distinct and are tested as such: no `curl` (`ProcessException`), no platform handler (`MissingPluginException`), network failure (`CurlPostFailure` / `PlatformException('network')`). The chain's behaviour is the set of exceptions each hop throws.
- If Cloudflare fixes the token endpoint, or starts blocking another fingerprint, the remedy is to reorder or trim the chain; nothing above the transport changes.
