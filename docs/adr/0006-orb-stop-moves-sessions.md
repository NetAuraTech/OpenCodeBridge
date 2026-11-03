# ADR-0006: Orb stop moves sessions to the host — cross-service session move preserves identity

- **Status**: accepted (2026-11-03, ticket #83, map #76)

## Context

An orb hosts its sessions on its own opencode service (the sandbox: the agent's tools run where the agent process runs). The obvious stop is a plain `docker stop`, but the orb's session history lives in the orb's service database — a plain stop would strand it, and an orb deleted or re-created after an image update would lose it.

The user requirement is explicit: in-flight or finished orb sessions must never be lost, for the history ("je veux pas perdre la session (en cours ou terminé) pour avoir un historique").

opencode v2.1.4 (the base-image version) provides the cross-service move, verified end-to-end on isolated scratch services: `opencode session export <id> --server <orb-url>` yields `{ info: { id, …, location: { directory } }, messages: […] }`, and `opencode session import <file> --directory <dir>` re-hosts the session **with the same session id** (an id collision returns 409, handled gracefully — the operation is idempotent), re-projecting it onto the project of `--directory`.

## Decision

- **Stop is the single trigger** for every orb death path: manual stop, merged-PR end of life (ticket #80's one-PR-per-orb rule), and the future automated stop. All of them run the same sequence.
- The sequence is **crash-safe and ordered**: export all sessions (top-level plus child/subagent sessions, one by one) → import each to the host service (`--directory` = the host checkout of that repo) → delete each from the orb, only after its import succeeded → `docker stop` last.
- **Move = delete at the source after successful import**: a session lives on exactly one service at a time (the host or one orb). No duplicates, ever; a woken orb has no old sessions.
- **In-flight sessions are moved too**: the partial turn is preserved as history; continuation is a new turn from the host, on the host checkout.
- **Move is a generic, service-agnostic primitive** (`export → import --directory → delete`), used in both directions. The host→orb move is a bridge action: the bridge guarantees the target orb is up (wake it, or create it per the lifecycle ticket #84), then moves. Users never talk to an orb service directly — the bridge is the sole orchestrator of orb services, extending the ADR-0001 "the app talks only to the bridge" position.
- Moved sessions are **plain host sessions** in the host project group — no orb provenance (the PR is the story of the work).

## Consequences

- The host checkout of a repo is the only meaningful import target: the orb workspace is a Docker volume with no host path, so re-projecting onto the in-container path would create a phantom project.
- The host service becomes the **single archive of all orb history**; import idempotency (409) makes the archive safe to re-run.
- A woken orb starts empty of sessions but with its workspace and branch untouched — history lives on the host, work continues where it left off.
- Recovery after crash/host reboot can reuse this sequence: orb sessions persist in the bind-mounted per-orb state volume, and re-wake re-attaches to the orb's service; moving them to the host is the same primitive.
- The move depends on opencode's session export/import endpoints (experimental API surface): if opencode removes them, the stop sequence — not the orb model — is what breaks.
