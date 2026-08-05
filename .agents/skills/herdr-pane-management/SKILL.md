---
name: herdr-pane-management
description: >-
  Agent-only reference for operating a herdr-backed home's workspace panes through agent-axi.
  Load whenever this home's runtime backend is herdr and you need to inspect, place, repair, or reason about crewmate panes.
  Owns the layout-authority rule; exact flags stay in `agent-axi --help` and mechanism detail in docs/herdr-backend.md.
user-invocable: false
metadata:
  internal: true
---

# herdr-pane-management

Load this when this home's runtime backend is herdr.
It owns the operating knowledge for the home's workspace panes; it does not replace `docs/herdr-backend.md`, which owns the backend mechanism, incidents, and verification evidence.

## agent-axi is the sole layout authority

`agent-axi` owns the durable per-home slot ledger and every layout mutation for a herdr-backed home.
Firstmate does not re-derive slot geometry: the herdr adapter delegates pane create and teardown to agent-axi and keeps only the pane I/O verbs plus a minimal fallback.
Ask agent-axi for the slot plan and occupancy, for one crewmate's reconciled slot record, for the live slot map, and for spawn, teardown, move, replace, snapshot, and `layout --repair`.

Exact subcommands, flags, and output shapes belong to `agent-axi --help`; read it rather than working from memory.
Never drive raw `herdr` pane commands to place, move, or reclaim a crewmate pane - that is exactly the re-derived geometry agent-axi replaced, and it desynchronizes the ledger.

## Crew panes are slots, not ad-hoc tabs

A crewmate pane lives in the home's own workspace as an occupied slot in agent-axi's plan, placed as a split within the tab that plan assigns rather than as an ad-hoc tab of its own.
Do not open a tab by hand for a crewmate and do not treat a stray tab as a tracked pane; agent-axi counts occupancy by live agent, not by label geometry, and reports an untracked pane as drift.
When a pane genuinely needs its own tab or another workspace, ask agent-axi to reparent it rather than moving it in herdr directly.

The one exception is the native fallback: when agent-axi is not resolvable, the adapter creates one plain tab per task with no split layout and no husk reaping, and refuses a same-labelled leftover rather than replacing it.
That fallback is a degraded mode, not the operating model - install agent-axi or close the leftover tab manually.
`docs/herdr-backend.md` "Native fallback contract" owns its exact behavior.

## Where firstmate already calls agent-axi

Three wirings are already in place through `bin/fm-herdr-layout-lib.sh`, and all three are no-ops unless the home is explicitly configured for herdr and agent-axi resolves.
Do not duplicate them by hand.

- Session start runs the mutating layout repair sweep as one of the bootstrap sweeps, so a workspace that drifted while firstmate was away self-heals (`AGENTS.md` section 3; `bin/fm-bootstrap.sh`).
- The session-start digest prints agent-axi's read-only snapshot in the fleet-state section, so slot occupancy and husks are already visible before you ask.
- The watcher heartbeat previews drift read-only and surfaces a non-converged workspace as a wake; the watcher never mutates geometry itself, so healing it is firstmate's action.

Spawning goes through `bin/fm-spawn.sh` as for every backend; its herdr branch ensures the home's workspace and delegates placement, so there is no separate slot argument to pass at dispatch.

## Handling a layout-drift wake

Treat a surfaced drift as a repair task, not an emergency.
Inspect the live slot map first, then converge the workspace with agent-axi's repair verb, previewing with its dry-run form when the drift is unfamiliar.
Repair reaps husks and re-binds drifted labels; it is not a substitute for `stuck-crewmate-recovery` when the worker itself is stopped or confused.

Before driving any herdr lifecycle action while testing or debugging, use the guarded isolated-lab path rather than the captain's live session; `AGENTS.md` section 11 and `bin/fm-herdr-lab.sh` own that contract.
