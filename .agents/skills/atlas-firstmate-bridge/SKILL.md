---
name: atlas-firstmate-bridge
description: >-
  Agent-only supervisor half of the optional Atlas module.
  Load in an Atlas-wired home at the points its session-start Atlas block names: every intake, before dispatching, landing, or cleaning up ticketed work, at every heartbeat, and whenever an Atlas instruction and AGENTS.md appear to disagree.
  Owns every supervisor-side Atlas rule: scope, node hygiene, the captain surface, secondmate messages, the dispatch order, the ready flag, the merge-kind mapping, the review gate, the captain-word recording, how a ticket closes, concurrency, the heartbeat duty, ghost legs, and the ledger that names one owner for every known contradiction.
user-invocable: false
metadata:
  internal: true
---

# atlas-firstmate-bridge

The Atlas doctrine and this repo's contract were written apart.
`atlas-supervising` and `atlas-working` live in the captain's dashboard repo and know nothing about projects, backlog items, delivery modes, worktrees, or hard rules.
AGENTS.md knows nothing about nodes, tickets, ready rows, or headroom.
This skill is the single owner of how they compose on the supervisor side.
It adds no new lifecycle.
It states which surface binds at each collision, and every ruling below resolves toward this repo's hard rules.

This skill is one part of the optional Atlas module, and `docs/atlas-module/README.md` is the map of all parts.
The session-start Atlas block says when to load this skill.
The worker half is `docs/atlas-module/crewmate-brief.md`, which spawn appends to a ticketed worker's launch brief.

## Scope

This skill applies only in an Atlas-wired home, which is a home whose `config/specs` names a local Atlas repo.
A home without that pointer owes the Atlas nothing, gets no Atlas instructions, and must not hand-write ticket state into another home's map.
`bin/fm-atlas-hook.sh` gates on the same pointer, so a home that cannot satisfy the doctrine also makes no Atlas call.
`atlas-supervising` and `atlas-working` are carried by the dashboard repo, not by this one.
If this session cannot resolve them, say so and stop rather than improvising the ticket procedure from memory.

## The one rule that resolves the rest

The Atlas is a map of work, never an authority over work.
An Atlas ticket describes what to build and what a supervisor can pick up unasked.
It never grants authority this repo withholds.
Where a ticket field and a hard rule disagree, the hard rule binds, and the ticket field is a planning value that firstmate translates.

## The map and node hygiene

In a wired home, the Atlas is the primary shared surface of truth for this home's work.
Keep it current: every node and region represents a feature or an aspect of its project that exists now.

Design and plan with nodes and regions first.
Work is conceived as changes to nodes, carried by tickets on those nodes.
An iteration of existing work is a new ticket on the existing node.
Never create a "round 2" or "v2" node for an iteration.
A genuine replacement strikes the old node and creates the new one.
Ephemeral work, such as an audit, an investigation, or a purely informational task, goes on an errand node and never on a feature node.

## The captain surface

Every ticket names where the captain tests and reviews its work, and `ticket queue` refuses without `--captain-surface`.
Declare that surface when you queue the ticket.
When the project's `AGENTS.md` names a standing captain surface, use it.
When you are not sure of the right surface, do not queue the ticket: ask the captain, with a recommendation.

## Messages from a secondmate

As a strong default, every message a secondmate sends includes some Atlas action.
That is a ticket queued, started, recorded, or closed; a node created, described, or reconciled; or a signal.
Pure question-answering, configuration relays, and bare acknowledgments are the named exceptions.

## Dispatch order

A ready ticket is a work-next row, not a dispatch.
A worker is spawned to work one ticket, and it is removed when that ticket's work closes.
Dispatch in this exact order, and treat any shortcut as a refusal to dispatch at all:

1. Read the ready row and resolve intake under AGENTS.md section 7: project, secondmate route, ship or scout, delivery mode, and `yolo` posture.
   The ticket supplies none of these.
2. File the backlog work item in this home.
   Where the backlog transition gate applies, `bin/fm-spawn.sh` refuses a task with no dispatchable item, so a missing item stops the dispatch before any record exists.
   A manual-backend home gets no such refusal and still owes the item, because AGENTS.md section 10 keeps filing with the supervisor either way.
3. Write the brief, then run `bin/fm-spawn.sh ... --ticket <c7>`.
   The spawn validates isolation, records the task and its ticket, and commits the backlog transition first.
   It appends the crewmate half of this module to the worker's launch brief, so never add Atlas instructions to a brief or a charter by hand.
4. The spawn itself calls `bin/fm-atlas-hook.sh start`, which issues `atlas-axi ticket start`.

**Never run `atlas-axi ticket start` as the dispatch act.**
`atlas-supervising` calls `start` a dispatch, and inside the Atlas it is one.
In a firstmate home it creates a running leg with no backlog row, no task record, no isolated worktree, and no supervision, so AGENTS.md section 8's "no turn ends blind" cannot see the work at all.
The hook writes the Atlas strictly after the spawn commits, so a rolled-back spawn leaves no started ticket behind.
`--ticket` is refused for batch dispatch, so eight ready rows are eight separate spawns.
`--ticket` is also refused with `--relaunch`, because a relaunch keeps the ticket that its task record names.
A ship or scout spawned without `--ticket` in a wired home gets a one-line warning, because it will not appear on the map.

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

**`normal` never authorizes a worker to fast-forward the default branch.**
`atlas-working` tells a worker under `normal` to rebase and fast-forward main itself.
In a firstmate project that act belongs to firstmate, hard rule 2 governs it, and `bin/fm-merge-local.sh` owns the guarded landing.
The crewmate half of this module tells every ticketed worker that its part ends with the branch committed and ready.

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
The flag is optional: without it, the hook attempts the close-out with no approval, and a refusal follows "A refused close-out" in "Ghost legs" below.
A recorded approval does not satisfy the testing-brief gate, which still needs a `ticket testing` handover.

### The adversarial reviewer

`atlas-working` runs the review stage with a committed `.claude/agents/adversarial-reviewer.md`.
That file belongs to the project repo: the dashboard repo carries one, and some project clones carry one.
Firstmate's tracked material never carries it, and firstmate never creates one in a project clone.
**The ruling:** when the project carries the file, the worker uses it.
When it does not, the selected delivery path's own review discharges the Atlas `review` stage.
For `no-mistakes` that is the pipeline's automated review, which is wider than the ticket-scoped adversarial pass and runs before the PR.
For `direct-PR` and `local-only` there is no automated review, so queue such a ticket `--review human`, or run a read-only reviewer from the supervising session instead.
The crewmate half of this module carries the worker's side of this ruling.

## What a worker can write

The crewmate half of this module is the single owner of what a worker can change on the Atlas.
In short: a worker restages, records checkpoints, and hands over to testing on its own ticket, and every write carries its own author name.
It never closes a ticket and never frees a node.
Never ask a worker to complete, land, abandon, abort, or release, and never pass it a `--repo` or `--by` for its Atlas commands.
Every ship and scout worker is launched with `ATLAS_REPO` and `ATLAS_AXI_BY`, so a bare `atlas-axi` reaches this home's map and is attributed to that task.

## How a ticket closes

A ticket closes in one of these ways, and never by its worker.

1. **Automatically, when the guarded merge path lands the work.**
   This is the main way.
   `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` complete the task's recorded ticket after the merge.
   `bin/fm-teardown.sh` completes it and lands the node after cleanup proves the work landed, which also covers a PR that merged outside `bin/fm-pr-merge.sh`.
   `bin/fm-atlas-hook.sh` owns those calls and their evidence.
   So spawn ticketed work with `--ticket`, and land it only through those guarded paths.
2. **By hand, by a supervisor.**
   A firstmate or secondmate can close a ticket itself with `atlas-axi ticket complete <c> --evidence "..." --summary "..."`.
   Do this for work that landed while its task record held no ticket.
   Do it also for a refused close-out after its gate is met, and for any other ticket that the hooks cannot reach.
   Then release the node, and land it when no open ticket remains on it.
3. **Back to the queue, when a dispatch produced nothing.**
   Cleanup aborts the ticket with `ticket abort`, which also frees the node.
   Only cleanup does this, and only for a leg that produced nothing.

A ticket whose work will not happen is abandoned with `atlas-axi ticket abandon`, by a supervisor, and only when the captain agrees.

## Concurrency precedence

AGENTS.md section 7 governs parallelism: dispatch isolated work immediately, with no cap beyond the agent limit, and serialize only for a true semantic dependency or shared mutable state.
The resource ceiling on the captain's machine is firstmate's concurrent agent limit, not a parallelism doctrine: `bin/fm-agent-count.sh` reads the crewmate agents really open in Herdr against `config/agent-limit`, and `bin/fm-spawn.sh` enforces it ([`docs/configuration.md`](../../../docs/configuration.md) "Concurrent agent limit").
Read room from that count, not from `atlas-axi limit` or `atlas-axi headroom`, which count started tickets, including parked work and ghost legs.
Treat a full reading as "no room right now", which is a line in your own report and a reason to wait, never a reason to call independent work dependent.
Pass `--over-limit` only when the captain asks for more concurrency.
Neither counter is a liveness fact for one task.
`bin/fm-crew-state.sh` and the recorded backend endpoint remain the only liveness truth.
One node holds one worker, so two tickets on one node serialize even when the work is independent.

## The heartbeat duty

This section is the single owner of the Atlas part of every heartbeat.
Do these steps in this order:

1. Run the heartbeat as AGENTS.md section 8 states it: review the whole fleet, reconcile suspicious tasks and PR state, and update the backlog.
2. Run `atlas-axi dispositions` for each project root this home works, and give every open ticket that needs one its disposition.
   A started ticket whose worker is gone is a ghost leg; handle it as "Ghost legs" says.
3. While the agent count shows room (see "Concurrency precedence") and ready tickets wait, dispatch the next ready ticket by the dispatch order above, with no captain prompt.
   Room with nothing ready is nothing to do.
   No room is a line in your own report, never a dispatch you let fail at the gate.

## Ghost legs

A ghost leg is a started ticket whose worker is gone.
One node holds one worker, so the next ticket on that node cannot start until the ghost is settled.
These are the known causes:

- a refused close-out;
- a forced cleanup that discarded work;
- a task record that never held the ticket;
- a worker lost to a restart;
- a node released to put a second worker on it.

Settle each ghost by what is true:

- Finished work that nobody closed: close it by hand, as "How a ticket closes" says.
- Real work that waits for the captain or a merge: defer it with `atlas-axi defer <node> --ticket <c> "<why>"`, naming the blocker with `--on` when one exists.
- Work that will not happen: abandon it only when the captain agrees.

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
- Keep Atlas rules out of this home's `captain.md`, `learnings.md`, and every charter.
  A captain preference about the Atlas belongs in `data/captain-shared.md` on the main home, and a rule belongs in this module.

## Recorded captain rulings

- **2026-08-28: `--story` is required.**
  Every Atlas verb that births a ticket refuses without it.
- **2026-09-22: workers change their own ticket only in specific ways, and never close it.**
  A worker can move its ticket's stages, add notes, and hand over to testing, and every move says who made it.
  Tickets close automatically after the merge, and a supervisor can also close one by hand.
- **2026-09-22: the Atlas integration is a separate module.**
  AGENTS.md, core scripts, and secondmate charters carry no Atlas doctrine, so firstmate and the Atlas update independently.
  `bin/fm-atlas-boundary-check.sh` enforces this.

## Contradiction ledger

Each known collision between the two surfaces, and the one line that owns it.

| Collision | Owner |
| --- | --- |
| `atlas-axi ticket start` presented as the dispatch act | "Dispatch order": never the dispatch act, and the spawn's hook writes it |
| `normal` merge kind tells a worker to fast-forward main | "Merge kind and delivery mode", and the crewmate half: the worker never lands |
| Who may write the Atlas: the shared captain file said workers never write, `atlas-working` says they write at every stage | The crewmate half owns worker writes; "What a worker can write" points to it |
| Three owners for completing a ticket: `atlas-supervising`, this skill, and the hooks | "How a ticket closes": the guarded merge path, or a supervisor by hand, never the worker |
| Briefs had no path to `atlas-working` | "Dispatch order": the spawn appends the crewmate half to every ticketed launch brief |
| The adversarial reviewer file was said to exist nowhere | "The adversarial reviewer": the file is project-owned, and the delivery path's review stands in when a project lacks it |
| Atlas ticket headroom against the Herdr agent cap | "Concurrency precedence": AGENTS.md governs parallelism, and the live Herdr count is the resource ceiling |
| `no-mistakes` names two different fields | "Merge kind and delivery mode": the mapping table, delivery mode binds |
| Atlas captain-review against hard rule 2 | "Review kind and the captain gate": the two gates add, neither replaces the other |
| Headroom counts a population firstmate does not | "Concurrency precedence": headroom is never a liveness fact |
| Ready flag read as an intake or merge authorization | "The ready flag": dispatch timing only |
| Heartbeat duties differed between AGENTS.md, this skill, and the supervision protocol | "The heartbeat duty": the one owner, and the supervision protocol stays Atlas-free |
| Forced cleanup named as the only cause of ghost legs | "Ghost legs": every known cause, and how to settle each |
| The captain gate refuses a close-out, and the captain's chat word never reaches the Atlas | "Recording the captain's word" and "Ghost legs": pass `--captain-word`, and resolve each `atlas-gate` line |
| Every project was said to name its captain surface in its `AGENTS.md` | "The captain surface": the ticket declares it, and a project's standing surface is used when it has one |
| Secondmate charters and per-home notes each carried their own Atlas rules | "Duties this doctrine places on the home": charters stay Atlas-free, and this module holds the rules |
| The doctrine mandated from homes with no Atlas | "Scope": the doctrine binds only an Atlas-wired home |
| The mandated Atlas skills live only in the dashboard repo | "Scope" and "Duties this doctrine places on the home": register that repo, and stop rather than improvise when a skill will not resolve |
| The `--story` ruling recorded only outside this repo | "Recorded captain rulings" |
