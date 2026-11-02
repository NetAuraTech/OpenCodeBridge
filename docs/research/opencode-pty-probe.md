# opencode persistent-PTY probe (live)

Research for ticket #7 "Shape of the bridge API" — question Q3: *who owns the PTY* for the terminal view (bridge-local PTY vs. service-owned PTY proxied by the bridge).

Unlike the earlier spec-reading pass, **every claim below was verified live** against the running service.

- Service: opencode v2.1.4, `serve --service` on `http://127.0.0.1:49374`, Basic auth (service.json).
- Artifacts: throwaway sessions and PTYs only. All deleted at the end (verified: `DELETE` → 204, pty list empty, no leftover `opencode --session ses_e7b9*` processes).

## Findings (all live-verified)

### 1. The service can host the TUI in a session-bound persistent PTY

`POST /api/experimental/session/{sessionID}/terminal` with body `PersistentPty.CreateInput`
(`command`, `args`, `cwd`, `title`, `env`, `size`) creates a persistent PTY **bound to the session** and returns `PersistentPty.Info`:

```json
{"id":"pty_persistent_4978265888717649","title":"OC | probe-tui2","command":"opencode",
 "args":["--session","ses_e7b953d46ffeqdue8TvVJYVvOO"],"cwd":"…/opencodebridge",
 "status":"running","pid":406903,"sessionID":"ses_e7b953d46ffeqdue8TvVJYVvOO",
 "foregroundProcess":"opencode","size":{"cols":120,"rows":30},
 "output":{"head":0,"tail":103156}}
```

With `command=opencode, args=["--session", <id>]`:

- The TUI **renders** (output ring reached 103 KB within ~7 s, growing afterwards).
- The service captures the terminal title from the OSC sequence (`"OC | probe-tui2"` — the TUI set it).
- `foregroundProcess` reports `"opencode"`.
- The child process connects to the service (ESTAB socket observed) and receives `OPENCODE_TERMINAL=1` injected into its environment.

`GET /api/experimental/session/{sessionID}/terminal` lists the session's PTYs; `terminal/read?lines=N` exists (see quirk 7.3).

### 2. The PTY child survives with zero viewers

A `sh -c 'while true; do date >> out.log; sleep 1; done'` pty kept running with **no WS viewer attached**: 172 log lines written, `status: "running"` throughout. Child lifecycle is decoupled from viewers.

### 3. Attach / WebSocket protocol (end-to-end)

1. `POST /api/experimental/persistent-pty/{ptyID}/connect-token` with header
   **`x-opencode-ticket: 1`** → `{"data":{"ticket":"<uuid>","expires_in":60}}`.
   The header value `1` is a *marker*, not a credential — it is literally what the opencode web UI ships (`x-opencode-ticket:`1`` in the client bundle). It designates a native/same-host client. A real pairing token (`POST /api/pair` → `GET /auth/connect/<code>` → token) sent in this header is **Forbidden** on this endpoint.
2. `GET /api/experimental/persistent-pty/{ptyID}/connect?ticket=<ticket>` opened as a WebSocket (`ws://…`, raw binary frames, `binaryType=arraybuffer`):
   - Frame 1 (JSON): `{"type":"attached","attachmentID":"…","inputProtocol":0,"info":<PersistentPty.Info>,"role":"controller","generation":3,"replay":{"requestedOffset":0,"availableOffset":2828014,"endOffset":4925166,"truncated":true}}`
   - Then a **raw ANSI replay** of the output ring (2 MB chunk; `truncated:true` when history exceeds the window).
   - Then `{"type":"replay_complete","endOffset":4925166}` — `endOffset` is the resumable cursor (`?cursor=` on connect).
   - Then **live ANSI frames** (TUI re-rendering observed in the stream).
3. Connect also accepts `role`, `takeover`, `input_protocol`, `attachment_id` query parameters.

### 4. Round-trip input verified

Sending `probeinput` as a raw WS text frame (1.5 s after attach) made the text appear in the TUI's input box, confirmed by the next snapshot (the first attach holds `role:"controller"`, i.e. it may send input).

### 5. Snapshot

`GET /api/experimental/persistent-pty/{ptyID}/snapshot` → `{info, text, checkpoint}`:

- `text` = the **current physical screen decoded as plain text** (not raw scrollback) — 442 chars, enough to see the TUI layout and to assert what is on screen.
- `checkpoint` = base64 token for WS re-attach/resumption.

### 6. Multi-viewer is a native service feature

`attached` carries `role` (first attachment = `controller`), `attachmentID`, `generation`; connect takes `role`/`takeover`/`input_protocol`/`attachment_id`. Controller arbitration, takeover, and replay are enforced **by the service**. A proxying client does not implement any of it.

### 7. Quirks / weaker surfaces

1. **`POST /api/pty` (non-persistent) is a different, weaker class**: PTYs created there are *not* session-bound, `GET …/snapshot` returns `PtyNotFoundError`, and they do not support the session terminal flow. Do not build the terminal view on `/api/pty`.
2. **Bulk disappearance observed**: all `/api/pty` PTYs I had created vanished at once (status gone, log stream stopped) without any `DELETE` from me, while the service itself stayed up and the user's real TUI session was untouched. Exact eviction mechanism unverified (suspected instance-scoped cleanup) — another reason to use session-bound persistent PTYs, which stayed alive throughout the probe.
3. **Spec/runtime mismatches**: `PersistentPty.CreateInput.env` is *required* at runtime despite the schema marking it optional (400 `Missing key at ["env"]` without it); `GET /api/pty/{id}` returns the **whole list** (path segment ignored); `terminal/read?lines=N` returned `data:null` for a plain Basic-auth client (possibly needs a paired-instance token; not pursued — the WS attach path covers the need).

## Implication for Q3

Everything the bridge's terminal view needs is provided natively by the service:

- hosting the TUI (`opencode --session <id>`) in a persistent PTY bound to the session,
- survival with no viewers (Closed-session reopen works),
- attach with replay + resumption (`cursor`/`checkpoint`),
- controller/viewer arbitration and takeover,
- screen snapshots for fast first paint.

Option (b) — *service-owned persistent PTY, bridge proxies* — is therefore fully supported and verified. Option (a) — *bridge-local PTY (forkpty)* — would have the bridge re-implement replay, scrollback, and multi-viewer control that the service already provides.

The bridge runs on the host, on the same machine as the service, so it can use the native marker `x-opencode-ticket: 1` for `connect-token` (no pairing needed).

## Not verified (honesty list)

- The exact eviction mechanism that wiped the `/api/pty` PTYs (only the observation is verified).
- `terminal/read` under a paired-instance token (returned null with plain Basic auth).
- Input semantics under `input_protocol` values other than 0 (only protocol 0 was exercised).
- Handoff (`POST /api/experimental/persistent-pty/handoff`) — spec only; not needed for the bridge design as long as the bridge itself is the attach client.
