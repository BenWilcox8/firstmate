---
name: firstmate-signalling
description: >-
  Agent-only reference for the firstmate-side delta on top of the dashboard-owned `dashboard-signals` skill.
  Load at session start in every firstmate and secondmate session, and reload when an instruction-update nudge arrives.
  Owns the routine-wake close-out command that ends a wake turn instead of a chat line, the crewmate exclusion, and the one-ask-per-decision routing rule between a secondmate and the main firstmate.
user-invocable: false
metadata:
  internal: true
---

# firstmate-signalling

The captain watches this session on a dashboard rather than reading the raw pane.

The signal protocol itself is owned by the `dashboard-signals` skill, which the agent-dashboard project installs at the user level.
Load that skill for the verbs (`atlas-axi ask`, `review`, `status`, `notif`), the option-list rule, the `%%dash-fin%%` and `%%dash-ans%%` marker grammar, the answer loop, the ban on harness-native pickers, and what to do when a signal fails.
Nothing here restates it.
The verbs ship from the same project as that skill, so a home without it has no dashboard to signal; the rules below still apply to everything else.

This skill owns only what is true of firstmate sessions and nothing else.

## Crewmates escalate instead of asking

The owner already reserves `ask` and `review` for firstmates and secondmates, and already lets any agent label its own phases.
This is the firstmate side of that boundary, and it does not narrow what the owner grants.

A crewmate reports to firstmate through its status file and firstmate relays, by captain decision (2026-07-27).
So the crewmate scaffold carries no dashboard instructions at all: never add signal instructions to a ship or scout brief.
A crewmate that needs the captain raises it with firstmate, which decides whether to signal.

## Routine wake close-out

Most wakes need no narration: a watcher nudge, a turn-end check, a heartbeat, a scheduled or self-set check-in, a steer you simply carried out.
End that turn with the close-out command and nothing else:

    bin/fm-ping-ack.sh --origin script|agent [--wake <key>] [--note "<short>"]

`--origin` says who caused the wake and is never inferred: `script` for a mechanism (a watcher nudge, a turn-end check, a heartbeat, a scheduled check-in), `agent` for a person or agent (a supervisor steer, a worker escalation, a routed reply).
The command refuses without it, because a guessed origin mis-files the wake on the captain's dashboard.
`--note` is optional and holds a handful of words, not a sentence of narration.
The command prints the `%%dash-ping: <origin>%%` marker and records the close-out durably; the dashboard folds it under its own type so the captain's timeline shows work rather than acknowledgements.

Only ROUTINE acknowledgements move to the command.
A real finding, a decision, a failure, a blocker, or anything the captain must act on is still written in prose and still goes through the signal verbs.
When you are unsure whether a wake is routine, it is not.

The close-out replaces the chat line, never firstmate's durable wake acknowledgement: the queue is still acknowledged exactly as the drain prints it.

## One question per decision, across homes

A secondmate that asks the captain directly must tell the main firstmate that it already asked.
Without that, the main firstmate re-raises the same decision and the captain answers it twice.
