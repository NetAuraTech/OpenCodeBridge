# OpenCodeBridge (app)

The Flutter app. The project README ([../README.md](../README.md)) has the full picture: features, the bridge, the tunnel, and the repository layout.

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

- `lib/bridge/` — the embedded bridge: loopback-only HTTP server over
  sessions, Docker, events, filesystem, notifications, tunnel, and orbs.
- `lib/client/` — the client side: authenticated HTTP, SSE events, the
  connection monitor, and per-domain clients (sessions, Docker, fs, events,
  notifications, tunnel).
- `lib/access/` — Cloudflare Access: managed OAuth against the app-managed
  cloudflared, loopback server, and the token store.
- `lib/ui/` — mode choice screen, 3-tab shell (Sessions, Docker, Settings),
  the structured view with its `/` and `@` menus and permission banner, the
  Docker tab, and the tunnel setup wizard.
- `lib/model/` — the data models (sessions, messages, permissions, containers,
  tunnel reports).
- `lib/sse/` — the SSE transport.
- `lib/notify/` — FCM push (Android) and the deep links.
- `lib/settings/` — persisted settings: last mode, tunnel URL, theme, push
  toggles.
