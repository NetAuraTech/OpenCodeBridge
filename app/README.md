# OpenCodeBridge

A cross-platform app (Android first, desktop Linux) for viewing and
controlling, in real time, opencode sessions and Docker containers running on
a host PC.

This is the scaffold slice: the app shell, the embedded bridge's health
endpoint, the desktop mode choice, and the connection indicator. The session
list, terminal/structured views, Docker monitoring, and push notifications
arrive in later slices (see the spec, GitHub issue #13).

## Run

```sh
flutter run -d linux   # desktop (shows the mode choice at launch)
```

- **Server mode** — the app hosts the embedded bridge (localhost-only,
  `http://127.0.0.1:48201`) and its client connects to it locally.
- **Client mode** — the app connects to a bridge at the tunnel URL entered in
  Settings.

The previous mode is preselected at every desktop launch. Android always
launches in client mode.

The connection indicator is the small dot in the app bar: green = the
bridge's `GET /api/health` answers, red = disconnected, grey = connecting.

## Tests

```sh
flutter analyze
flutter test
```

## Layout

- `lib/bridge/` — the embedded bridge: loopback-only HTTP server,
  `GET /api/health` (bridge / opencode / Docker reachability).
- `lib/client/` — the connection monitor that polls the health endpoint.
- `lib/settings/` — persisted settings: last mode, tunnel URL, push toggles.
- `lib/ui/` — mode choice screen, 3-tab shell (Sessions, Docker, Settings),
  connection indicator.
