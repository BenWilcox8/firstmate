# Herdr runtime backend

Herdr is an experimental agent-native terminal backend with native per-pane agent state and push events.
Firstmate requires Herdr protocol 14 or newer; broad backend verification covers versions 0.7.1, 0.7.3, 0.7.4, 0.7.5, and 0.8.0, while protocol-16 features remain gated by availability.
Default-on presentation spaces have a higher floor of Herdr 0.8.0 for the reason given under [Presentation spaces](#presentation-spaces).
Herdr provides the terminal session while Treehouse continues to provide task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Pick Herdr when you want native busy, idle, and blocked state and accept the experimental limits below.

Prerequisites:

- Herdr protocol 14 or newer, installed from [herdr.dev](https://herdr.dev).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).
- `python3` only for optional protocol-16 presentation-space ordering and native event subscription.

Herdr is dual-licensed AGPL-3.0-or-later or commercial.
Firstmate invokes its CLI as a separate process.

Select Herdr with local `config/backend` containing `herdr`, `FM_BACKEND=herdr` for one launch, or an explicit request to Firstmate.
A remote second-mate agent is the one case with no choice: it always runs on Herdr, and [`remote-secondmates.md`](remote-secondmates.md) owns that requirement and the readiness its host must meet.
It is also auto-detected when the primary runs natively under `HERDR_ENV=1` and is not inside tmux.
A tmux pane nested inside Herdr resolves to tmux because the innermost multiplexer wins.
An auto-detected Herdr spawn prints an opt-out notice.

Spawn stops before creating a Herdr container or acquiring a task worktree when `herdr`, `jq`, or the protocol floor is unavailable.
No separate first-run provisioning is required.

The required CI lane uses the pinned installers in `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`.
Those script headers own release assets, checksums, download bounds, and post-install gates.
Real harness credential tests remain opt-in rather than part of default CI.

## Watching and task containers

The ordinary topology puts one task tab per endpoint in the exact workspace of the Firstmate or secondmate that launches it.
When the launcher has no Herdr workspace to inherit, the adapter maintains one durable home-labeled workspace instead.
The primary home label is `firstmate`.
A secondmate home label is `2ndmate-<secondmate-id>`, derived from its validated `.fm-secondmate-home` marker.
A secondmate launched by the primary receives a narrowly scoped home override during container creation.

Attach to the selected named Herdr session and switch to the relevant home workspace to watch its task tabs.
Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without attaching.

Workspace and tab creation use `--no-focus`.
The first workspace in a completely empty Herdr session must become focused because no prior target exists, but later task creation does not intentionally steal focus.

Herdr does not enforce workspace or tab label uniqueness, so a label can never decide where a worker goes.
Herdr 0.7.5 exports `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` into every process it manages a pane for, and a Firstmate or secondmate agent's own commands inherit them.
Older injection shapes are unverified, so a claimed launcher pane without the injected socket identity cannot be trusted.
With presentation spaces disabled, a crewmate or scout is created in the exact workspace that identity currently resolves to, read live from Herdr rather than from the injected snapshot, so the worker always appears beside the agent that launched it.
Duplicate labels elsewhere in the session are irrelevant, and the globally focused workspace is never the target.
A `--secondmate` launch is the deliberate exception: it stands up that secondmate home's own workspace instead of joining the launcher's.

A claimed parent identity that cannot be resolved exactly stops the spawn before any worker endpoint exists, rather than falling back to a label search.
That covers a missing or unusable socket identity, a closed or unreadable launcher pane, a pane and tab that disagree about their workspace, a workspace missing from the session, and a pane belonging to another named session or Herdr server.

Firstmate running outside Herdr entirely has no launcher workspace to inherit, so its workers use this home's own labeled workspace, created on first use.
That path needs the home label to identify exactly one workspace: two workspaces sharing it are an unresolvable placement and refuse rather than adopting either.
Avoid naming a personal workspace `firstmate` or `2ndmate-<id>` for that reason, and because the adapter cannot distinguish that label collision from its own container.
An older secondmate workspace using `firstmate-<id>` is not migrated automatically; rename it manually before expecting new tasks or recovery to use it.
Recovery and list-live still scan the first workspace matching the home label, because they address panes they already recorded rather than choosing where new work goes.

Existing task operations use recorded endpoint ids and do not move a live task when labels change.
The per-home workspace is reused while it has task tabs.
Closing its last tab can remove the workspace, and the next spawn recreates it.

## Presentation spaces

Each new crewmate or scout is placed in a disposable one-task workspace by default, on Herdr 0.8.0 and newer.
A home opts out by writing `off` into local gitignored `config/herdr-presentation-spaces`, and forces the projection on by writing `on`.
An absent file leaves the choice to the version floor below, an empty file and the value `on` are both a deliberate opt-in, values are compared with whitespace stripped and case ignored, and an unrecognized value warns and follows the unconfigured default rather than failing a spawn over a purely visual setting.
The empty file is the historical presence-based opt-in form, so every home that had already enabled the projection stays enabled with no migration step, and no previously enabled home can be turned off by the default or by the floor.
A home that never created the file gains the projection at its next Herdr spawn on a supported release; that flip is deliberate, and it reaches only the Herdr backend because no other runtime backend has a projection path.

Projecting each task into its own workspace makes every task cleanup a workspace-emptying removal, which is the only removal shape Herdr's pre-0.8.0 focus defect touches, and the focus-safe removal plan below can only avoid it while the closing pane's shell can be proved lone, childless, and idle.
A persistent child of that shell - a `gitstatusd`, a `zsh-async` worker, or `direnv` - fails that proof permanently and forces the plain explicit close, which on those releases moves the active workspace for roughly a seventh of a second before the restore backstop pulls it back, once per task cleanup.
An unconfigured home is therefore projected only on a release at or above the 0.8.0 floor, where every workspace-removal primitive preserves focus and that proof stops being load-bearing.
Below the floor an unconfigured home uses the ordinary flat per-home layout instead and warns once per home per detected release, naming the running release and the upgrade that restores the projection.
That one-warning-per-release record is a `state/.herdr-presentation-floor-<release>` marker; deleting it only makes the same warning appear again, and an upgrade or downgrade re-announces itself because the release is part of the key.
The floor reads both the installed client's protocol and version and the selected named session's server signals while that server is running, requires both applicable releases to pass, and uses only the client when status positively reports no running server because that client will start it.
The unconfigured default is rechecked after the server is started or adopted and before any presentation journal or workspace is created, while an unreadable server state or release is treated as unsupported rather than guessed at.
An explicit `on` is honored below the floor, so a home that deliberately opted in is never silently downgraded; it accepts that documented focus move, and the exact prior-tab restore stays its backstop.
The floor has a single owner, the spawn-time gate, so cleanup for a projection that already exists always runs and never strands a workspace, whatever release the home is on now.
Upgrading Herdr to 0.8.0 or newer is the fix; writing `off` is the immediate mitigation for a home that cannot upgrade yet.
The setting is inherited into secondmate homes through the normal configuration-convergence owner, and the default needs no special convergence: the primary's absent file and the secondmate's absent file both mean the same unconfigured default, so leaving it converges a secondmate to that same default rather than turning it off, and only an explicit primary `off` propagates the opt-out.
A secondmate agent itself always stays in its ordinary parent workspace; only children launched by that home are eligible.
An unconverged opt-out keeps the default projection in that home until convergence.

Presentation is a best-effort visual projection, never task ownership or lifecycle authority.
Only a fresh task with neither metadata nor an existing presentation journal is eligible for projected creation.
Firstmate atomically publishes a three-field version 1 journal containing a random 128-bit base64url token before asking Herdr to create anything.
After the new workspace converges to one exact task endpoint beneath one exact parent workspace id, the journal advances to a version 2 binding that records the physical home, named session, endpoint, parent, and immutable expected labels.
Another parent with the same presentation label does not prevent publication or participate in restart reclaim.
The token is visible in the workspace title because Herdr exposes no verified hidden persistent field, but neither token, title, nor journal authorizes send, capture, task ownership, Treehouse return, or general recovery.

The owning parent is the launcher's own exact workspace, resolved from the same identity the flat path uses, and falls back to a unique home-label lookup only for a Firstmate outside Herdr.
Projected children are never collapsed back into that parent; it is the placement and ordering reference the projection is bound under.
The normal `fm-<id>` task tab is created in the exact new workspace returned by Herdr.
Only the exact seeded default tab returned by the same workspace-create response can be pruned.
Before and after create, prune, order, abort cleanup, and normal cleanup, Firstmate verifies exact workspace, tab, pane, and active-focus ids.
An ambiguous response grants no mutation or cleanup authority.

Protocol 16 exposes `workspace.move` over the named session socket but no CLI subcommand.
`bin/backends/herdr-workspace-move.py` sends only that whitelisted method and verifies the complete returned workspace order.
Projected children are placed in one contiguous block immediately after their owning home when the session layout, protocol, socket, `python3`, and machine-private per-session lock are all verifiable.
Existing legacy child labels may extend an already adjacent block read-only but are never renamed or migrated.
A foreign, ambiguous, detached, or manually interleaved child makes ordering skip with a warning rather than rewriting the layout.

Ordering failure never fails the task spawn.
Firstmate does not retry, adopt, reuse, close, delete, or rename anything in response to an unavailable method, lock contention, ambiguous socket, lost response, failed move, or verification mismatch.
The worker remains on the ordinary flat or Herdr-current-order path.

Because the label is derived from the home's own durable identity - the marker file lives at the home's root, not in an environment variable passed down a call chain - it is automatically stable across every respawn, recovery, and firstmate restart for the life of that home, with no extra bookkeeping required.
Two different secondmate homes always get two different, non-colliding labels because their marker ids are unique (verified: `tests/fm-backend-herdr.test.sh`'s `test_workspace_label_different_secondmates_get_different_labels`).

Every workspace-scoped adapter path reads this SAME resolution: find/ensure (`fm_backend_herdr_workspace_find`/`_ensure`), tab create and its duplicate-label check (`fm_backend_herdr_create_task`), list-live recovery (`fm_backend_herdr_list_live`), and pane-for-tab (`fm_backend_herdr_pane_for_tab`, via the workspace id these resolve).
So a secondmate's own recovery/duplicate-check calls are automatically scoped to its own space and never see (or collide with) the primary's or a sibling secondmate's tabs.

### The one wrinkle: a `--secondmate` spawn is launched BY the primary

For every other spawn kind, `$FM_HOME` at spawn time already names the right home: the primary spawning its own crewmate/scout, or a secondmate spawning a crewmate/scout FROM ITS OWN `fm-spawn.sh` process (its own `$FM_HOME` already IS that secondmate's home).
The one exception is `bin/fm-spawn.sh <id> <secondmate-home> --secondmate`: this command runs IN THE PRIMARY's own process, so the primary's OWN `$FM_HOME` is what the label-resolution helpers would see by default, even though the tab being created belongs to the SECONDMATE.
`fm-spawn.sh`'s herdr case arm handles this with a narrow, targeted shadow: it computes `HERDR_LABEL_HOME` (the secondmate's own home, `PROJ_ABS`, for `KIND = secondmate`; the process's own `$FM_HOME` otherwise) and passes it as a bash temporary-assignment prefix - `FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure ...` and `FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task ...` - which scopes the override to exactly those two calls and is automatically restored afterward (verified: bash's temporary-assignment-before-a-simple-command form applies for the duration of a shell FUNCTION call too, not only external commands).
Nothing else in `fm-spawn.sh` reads `$FM_HOME` again after this point, so no explicit restore is needed.

Every other backend-scoped call site needs no such glue: it already runs inside a process whose own `$FM_HOME` correctly names the home doing the work.
This includes the previously-unexercised path of a crewmate spawned FROM a secondmate's own `fm-spawn.sh` - proven end to end in `tests/fm-backend-herdr-workspace-per-home-e2e.test.sh`, not merely by code inspection (see "End-to-end verification" below).

### Focus behavior: never steals the captain's attention

Verified empirically against the real binary, in an isolated session:

- `herdr workspace create` and `herdr tab create` do NOT focus by default once at least one workspace already exists in the session - matching (and no worse than) the pre-P3 adapter's already-flagless calls.
- The ONE exception: the very first workspace ever created in a brand-new, empty herdr session focuses regardless, because herdr always needs something focused to attach a client to - there is nothing to "not steal focus from" at that point.
- `--focus` reliably DOES focus (both the workspace and, for a tab, the pane within it) - confirming the flag has real effect and isn't a no-op, so its absence is meaningful.

Both `fm_backend_herdr_workspace_ensure`'s workspace create and `fm_backend_herdr_create_task`'s tab create now pass `--no-focus` unconditionally.
This is defense in depth rather than a behavior change in the already-safe steady state: it guards workspace and tab creation after the session already has a focused workspace, but it cannot prevent herdr's unavoidable first-workspace focus in a brand-new empty session.
Once a workspace exists, spawning - primary or secondmate, workspace or tab - should not switch whatever space the captain is actively watching.

### Label collisions: adopt-don't-duplicate, unchanged in spirit

Herdr enforces NO label uniqueness at all for either workspaces or tabs (re-verified for workspaces specifically in this pass: creating a second workspace with an already-used label succeeds and produces two workspaces sharing that label).
`fm_backend_herdr_workspace_find` therefore adopts the FIRST matching workspace `jq` returns for a home's own label - in practice list order, normally creation order / the oldest - rather than attempting to disambiguate; this mirrors the pre-existing tab duplicate-label check in `fm_backend_herdr_create_task` (which still refuses an exact duplicate TAB label within the adopted workspace).
Practical consequence: if a user manually creates their own herdr workspace that happens to share a firstmate home's label (`firstmate`, or `2ndmate-<some-id>`), firstmate's next spawn silently ADOPTS that pre-existing workspace as if it were its own, rather than creating a second one or refusing.
This is a pre-existing characteristic of the adapter's find-before-create pattern, not a new risk introduced by the per-home refinement; avoid naming a personal herdr workspace `firstmate` or `2ndmate-<secondmate-id>` if you want to keep it separate from firstmate's own space.

### No forced migration

Existing live tasks are unaffected by this change: a task's meta already records its own `window=`/`herdr_pane_id=` target, which every backend-scoped operation (send/capture/kill/busy-state) resolves directly and never re-derives from a workspace label.
So a task spawned before this pass keeps working exactly as before, from whatever workspace it already lives in (the old shared `firstmate` workspace, or a pre-rename `firstmate-<secondmate-id>` workspace if that is where its home's tasks previously landed).
New workspace lookup does not adopt old secondmate labels: for new spawns, recovery, and list-live, the adapter exact-matches the current label derived from `FM_HOME` (`2ndmate-<secondmate-id>`).
If an older live workspace is still labeled `firstmate-<secondmate-id>`, rename it with `herdr workspace rename <workspace_id> 2ndmate-<secondmate-id>` before expecting new tasks or recovery/list-live to use that workspace.

Tab-per-task within each home's own workspace remains the durable default for the reason P2 originally found: attaching once shows every one of that home's tasks as a tab in one tab bar, switchable with `ctrl+b <n>`, matching how a captain already watches a tmux-backed fleet.
Durable workspace-per-task remains rejected.
The optional projection accepts a top-level space per clean new task as a disposable visual aid, with exact same-identity restart replacement and explicit flat fallback for every ambiguous case.

## Pane layout is owned by agent-axi (delegation architecture)

Pane placement - tab vs split, the slot plan, overflow, husk reaping, and recovery-by-label for placement - is owned by `agent-axi` (a local project clone; spec `agent-axi/v1`; design report `data/agent-axi-research-f2/report.md`), NOT by firstmate bash.
agent-axi keeps a durable per-home slot ledger, reconciles it against live herdr before every mutation, counts occupancy by live agent (never by label geometry), and drives herdr's atomic `agent start` / native `pane move` primitives.
firstmate's herdr adapter delegates the pane lifecycle to it; the adapter now owns only the pane I/O verbs (resolve target, capture, send, busy-state, composer-state) plus workspace ensure/prune and a minimal fallback.

### Delegation architecture

`fm_backend_herdr_create_task` and `fm_backend_herdr_kill` delegate to `agent-axi spawn` / `agent-axi teardown` when an agent-axi executable is resolvable (phase-0 shim, slice s6; `fm_backend_herdr_axi_available`, gated by `FM_BACKEND_HERDR_AXI_BIN`, default `agent-axi`, empty forces the native fallback).
The returned target string (`"<session>:<pane_id>"`), the `"<tab_id> <pane_id>"` create echo, the `fm-<id>` label, and every meta field stay byte-identical, so `fm-spawn`, `fm-teardown`, the watcher, crew-state, and every existing caller are unaffected.
`bin/fm-spawn.sh`'s herdr branch no longer has a split path or a `config/herdr-layout` read: it only ensures the home's workspace and calls `create_task`, which delegates placement to agent-axi's ledger.

### What was deleted (phase 1, slice s7, 2026-07-20)

The re-derived slot/geometry/label-scan bash that agent-axi's ledger now owns was removed from `bin/backends/herdr.sh`:

- The deterministic split-slot bisection plan and its resolver (`fm_backend_herdr_split_plan`), the split spawn path (`fm_backend_herdr_split_create_task`), and the split knobs (`fm_backend_herdr_layout`, `fm_backend_herdr_split_ratio`, `fm_backend_herdr_split_max`, and the `FM_BACKEND_HERDR_SPLIT_*` constants).
- The label-based pane discovery used for placement (`fm_backend_herdr_tab_crew_panes`, which joined `pane list` labels to `pane edges` geometry) and the spawner-anchor probe (`fm_backend_herdr_spawner_pane`).
- The husk-classification heuristics that drove placement decisions: the tab-mode close-and-replace of a restored same-labelled husk tab, the cross-layout same-label scan, and `fm_backend_herdr_tab_is_husk`.

`config/herdr-layout` and the `FM_HERDR_LAYOUT` / `FM_HERDR_SPLIT_MAX` / `FM_HERDR_SPLIT_RATIO` overrides no longer exist; agent-axi owns the plan (its own `--plan` / built-in `home` + `overflow` plans).
`fm_backend_herdr_pane_agent_state` stays (it still backs the `fm_backend_herdr_agent_state` recovery verb and its `fm_backend_herdr_agent_alive` compatibility view), and the recovery/selector helpers `fm_backend_herdr_list_live` and `fm_backend_herdr_resolve_bare_selector` stay - they are recovery scoping, not placement, and match every other backend's contract.

### Native fallback contract

When agent-axi is not resolvable (empty `FM_BACKEND_HERDR_AXI_BIN`, or the binary absent), `fm_backend_herdr_create_task` falls back to a MINIMAL native path: one plain tab per task in the home's own workspace, `--no-focus`, plus the seeded-default-tab prune.
There is NO split layout and NO proactive husk reaping in the fallback - split layouts and husk convergence REQUIRE agent-axi.
The fallback keeps only a cheap same-label refusal: it never re-derives geometry and never classifies husks, so a same-labelled tab left over from a herdr session restore is reported (`error: ... already exists ... close it manually or install agent-axi`), not silently replaced.
Install agent-axi (whose `layout --repair` reaps husks) or close the leftover tab manually to recover.

### Repair and snapshot wiring (supervision loop)

firstmate no longer re-derives layout; it only asks agent-axi to keep the workspace converged and to report drift, through the shared `bin/fm-herdr-layout-lib.sh` (the single owner of the applicability guard and the three invocations).
Every wiring is a definitive no-op unless the home is EXPLICITLY configured for herdr (`FM_BACKEND` or `config/backend`, never runtime auto-detection) AND agent-axi (and `jq`) resolve (`fm_herdr_layout_applicable`).
Keying on explicit configuration rather than auto-detection is deliberate: the mutating `layout --repair` drives agent-axi against the home's live herdr workspace, so it must never fire merely because firstmate happens to run inside an ambient herdr pane in a home that is not itself herdr-backed.

- **Session start (`bin/fm-bootstrap.sh`, `herdr_layout_repair_sweep`).** At a locked session boundary, the full `agent-axi layout --repair` converges the live workspace to the slot plan (reaps husks, re-binds drifted labels), so a layout that drifted while firstmate was away self-heals on session start. A converged workspace stays silent; a heal reports one `BOOTSTRAP_INFO:` fact. It is one of the six mutating sweeps skipped in the lock-refused read-only path.
- **Watcher heartbeat (`bin/fm-watch.sh`, `heartbeat_finds_herdr_layout_drift`).** On the heartbeat cadence, the read-only `agent-axi layout --repair --dry-run` PREVIEWS drift; the watcher never mutates geometry on its own, it only SURFACES a non-converged workspace as a heartbeat wake for firstmate to heal. Deduped against `state/.herdr-layout-drift-surfaced` (drift signature) so a persistent drift is woken once, not every heartbeat.
- **Session-start digest (`bin/fm-session-start.sh`).** The read-only `agent-axi snapshot` (token-lean live slot map) is printed in the FLEET STATE section for herdr-backed homes, so the digest opens already showing live slot occupancy and any husks. Read-only, so it also runs in the lock-refused path.

### Verification (2026-07-20, herdr 0.7.2, protocol 16, agent-axi 0.1.0, NixOS Linux x86_64)

Environment:

```sh
herdr status --json | jq -c '{version:.client.version,protocol:.client.protocol}'
# {"version":"0.7.2","protocol":16}
uname -sm   # Linux x86_64
```

The mutating native-fallback checks ran in an isolated `fm-lab-*` session provisioned and torn down through `bin/fm-herdr-lab.sh` (the guarded lab helper); the captain's `default` session was never a target and its fleet-state tripwire held (verified intact after teardown).
The read-only wiring checks (`snapshot` and the `--dry-run` drift preview) ran against the live server, since they never mutate.

- **Native fallback (agent-axi disabled, `FM_BACKEND_HERDR_AXI_BIN=`, lab session).** `fm_backend_herdr_container_ensure` created the home's own workspace (`w1`, seeded default tab `w1:t1`); `fm_backend_herdr_create_task` made exactly one plain `fm-nativeA` tab (`w1:t2 w1:p2`) and pruned the seeded tab. A second `create_task` for the same label REFUSED with `error: herdr tab 'fm-nativeA' already exists ... close it manually or install agent-axi` and created no replacement tab (still exactly one `fm-nativeA` tab, no `pane close`). `fm_backend_herdr_kill` closed the pane. No split logic ran at any point.
- **Read-only wiring (agent-axi present, real server).** `fm_herdr_layout_snapshot` rendered the live token-lean slot map for workspace `firstmate (wJ)` (0 occupied, 0 husks, 1 untracked pane). `fm_herdr_layout_drift` (the heartbeat's `layout --repair --dry-run`) reported the drift signature `0 husk(s), 0 rebind, 0 freed, 1 adopted` for that untracked pane - drift surfaced for firstmate to heal, nothing mutated.
- **Applicability guard.** With `FM_BACKEND=tmux` (or `FM_BACKEND_HERDR_AXI_BIN=`), every helper is a silent no-op and never invokes agent-axi (covered by `tests/fm-herdr-layout-lib.test.sh`); the watcher heartbeat's no-change absorb is unaffected (`tests/fm-watch-triage.test.sh`).

Fake-CLI unit coverage lives in `tests/fm-backend-herdr.test.sh` (the delegation and native-fallback `create_task` cases) and `tests/fm-herdr-layout-lib.test.sh` (the repair/snapshot/drift wiring and its applicability guards: absent executable, non-herdr backend).

## Default workspace lifecycle: one per-home workspace, reused

Each home's own workspace (`firstmate` for the primary, `2ndmate-<secondmate-id>` for a secondmate - see "Label derivation" above) is created as needed and reused by each subsequent default-container spawn while it exists: `fm_backend_herdr_workspace_ensure` calls `fm_backend_herdr_workspace_find` first and creates a workspace only when none labelled for that home exists yet.
Teardown (`fm_backend_herdr_kill`) closes only the task's pane/tab, never the workspace.

## Optional disposable single-task presentation spaces

Create the local, gitignored `config/herdr-presentation-spaces` file on the primary home to enable the presentation projection.
The primary's literal presence or absence converges to registered secondmate homes through the same launch, bootstrap, and config-push inheritance owner as the other declared inheritable config items.
An absent file is off, and the off path runs the existing home-workspace and `fm-<id>`-tab command sequence unchanged.
A home that has not yet converged stays flat rather than gaining partial projection authority.
This is a visual convenience, not a task container authority, lifecycle foundation, or durable grouping guarantee.
The `kind=secondmate` agent itself always uses its ordinary `2ndmate-<id>` parent workspace and never receives a corner projection; only eligible crewmates and scouts launched by that home project beneath it.

Only a Herdr task with neither `state/<id>.meta` nor `state/<id>.herdr-presentation` is eligible for a projected create.
Firstmate generates 128 random bits, encodes them as a 22-character base64url `projection_id`, and atomically publishes `state/<id>.herdr-presentation` before asking Herdr to create anything.
The initial three-line version 1 journal contains only `version=1`, `task_id=<id>`, and `projection_id=<token>`.
After the exact new workspace is nested under one unambiguous parent and converges to one exact task tab and pane, Firstmate atomically upgrades the journal to version 2.
Version 2 has exactly 12 fields: the version, task id, token, physical home, named session, workspace id, tab id, pane id, parent workspace id, parent label, workspace label, and task label.
The journal never selects or authorizes send, capture, Treehouse return, or general task-ownership decisions.

The new workspace is created with the normal project cwd, `--no-focus`, and a visible label such as `└ release-notes · p:AbCdEfGhIjKlMnOpQrStUv`.
Every newly created child uses the literal U+2514 `└`, one space, the concise task label with redundant `firstmate/`, `2ndmate-<id>/`, and presentation-level `fm-` owner prefixes removed, then the unchanged ` · p:<full-22-character-token>` suffix.
The ordinary task tab remains `fm-<id>` and is unchanged.
The full token is intentionally visible because Herdr has no verified persistent hidden field suitable for this non-adversarial correlator.
The create response's exact workspace, seeded tab, and root pane IDs stay in the spawning process while it verifies the projection.
Only the verified workspace, task tab, task pane, and exact parent identities are persisted in the version 2 restart binding.
The normal `fm-<id>` tab is created in that exact workspace, and only the exact seeded tab from the same workspace-create response is eligible for pruning.
The projected create refuses success unless the workspace converges to exactly one tab and one pane, both matching the new task response.
There is no log or placeholder tab because retaining one would keep the workspace alive after the task pane closes.
Immediately before and after projected workspace create, task-tab create, seeded-tab prune, workspace move, abort cleanup, and normal cleanup, Firstmate verifies one exact active workspace id and active tab id.
The snapshot comes only from the named session's response and is cross-checked against that workspace's focused tab.
An ambiguous pre-operation snapshot refuses the focus-sensitive mutation rather than guessing from a label, order, or ambient client.

For every eligible projected create from a primary or secondmate home, Firstmate makes one presentation-only ordering attempt after that exact workspace has converged.
One bounded lock per live named Herdr session/socket serializes projected creates, ordering, exact restart replacements, abort cleanup, and projected normal cleanup across every Firstmate home that shares the session.
The lock key is derived from the verified session name and canonical socket path and lives in a machine-private shared runtime namespace, never inside any one home's `state/`.
An unverified or ambiguous socket or an insecure shared-lock namespace fails closed for presentation mutation, warns, and leaves the task on the ordinary flat path.
The new response-derived workspace id is inserted immediately after its owning parent (`firstmate` or `2ndmate-<id>`) contiguous child block and before the next parent.
New-format `└ ... · p:<token>` children define that block; already-adjacent old-format `firstmate/... · p:<token>` or `2ndmate-<id>/... · p:<token>` projections may extend it read-only for compatibility and are never renamed or migrated.
An ambiguous, foreign, or detached presentation child makes the ordering shape unverifiable, so Firstmate warns and skips the move instead of assigning ownership by guesswork.
Only the exact workspace id returned by the current projected create is ever a move target.
After a successful move, the sequence of every pre-existing workspace id excluding the new id must be byte-identical to the pre-move sequence.
Labels and tokens remain non-authoritative correlators only; by themselves they never authorize adoption, close, delete, rename, task routing, Treehouse return, or recovery.

Herdr 0.7.4 protocol 16 exposes `workspace.move` in `herdr api schema`, with exact parameters `workspace_id` and zero-based `insert_index`, but does not expose it as a CLI subcommand.
`bin/backends/herdr-workspace-move.py` therefore sends that one whitelisted method over the exact named session's Unix socket and accepts only its matching `workspace_list` response.
The returned order is checked against the full pre-existing workspace-id sequence and the owning-parent insertion point.
The installed move does not focus its target, but Firstmate still compares the exact pre-operation workspace and tab afterward and restores that exact tab if a future or failed move changes focus.
Focus restoration is not an ordering retry and grants no authority over the moved workspace.

Ordering is best-effort and never becomes task or lifecycle authority.
An unavailable protocol, missing method schema, missing `python3`, ambiguous socket or workspace layout, busy shared lock, explicit move error, lost response, or failed verification prints a warning and does not fail the spawn.
Firstmate performs no ordering retry, adoption, reuse, close, delete, rename, or cleanup in response.
If a move response is lost after Herdr applied it, the current order may already have changed, but the worker remains safely running and no ambiguous response grants additional authority.

After creation, the ordinary task metadata remains the sole operational endpoint record.
Its `window=`, `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=` fields have exactly the same shape as the flag-off path.
No projection ownership flag is added.
The existing `treehouse get`, cwd polling, worktree validation, harness launch, and teardown return sequence is unchanged.

If the same spawning process fails after both creates returned complete exact IDs, its abort trap may close only the exact task and seeded panes returned by those calls.
An ambiguous create result grants no cleanup authority, so Firstmate performs no lookup, adoption, reuse, or cleanup and leaves the journal quarantined.
Normal task metadata remains the sole endpoint authority after creation.
Cleanup closes only the exact recorded task pane and never calls `workspace close`.
Herdr 0.7.5's explicit close moves focus to a neighbor whenever it empties a non-focused workspace, while its pane-death removal preserves the focused workspace whenever the dying workspace sits behind it or the focused workspace is last; both behaviors are fixed in Herdr 0.8.0, and the exact rules live in the adapter header of `bin/backends/herdr.sh`.
Projected cleanup therefore runs under the same session lock, captures the exact active tab, refuses to delete the active tab, and treats a workspace-emptying close as a focus-safe removal: it verifies the close would empty the workspace, repositions the doomed workspace behind the focused one through the verified `workspace.move` transport when needed, proves the pane holds one lone idle shell, and ends that shell so Herdr removes the emptied workspace through its focus-preserving pane-death path.
The repositioning move-to-last preserves every surviving workspace's relative order, and removal is confirmed against the exact moved workspace rather than inferred from pane disappearance before an unconfirmed removal makes one verified attempt under the same session lock to roll the doomed workspace back to its exact original position.
If that rollback cannot restore the verified original order, cleanup warns loudly and leaves the retained records for inspection rather than retrying the shared-layout mutation.
The pane-death signals are pid-exact: the escalation re-reads the pane's process information and refuses unless the same shell pid still passes the strict bare-idle ownership proof, so an exited and reused pid is never signaled.
Any ambiguity, unsupported or failed move, or unproved shell falls back to the plain explicit close, and the exact prior-tab restore remains the backstop behind every close, so degraded behavior is never worse than the pre-mitigation sub-second restore.
Ordinary non-projected task removal serializes through the same session lock, applies the same focus-safe plan when its close would empty a non-focused workspace, keeps the legitimate plain close when the target is the active tab, and refuses an unlocked close if the lock cannot be acquired.
Task cleanup acquires that session lock before the task's isolated copy is returned, so a contended lock refuses up front while the copy, every durable record, and the endpoint are all intact for a plain rerun.
Forced secondmate cleanup recursively preflights every Herdr child endpoint and acquires every affected named-session lock before mutating any child, then retains each child's durable identity unless that exact pane returns structured not-found after its close.
An ordinary task's close is confirmed against the exact recorded pane's structured presence: only a structured not-found response counts as gone, an already-gone pane is confirmed without another close, and an unconfirmed close is retried a bounded number of times under the same held lock before teardown gives up.
A pane that still cannot be confirmed gone after those retries is reported loudly by exact task and pane id while cleanup continues, so the supervising turn can close it by that id instead of the pane leaking silently as a bare terminal.
The presentation journal is retired only on that same single confirmation; an unconfirmed close, renamed label, duplicate token, flat fallback, or unreadable state retains the journal and attempts no workspace cleanup.
If lock, snapshot, pane identity, or restoration is ambiguous, cleanup warns and preserves the journal for manual inspection.

Recovery is deliberately conservative and presentation-only.
An existing journal suppresses another projected create.
Before any recovery mutation, Firstmate holds both the task spawn lock and the named-session presentation lock.
A same-identity version 2 binding may replace one exact agent-free restart husk in place only when the physical home, session, metadata endpoint, unique token match, workspace shape and labels, parent identity and placement, and non-target focus snapshot all agree.
The replacement tab and pane are created and verified before the old pane is rechecked and closed, then the journal advances atomically to the replacement endpoint before metadata publication.
The reclaim path never moves, closes, deletes, or renames a workspace and never touches a parent, sibling, captain, or foreign pane.
A failed replacement rolls back only the exact response-derived new pane when focus-safe verification permits it.
Version 1 journals, dead or missing panes, duplicate or absent tokens, renamed or detached spaces, cross-home mismatches, inconsistent endpoint bindings, active target tabs, and ambiguous identity or focus fall back flat without mutating the old projection when duplicate-agent risk is positively absent.
A live or unknown recorded or token-matched endpoint refuses duplicate launch.

Locked session start has one narrower cleanup for a restored projected child that is no longer current task state.
It runs only when the current home has at least one ordinary presentation journal and considers only that home; a primary never recursively sweeps a secondmate home.
Discovery starts from the exact current `└ <concise-task> · p:<22-character-token>` grammar, but a title or token alone is never mutation authority.
The title must contain exactly one token occurrence across the named-session snapshot and must equal the title derived from exactly one valid presentation journal in this home's own `state/`; a version 2 journal additionally must bind this exact physical home, named session, workspace, tab, and pane.
The task's ordinary metadata must be absent, and the candidate must have exactly one tab and exactly one pane.
Before cleanup, Firstmate acquires the existing task-id spawn lock and then the shared named-session presentation lock.
Inside both locks it takes one exact snapshot, requires one unambiguous non-target focus and the exact title, token, tab, and pane shape, positively confirms no registered agent, and reads Herdr's process information for the exact named-session pane.
The process proof requires one recognized idle shell as both the shell process and the sole foreground process-group member, an operating-system process-table row for that shell, no child process, and a sleeping or idle shell state.
The proof retries strict single samples for a bounded settle window because an idle interactive shell transiently hosts short-lived prompt helpers; a genuinely busy pane fails every sample.
Any foreground command, child process, active shell job, unknown shell, unreadable process table, missing field, or API error preserves the pane.
Firstmate immediately revalidates the same journal, metadata absence, workspace title and token uniqueness, one-tab and one-pane topology, exact pane relationship, absent agent, process proof, and non-target focus before calling the existing exact-pane focus-preserving close helper.
It closes only that pane, never a workspace.
The matching journal is retired only after the exact pane is positively confirmed gone; an unconfirmed close retains the journal, while a confirmed close may retire it even when focus restoration reported an error after the close.
A second run finds no matching title or journal and is a no-op.
A malformed or missing title or token, duplicate token, zero or multiple journal matches, cross-home version 2 binding, current metadata, registered or unknown agent, extra tab or pane, active target, busy lock, changed revalidation, unreadable check, or any error preserves the candidate and lets session startup continue with at most a concise warning.

Operational compromises:

- Grouping is best-effort; only an exact same-identity version 2 binding survives a Herdr restart in place.
- A failed journal publication or projected workspace create stops that spawn instead of falling back flat, so a Herdr create failure surfaces as a spawn failure in every Herdr home rather than only in homes that opted in; every earlier degradation on the fresh projected-create path (no session server, contended presentation lock, absent or ambiguous parent) still warns and continues flat.
- Recovery of an existing presentation journal deliberately refuses the spawn when the shared presentation lock is contended rather than falling back flat, and default-on makes that refusal reachable in any Herdr home.
- Existing layouts are not force-renamed or rearranged.
- Missing or ambiguous restart bindings fall back to the ordinary home workspace while the old projection remains untouched.
- Crashes, lost responses, failed exact-pane cleanup, or human renames can leave quarantined spaces; session start removes only the exact home-local, uniquely journal-correlated, childless idle-shell shape above.
- Spaces have no cross-home cleanup path, and a secondmate child can clean up only from its exact home.
- Every stale-looking space outside that narrow startup proof still requires manual cleanup in Herdr's UI after human inspection.
- Regaining a dedicated space after degradation requires stopping the flat task, manually checking the stale projection, and clearing its journal before a genuinely fresh launch.
- The visible token is only a restart-stable correlator and never substitutes for the exact binding.

`tests/fm-backend-herdr-presentation-e2e.test.sh` covers multi-home ordering, concurrency, lock contention, legacy coexistence, focus preservation, exact same-identity restart replacement, ambiguous bindings and tokens, and exact-pane cleanup through the guarded lab path.
`tests/fm-herdr-session-cleanup.test.sh` covers every discovery, ownership, topology, process, locking, revalidation, focus, retirement, and continue-on-error boundary.
`tests/fm-herdr-session-cleanup-e2e.test.sh` covers the restored-shell cleanup in a guarded non-default named lab.
`tests/fm-backend-herdr-focus-flash-e2e.test.sh` reproduces the raw explicit-close focus steal on the installed release and proves the focus-safe emptying-close plan removes a doomed workspace with no wrong-focus interval; [`verification/runtime-backends.md`](verification/runtime-backends.md#workspace-removal-focus-safety) owns the active versioned evidence.

## Default-tab prune safety

`herdr workspace create` seeds one default tab.
Firstmate prunes it only after a real task tab exists and only when the same create response supplied the seeded tab id.
An adopted workspace never supplies that id and can never enter the prune path, regardless of labels or tab count.
Immediately before close, Firstmate rechecks the exact tab, expected seed label, and native agent state.
A working seed pane is never closed.

This created-versus-adopted gate is a destructive safety boundary.
A prior label heuristic could adopt a captain-owned workspace named `firstmate` and close its live seed-shaped tab.
The current structural gate removes label inference from cleanup authority.
`tests/fm-backend-herdr-prune-safety-e2e.test.sh` reproduces the collision in an isolated named session and proves the adopted pane remains untouched.

## Endpoint metadata

```text
backend=herdr
window=<session>:<pane-id>
herdr_session=<session>
herdr_workspace_id=<workspace-id>
herdr_tab_id=<tab-id>
herdr_pane_id=<pane-id>
```

The recorded pane is the operational fast path.
Workspace and tab ids support verification and cleanup but are not inferred from mutable labels during normal operation.

### Target format

A Firstmate endpoint target is `<session>:<pane-id>`.
The session is always the first field and the pane id is the whole remainder, so a pane id that holds its own colon stays intact.
`fm_backend_herdr_parse_target` is the one owner of that split, and `fm_backend_herdr_bare_id` backstops any id passed to a verb.

Herdr 0.8.2 accepts only the bare id.
A session-prefixed target is refused with `pane <target> not found` or `agent target <target> not found`, and `agent list` and `pane list` print `pane_id` bare.
No Herdr call receives a prefixed id, so a task recorded before 0.8.2 keeps working unchanged.
No metadata is rewritten and no migration is required.

A bare pane id, now the only form Herdr prints, carries no session.
Two sessions can hold identically named panes, so the adapter never infers one from an id.
`fm-send` resolves a bare id through this home's own metadata instead: an exact `herdr_pane_id` match names one recorded task and steers that task's recorded endpoint.
A match whose record has no session or endpoint is refused, and so is a bare id this home does not record.

| Target | Session | Pane id sent to Herdr |
| --- | --- | --- |
| `default:w1:p2` | `default` | `w1:p2` |
| `fm-remote:w1:p2` | `fm-remote` | `w1:p2` |
| `w1:p2` (recorded here) | from the record | `w1:p2` |
| `w1:p2` (not recorded here) | refused | none |
| `w1`, `default:`, `:w1:p2` | refused | none |

## Current transport behavior

The adapter starts and polls a named server before workspace, tab, pane, or agent calls.
Every Herdr invocation goes through `fm_backend_herdr_cli`, which sets the environment and passes an explicit trailing `--session <name>`.
An environment variable alone is not reliable when another Herdr server is running.

Literal text and Enter are separate operations on `fm-send.sh`'s typed plane; ordinary local text steers instead use the durable steering inbox and send only its best-effort constant doorbell through this adapter.
Spawn-time fixed commands may use Herdr's atomic run primitive.
Enter, Escape, and Ctrl-C are supported.
Typed-plane slash input, and dollar-prefixed skill input for Codex, uses the shared harness-aware settle before the first Enter so a completion popup cannot consume it.
Typed-plane text is typed once; only Enter is retried.

On an idle or done native baseline, submit confirmation first waits for `working` or `blocked` across a bounded polling window.
If native status stays idle, the shared composer verdict is the next positive signal: a cleared composer is delivery, and proven pending text retries Enter.
After the retry budget, `fm_composer_queued_enter_verdict` treats proven pending text plus a generating busy signal as a queued delivered Enter, and keeps an idle pending composer as a genuine swallow.
On an already active or unreadable baseline, the adapter falls back to conservative composer clearance, with a pre-Enter rendered-footer transition when that baseline is unavailable.
A fully unreadable target stops retrying and reports unknown.
The queued-Enter busy signal is read at the moment of that verdict, not taken from the pre-Enter baseline: native `working` answers it, native `blocked` positively denies it, and every other native answer leaves it to the pane's rendered busy footer.
blocked is therefore not treated as a queued-Enter busy signal, so a Cursor pane that reports blocked in every state does not receive that conversion.

Some harnesses never present a legibly idle native baseline at all, so the composer fallback is their only path.
Herdr reports a Cursor pane `blocked` in every state, and Cursor's mid-turn composer renders its placeholder beside a right-aligned busy token, which is composer content and therefore `pending` on a composer that holds no user text.
That fallback alone reported every delivered steer as unconfirmed, so it is paired with a rendered-footer transition: the pane's verified busy footer is read once before the first Enter, and an idle-to-busy transition across that Enter confirms the submit.
It is the same semantic signal the native path uses and the same one the tmux submit core reads.
A pane already mid-turn cannot borrow a rendered-footer transition as proof of this delivery, because that proof needs an idle-to-busy edge across our own Enter.
The separate queued-Enter verdict after the retry budget asks a different question - is this pane generating right now - so it reads the footer whatever the baseline was.
Gating that read on a legibly idle baseline let one non-idle or failed baseline read disable the only busy signal a mid-turn Claude pane has, and a delivered steer was then reported as a swallow.
The composer verdict itself is deliberately unchanged: a right-aligned status token on the composer row stays content for every other caller, including the away-mode pre-injection guard.

An endpoint Herdr structurally refuses is reported differently: a `pane_not_found` or `agent_not_found` answer makes the submit report `target-missing`, and `fm-send` then says the endpoint is gone instead of reporting an unconfirmed delivery.
The two failures call for opposite responses - reconcile the task, or wait and retry - so they must not share one message.
Only that structural refusal earns the hard verdict; an unparseable answer stays unknown.
The poll density bounds the residual possibility of an extremely fast complete turn; a missed native transition falls through to the composer verdict rather than reporting a false swallow.

`pane read --lines N` can return empty output when N is below the viewport height.
The capture owner requests at least 200 lines from Herdr and trims locally to the caller's bound.
This generous floor is required for small composer and peek reads.

Herdr's native agent state can read idle while a harness waits on its own long foreground tool.
The shared crew-state path therefore accepts a native `busy` as evidence of activity but never a native `idle` as evidence that a worker has stopped; the task's own semantic busy state (`bin/fm-busy-lib.sh`) decides that.
A human-blocked permission dialog has no busy banner and still surfaces.

## Composer and injection safety

Herdr has no direct cursor-row primitive.
The adapter is a thin capture: it hands a bounded ANSI tail plus Herdr's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape - bordered boxes, bare agent-glyph rows (including muse's `⟩`, which the adapter's retired local pattern silently omitted), opencode's left bar, and the Pi separator region this adapter pioneered, admitted only when native `agent get` identity is exactly Pi and state is idle or done.
A blocked Pi is parked on an interactive prompt, so its blank composer region is a menu's and not a free composer's; that state defers instead of proving emptiness.
A working Pi, pending middle row, missing identity, incomplete separator pair, or over-tall candidate remains unknown or pending.
Identity stays a lazy second read, consulted only when a separator pair could change the verdict.

ANSI capture preserves de-emphasized placeholder style.
`bin/fm-composer-lib.sh` is the fleet-wide owner that strips dim or faint runs and dark truecolor placeholders while retaining bright typed input.
If the ANSI capture ever fails, the plain fallback declares itself unstyled and the classifier degrades a glyph row carrying trailing text to `unknown` instead of misreading ghost suggestions as typed input, which safely defers injection and eventually raises the wedge alarm.

A bare shell prompt is never an empty agent composer.
Away-mode injection proceeds only on an affirmative `empty` result, never on unknown.
This prevents a dead agent pane from receiving and possibly executing an escalation as shell input.

The current operational envelope starts with U+2063 and `FIRSTMATE_OP: `.
The separate routed-request carrier uses `[fm-from-firstmate]` plus U+2063.
U+2063 survives Herdr terminal input as text, unlike the legacy ASCII control separator that could erase the visible routing label.
`bin/fm-operational-input.sh` owns current operational construction and parsing, and the AFK skill owns legacy away-input compatibility.
No Herdr-specific copy of that protocol exists.

## Restart and liveness behavior

Stopping and restarting a named Herdr server preserves workspace, tab, pane, and label ids, but the underlying harness processes and live agent registrations do not survive.
A restored same-labeled tab with a missing pane or no registered agent is a husk.
Create replaces only a confidently dead or no-agent husk, creates the replacement before closing the old tab, and refuses live or unknown states.
This prevents closing the workspace's last tab before a replacement exists.

The generic Herdr agent-liveness probe reuses the same classifier.
A structurally gone pane becomes `missing`, a restored agent-less shell becomes `dead`, a registered agent becomes `alive`, and an unexpected read becomes `unreadable`.
Unlike tmux process-name inspection, native registration can classify Pi without guessing from a generic interpreter name.

The session-start sweep uses this probe.
Mid-session secondmate agent-process liveness is not implemented because idle secondmates are deliberately exempt from stale-pane escalation and need a separate periodic identity signal.

## Push events and polling fallback

Protocol 16 can subscribe to `pane.agent_status_changed` over one bounded Unix-socket reader.
`bin/fm-transition-lib.sh` owns the backend-neutral transition vocabulary and policy.
The Herdr adapter subscribes before reconciling current levels, buffers edges during reconciliation, and returns fresh blocked transitions for this home's panes.
The watcher maps the pane back to the task and skips secondmate endpoints, declared `paused:` waits, and verified `captain-held` transfers, because a declared wait already names the human the fast escalation would report and is left to the watcher's own bounded pause cadence.

The push path only shortens latency.
Polling runs every cycle and remains the permanent fallback when protocol 16, the event schema, Python, connection, subscription, or repeated reader execution is unavailable.
There is still one watcher process; the event reader is a bounded child of that watcher.

`tests/fm-backend-herdr-eventwait-smoke.test.sh`, `tests/fm-transition-lib.test.sh`, and `tests/fm-supervision-events.test.sh` cover capability, subscribe-then-reconcile ordering, dedupe, exemptions, and polling fallback.

## Away-mode supervisor support

The away daemon supports tmux and Herdr supervisor panes only.
It refuses Zellij, Orca, and cmux as supervisor backends rather than applying the wrong transport.
For Herdr, target existence, native state, capture, composer state, and verified submit all route through the shared backend dispatcher and the explicit named-session CLI owner.
The pane-independent max-defer alert is configured in [`wedge-alarm.md`](wedge-alarm.md).

Harnesses with native tracked background execution can run the daemon in their terminal.
Pi has no such mechanism.
`bin/fm-afk-launch.sh` therefore creates a dedicated unfocused Herdr workspace, runs the daemon there with an explicit supervisor target and backend, records the exact daemon pane, and closes only that pane on stop.
It never splits the captain's active tab and never uses shell `&`.
Recovery reconciles only the recorded exact id.

On stop, the daemon receives termination while `state/.afk` still exists so its final flush can run, the recorded terminal is closed, and the AFK flag is removed last.
A fresh entry clears stale transient escalation caches, while durable queue and task records remain authoritative.

## Destructive lab safety

Never use ambient `herdr server stop` for Firstmate verification.
An environment-only session selection can silently reach a different running server, and the ambient stop command has no explicit target.

`bin/fm-herdr-lab.sh` is the sole supported lifecycle helper for isolated verification.
It provisions only non-default names beginning with `fm-lab-`, appends an explicit `--session` to allowed task commands, refuses caller-supplied session flags and server/session lifecycle subcommands, and performs destructive stop/delete only through its guarded lifecycle actions.
Immediately before every destructive call it re-queries the named session and refuses empty, missing, literal `default`, or `default:true` identities.
Its before/after tripwire requires the live default-session snapshot to remain byte-identical.

The helper's header and `--help` own exact commands.
Tests use thin compatibility wrappers in `tests/herdr-test-safety.sh` and never duplicate the destructive policy.

## Active limits

- Herdr remains experimental.
- Presentation ordering needs protocol 16 and Python and is best-effort only.
- Mutable labels can collide; they are never placement or destructive authority.
- A Firstmate outside Herdr cannot resolve a launcher workspace, so a colliding home label refuses new spawns until the collision is cleared.
- Ghost and placeholder recognition uses ANSI de-emphasis when available; an unstyled glyph row carrying trailing non-idle text fails safely to `unknown`.
- Mid-session secondmate agent-process liveness is not implemented.
- Only tmux and Herdr can host the away-mode supervisor terminal.

## Regression entry points

```sh
tests/fm-backend-herdr.test.sh
tests/fm-composer-lib.test.sh
tests/fm-send-strict.test.sh
tests/fm-herdr-submit-confirm-live-e2e.test.sh
tests/fm-backend-herdr-smoke.test.sh
tests/fm-backend-herdr-prune-safety-e2e.test.sh
tests/fm-backend-herdr-respawn-idem-e2e.test.sh
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
tests/fm-backend-herdr-presentation-e2e.test.sh
tests/fm-backend-herdr-eventwait-smoke.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-herdr-session-cleanup-e2e.test.sh
tests/fm-afk-inject-herdr-e2e.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Real Herdr tests use the named lab helper and default-session tripwire.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) records the active version, CLI, projection, event, and lifecycle evidence without task-specific chronology.
