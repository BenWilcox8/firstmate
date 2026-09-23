# Atlas module

The Atlas is the captain's map of each project's nodes, regions, and tickets, shown on the dashboard.
Firstmate's Atlas integration is an optional module.
It loads only in a home whose `config/specs` names a local Atlas repo ([configuration](../configuration.md#atlas-pointer-configspecs)).
In any other home, no session sees Atlas text and no script makes an Atlas call.

The module keeps its files apart from firstmate's core files.
Then an upstream firstmate merge and an Atlas or dashboard update touch different files, and each part of the module changes without an edit to the others.

## Parts

| Part | Role | When it loads |
| --- | --- | --- |
| [`supervisor-block.md`](supervisor-block.md) | Supervisor prompt fragment: the map-not-authority rule and the skill load points | `bin/fm-session-start.sh` prints it in every firstmate and secondmate session of a wired home |
| [`crewmate-brief.md`](crewmate-brief.md) | Worker prompt fragment: what a ticketed worker may change on the Atlas | `bin/fm-spawn.sh` appends it to the launch brief of a ticketed ship or scout worker in a wired home |
| `.agents/skills/atlas-firstmate-bridge/` | Supervisor skill: every supervisor-side Atlas rule | The supervisor loads it at the points the supervisor block names |
| `bin/fm-atlas-module.sh` | Entry point for the prompt fragments, the dispatch warning, and the worker environment | Called by the core hook points below |
| `bin/fm-atlas-lib.sh` | The pointer rule and the crew-name rule, shared by the module scripts | Sourced by the module scripts |
| `bin/fm-atlas-hook.sh` | Ticket lifecycle calls: start, complete, land, abort, and the cleanup decision | Called by spawn, the two merge paths, and cleanup |
| `bin/fm-atlas-boundary-check.sh` | Guard: the module file set and the hook-point registry | Run by `tests/fm-atlas-boundary.test.sh` |
| `tests/fm-atlas-*.test.sh` | Module behavior tests | The ordinary test suite |

The dashboard repo owns the other half of the integration: the `atlas-axi` command, the Atlas store, and the `atlas-supervising` and `atlas-working` skills.
The module points at them and never copies them.

## Hook points in core files

Core files reach the module only through short, stable hook points:

- `AGENTS.md`: one layout line for `config/specs` that points here.
- `bin/fm-session-start.sh`: one call that prints the supervisor block.
- `bin/fm-spawn.sh`: the `--ticket` flag, the `atlas_ticket=` record line, the dispatch warning call, the crewmate fragment call, the worker environment call, and the lifecycle start call.
- `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh`: one close-out call after the merge.
- `bin/fm-teardown.sh`: one close-out call that passes the facts cleanup proved.
- `docs/configuration.md`, `docs/scripts.md`, and `docs/documentation-audiences.json`: one entry for each module file or setting.

The registry in `bin/fm-atlas-boundary-check.sh` is the enforced list.
A new Atlas line in a core file fails that check until the registry allows it, so each new hook point is a reviewed decision.

## Where each rule lives

- Supervisor rules: the bridge skill.
- Worker rules: `crewmate-brief.md`.
- When a supervisor loads the skills: `supervisor-block.md`.
- Lifecycle mechanics and their evidence: the `bin/fm-atlas-hook.sh` header.
- The pointer rule and the crew-name rule: `bin/fm-atlas-lib.sh`.
- The worker environment: the `bin/fm-atlas-module.sh` header.
- The ticket procedure itself: the dashboard's `atlas-supervising` and `atlas-working`.

Each rule has one owner.
Another part that needs the rule points to its owner and does not restate it.
