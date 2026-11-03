# OpenCodeBridge

A cross-platform app (Android first, desktop Linux/Windows) for viewing and controlling, in real time, opencode sessions and Docker containers running on a host PC.

## Language

### The bridge

**Bridge**:
The HTTP service embedded in the desktop app (server mode) that is the single API the app consumes: sessions, Docker, events. The app talks only to the bridge, in every mode and on every machine.
_Avoid_: gateway, service (too generic), backend

**Server mode**:
Desktop launch mode in which the app hosts the bridge, the named tunnel, and opens its own local client.
_Avoid_: host mode, listen mode

**Client mode**:
Desktop launch mode in which the app is a pure client connecting to a bridge.
_Avoid_: remote mode, consumer mode

**Tunnel**:
The locally-managed named Cloudflare tunnel that server mode runs, exposing the bridge's localhost port through the user's domain behind Cloudflare Access.
_Avoid_: cloudflared (the binary), reverse proxy

**App-owned files**:
The two files the tunnel runs on that the app owns and writes: the credentials `~/.cloudflared/<uuid>.json` and the config `~/.config/opencodebridge/cloudflared.yml`. The user never writes them by hand.
_Avoid_: tunnel files, config files

**Assisted setup**:
The in-app, server-mode wizard that collects the tunnel name, public hostname, and — optionally — pasted credentials, and has the bridge write the app-owned files, then re-checks and (re)starts the tunnel.
_Avoid_: setup wizard, tunnel wizard, onboarding

**App-driven login**:
The in-app Cloudflare login: the bridge runs the app-managed `cloudflared tunnel login`, which opens the default browser on the OAuth consent page; the session lands in the user's own `~/.cloudflared/`, never in the app. Without pasted credentials, the wizard's submit also drives `cloudflared tunnel create` the same way.
_Avoid_: SSO, OAuth login (too generic), cloudflared login

### Sessions

**Session**:
An opencode conversation. A session lives on exactly one service at a time: the host's shared service, or one of an orb's.
_Avoid_: conversation (in UI copy), thread

**Active**:
A session whose agent is currently working (generating or running tools).
_Avoid_: busy, running

**Turn**:
One unit of agent work in a session; it ends when the agent goes from active to idle.
_Avoid_: request, exchange

**Permission**:
An approval request raised by the opencode agent during a turn; answered once, always, or rejected.
_Avoid_: prompt, consent

### Orbs

**Orb**:
A Docker container running its own opencode service on a dedicated clone of one project — the long-lived sandboxed workspace of that project.
_Avoid_: container (too generic), sandbox, devcontainer

**Orb session**:
A session hosted on an orb's service, as opposed to a session on the host's shared service.
_Avoid_: child session, subagent session (those are subagent sessions)

**Stop**:
Stopping an orb, without loss: the orb's sessions move to the host first.
_Avoid_: kill, terminate

**Wake**:
Bringing a stopped orb back up: workspace and branch untouched, and it starts with no old sessions — they live on the host.
_Avoid_: resume, restart

**Move**:
Transferring a session between the host and an orb, preserving the session's identity; after a move the session lives on exactly one service.
_Avoid_: transfer, sync, export/import (those are mechanisms)

### Views

**Structured view**:
The app view of a session (any row in the home list): messages, tools in flight, costs, permissions.
_Avoid_: message view, chat view
