# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, which have no side effects, so they can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`, `park`, `resume`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

The one thing this file owns that is not a pure table is the [endpoint-absence proof](#reclaiming-a-task-whose-endpoint-is-gone) below, which does run backend reads; sourcing the file is still free.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

Herdr ship and scout tasks in the home's workspace use the [ended-pane cleanup contract](herdr-backend.md#ended-worker-panes).
For those tasks, while the recorded session server runs, `exit` closes the stopped pane and `relaunch` creates a fresh pane in its previous slot and recorded worktree.
The endpoint-preserving descriptions below apply to the other task and backend combinations.

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. An endpoint reading `missing` goes through the same [absence proof](#reclaiming-a-task-whose-endpoint-is-gone) the reclaim uses before anything is claimed about it, and only Herdr can supply one: proven gone reports `endpoint-gone` (the agent went with it, and the endpoint this verb normally preserves did not survive), a pane that turns out to be there and idle is the ordinary `already-stopped`, one whose agent is back takes the ordinary interrupt-then-exit path. A tmux `missing` always refuses rather than claim a stop it cannot see. |
| `relaunch` | Replace the running agent with a new one in the same worktree - and the same endpoint whenever that endpoint still exists - on the exact recorded adapter or an explicitly chosen harness, model, and effort. A parked task is resumed instead. | The new agent is alive on the endpoint the task's record now names, and that record names the harness that is actually running. |
| `park` | Record the running agent's proven native session and the reason the work waits, exit the agent, and close only its endpoint. | The session and reason are in the task record, the Atlas ticket (when there is one) reads parked, the agent is stopped, and the endpoint is proven gone. The worktree, branch, record, backlog item, status log, and inbox stay. |
| `resume` | Reopen a parked task's recorded session with the harness's native resume, in the same worktree. | The Atlas ticket reads started, the resumed agent is alive, and the park record is cleared. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

`exit` reads the composer's state before typing the exit command and requires the exact `empty` verdict; a `pending` verdict refuses by naming the pending text, and any other verdict (`unknown`, `pending-unproven`, or an unreadable read) refuses as not proven empty, matching the fail-safe contract every other consumer that can overwrite composer input follows.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`park` and `resume` keep a conversation, and `relaunch` replaces it.**
A relaunch gives a new agent the brief plus a progress note, which works on every adapter because the brief on disk is the durable instruction.
A park keeps the conversation itself, so it exists only where a native session can be proven and reopened: claude, codex, pi, and pi-signed.
Every other adapter refuses `park` and `resume` by name and keeps `relaunch`.

## Park and resume

`park` is the one act for "worker gone, work preserved": a worker whose work waits on a decision, a merge word, a stop order, or a planned reboot.
The captain can then close that worker's pane and pick the same conversation up later with no information loss.
`bin/fm-control.sh`'s header owns the exact verbs, the six task-record keys, and every refusal.
[`bin/fm-native-session-lib.sh`](../bin/fm-native-session-lib.sh) owns which adapters have a native session, how each session is proven from the running worker, how it is found again, and the launch that reopens it.

A park proves the session before it changes anything, because a wrong id is worse than none: it resumes another conversation, or silently a fresh one.
Each proof comes from evidence the harness itself keeps for the exact running process, never from a guess such as the newest session file in the directory.
A session that cannot be proven refuses the park, and the worker keeps running.
The park also confirms that the resume will find the session where it looks for it.
For example, a Claude worker that uses another account profile's configuration refuses the park, because the resume launches with the configuration of the firstmate home.

The park then runs in this order:

1. Record the session and the reason in the task record.
2. Record the park on the task's Atlas ticket, when it has one, and require the Atlas to read that park back.
   The hook reports a refused park, and its `parked` read must then show the same reason and session, and a blocker only when one was sent.
   A refusal withdraws the record.
3. Stop the agent through `exit`.
   A refusal re-opens the ticket and withdraws the record.
   An agent's own short-lived child processes can make one state read unclassifiable, so park and resume re-sample a read for a few seconds before they act, and park retries a refused stop while the agent still reads alive.
4. Close only the endpoint, with proof that it is gone.
   On Herdr this uses the same primitives as teardown: the session presentation lock, the focus-preserving close for a projected task pane, otherwise the agent-axi slot release and the serialized close.
   A close that cannot be proven leaves the task parked and names the pane.
   The resume closes that pane if it is still in the task's worktree.

Parking a parked task again only updates its reason, blocker, and Atlas park.
It never closes a pane, because the recorded id can name another pane by then.
A ticket that was already parked still reads parked when the Atlas refuses the update, so the hook reports the refusal itself.
A retry of a park that the Atlas already holds is accepted, because the Atlas records an identical park as a no-op.
If the Atlas does not record the update, the prior park record stays.

A resume first confirms that the recorded session file still exists, where the resume will look for it.
A missing file refuses with the task still parked, and a resume never falls back to a fresh session.
It then returns the ticket to started (`ticket unpark`) and requires the Atlas to confirm that before it launches anything.
The launch goes through `bin/fm-spawn.sh --relaunch --resume-session`, so the fleet's launch environment and flags are the same as for any other launch.
Only the brief argument is replaced by the native resume of the recorded session.
The resume always opens a new endpoint directly in the recorded worktree and records it.
The park closed the old one, and its id can since name another pane, for example after a Herdr server restart, when pane ids start low again.
So only a pane that sits in the task's worktree counts as the task's own: an agent-free one, left by a park whose close never finished, is closed first, and an agent running there refuses the resume.
Any other pane is left alone.
On Herdr a stopped session server also reads `missing`, and the task's pane can come back with it, so a resume proves that absence with the server running and refuses, still parked, when it cannot.
The new endpoint adds an agent, so on Herdr a resume is held to the concurrent agent limit ([`docs/configuration.md`](configuration.md) "Concurrent agent limit") and refuses before it changes the ticket or any pane.
`--over-limit` lets one resume through, and a relaunch of a parked task takes it as well.
The resumed agent submits no prompt, so its busy state starts idle.
The park record is cleared only after the resumed agent is confirmed running.
A launch that fails after the unpark records the park on the ticket again.
A `--note` reaches the resumed agent as a durable inbox steer.
Its doorbell waits, for a bounded time, until the resumed agent's composer reads empty, because a doorbell typed while the TUI still replays the conversation can be lost.
The watcher re-rings an unhandled steer in any case.

A parked task is visible as parked everywhere firstmate reads the fleet.
`bin/fm-crew-state.sh` reports `parked` from `park` with the reason and the resume command.
The session-start digest and the fleet view print the endpoint as parked, not dead or absent.
The watcher raises no stale wake for it, and a steer sent to it waits in the inbox for the resume.
Recovery never restarts a parked task fresh: `relaunch` of a parked task runs the resume, and refuses a harness, model, or effort change for it.

## Transactional relaunch

`relaunch` is the only verb that changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
2. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which reuses the recorded worktree instead of creating one, adopts the recorded endpoint when it still exists, clears the previous harness's per-task wiring, and arms a fresh busy generation.
   When the recorded endpoint is proven gone rather than merely idle or unreachable - which only Herdr can establish - the launch owner creates one fresh endpoint in that same worktree and the republished record rebinds the task to it - see [Reclaiming a task whose endpoint is gone](#reclaiming-a-task-whose-endpoint-is-gone).

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Reclaiming a task whose endpoint is gone

A Herdr pane or workspace can be destroyed out from under a live task by churn or a session restart.
The task's worktree, branch, commits, and uncommitted changes all survive that; only its terminal does not.

**Reclaim is Herdr-only.** On tmux, both verbs refuse a `missing` endpoint, leaving it exactly as deadlocked as it was before this mechanism existed - deliberately, and with the reason stated rather than guessed past.

Two endpoint verdicts are agent-free, and both license a relaunch:

- `dead` - the endpoint exists and confidently holds no agent. It is **adopted**, so the task keeps its exact recorded address.
- gone, **proven** - there is no endpoint and therefore no agent, and it cannot be adopted, so the launch owner **creates one fresh endpoint in the recorded worktree** and the republished record rebinds the task to it.

That proof is its own step, because the classifier's `missing` is not one state: it conflates *the endpoint was destroyed* with *the endpoint is unreachable from here right now*.
An unreachable endpoint can still hold the live agent a rebind would duplicate, so absence is proven and never inferred from a failed read - and whether it is provable at all is a property of the backend:

- **Herdr can prove it.** Every read goes through the adapter's `--session <session>` CLI, so the recheck starts and reads the session the *record* names, through that session's own socket.
  It starts that server (only the server: no workspace and no tab are created) and **re-reads the recorded pane**.
  `dead` means the pane survived the restart and is adopted after all, with no second tab; `alive` means the agent came back and refuses; only a second `missing` proves the pane itself did not survive ([`docs/herdr-backend.md`](herdr-backend.md) "Restart and liveness behavior").
  That server start is a real side effect, and the parenthetical above does not cover it: when the recorded session's server no longer exists at all, the probe stands a fresh empty one up in order to ask, and nothing afterwards uses it.
  So in that state `exit` - which otherwise reads as a read-only inspection - leaves an idle herdr server behind.
- **tmux cannot.** `list-windows -a` describes only the tmux server the *current process* addresses (its `TMUX_TMPDIR`/socket), and a task record carries no socket identity for its endpoint.
  A different but running server would answer "not anywhere" about a window it was never able to see, so a server-wide read cannot tell a destroyed window from one on a server this process cannot address.
  There is no read available that closes that gap, so tmux always refuses - for a renamed session, a moved window, a foreign socket, and a dead server alike.

Every transient or self-contradicting read stays `unreadable` or `ambiguous` and still refuses, so a momentary backend failure can never be mistaken for absence.

That proof has one owner for the whole control plane (`fm_control_endpoint_absence_verdict` in `bin/fm-control-lib.sh`), so `exit` and `relaunch` cannot reach two different answers about one endpoint.
`exit` reports what the proof established and nothing more - see its row in the verb table above.

What a reclaim is not:

- It is **not a teardown**. The worktree is reused exactly as the previous agent left it; nothing unlanded is ever discarded, and the ordinary `--note` requirement still applies.
- It does **not** change the task's identity. The task id, its armed poll and registration, and its status log are untouched; only the endpoint binding in the record moves.
  Its instructions are the one exception, and only in the way an ordinary relaunch already changes them: a ship or scout reclaim appends the required `--note` under a `## Progress note (<timestamp>)` heading in `data/<id>/brief.md`, so re-read that brief rather than assuming it is byte-identical - a reclaim that failed and was retried leaves one block per attempt.
  A secondmate's standing charter is never rewritten.
- It is **not** a peer seat's operation. `fm-control` resolves an exact task id against **this** home's `state/`, so only the home that owns the task can reclaim it.
- It does **not** cover a secondmate. A secondmate whose endpoint is gone already has one owner for that recovery - `bin/fm-spawn.sh <id> --secondmate`, driven by the session-start liveness sweep - so relaunch refuses and names it rather than becoming a second path to the same outcome.

The re-created tab is opened in the herdr session the record names, never in whichever session the recovering seat happens to sit in - relocating a task onto another herdr server would be an identity change published as a self-consistent but wrong record.
A seat that *claims* a herdr launcher pane belonging to a different session is refused rather than allowed to place the endpoint somewhere else, so reclaim such a task from a seat in the recorded session.
A seat with no herdr launcher pane at all - a plain ssh or cron shell, which is the ordinary way an operator reclaims - is not refused: placement falls back to the recorded session's labeled container, so the tab still lands in the session the record names.
The reclaim pins the recorded **session** but not the **workspace**: the container follows the reclaiming seat, so a reclaim run from a seat inside the recorded session places the new tab in *that seat's* workspace rather than the recorded `herdr_workspace_id`, even when the recorded workspace still exists and only the pane was destroyed.
The record is republished consistently and no work is lost, but the task's `herdr_workspace_id` moves with it.
The pane id necessarily changes (the pane did not survive), and the record follows it.
A Herdr reclaim deliberately uses the flat container shape rather than presentation projection: projection is a presentation-only layout that is never endpoint or ownership authority, and flat is already the documented fallback for every recovery it cannot bind exactly ([`docs/herdr-backend.md`](herdr-backend.md)).

**Known limitation - a refusal before the record is republished leaves a stray husk pane** (follow-up bead `fm-herdr-rebind-leak-20260913`).
The rebind registers no abort cleanup, so a refusal in the window between the new tab being created and the record being republished leaves that pane behind while the record still names the old, gone one.
The stray pane holds a bare shell - the harness is not delivered until after publication - so the next reclaim cleans up after it: the re-created tab carries the same `fm-<id>` label, `tab create` finds it, classifies it a husk, and closes and replaces it.
That self-heals only when the retry resolves the *same* workspace, which the placement rule above does not guarantee.
The worktree and the task's records are unaffected either way.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Endpoint retirement

A task record names exactly one endpoint.
Any path that rewrites `window=` must therefore settle the endpoint the record stops naming, or that pane stays open with nothing pointing at it.
`relaunch` never has that problem, because it adopts the recorded endpoint: the task keeps exactly one pane and no close happens at all.
A REPLACEMENT spawn does have it.
That is a fresh [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) run on a task id this home already holds a record for, and it is how the secondmate liveness sweep and hand-driven stuck recovery replace a worker.

A replacement settles its previous endpoint in two halves.

**Before anything is created**, the spawn reads that endpoint's state and refuses unless it is positively agent-free or authoritatively absent.
This is the same rule `fm-spawn --relaunch` applies to the endpoint it adopts, and it is what makes the dangerous outcomes impossible rather than merely reported.
A live previous agent would otherwise keep running beside the replacement on the same recorded local copy with no record naming it, and an ambiguous or unreadable read is exactly the case where a close could end a working agent's turn.
A refusal here changes no record, no endpoint, and no local copy.
A backend with no recovery-grade classifier can never satisfy that read, so a replacement on zellij, orca, or cmux refuses by construction and its lifecycle is driven explicitly instead.

**After the replacement endpoint exists and before the new window value is written**, `fm_backend_endpoint_retire` in [`bin/fm-backend.sh`](../bin/fm-backend.sh) closes the old one.
It extends each adapter's existing `fm_backend_kill` primitive with proof rather than adding a second close implementation.
Its rules:

- An authoritatively absent endpoint is already retired, so nothing is closed.
- Only a positively agent-free endpoint is closed.
  Alive, ambiguous, unreadable, and unverified all refuse the endpoint untouched, matching `fm_backend_agent_state`'s own contract that only `dead` and `missing` license recovery.
- A close is followed by a structured read that must prove the exact endpoint gone.
  An ambiguous or unreadable probe is never proof, and a backend with no recovery-grade classifier can never produce one.
- The close is unlabelled, so it targets that one endpoint and nothing else.
  A labelled close reaches Herdr's `agent-axi teardown`, which resolves a pane from the slot ledger by task id, and a replacement has already pointed that slot at its new pane, so a labelled close would tear down the replacement instead of the endpoint it is retiring.
  Freeing a ledger slot stays with teardown and the layout repair sweep, which own it.

An endpoint the retire cannot close is named in the spawn's own report and in the liveness sweep's `SECONDMATE_LIVENESS:` line.
The replacement still lands there, because its agent is already running and the endpoint it strands is one the captain can close, while unwinding a live replacement is not.
An endpoint the replacement resolved to the same target was reused, so it is left alone.

Two boundaries this does not cross.
A remotely placed secondmate has no local endpoint to read or retire, so a replacement skips it and that lifecycle stays on its own host.
The close uses the adapter's ordinary unserialized primitive, the same one every non-teardown caller uses, so it carries Herdr's existing focus-movement behavior rather than teardown's focus-safe serialized path.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
  For `relaunch` that host-side drive is `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch ...`, whose host-local leg runs this same plane against a record that is ordinary and local there, so every checkpoint, journal, rollback, and postcondition below applies unchanged ([`docs/remote-secondmates.md`](remote-secondmates.md)); `interrupt` and `exit` have no such route.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit`, `relaunch`, `park`, and `resume` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- `exit`'s composer-empty check, above, is itself a fail-closed boundary that `relaunch` inherits by stopping the old agent through `exit`.
- `fm-spawn --relaunch` independently refuses unless the endpoint is positively agent-free - either a `dead` endpoint that survives, or a Herdr endpoint proven gone by the absence proof above - so a replacement can never join a live agent.
  An `alive`, `ambiguous`, or `unreadable` verdict all refuse, and so does any endpoint whose absence is not provable, which on tmux is every `missing`; absence is claimed only from positive evidence of it.
  It also requires the shell to be in the recorded worktree: tmux refuses immediately when it is not, while Herdr sends one `cd` to the recorded path and refuses unless a subsequent path read confirms the move.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Recovery-grade agent state |
| --- | --- | --- | --- | --- | --- |
| tmux | yes | yes | yes | yes | yes |
| herdr | yes | yes | yes | yes | yes |
| zellij | yes | yes | yes | yes | no |
| cmux | yes | yes | yes | yes | no |
| orca | no | yes | yes | no | no |

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`, with adapters outside its lane pinning their control mechanics in their own harness suites.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for its verified-harness lane (adapters outside the lane pin their control mechanics in their own harness suites), the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch, and the endpoint-absence proof both verbs share - the Herdr reclaim of a destroyed endpoint, and tmux refusing one it cannot prove absent.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-native-session.test.sh` - the native session proof per harness against real stand-in processes, the refusal of every session it cannot prove, the resume-time file check, the resume launch form, and the Pi worker extension's session record.
- `tests/fm-control-park.test.sh` - park and resume: the recorded session and reason, the Atlas park and unpark and their order, the endpoint close, every refusal with nothing changed, the new endpoint in the same worktree, the rollback after a launch that does not come up, and relaunch of a parked task.
- `tests/fm-park-resume-live-e2e.test.sh` - opt-in live proof in an isolated Herdr lab: real claude, codex, and pi workers each learn a fact, are parked with their panes closed, are resumed (claude after a lab server restart), and recall the fact.
- `tests/fm-endpoint-retire.test.sh` - endpoint retirement on both state-verified backends: the proven close, the live-agent refusal, the unproven close, the replacement spawn's ordering and leftover report, and a relaunch that opens and closes nothing.
