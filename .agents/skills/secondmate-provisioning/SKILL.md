---
name: secondmate-provisioning
description: >-
  Agent-only reference for persistent secondmate setup and retirement.
  Use when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited config into, or retiring a secondmate home, or when editing data/secondmates.md.
  Covers home leases, transactional seeding, project clone restrictions, secondmate harness pins, inherited config push, idle charter, handoff helper, and teardown safety.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main firstmate, and secondmates are idle by default.

## Routing table

`data/secondmates.md` has one line per persistent domain supervisor:

```markdown
- <id> - <charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

`scope:` is used during intake; `projects:` is a non-exclusive clone list, not ownership.

## Charter and seed

Scaffold a secondmate charter:

```sh
bin/fm-brief.sh <id> --secondmate {<project>...|--no-projects}
```

Set `FM_SECONDMATE_CHARTER='<charter>'` for the charter text and `FM_SECONDMATE_SCOPE='<scope>'` when the routing scope differs; if you scaffold without `FM_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding.
`--no-projects` scaffolds a project-less charter for a domain whose subject is the firstmate repo itself (home is a firstmate worktree, crews take pooled worktrees of it); it is mutually exclusive with a project list, omitting both fails loudly, and re-seeding a populated home as project-less is refused non-destructively (retire or clean that home first).
Keep the scaffolded charter wording (persistent responsibility, available clones, escalation to the main firstmate status file, the marked-vs-unmarked request-return contract, and the idle-by-default definition of done - reconcile only own in-flight work then wait, never self-initiate a survey or audit); `AGENTS.md` sections 6 and 11 own that contract.

Provision the home and registry entry after the charter is filled:

```sh
bin/fm-home-seed.sh <id> <home|-> {<project>...|--no-projects}
```

`--no-projects` in the project position seeds the project-less home above (same rules); it may only seed a home with no project clones or registry entries, refusing to convert a populated home.
`-` leases a fresh firstmate worktree via `treehouse get --lease` under the secondmate id; the lease survives with no live process, is never recycled by later `treehouse get`/`prune`, stays reserved across restarts, and is released only on explicit retirement or seed rollback.
`bin/fm-home-seed.sh` copies the charter into the home as `data/charter.md` and writes the required gitignored `.fm-secondmate-home` identity marker (must remain for home validation); it refuses a missing or placeholder charter, and a direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
`bin/fm-home-seed.sh validate` checks registry integrity, refusing duplicate ids, duplicate homes, and nested or overlapping homes.
Seeding is transactional: any failure (validation, cloning, no-mistakes init, registry update) rolls back all generated briefs, new homes, new clones, and registry edits.

`bin/fm-spawn.sh --secondmate` launches through the secondmate harness path (resolution chain `config/secondmate-harness` -> `config/crew-harness` -> own, owned by `harness-adapters` and `AGENTS.md` section 4; an explicit per-spawn harness overrides).

**Model/effort pin.** `config/secondmate-harness` may pin model and effort on the same line - `<harness> [<model>] [<effort>]`, first non-empty non-comment line only; a bare `<harness>` is fully backward-compatible.
`bin/fm-harness.sh secondmate-model` / `secondmate-effort` print the optional 2nd/3rd tokens (empty when absent, or when the file is absent/`default`/harness-only), reading only `config/secondmate-harness`, never `config/crew-harness`.
`fm-spawn` applies those tokens only when the harness itself came from the secondmate config path; an explicit per-spawn `--harness`/positional/raw launch starts clean on model/effort, and an explicit `--model`/`--effort` always wins.
Resolved every spawn, so durable across respawns; secondmate-only, crewmate/scout resolution untouched.

**Sync and inheritable-config propagation (this section is the single owner; `AGENTS.md` sections 3 and 4 point here).**
Before launch `fm-spawn.sh --secondmate`, and for every live home the locked session-start bootstrap sweep (homes discovered from `state/<id>.meta` `kind=secondmate` records; `data/secondmates.md` only backfills `home=` for older ones), locally fast-forward the home to the primary checkout's current default-branch commit when safe; dirty, diverged, or in-flight homes are left unchanged with a warning.
That no-fetch path is a purely local fast-forward of tracked files only - never an origin fetch, never touching the gitignored operational dirs - so backlog, projects, and in-flight work are undisturbed; a standalone clone lacking the target instead updates through `/updatefirstmate`'s origin refresh.
The same launch and sweep also propagate the primary's declared inheritable config (`config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`) into the home's `config/` - a separate primary-authoritative copy (since `config/` is gitignored) that re-converges every live home whether or not its tracked files advanced, touching only the declared items.
Inheritance copies the literal `config/crew-harness`, so a secondmate's own crewmates use the primary's crewmate harness only when it names a concrete adapter (e.g. `codex`); `config/secondmate-harness` is not inherited (only the primary's knob for launching secondmates).
No reread nudge is needed at spawn or respawn (the agent reads `AGENTS.md` fresh); only the bootstrap sweep's `NUDGE_SECONDMATES:` case (a RUNNING home whose instruction surface advanced) needs one.
For already-live secondmates, `bin/fm-config-push.sh` pushes a mid-session inherited-config change without the fast-forward or a nudge, using the same discovery/propagation helper and reporting each item as `pushed`, `unchanged`, `skipped`, or `error`.

Secondmate project lists may include `no-mistakes` and `direct-PR` projects only; `local-only` projects stay with the main firstmate.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.

## Backlog handoff

Apply `AGENTS.md` section 10's work-items-only backlog contract before creation or handoff.
After seeding a new secondmate, move its in-scope queued main-backlog items in - scope-matching is firstmate's judgment against the natural-language scope, not a keyword rule:

```sh
bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...
```

The helper resolves and validates the secondmate home from `data/secondmates.md`, then delegates the move to `tasks-axi mv` (the single owner of the backlog format), which byte-exact moves each named item plus its connected set (blocker plus dependents) atomically into the secondmate home's `data/backlog.md`.
It accepts `## Queued` entries only (refusing `## In flight`, historical `## Done`, and orphan-risking single-space/tab continuations), is idempotent, and refuses any destination that is not a genuine seeded firstmate home with a `.fm-secondmate-home` marker and safe operational dirs.
Do not hand off `local-only` items; this delegated route stays required even under `config/backlog-backend=manual` (which controls only routine firstmate backlog edits).

## Recovery

For `kind=secondmate` meta with no window, treat the secondmate as a dead persistent direct report and respawn with `bin/fm-spawn.sh <id> --secondmate` using the recorded `home=`; if meta is missing but `data/secondmates.md` still registers it, respawn from the registry entry and its on-disk home.
Respawn re-resolves the harness and reruns the guarded sync and config propagation above, so recovered secondmates converge to the primary when their home can be cleanly fast-forwarded; if one is already running and only config changed, prefer `bin/fm-config-push.sh`.
Do not reconstruct a secondmate's whole tree from the main home: the main firstmate reconciles only direct reports, and each secondmate reconciles only work already its own and then idles, never initiating a survey or audit during recovery.

## Retirement and teardown

A secondmate is persistent by default; an empty queue is healthy and does not trigger teardown.
Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when the captain or main firstmate explicitly decides to retire it.
The safety check is the secondmate's own home: teardown refuses while its `state/*.meta` contains in-flight work.
When safe, teardown kills the direct window, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired home; a leased home releases its treehouse lease via `treehouse return` (a plain-clone home is just removed), and if `treehouse return` fails teardown stops with state intact rather than hide a held lease.
With `--force`, teardown is the explicit discard path (kills child windows, discards child work and state, removes the route, releases the lease, removes the home); never use `--force` unless the captain explicitly said to discard the work.
