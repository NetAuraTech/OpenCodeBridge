# ADR-0007: Nested orbs are flat siblings — spawn tree without cascade

- **Status**: accepted (2026-11-03, ticket #87, map #76)

## Context

The spawn contract (#79) puts the `orb_spawn` tool in the global opencode config, which is copied into every orb — so an agent **inside** an orb already has the spawn tool, and the permission model (#79) already presupposes a spawn tree. The open question (ticket #87): whether an in-orb agent may spawn orbs at all, and if so what a nested orb is, how it appears in the app, who controls it, and what happens when the parent stops.

The user's driving scenario: an agent inside an orb B of project P wants an isolated copy of P carrying the work-in-progress, to test a variant.

## Decision

- **Allowed, no special type**: a nested orb is just an orb — a sibling container with its own volume, its own services, its own `orb-<id>-data` volume, its own branch and its own PR. No container nesting, no network nesting, no UI depth: the only link to the parent is the spawn tree (bridge-internal, for permissions only).
- **Creation is parameterized by a `seed`** (optional orb name on `orb_spawn`): omitted → fresh clone of the project's default branch (unchanged); present → the new clone starts from the parent's **branch tip** (committed state, read **from the remote** — the branch is always pushed, #80 — so the parent may be stopped). The seed is **git state only**: no uncommitted working tree (the durable state is the branch tip; an agent that needs the exact current state commits first — the post-commit push flow, #80), no service data (the new orb's services start empty: clean base + its own migrations). Full boot preparation (#82) — only the clone source differs. A parent whose branch was never pushed cannot be seeded from (its state is the default branch anyway) → refused.
- **The PR base is the branch the clone started from**: a seeded orb's PR stacks on the parent's branch (`orb/<id-C>` → `orb/<id-B>`) — a winning variant merges into the parent, a losing one is force-deleted (the intended discard case of #79). Unseeded orbs target the default branch (unchanged).
- **No cascade on stop**: stopping B does not stop C. Stop stays per-orb and unguarded (#84) — ADR-0006's single-trigger model keeps one death path. C keeps running as an independent workspace; its completion still reaches the calling session (moved to the host, same session id, #79/#83). Orphan reaping belongs to the automated lifecycle (#89).
- **The tree is transitive and unbounded**: A spawns B, B spawns C ⇒ C is in A's tree (A can stop/delete C as B); B's agent cannot stop B (its own orb is outside its tree, #79); the human is unrestricted. No depth limit: the bounds are named cardinality (#84), flat visibility, and the deletion guard — the runaway-spawner risk class is identical to top-level.

## Consequences

- The agent-facing `orb_spawn` surface is identical at every depth — no new API, no new UI: a nested orb is a workspace card like any other (#85), with no "spawned by" provenance (consistent with ADR-0006's no-provenance choice).
- A nested orb's clone reads the parent's branch **from the remote, not from the parent's volume** — the parent's container and volume are not touched by the seed; seeding only requires a parent orb of the same project whose branch is pushed.
- Discarded variants leave their pushed `orb/<id>` branches on the remote, as any force-deleted orb does — remote-branch cleanup belongs to the automated lifecycle (#89).
- Container→host reachability — needed by **every** orb to call the bridge (even one spawned from a host session, where "localhost" is not the host) — is settled by `host.docker.internal` (`--add-host=host.docker.internal:<host IP>`), with the bridge writing its URL into the container-local config at every copy (#82 owns the copy, host-authoritative).
- Cross-restart storage of the spawn tree is out of scope here: the tree is a bridge-side fact keyed by session id, and its recovery after crash/reboot belongs to ticket #90.
