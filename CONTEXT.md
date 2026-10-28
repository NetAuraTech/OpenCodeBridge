# OpenCodeBridge

A single cross-platform app that controls opencode and Docker on a host PC from a phone or desktop: viewing and interacting with opencode sessions in real time, launching new sessions, and monitoring Docker containers.

## Language

**Session**:
One agent conversation in the opencode service.
_Avoid_: conversation, chat

**App-launched session**:
A session started by the app, for which the bridge opened a terminal window on the PC.
_Avoid_: managed session, spawned session

**External session**:
A session started elsewhere, e.g. by a manual TUI on the PC.
_Avoid_: remote session, foreign session

**Terminal view**:
The app's live, interactive view of an app-launched session: the content of its terminal.

**Structured session view**:
The app's view of an external session: messages, tools in flight, costs, permissions, and message input.

**Active**:
A session whose agent is currently working (generating or running tools).

**Turn**:
One unit of agent work in a session; it ends when the agent goes from active to idle.

**Closed session**:
An app-launched session whose terminal window has been closed; kept on the opencode server, resumable, hidden from the main list.
_Avoid_: terminated session, archived session

**Bridge**:
The server-side of OpenCodeBridge embedded in the desktop app's server mode.

**Server mode / Client mode**:
The two launch modes of the desktop app: hosting the bridge (and the tunnel), or connecting to a host.

**Permission**:
An approval request raised by the opencode agent during a turn, answered once, always, or reject.

