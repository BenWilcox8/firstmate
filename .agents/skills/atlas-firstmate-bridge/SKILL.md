---
name: atlas-firstmate-bridge
description: >-
  Agent-only reference for composing the Atlas ticket doctrine with the AGENTS.md contract.
  Load in an Atlas-wired home before dispatching, landing, or tearing down ticketed work, and whenever an Atlas instruction and AGENTS.md appear to disagree.
  Owns the dispatch order, the merge-kind mapping, the captain-word recording, the concurrency precedence, the heartbeat headroom duty, the ghost-leg repair, and the ledger that names one owner for every known contradiction between the two surfaces.
user-invocable: false
metadata:
  internal: true
---

# atlas-firstmate-bridge

The Atlas doctrine and this repo's contract were written apart.
`atlas-supervising` and `atlas-working` live in the captain's dashboard repo and know nothing about projects, backlog items, delivery modes, worktrees, or hard rules.
AGENTS.md knows nothing about nodes, tickets, ready rows, or headroom.
Read literally and together, the two surfaces contradict each other at points where the result is a crewmate that lands work with no captain word, or a running Atlas leg that firstmate cannot supervise.
This skill is the single owner of how they compose.
It adds no new lifecycle.
It states which surface binds at each collision, and every ruling below resolves toward this repo's hard rules.

## Scope

This skill applies only in an Atlas-wired home, which is a home whose `config/specs` names a local Atlas repo.
A home without that pointer owes the Atlas nothing, must not hand-write ticket state into another home's map, and can ignore the whole doctrine.
`bin/fm-atlas-hook.sh` gates on the same pointer, so a home that cannot satisfy the doctrine also makes no Atlas call.
`atlas-supervising` and `atlas-working` are carried by the dashboard repo, not by this one.
If this session cannot resolve them, say so and stop rather than improvising the ticket procedure from memory.

## The one rule that resolves the rest

The Atlas is a map of work, never an authority over work.
An Atlas ticket describes what to build and what a supervisor can pick up unasked.
It never grants authority this repo withholds.
Where a ticket field and a hard rule disagree, the hard rule binds, and the ticket field is a planning value that firstmate translates.

## Node hygiene

Design and plan with nodes and regions first.
Work is conceived as changes to nodes, carried by tickets on those nodes.
These rules moved here from AGENTS.md so an agent holding only repo-tracked material still has them.

An iteration of existing work is a new ticket on the existing node.
Never create a "round 2" or "v2" node for an iteration.
A genuine replacement strikes the old node and creates the new one.
Ephemeral work, such as an audit, an investigation, or a purely informational task, goes on an errand node and never on a feature node.

## Dispatch order

A ready ticket is a work-next row, not a dispatch.
Dispatch in this exact order, and treat any shortcut as a refusal to dispatch at all:

1. Read the ready row and resolve intake under AGENTS.md section 7: project, secondmate route, ship or scout, delivery mode, and `yolo` posture.
   The ticket supplies none of these.
2. File the backlog work item in this home.
   Where the backlog transition gate applies, `bin/fm-spawn.sh` refuses a task with no dispatchable item, so a missing item stops the dispatch before any record exists.
   A manual-backend home gets no such refusal and still owes the item, because AGENTS.md section 10 keeps filing with the supervisor either way.
3. Write the brief, then run `bin/fm-spawn.sh ... --ticket <c7>`.
   The spawn validates isolation, records the task, and commits the backlog transition first.
4. The spawn itself calls `bin/fm-atlas-hook.sh start`, which issues `atlas-axi ticket start`.

**Never run `atlas-axi ticket start` as the dispatch act.**
`atlas-supervising` calls `start` a dispatch, and inside the Atlas it is one.
In a firstmate home it creates a running leg with no backlog row, no task record, no isolated worktree, and no supervision, so AGENTS.md section 8's "no turn ends blind" cannot see the work at all.
The hook writes the Atlas strictly after the spawn commits, so a rolled-back spawn leaves no started ticket behind.
`--ticket` is refused for batch dispatch, so eight ready rows are eight separate spawns.

## The ready flag

Ready is a dispatch-timing authorization and nothing else.
It removes one captain prompt: "may I start this queued ticket now?".
That gate was already paid at queue time, where `--captain-surface` and `--story` are both refusals.
Ready does not resolve a project, a route, a delivery mode, or a `yolo` posture, and it never touches landing.
Hard rule 2 and AGENTS.md section 7 intake are unchanged by it.

## Merge kind and delivery mode

The two surfaces use one shared word for two different fields.
The ticket's merge kind is a planning value.
The task's delivery mode, resolved at intake and passed to the brief and the spawn, is what the worker actually follows.

| Ticket merge kind | Delivery mode firstmate resolves | Who lands it |
| --- | --- | --- |
| `no-mistakes` | `no-mistakes` | The configured merge authority, through `bin/fm-pr-merge.sh` |
| `normal` | `direct-PR` or `local-only`, chosen at intake by the project's registry posture | The configured merge authority, through `bin/fm-pr-merge.sh` or `bin/fm-merge-local.sh` |

**`normal` never authorizes a crewmate to fast-forward the default branch.**
`atlas-working` tells a crewmate under `normal` to rebase and fast-forward main itself.
In a firstmate project that act belongs to firstmate, hard rule 2 governs it, and `bin/fm-merge-local.sh` owns the guarded landing.
A crewmate's part always ends with the branch committed and ready.
When you queue a ticket `--merge normal`, say so in the brief in one line, so the crewmate reaches that fact before it reaches the skill's own text.

## Review kind and the captain gate

The Atlas review kinds are a second, independently configured captain gate beside hard rule 2.
They compose by addition, never by substitution:

- `human` and `adversarial-then-human` block the Atlas merge stage until the captain's word is recorded, and hard rule 2 still governs the actual merge.
- `adversarial` records no captain approval, so a `yolo`-off project still needs the captain's word before anything lands.

An Atlas approval is never a merge authorization, and `yolo` never satisfies an Atlas captain-review gate.

### Recording the captain's word

The Atlas refuses `ticket complete` and `land` for a ticket that waits on the captain's approval, and for a ticket that promised the captain a look (`captain-review` on its path and a captain surface other than `none`) but has no testing brief.
The captain usually gives the word in chat, not on the dashboard.
**When the captain authorizes a merge or accepts delivered work in chat, record the captain's exact words as the Atlas approval.**
Pass them to the guarded path that closes the ticket, as `--captain-word "<the captain's exact words>"`:

- `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` for a merge, beside `--captain-authorized` when the project's posture needs that flag;
- `bin/fm-teardown.sh` for work that is accepted at cleanup, such as a scout report.

The hook then runs `atlas-axi ticket approve <c> --word "<words>"` before it completes the ticket.
Quote the captain, never a paraphrase, and never pass words the captain did not say.
The flag is optional: without it, the close-out is attempted as before, and a refusal follows the rule in "Ghost legs" below.
A recorded approval does not satisfy the testing-brief gate, which still needs a `ticket testing` handover.

### The adversarial reviewer

`atlas-working` requires a committed `.claude/agents/adversarial-reviewer.md`.
This repo does not carry that file, does not ship harness-specific agent files, and does not create one in a project clone.
**The substitution, recorded here as the ruling:** in a firstmate-delivered project, the Atlas `review` stage is discharged by the selected delivery path's own review gate.
For `no-mistakes` that is the pipeline's automated review, which is wider than the ticket-scoped adversarial pass and runs before the PR.
For `direct-PR` and `local-only` there is no automated review, so queue such a ticket `--review human` or run the read-only reviewer from the supervising session instead.
Where a project genuinely wants the committed agent file, it belongs in that project's own repo, never in firstmate's tracked material.

## Concurrency precedence

AGENTS.md section 7 governs parallelism: dispatch isolated work immediately, with no cap beyond the agent limit, and serialize only for a true semantic dependency or shared mutable state.
The resource ceiling on the captain's machine is firstmate's concurrent agent limit, not a parallelism doctrine: `bin/fm-agent-count.sh` reads the crewmate agents really open in Herdr against `config/agent-limit`, and `bin/fm-spawn.sh` enforces it ([`docs/configuration.md`](../../../docs/configuration.md) "Concurrent agent limit").
Read room from that count, not from `atlas-axi limit` or `atlas-axi headroom`, which count started tickets, including parked work and ghost legs.
Treat a full reading as "no room right now", which is a line in your own report and a reason to wait, never a reason to call independent work dependent.
Pass `--over-limit` only when the captain asks for more concurrency.
Neither counter is a liveness fact for one task.
`bin/fm-crew-state.sh` and the recorded backend endpoint remain the only liveness truth.
One node holds one crewmate, so two tickets on one node serialize even when the work is independent.

## The heartbeat headroom duty

`atlas-supervising` adds a dispatch decision to every heartbeat, and AGENTS.md section 8's heartbeat contract does not mention it.
Both hold, in this order.
Run the heartbeat as AGENTS.md states it: review the whole fleet, reconcile suspicious tasks and PR state, and update the backlog.
Then, if there is room and ready tickets are queued, dispatch the next ready one by the dispatch order above, with no captain prompt.
Room with nothing ready is nothing to do.
No room is a line in your own report, never a dispatch you let fail at the gate.

## Ghost legs

A ghost leg is a started ticket whose node is still held after its work stopped.
One node holds one crewmate, so the next ticket on that node cannot be started by anyone.
`bin/fm-atlas-hook.sh` owns the automatic close-outs; this section owns what firstmate must still do by hand.

**A refused close-out.**
When the Atlas refuses the merge or cleanup close-out, the hook still releases the node and writes one keyed line to the task's status log: `blocked [key=atlas-gate-<ticket>]: ...`, naming the ticket and the missing gate.
Cleanup writes that line after it retires the task's records, so it stays as an orphan status log.
The merge or cleanup itself is unchanged, and the ticket stays started.
To resolve it: get the missing gate, which is the captain's word (`atlas-axi ticket approve <c> --word "<words>"`) or a testing brief (`atlas-axi ticket testing <c> ...`), then run `atlas-axi ticket complete <c>` with the evidence and a summary, and land the node when no open ticket remains.
Then append `resolved [key=atlas-gate-<ticket>]: <how>` to that same status log.

**A forced cleanup that discards work.**
A forced cleanup of a leg that produced nothing aborts the ticket back to the queue, which also releases the node.
A forced cleanup that discards real work records nothing, which is correct: it proves nothing, and recording it as landed would write a false fact into a log that replays forever.
That ticket stays started and its node stays held.
**After a forced cleanup that discarded real work on a ticketed task, release the node by hand with `atlas-axi`, and record the truth: the work was discarded, not landed.**
Do this in the same turn, because nothing later will remind you.

## Duties this doctrine places on the home

- Register the dashboard repo (`agent-dashboard`) in `data/projects.md`.
  The Atlas operating skills and the Atlas store documentation live there, and an unregistered clone is invisible to fleet sync and to `/updatefirstmate`.
- Write the `atlas-working` pointer and the ticket id into a ticketed crewmate's brief by hand.
  No brief scaffold carries Atlas content, and `tests/fm-brief.test.sh` keeps the generated scaffolds signal-free on purpose.
  A crewmate that is never told to read `atlas-working` cannot walk the stages its ticket declares.
- Add the `normal` merge-kind line above to that same brief whenever the ticket carries `--merge normal`.
- On a wired home, `bin/fm-spawn.sh` launches every ship and scout worker with `ATLAS_REPO` and `ATLAS_AXI_BY`.

## Recorded captain rulings

- **2026-08-28: `--story` is required.**
  Every Atlas verb that births a ticket refuses without it.
  This is a captain ruling, so it is recorded here rather than only in the dashboard repo.

## Contradiction ledger

Each known collision between the two surfaces, and the one line that owns it.

| Collision | Owner |
| --- | --- |
| `atlas-axi ticket start` presented as the dispatch act | "Dispatch order" above: never the dispatch act, and the spawn's hook writes it |
| `normal` merge kind tells a crewmate to fast-forward main | "Merge kind and delivery mode": the crewmate never lands |
| Crewmate merge authority is stated nowhere | Same section: a crewmate's part always ends with the branch committed |
| AGENTS.md claimed briefs point crewmates at `atlas-working` | "Duties this doctrine places on the home": firstmate writes that pointer by hand |
| `.claude/agents/adversarial-reviewer.md` exists nowhere | "The adversarial reviewer": the delivery path's review gate is the substitution |
| Atlas ticket headroom against the Herdr agent cap | "Concurrency precedence": AGENTS.md governs parallelism, and the live Herdr count is the resource ceiling |
| `no-mistakes` names two different fields | "Merge kind and delivery mode": the mapping table, delivery mode binds |
| Atlas captain-review against hard rule 2 | "Review kind and the captain gate": the two gates add, neither replaces the other |
| Headroom counts a population firstmate does not | "Concurrency precedence": headroom is never a liveness fact |
| Ready flag read as an intake or merge authorization | "The ready flag": dispatch timing only |
| Heartbeat duties differ between the surfaces | "The heartbeat headroom duty": AGENTS.md order first, then the dispatch decision |
| Forced cleanup that discards work strands a held node | "Ghost legs": release by hand in the same turn |
| The captain gate refuses a close-out, and the captain's chat word never reaches the Atlas | "Recording the captain's word" and "Ghost legs": pass `--captain-word`, and resolve each `atlas-gate` line |
| The doctrine mandated from homes with no Atlas | "Scope": the doctrine binds only an Atlas-wired home |
| The mandated Atlas skills live only in the dashboard repo | "Scope" and "Duties this doctrine places on the home": register that repo, and stop rather than improvise when a skill will not resolve |
| The `--story` ruling recorded only outside this repo | "Recorded captain rulings" above |
