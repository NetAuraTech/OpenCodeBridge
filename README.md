# OpenCodeBridge

View and control, in real time, [opencode](https://opencode.ai) sessions and Docker containers running on a host PC — from a desktop app, or from your phone.

OpenCodeBridge is a cross-platform Flutter app (Android first, desktop Linux). The app never talks to opencode or to Docker directly: it talks only to **the bridge**, an HTTP service embedded in the desktop app. The bridge is the single API the app consumes — sessions, Docker, events — in every mode, on every machine.

## How it works

- **Server mode** (desktop): the app hosts the embedded bridge (loopback-only HTTP at `http://127.0.0.1:48201`), manages the tunnel, and opens its own local client.
- **Client mode** (desktop and Android): the app is a pure client that connects to a bridge at the tunnel URL entered in Settings. On the phone, this is how you reach the bridge running on your PC.

Remote access runs on a locally-managed **named Cloudflare tunnel** exposed on your domain and protected by **Cloudflare Access**. The whole local side is driven from an in-app assisted setup wizard: it collects the tunnel name and hostname, runs the app-managed `cloudflared tunnel login` (browser consent) and `cloudflared tunnel create`, writes the app-owned tunnel files (`~/.cloudflared/<uuid>.json` and `~/.config/opencodebridge/cloudflared.yml`), and re-checks and (re)starts the tunnel. You only do two things yourself in the Cloudflare dashboard — a proxied CNAME record and a Cloudflare Access policy (see [docs/cloudflare-setup.md](docs/cloudflare-setup.md)).

## Features

- **Sessions** — the home list of your opencode sessions, with persistence and delete; create a new session, or a new project (with a filesystem browser dialog), directly from the app via the opencode API.
- **Structured view** — a session's messages, thinking text, tools in flight (readable tool cards for shell, read, grep, execute), costs, and permissions, updated live:
  - a `/` command menu with all opencode slash commands plus your custom commands;
  - an `@` mention menu to attach skills and repo files to the prompt;
  - `Ctrl+V` pastes a clipboard image as an atomic `[Image N]` token;
  - answer the agent's *question* tool right from the view;
  - a floating permissions banner, above the prompt bar, to answer the agent's permission requests.
- **Docker** — monitor the containers and compose projects on the host.
- **Orbs** — a Docker container running its own opencode service on a dedicated clone of one project: the project's long-lived sandboxed workspace, where the agent's tools really run inside the container. Create an orb from the UI or from a session, with an app-owned image build pipeline; **stopping** an orb moves its sessions to the host without loss; **waking** brings it back with the workspace and branch untouched.
- **Push notifications** — in server mode the bridge sends FCM push for the moments that matter: a permission is requested, a turn ended, or a Docker container stopped or crashed. On Android they deep-link straight into the relevant session.
- **Themes** — a persisted Light / Dark / System choice.

## Repository layout

- `app/` — the Flutter app:
  - `lib/bridge/` — the embedded bridge: loopback-only HTTP server over sessions, Docker, events, filesystem, notifications, tunnel, and orbs;
  - `lib/client/` — the client side: authenticated HTTP, SSE events, health monitoring, per-domain clients;
  - `lib/access/` — Cloudflare Access (managed OAuth, loopback server, token store);
  - `lib/ui/` — mode choice, 3-tab shell (Sessions, Docker, Settings), structured view, permission banner, tunnel setup wizard;
  - `lib/model/` — data models; `lib/sse/`, `lib/notify/`, `lib/settings/` — transport, FCM, persisted settings.
- `CONTEXT.md` — the domain glossary: bridge, session, turn, permission, orb, stop, wake, move, seed, and friends.
- `docs/` — ADRs, the orbs spec, the Cloudflare dashboard setup reference, and research notes.

## Run

```sh
cd app
flutter run -d linux   # desktop — shows the mode choice at launch
```

- **Server mode** — the app hosts the embedded bridge and its client connects to it locally.
- **Client mode** — the app connects to a bridge at the tunnel URL entered in Settings. Android always launches in client mode.

The previous mode is preselected at every desktop launch. The small dot in the app bar is the connection indicator: green = the bridge's `GET /api/health` answers, red = disconnected, grey = connecting.

### Tests

```sh
cd app
flutter analyze
flutter test
```
