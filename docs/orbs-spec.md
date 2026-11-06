# Orbs — consolidated feature spec

**Status**: locked. This is the hand-off spec of the Orbs feature for the implementation effort — its entry point.
**Source**: wayfinder map [#76 Orbs — spec: opencode agents coding in Docker sandboxes](https://github.com/NetAuraTech/OpenCodeBridge/issues/76). Every section cites the ticket that decided it (GitHub issue numbers). The tickets' resolution comments hold the full deliberation; this document is the consolidated, normative view.

**Domain**: Flutter app OpenCodeBridge; the **bridge** (server mode) is the single API of the app. The orb host is the machine running the bridge — local Docker, Windows and Linux (no WSL). Vocabulary: [`CONTEXT.md`](../CONTEXT.md) (Orb, Orb session, Stop, Wake, Move, Seed, Broken orb, Session, Project, Bridge, Server mode).

## 0. Standing invariants

1. **The bridge is the sole orchestrator of orb services.** The app talks only to the bridge (ADR-0001 position, extended to orbs). Users and agents never talk to an orb's service directly. The bridge shells out to the `docker` CLI, as it already does for compose actions.
2. **A session lives on exactly one service at a time** (the host's shared service, or one orb's). Moves preserve the session id and delete at the source after a successful import — no duplicates, ever.
3. **The host is authoritative** for `.env*` files and for opencode config+auth: copied into the orb on **every** start. Agent edits inside the orb never survive a wake.
4. **The remote is always the mirror of the orb branch**: a post-commit hook pushes after every commit.
5. **Orb state lives in Docker labels only** — no registry file. A second state store would drift from Docker's real state.
6. **Nothing is committed to the project repo** as preparation: the base image, boot scripts, and agent tools all live in global, app-owned locations.

## 1. Orb model

### 1.1 What an orb is

An **Orb** is a Docker container running its own opencode service (`opencode serve`) on a dedicated clone of one project, the clone living in a Docker volume. An orb is the project's **long-lived sandboxed workspace** ([#76](https://github.com/NetAuraTech/OpenCodeBridge/issues/76)).

Why its own opencode per orb (not the host's shared service): a sandbox means the agent's tools run where the agent process runs — the host's opencode cannot code inside a container without its shells running on the host. Hence `opencode serve` per orb; only the host's opencode config/auth are shared (copied in, zero setup), never the process.

### 1.2 Artifacts per orb

| Artifact | Naming | Notes |
|---|---|---|
| Container | carries the `ocb.*` labels (§2.1) | **Disposable**: workspace + history live in the volumes, so the container is recreated freely (image update, §2.8) |
| Workspace volume | named volume, labeled `ocb.*` | holds the clone, `.env*`, dependencies |
| Data volume | `orb-<id>-data` (labeled) | service state (postgres/redis/…); **not mounted into the workspace** — the agent reaches services by port only |
| State dir | `~/.config/opencodebridge/orbs/<id>/` → bind-mounted to the container's XDG data/state | the in-flight `opencode.db` survives container recreation ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83)) |
| Branch | `orb/<id>` on the remote | one per orb; the PR's head (§3) |

`<id>` is a short generated token (label `ocb.id`) — the technical identifier of the branch, the volumes, the state dir, and the labels. The user-facing handle is `ocb.name`.

### 1.3 Orb ↔ sessions

- An **orb session** is a session hosted on the orb's opencode service, as opposed to a session on the host's shared service. Subagent/child sessions of an orb session are part of it and move with it.
- Live orb sessions carry an **optional `orb` field** on the shared `Session` contract (absent on host sessions, including moved ones — §7.2).
- **Stop** moves an orb's sessions to the host as **plain host sessions** (no provenance badge; the PR is the story of the work) ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83)).
- A woken orb has no old sessions after a **clean** stop (they live on the host); its workspace and branch are untouched. After a **crash**, the bridge auto-wakes the orb and it resumes with its in-orb sessions ([#90](https://github.com/NetAuraTech/OpenCodeBridge/issues/90)).
- "New session in orb" = the existing new-session flow targeted at the orb's workspace ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83)).

### 1.4 Cardinality — several orbs per project

"Project" = the checkout the bridge knows, not the git repo: two checkouts of the same repo = two projects = two orbs possible. The **name is the handle, unique within the project**; creating with an already-taken name is refused (UI wizard and agent alike) ([#84](https://github.com/NetAuraTech/OpenCodeBridge/issues/84)).

Creation only happens where the project is known: the **UI wizard** (project + name) or **`orb_spawn` from a session** (the session knows its project — §8). Nested orbs (an agent inside an orb spawning more orbs) are allowed and are plain orbs — flat siblings, no special type, no cascade ([#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87), ADR-0007).

## 2. Lifecycle

### 2.1 State — Docker labels only, no registry file

The container **and** both volumes carry the labels ([#84](https://github.com/NetAuraTech/OpenCodeBridge/issues/84), extended by [#90](https://github.com/NetAuraTech/OpenCodeBridge/issues/90)):

| Label | Meaning |
|---|---|
| `ocb.orb=true` | marks the object as an orb artifact |
| `ocb.id` | short generated token — technical identifier |
| `ocb.name` | user-facing handle, **unique within the project** |
| `ocb.project` | project identifier as the bridge knows it |
| `ocb.branch` | `orb/<id>` |
| `ocb.created` | creation timestamp |
| `ocb.stopped` | clean-stop marker: set at the **end** of the stop path (after `docker stop`), removed on Wake |

No port label (the host port is ephemeral, §2.9). No registry file: the bridge is the OS and container + volumes are the primary artifacts.

### 2.2 Reconstruction at bridge startup

Enumerate labeled containers (`docker ps -a`, running + stopped) **plus** labeled volumes; compose the orb list ([#84](https://github.com/NetAuraTech/OpenCodeBridge/issues/84)). For each running orb: URL = ephemeral host port from `docker inspect`, password = last `server password` line of the orb's `docker logs` (§7.1).

- **Orphan** (labeled volume without container) → surfaced in the Orbs tab for **explicit** cleanup — never auto-deleted.
- **Broken orb** (container present, its workspace volume or state dir missing) → surfaced as **broken** (state named after the missing part), deletable, **never silently repaired** (§2.11).

### 2.3 Creation

Creation is refused up front with a clear message when: the name is taken in the project; the project has **no remote** or a **non-GitHub remote** (the push channel is gh-backed, §3) ([#80](https://github.com/NetAuraTech/OpenCodeBridge/issues/80), [#84](https://github.com/NetAuraTech/OpenCodeBridge/issues/84)).

Sequence (bridge-side, all steps bridge-owned):

1. Ensure the image exists (§5: compute expected tag `orb:<hash>`; missing → auto-`docker build`, logs streamed as events).
2. Create the workspace volume, the data volume `orb-<id>-data`, the state dir, and all labels.
3. Inject the host checkout's `.env*` into the workspace volume (always before start, §6.1).
4. Copy the host's opencode config+auth to the container-local config dir, including the bridge's URL for `host.docker.internal` (§6.2).
5. `docker run` with: `-p 127.0.0.1:0:<in-container-port>` (ephemeral host port, §2.9), `--add-host=host.docker.internal:<host IP>` (§8.5), the read-only `~/.ssh/` and `~/.config/gh/` mounts (§4), and the state-dir bind mount.
6. The container's first start runs the entrypoint's first-start path: clone, hook, installers (§6.3). Boot is health-gated (§6.5).
7. Read back the ephemeral host port (`docker inspect`) and the password (last `server password` log line) — the per-orb service descriptor (§7.1).

Clone source: the project's default branch, **or** a seed — the branch tip of another orb of the same project, read from the remote ([#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87), §3.3). The clone is **non-empty-dir-tolerant** because the injected `.env*` already occupy the workspace volume (§6.1).

### 2.4 Wake

Wake = re-run the full start path on the same container/volumes/state: `.env*` re-injection + config/auth re-copy (§6, host-authoritative), entrypoint (services + health gate; the first-start path is skipped — the clone exists), ephemeral port re-read, password re-read, session re-attach ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83), [#90](https://github.com/NetAuraTech/OpenCodeBridge/issues/90)). Remove the `ocb.stopped` marker. Wake is **lossless by construction** (nothing to lose: after a clean stop the orb holds no sessions; after a crash it holds its own, re-attached).

### 2.5 Stop — move to host (the single trigger)

**Stop is the single trigger for every orb death path** — manual stop, merged-PR end of life (§3.2), automated stop (§2.10). All of them run the same sequence ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83), ADR-0006). It is **unguarded** (lossless — the guard exists only on delete, §2.7):

1. **Export all** sessions — top-level plus child/subagent sessions, one by one: `OPENCODE_PASSWORD=<pw> opencode session export <id> --server http://127.0.0.1:<orb-port>` → JSON `{ info: { id, projectID, …, location: { directory } }, messages: […] }`.
2. **Import each to the host**: `opencode session import <file> --directory <host-checkout>` (connects to the host background service); **the same session id is preserved**; an id collision returns 409, handled gracefully → the operation is **idempotent**.
3. **Delete each session from the orb** — only after its import succeeded.
4. **`docker stop` last**, then set `ocb.stopped`.

Semantics:

- **Move = delete at the source after successful import** — a session lives in exactly one place; no duplicates on wake.
- **In-flight sessions are moved too**: the partial turn is preserved as history; continuation = a new turn from the host, on the host checkout.
- **Import target = the host checkout of that repo** — forced by the facts: the orb workspace is a Docker volume with no host path, so re-projecting onto the in-container path would create a phantom project. The session lands in the host project group.
- The host service becomes the **single archive of all orb history**.

### 2.6 Session move — the generic, service-agnostic primitive

`move(session, source, target, directory)` = export (source) → import (target, `--directory`) → delete (source). Works in both directions (verified end-to-end on opencode v2.1.4); same no-duplicate rule; import idempotent (409); source deleted only after import succeeds. One constraint: **the target service must be running** (import needs a live URL + password; `--directory` = the workspace path as seen from inside the target).

Uses:

- **Stop** (§2.5): orb → host, every session.
- **Host → orb move** (app action): goes **entirely through the bridge** — one action: the bridge guarantees the target orb is up (wake it if the record exists, otherwise create it, §2.3), then moves. Users never talk to an orb service directly.

### 2.7 Deletion — protected

**Guard**: deletion is **refused** when the tree is dirty — `git status --porcelain` non-empty (untracked included, ignored excluded) — **or** when commits not on any remote exist (unpushed — rare under the post-commit hook, real on push failure) ([#84](https://github.com/NetAuraTech/OpenCodeBridge/issues/84)).

"Safe" = clean tree + everything pushed to `orb/<id>` (work safe on GitHub, PR open or not). Explicit **force** overrides: a UI action for humans, `force: true` for agents ([#79](https://github.com/NetAuraTech/OpenCodeBridge/issues/79)) — the "discard the prototype without committing" case is the intended use of force, not an error case. The automated path **never** uses force (§2.10).

Delete = removal of the container + the workspace volume + the data volume + the state dir `~/.config/opencodebridge/orbs/<id>/` (nothing to release port-wise — the port is ephemeral). **Accepted consequence**: deletion wipes the service data volumes — the guard protects git work, not database content; the DBs are disposable dev state by design ([#89](https://github.com/NetAuraTech/OpenCodeBridge/issues/89)).

### 2.8 Image update — per orb, opt-in

Existing orbs keep their image until deletion; only new creations use a new image. An explicit per-orb **"update"** action = recreate the container on the same volume (workspace preserved — the code lives in the volume; the container is disposable). Never forced, no auto-migration on wake: the user picks the moment ([#81](https://github.com/NetAuraTech/OpenCodeBridge/issues/81)).

### 2.9 Ports — ephemeral, no allocation logic

`-p 127.0.0.1:0:<in-container-port>`; the host port is read from `docker inspect` at **every** start. No range, no pin, no allocation logic. The **in-container** port stays fixed — a single constant shared by the entrypoint (`opencode serve --port`) and the bridge (the `-p` mapping); it supersedes the "pinned host port" wording in [#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83) ([#84](https://github.com/NetAuraTech/OpenCodeBridge/issues/84)). The per-orb opencode API itself stands: the agent's tools run where the server process runs — the host's opencode cannot code inside the container; only the config/auth are shared.

### 2.10 Automated lifecycle — idle stop, TTL, cleanup

Automation lives in the **bridge**: a periodic lifecycle pass (~1 min, over all orbs) is the single actor. No new state: the idle clock is in bridge memory (reset on bridge restart — harmless, stop is lossless); the "stopped" clock is the container's last exit, read from `docker inspect`. Bridge down = no automation (already accepted by construction) ([#89](https://github.com/NetAuraTech/OpenCodeBridge/issues/89)).

1. **Idle & auto-stop.** An orb is **busy** if it has any **active** session **or any pending permission** — a pending approve/deny is a mid-turn state, the most fragile thing to carry in a move, so it keeps the orb alive. **Idle** = no busy session for **60 minutes** — a **fixed constant, no knob**. **Auto-stop is exactly the shared stop path** (§2.5): all sessions, in-flight included, move to the host; unguarded by construction.
2. **Stopped-TTL & cleanup.** A stopped orb becomes an auto-delete candidate after **24 h** stopped (clock = the container's last exit). The deletion guard (§2.7) is **re-evaluated on every pass**: a blocked orb is **kept, never forced** — the automated path never uses force; explicit force stays human/agent-only. Guard-blocked orbs are **surfaced**: the card (§9) gains a **"cleanup pending"** state with the reason (uncommitted / unpushed work), so a "blocked forever" orb is a visible state, not a silent leak.
3. **Merged-PR signal.** A merged PR does **not** stop the orb unconditionally — it must never yank a live conversation (an active session or a pending permission keeps the orb alive). The merged state only **bypasses the 24 h stopped-TTL**: the orb stops on the normal idle rule, and the pass following its stop deletes it if the guard passes. End-of-life at merge (§3.2) is preserved: a merged orb dies ~60 min after its last turn, without waiting the 24 h window.
4. **Orphaned variants.** No special auto-reaping, no auto-force: a losing seeded variant (PR closed unmerged, branch deleted) is reaped by the **parent agent** using its existing `force` permission on its spawn tree ([#79](https://github.com/NetAuraTech/OpenCodeBridge/issues/79)). Leak backstop: once the branch is gone from the remote, the orphan's commits read as "unpushed" to the guard, so a leaked orphan stays stopped with the "cleanup pending" badge and waits for a human force from the UI.
5. **User control — none today, architected for.** The thresholds (60 min, 24 h) are **named single-source constants** in the bridge (a knob = config field + UI, zero logic change), and the lifecycle pass consults **one per-orb exemption point** ("is this orb exempt from auto-cleanup?" — always no today). A future pin = answering that point yes, stored as a Docker label (§2.1 state, no registry file).

### 2.11 Recovery after crash / host reboot

**The bridge owns every start — no Docker restart policy** ([#90](https://github.com/NetAuraTech/OpenCodeBridge/issues/90)). At bridge startup, after the orb enumeration (§2.2), for every stopped orb:

- **Clean-stop label present** (`ocb.stopped`) → left stopped. The move already ran; no in-orb sessions.
- **Label absent** → the orb was running at crash/reboot time → the bridge **auto-wakes** it through the full start path (§6 injections, entrypoint, health gate). Its **in-orb sessions stay in the orb** (re-attach on the last `server password` log line) — faithful "the reboot never happened": no move at recovery, because a move would re-home the sessions to the host checkout without the user stopping the orb. A mid-turn session = partial turn preserved, continuable as a new turn. Boot failure of an auto-wake = the existing boot-failure states.

**Startup reconciliation**: the bridge already fetches every live session list at startup (home list). For each session id present on **both** the host and an orb, it **deletes the in-orb copy** (host canonical; import is 409-idempotent). This completes a stop interrupted by the crash (every session ends up exactly once, no direction recorded) and reverts a host→orb move interrupted by the crash (the session stays on the host; the user re-issues the move).

**Documented edges**: a manual `docker stop` outside the app leaves no label → the bridge wakes the orb at its next startup (the container belongs to the bridge); a manual `docker start` → the bridge simply attaches.

**Bottom line**: crash recovery needs **nothing beyond re-attach + move** — in-flight sessions need no special case.

## 3. Work retrieval

### 3.1 Branch model & commit convention

- **One branch per orb**: `orb/<orb-id>` — long-lived across the orb's life, **multiple tasks per orb**. No per-task branches ([#80](https://github.com/NetAuraTech/OpenCodeBridge/issues/80)).
- **Identity**: the host's global `user.name`/`user.email`, captured into the container-local gitconfig the entrypoint synthesizes (§4).
- **When to push**: a `post-commit` hook in the orb's clone pushes `HEAD` to `orb/<orb-id>` **after every commit** — the remote is always the mirror of the branch; the agent just commits. (Hook installation belongs to boot preparation, §6.3.)

### 3.2 The PR is the return channel

- The branch accumulates commits/pushes continuously from the first task.
- The **orb's agent opens the PR only once the work is done** — "done" is per task, and the work can span several tasks. On the task that completes the work, the agent runs `gh pr create` (head `orb/<id>`, **base = the branch the clone started from** — the remote's default branch for a fresh clone, or the seed parent's branch for a seeded one, §3.3) with the mounted gh auth; the task result includes the PR URL ([#80](https://github.com/NetAuraTech/OpenCodeBridge/issues/80), [#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87)).
- **One PR per orb**: later tasks push to the same branch, updating the same PR (never a second PR).
- **The agent never merges its own PR**; merging is human, the `implement-pr` rule applied as-is.
- **Post-merge semantics**: merging the PR = the work is done = the orb is at end of life (deletable — the deletion guard is satisfied; the automated path then applies, §2.10.3). **Safety net** if an orb outlives its work: **at the start of every task**, if the branch tip is an ancestor of the remote default (fully merged), the workspace resets to the new default; otherwise the task continues on the branch.

### 3.3 Seed — cloning from another orb

Creation gains an optional **`seed`** (orb name), agent-facing (`orb_spawn` argument; no UI field) ([#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87), ADR-0007):

- omitted → fresh clone of the project's default branch (unchanged);
- present → the new clone starts from the seed's **branch tip** (committed state of `orb/<id-B>`, read **from the remote** — the branch is always pushed, so the parent may be stopped); the new orb's branch `orb/<id-C>` is based on that tip;
- the seed is **git state only** — the uncommitted working tree is never in it (the durable state is the branch tip; an agent needing the exact current state commits first — the post-commit push flow). A parent whose branch was never pushed cannot be seeded (its state is the default branch anyway) → refused;
- the seed is **git state only**: the new orb's services start **empty** (clean base + its own migrations); copying the parent's data volume is an escape hatch, not spec;
- the new orb gets the full boot preparation (§6) — only the clone source differs.

**PR base** for a seeded orb: the PR targets the branch the clone started from — it stacks on the parent's branch (`orb/<id-C>` → `orb/<id-B>`). A winning variant merges into the parent; a losing one is force-deleted (the intended discard case of [#79](https://github.com/NetAuraTech/OpenCodeBridge/issues/79)) and, like any force-deleted orb, leaves its pushed branch on the remote (orphan-branch cleanup is owned by the automated lifecycle, §2.10.4).

### 3.4 `docker cp` export — the WIP escape hatch

Export = **tar.gz of the whole workspace** (untracked files included, `.git` included), placed **next to the project's local clone** on the host (the bridge knows the path from the session's project), deterministic timestamped name. Lossless: the user extracts and resumes exactly where the agent stopped ([#80](https://github.com/NetAuraTech/OpenCodeBridge/issues/80)).

Trigger: human (app action — §9) or agent (scoped to its spawn tree, §8.4).

## 4. git/gh authentication inside the orb

Mount the host's auth **surface**, never a specific key file ([#77](https://github.com/NetAuraTech/OpenCodeBridge/issues/77), locked in [#80](https://github.com/NetAuraTech/OpenCodeBridge/issues/80)):

- **Mounts** (whole directories, **read-only**): `~/.ssh/` + `~/.config/gh/`.
- The **orb entrypoint synthesizes a container-local gitconfig**: the host's commit identity (global `user.name`/`user.email`) + the git credential helper pointing at the container-local `gh` (in the base image).
- **Fallback** `ssh-keyscan github.com` when the mounted `known_hosts` has no entry for it.
- The **codebase is not mounted** (the clone lives in the orb's volume; work comes out via push / `docker cp`).
- This replaces the retired skill's `GH_TOKEN`/`insteadOf` mechanism.

Full findings: branch `research/host-git-gh`, file `docs/research/host-git-gh-config.md` (that branch).

## 5. Shared base image

### 5.1 Contents & versions

One image **for all projects** (the same base): node, npm, php, flutter, redis, postgres, typesense, mailhog, opencode, git — every one at an explicit version (Dockerfile ARGs with defaults). Versions **pinned** — no rolling latest; update = bump + (auto-)rebuild → new tag ([#81](https://github.com/NetAuraTech/OpenCodeBridge/issues/81)). The opencode version is **v2.1.4** — the version every orb mechanism was verified against ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83)).

### 5.2 Build context — the app-owned global files

- The app is a built binary — there is no OpenCodeBridge checkout on the host. The app **embeds** the orb build context (Dockerfile + boot scripts) and **materializes it at startup, create-if-missing**, in the app-owned directory `~/.config/opencodebridge/orb/` (the `docker build` context; same "app-owned files" pattern as the tunnel's `cloudflared.yml`). The repo copy stays the reviewed source at app-build time.
- **The on-disk build context is the single source of truth for image content** (not the app's embedded copy):
  1. **Updating the base = the user edits the global files** (bumping the pinned versions). An app upgrade never overwrites an existing file → pins are under user control, never under the running app version's.
  2. **No "stale image" warning**: the tag derives from a content hash of the context and the bridge builds the image when it is missing → the image is in sync with the files by construction. No stale state to report.
  3. **Reset = delete the files**: at next startup the app re-creates them from the embedded copy. No dedicated restore action.
  4. **Broken file** → the build fails, the streamed build logs show why; orb creation is blocked until fixed. No Dockerfile validation.

### 5.3 Building

The **bridge** builds:

- **Auto**: before orb creation, if the expected image is missing the bridge runs `docker build` (the bridge already shells out to the docker CLI for compose actions; build logs stream as events, like container logs). Zero setup for the user.
- **Explicit**: a "rebuild" UI action (Orbs tab, §9), for when the user bumped the pins and wants the image without creating an orb.

**Tag**: `orb:<hash>` — `<hash>` is a short hash of the **whole build context** (Dockerfile + scripts): the scripts evolve (their content is §6's) and are part of the image. Content ↔ tag 1:1; the bridge computes the *expected tag* without comparing anything — missing = build.

## 6. Boot preparation

Division of labor: the **bridge** (host side, before every start) and the **entrypoint** (in-orb; runs on **every** container start — create *and* wake) ([#82](https://github.com/NetAuraTech/OpenCodeBridge/issues/82), with [#80](https://github.com/NetAuraTech/OpenCodeBridge/issues/80), [#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83), [#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87)).

### 6.1 `.env*` injection — bridge, every start

Before `docker start`, the bridge copies the host project checkout's `.env*` files (`.env` + `.env.*`, **excluding** `*.example`) into the orb's **workspace volume**. **Always-on** — no disable knob. The host is **authoritative**: the copy is overwritten from the host on every start, so agent edits to `.env` inside the orb do not persist across a wake. The container mounts **no part** of the host checkout (sandbox: the orb sees no host tree).

*Consequence*: at create, the workspace volume already holds the injected `.env*` when the clone runs, so the clone must be **non-empty-dir-tolerant** (`git init` + fetch + checkout, or clone-into-temp + move); plain `git clone <url> /workspace` would fail on the non-empty dir.

### 6.2 Config/auth copy — bridge, every start

The host's opencode **config + auth** are **copied to a container-local config dir** at every start (host-authoritative; no concurrent-write contention) ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83)). The bridge additionally writes its **URL** into that config at every copy — the address orbs use to reach the bridge via `host.docker.internal` (§8.5).

The staged copy is **rewritten for container networking** ([#117](https://github.com/NetAuraTech/OpenCodeBridge/issues/117)): every `http(s)` URL whose host is the loopback (`localhost`, `127.0.0.1`, `0.0.0.0`) — provider `baseURL`, MCP server URLs — becomes `host.docker.internal` on the same port/path: inside the container `localhost` is the container itself, so a host-local provider (llama.cpp/llama-swap…) would be dead in every orb. Remote URLs pass through untouched; the **host config file is never modified** (host-authoritative — the rewrite lives only in the staged copy).

### 6.3 First start — clone, hook, installers — entrypoint, create only

On the container's first start (the workspace volume holds only the injected `.env*`):

1. **Clone** (non-empty-dir-tolerant, from the default branch or the seed, §2.3/§3.3).
2. **Install the `post-commit` hook** (push `HEAD` to `orb/<id>` after every commit, §3.1).
3. **Run the installers** — non-fatal (log + continue), triggered purely by file presence in the clone:
   - npm: `npm ci` if `package-lock.json`, else `npm install` (npm only — no yarn/pnpm; that would be a base-image concern, §5);
   - composer: `composer install` if `composer.json`;
   - flutter: `flutter pub get` if `pubspec.yaml`.

Installers run **once, at create** (deps live in the persistent workspace volume; re-running on every wake is slow and redundant).

### 6.4 Local services — entrypoint, every start

postgres, redis, typesense, mailhog — started **only when declared** by `.env*` local-host detection (host ∈ {127.0.0.1, localhost, ::1}; other hosts logged + ignored):

- The service binds to the **host:port the app's `.env` expects** — 127.0.0.1 **inside the container**, port from the `.env` when present else the service's conventional default (5432 / 6379 / 8108 / 8025) — so app code and `.env` work unmodified. Bound inside the container ⇒ no host port collision, no dynamic allocation.
- **Data**: the dedicated named volume `orb-<id>-data`, **not mounted into the workspace** — the agent reaches services by port only and cannot see or tamper with raw service state. Survives container recreation (the per-orb "update").
- **Idempotent**: health-check before start (`pg_isready`, `redis-cli ping`, service health endpoints).
- **Provisioning from `.env`**: postgres role/DB creation (`PG_USER` / `PG_PASSWORD` / `PG_DB_NAME`); typesense data-dir + API key from `.env`; mailhog no credentials.

### 6.5 Health gate — entrypoint, every start

After starting the declared services, the entrypoint waits until **all** declared services report healthy (per-service timeout ~30 s, a constant in the boot script) and only then `exec opencode serve` (in-container port fixed, §2.9). If a declared service is not healthy within the timeout, the entrypoint **exits non-zero**: the orb boot **fails** and the bridge surfaces the failure + container logs. An `.env*` declaring no services means no gate (opencode starts immediately).

**Deliberate asymmetry**: an installer failure is **non-fatal** (a missing dep doesn't brick the orb — the agent can install it), but a declared service failing to boot is **fatal** (the app would be broken, so the orb must not come up "ready").

### 6.6 Config location — scripts-as-config

Unified in the image: the boot scripts (with the Dockerfile) live in the app-owned build-context dir (§5.2) and are **baked into the image** (part of the tag hash). **scripts-as-config**: changing boot behavior = editing those global files (the §5 "edit the files" model) — no separate knobs file, no app/bridge settings surface for boot prep. The global opencode plugin tool (§8) stays in `~/.config/opencode/plugins/`, untouched — two config domains, each file where its reader finds it.

## 7. Bridge architecture

### 7.1 Per-orb service descriptor — no descriptor file

There is **no descriptor file to read**: a directly-invoked `opencode serve` writes no `service.json` (verified on v2.1.4 with an isolated XDG state home) ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83)). The per-orb descriptor — **URL + password** — is derived at **every** start:

- **URL** = `http://127.0.0.1:<host-port>`, host port ephemeral from `docker inspect` (§2.9);
- **password** = the **last** `server password <pw>` line of the orb's `docker logs` (`opencode serve` prints it to stdout; every start/respawn generates a new password — the last line wins);
- **Auth**: v2 API Basic `opencode:<pw>`; CLI operations with `--server` require the `OPENCODE_PASSWORD=<pw>` env (verified).

### 7.2 Session aggregation & routing

- Per-session routing via an in-memory `sessionID → service` table (host shared service + each running orb) ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83)).
- The shared `Session` contract gains an **optional `orb` field** (present on live orb sessions, absent on host sessions — including moved ones).
- **Main list**: orb sessions are **flat rows in the existing project groups**, wearing a tappable orb chip that navigates to the orb's card (UI, §9.2 — [#85](https://github.com/NetAuraTech/OpenCodeBridge/issues/85) supersedes the earlier "one group per orb" wording).
- `active` = merged across live services (`activeSessionIds()` union).
- **No special permission handling**: in-orb permission requests get the same approve/deny banner as host ones.
- The **spawn tree** (parent/child agent↔orb links) is bridge-internal state keyed by **session id** (preserved across moves, so the session that spawned an orb keeps control of it after being moved to the host) — used for permissions only, never shown ([#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87)).

### 7.3 Events — the composite event service

- **Composite `OpencodeEventService`**: one self-healing upstream `GET /api/event` per live service (the host shared service + each running orb) ([#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83)).
- **Raw pass-through, no envelope** — session ids are globally unique across services.
- `EventHub`, the SSE contract, and the push dispatcher are **unchanged**.
- Orb events also drive push notifications.

### 7.4 Registries

Models/agents/skills registries are exposed **once** (identical across orbs — the host config is copied into every orb, §6.2).

### 7.5 Bridge contract changes (summary)

1. Per-orb service access: ephemeral host port (`docker inspect`) + password (last `server password` log line) + Basic auth; `OPENCODE_PASSWORD` for CLI operations (export/import, §2.5/§2.6).
2. Composite, self-healing multi-upstream event service (raw pass-through).
3. Cross-service session-move primitive (`export → import --directory → delete`): used by the stop flow (orb → host) and by the move action (host → orb, bridge-guaranteed target up-state).
4. `Session.orb` optional field on the shared contract.
5. In-memory `sessionID → service` routing table.
6. Orb lifecycle ownership: creation, wake, stop, delete, image build/update, labels, the ~1-min lifecycle pass (§2.10), and startup recovery (§2.11) — the bridge owns every start.

## 8. Agent-facing spawn surface & contract

### 8.1 The surface — a global opencode plugin tool

A global opencode **plugin** (a dependency-free TypeScript file in `~/.config/opencode/plugins/` exporting `{ id, setup }` and registering the tools through `ctx.tool.transform`) that calls the **bridge's HTTP API** (localhost) — the tool never talks to Docker directly. No MCP server, no CLI command ([#79](https://github.com/NetAuraTech/OpenCodeBridge/issues/79); extension-point research: [#78](https://github.com/NetAuraTech/OpenCodeBridge/issues/78), branch `research/opencode-agent-tools`, file `docs/research/opencode-agent-tools.md` (that branch)). A v1 `tools/` file (the `tool()` helper shape) is *not* loaded by opencode v2 servers (verified on v2.1.4) — the plugin dir is where v2's reader finds agent tools.

Global placement on purpose: no scripts committed to any repo (spirit of the global preparation), and **every orb's opencode inherits the tool** through the host config copied at every start (§6.2) — which is also what makes nested spawning work ([#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87)).

### 8.2 `orb_spawn`

Idempotent **wake-or-create** on the project's workspace orb. The project is **not** an argument: the session knows it. The spawn itself is async — the tool returns an orb handle immediately.

| Argument | Required | Meaning |
|---|---|---|
| `task` | yes | Free text given to the orb's agent |
| `model` | no | Default = the calling session's model |
| `wait` | no | Boolean, default `true`: when true the tool blocks until the task completes and returns the structured result; when false the tool returns the orb handle immediately |
| `orb` | no | **Name** of the target orb ([#84](https://github.com/NetAuraTech/OpenCodeBridge/issues/84)) — see targeting below |
| `seed` | no | **Name** of the orb to clone from ([#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87)) — see §3.3 |

**`orb` targeting**: omitted → the project's single orb (wake it); several orbs exist → the tool **refuses and lists** the project's orbs (the agent retries with an explicit name); none → **create** (name derived from the task). An explicit name not yet taken → **additional orb** (fresh clone, fresh `orb/<id>` branch), attached to the calling agent's spawn tree.

### 8.3 `orb_wait` & completion

- `orb_wait` — blocks until the orb's task completes; returns the structured result: **status, summary, results, dedicated branch name** — and the **PR URL** once the work is done ([#80](https://github.com/NetAuraTech/OpenCodeBridge/issues/80) refinement of the [#79](https://github.com/NetAuraTech/OpenCodeBridge/issues/79) contract).
- **Async path**: when the task completes, the bridge (which aggregates the orb's opencode session) **injects a message** into the calling session ("Orb X done — work on branch `orb/<id>`"). The work itself comes back via commit/push on the dedicated branch (the primary channel, §3), not via the tool.
- **Calling session ends before the orb finishes**: the orb keeps running (it is the project's workspace, not an ephemeral process); the result is persisted; the notification to a dead session is dropped. Cleanup of such orphaned orbs belongs to the lifecycle (§2.10).

### 8.4 Permissions — scoped to the spawn tree

The agent has full rights — spawn, wait/status, stop, delete, `docker cp` export — but they are **scoped to its spawn tree**: the orbs it spawned itself or had its subagents spawn. An agent never stops, deletes, or exports another agent's orb (nor one created by the human in the app). The tree is **transitive with no depth limit** (A spawns B, B spawns C ⇒ C is in A's tree; B's agent cannot stop B — its own orb is outside its tree); the human is unrestricted ([#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87)).

**Deletion guard**: applied to the agent exactly as to the human (refused when changes are uncommitted, §2.7), overridable with an explicit `force: true` — the "prototype not kept, I discard without committing" case is the intended use of `force`, not an error case.

### 8.5 Orb → bridge networking

Every orb (even one spawned from a host session) calls `orb_spawn`/`orb_wait` from inside a container, where localhost is not the host. Orbs reach the bridge via **`host.docker.internal`** (`--add-host=host.docker.internal:<host IP>`); the bridge writes its URL into the container-local config at every copy (§6.2) ([#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87)).

## 9. UI

Variant B "**Workspace cards**" — decided by the user after poking the prototype (branch [`prototype/orbs-ui`](https://github.com/NetAuraTech/OpenCodeBridge/tree/prototype/orbs-ui), throwaway, in-memory mock) ([#85](https://github.com/NetAuraTech/OpenCodeBridge/issues/85)).

### 9.1 The Orbs tab — workspace cards

A grid of **workspace cards** (280 px). **The card is the view of the orb — no detail screen**:

- state dot + word (the current boot stage while preparing);
- `project · branch`;
- the session count;
- a **PR badge** when the PR is open;
- the actions **on the card itself**: **Wake/Stop** (gated by state), **New session in the orb**.

### 9.2 Orb sessions in the main list

**Flat rows, no nesting**: the project groups stay as they are. Orb sessions are plain rows wearing a **tappable orb chip** (state dot + orb name) — tapping the chip **highlights the card** in the Orbs tab (the session → orb navigation). Host sessions wear a muted "host" label. No per-orb subgroups, no filter banner (see also §7.2 — [#85](https://github.com/NetAuraTech/OpenCodeBridge/issues/85)).

### 9.3 The create-orb flow

**FAB → bottom-sheet wizard**: the project + the orb name first, then the **live staged boot log in the sheet** as the prep stages run — the sheet stays open while the orb boots, the card appears in the grid behind it. No pushed screen, no dedicated entry in the Sessions tab.

### 9.4 Orb states (card)

- **preparing** (amber) — the current boot stage is shown as the state word;
- **running** (green);
- **stopped** (grey);
- **cleanup pending** (badge + reason — uncommitted / unpushed work) for guard-blocked auto-delete candidates (§2.10.2);
- **broken** — names the missing part (workspace volume / state dir); no Wake/Stop/New session; actions: **force-delete** (always) and, when only the state dir is missing, **start with fresh state** — a normal Wake with a fresh `opencode.db`: keeps the workspace (uncommitted work included), loses the in-orb sessions (stated in the confirmation dialog) (§2.11, [#90](https://github.com/NetAuraTech/OpenCodeBridge/issues/90)).
- Orphaned volumes (labeled volume without container) are surfaced for **explicit** cleanup — never auto-deleted (§2.2).

**Stop** renders per the vocabulary: it moves the orb's sessions to the host first, as plain host sessions with **no provenance** shown in the UI; **Wake** re-runs only the service stages.

### 9.5 Lifecycle actions (surface)

On the card: Wake / Stop / New session / per-orb **update** (recreate on the image, §2.8) / **force-delete**. Global (Orbs tab): image **rebuild** (§5.3). On the session row / detail: **`docker cp` export** (§3.4) and the **host → orb move** action (§2.6 — one action, entirely through the bridge).

## 10. Out of scope

Ruled beyond this effort (map [#76](https://github.com/NetAuraTech/OpenCodeBridge/issues/76)):

- **Portals** (exposing the orb's web servers by URL, comments to the agent).
- **Terminal inside the orb** (interactive terminal sharing the filesystem + the agent's tmux).
- **Dedicated Secrets & Env store** — env comes from the repo's `.env*` via the preparation, no vault.
- **Bidirectional sync** a la `amp sync` (mirror orb ↔ local checkout while the agent works).
- **`.agents/setup` / `.agents/resume` scripts committed to the repo** — the preparation is global, not committed to git.
- **Multi-host / orb snapshots** (image snapshots a la `docker commit`, recreating an orb on another host).
- The **old `orbs` skill** (WSL / Git Bash / Herdr) — leftover, inspiration only, not a base.

## 11. References

### Decided tickets (map #76)

| Ticket | Decision |
|---|---|
| [#77](https://github.com/NetAuraTech/OpenCodeBridge/issues/77) (research) | Host git/gh auth: mount the auth surface (`~/.ssh/` + `~/.config/gh/` RO), synthesized container gitconfig |
| [#78](https://github.com/NetAuraTech/OpenCodeBridge/issues/78) (research) | opencode extension points: custom tools recommended |
| [#79](https://github.com/NetAuraTech/OpenCodeBridge/issues/79) | Agent spawn surface & contract: global custom tool `orb_spawn`/`orb_wait` on the bridge HTTP API |
| [#80](https://github.com/NetAuraTech/OpenCodeBridge/issues/80) | Work retrieval: `orb/<id>` branch, post-commit push, PR as the return channel, `docker cp` export |
| [#81](https://github.com/NetAuraTech/OpenCodeBridge/issues/81) | Shared base image: app-owned build context, `orb:<hash>`, pinned versions, per-orb update |
| [#82](https://github.com/NetAuraTech/OpenCodeBridge/issues/82) | Boot preparation: `.env*` injection, installers, local services, health gate, scripts-as-config |
| [#83](https://github.com/NetAuraTech/OpenCodeBridge/issues/83) | Bridge aggregation: per-orb service access, composite events, move-on-stop, routing |
| [#84](https://github.com/NetAuraTech/OpenCodeBridge/issues/84) | Lifecycle & state: Docker labels only, ephemeral ports, several orbs per project, deletion guard |
| [#85](https://github.com/NetAuraTech/OpenCodeBridge/issues/85) | UI: variant B "Workspace cards" (Orbs tab, flat rows with orb chip, FAB wizard) |
| [#87](https://github.com/NetAuraTech/OpenCodeBridge/issues/87) | Nested orbs: flat siblings, seed, stacked PR base, no cascade |
| [#89](https://github.com/NetAuraTech/OpenCodeBridge/issues/89) | Automated lifecycle: ~1-min bridge pass, 60-min idle auto-stop, 24-h TTL, merged-PR bypass |
| [#90](https://github.com/NetAuraTech/OpenCodeBridge/issues/90) | Recovery: bridge owns every start, `ocb.stopped` marker, startup reconciliation, broken orb |

### ADRs

- [ADR-0006](adr/0006-orb-stop-moves-sessions.md) — stop moves sessions to the host; cross-service move preserves identity.
- [ADR-0007](adr/0007-nested-orbs-are-flat-siblings.md) — nested orbs are flat siblings; spawn tree without cascade.

### Research & prototype assets

- Branch `research/host-git-gh` → `docs/research/host-git-gh-config.md` (host git/gh configuration, auth mechanism).
- Branch `research/opencode-agent-tools` → `docs/research/opencode-agent-tools.md` (opencode v2.1.4 extension points for the spawn tool).
- Branch `prototype/orbs-ui` → throwaway Flutter prototype of the UI (variant B), `app/lib/ui/prototype/` — a pointer to react against, not code to fold in.

### Known risks

- The stop/recovery design depends on opencode's **session export/import endpoints** (experimental API surface, v2.1.4): if opencode removes them, the **stop sequence** — not the orb model — is what breaks (ADR-0006).
- The image pins opencode **v2.1.4**; all verified mechanisms (no descriptor file, password log line, export/import, 409 idempotency) were verified against that exact version.
