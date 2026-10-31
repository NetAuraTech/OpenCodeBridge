# OpenCodeBridge

A cross-platform app (Android first, desktop Linux/Windows) for viewing and controlling, in real time, opencode sessions and Docker containers running on a host PC.

## Language

### The bridge

**Bridge**:
The HTTP service embedded in the desktop app (server mode) that is the single API the app consumes: sessions, terminal, Docker, events. The app talks only to the bridge, in every mode and on every machine.
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
The in-app, server-mode wizard that collects the tunnel name, public hostname, and pasted credentials and has the bridge write the app-owned files, then re-checks and (re)starts the tunnel.
_Avoid_: setup wizard, tunnel wizard, onboarding

### Sessions

**Session**:
An opencode conversation on the host's shared opencode service.
_Avoid_: conversation (in UI copy), thread

**App-launched session**:
A session whose terminal window was opened by the bridge on the host.
_Avoid_: owned session, tracked session

**External session**:
A session started manually by the user in a terminal, never launched by the bridge.
_Avoid_: manual session, foreign session

**Closed session**:
An app-launched session whose terminal window has been closed; the session remains on the opencode service and can be reopened in a new window.
_Avoid_: dead session, finished session

**Active**:
A session whose agent is currently working (generating or running tools).
_Avoid_: busy, running

**Turn**:
One unit of agent work in a session; it ends when the agent goes from active to idle.
_Avoid_: request, exchange

**Permission**:
An approval request raised by the opencode agent during a turn; answered once, always, or rejected.
_Avoid_: prompt, consent

### Terminal window

**Terminal window**:
The physical window on the host opened by the bridge, hosting the attach client of one session's terminal.
_Avoid_: shell, console

**Attach client**:
The process running inside the terminal window that displays and drives the session's terminal through the bridge.
_Avoid_: terminal client, viewer

### Views

**Terminal view**:
The app view of an app-launched session: the live content of the host terminal, interactive.
_Avoid_: terminal session, raw view

**Structured view**:
The app view of an external session: messages, tools in flight, costs, permissions.
_Avoid_: message view, chat view
