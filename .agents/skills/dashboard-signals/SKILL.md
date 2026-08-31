---
name: dashboard-signals
description: >-
  Agent-only reference for signalling the captain's dashboard from a firstmate or secondmate session.
  Load at session start, and reload when an instruction-update nudge arrives.
  Owns the four atlas-axi signal verbs (ask/review/status/notif), the routine-wake close-out command that ends a wake turn instead of a chat line, the numbered-notification and %%dash-fin%% marker rules, and the hard ban on harness-native pickers for captain decisions.
user-invocable: false
metadata:
  internal: true
---

# dashboard-signals

The captain watches this session on a dashboard rather than reading the raw pane.
This skill is the single owner of how a firstmate or secondmate session signals that dashboard.

Scope is firstmate and secondmate sessions only.
Crewmates are deliberately out of scope by captain decision (2026-07-27): a crewmate reports through its status file and firstmate relays, so the crewmate scaffold carries no dashboard instructions.
The wire protocol, marker grammar, and dashboard-side rendering are owned by `/home/ben/apps/agent-dashboard/docs/message-markers.md`; consult it rather than restating it here.

## Signal verbs

`atlas-axi` is on `PATH`; `spec-axi` remains a compatible alias for these verbs.
Each verb prints one word on success except `ask`, which prints the notification number it raised (e.g. `asked n47`); note it and carry on.

- `atlas-axi ask "<question>"` - you are BLOCKED on a human decision and need the captain's answer.
  Run it once per independent question.
  It prints the notification number it raised, e.g. `asked n47` - remember it.
  When the decision is a pick from a few choices, offer them so the captain can tap one: `atlas-axi ask "which db?" --options "postgres,mysql,sqlite"`.
  Options are optional; omit them for a free-text question.
- `atlas-axi review "<concise summary>"` - you FINISHED something the captain should look at: work ready for review, a finished design, a completed investigation.
  It is non-blocking, so move on immediately; the captain marks it reviewed when handled.
  Use this, not `ask`, whenever you are proceeding either way.
- `atlas-axi status "<2-6 words>"` - label the timeline when you start or finish a distinct phase of work.
  Once per phase is enough.
- `atlas-axi notif nNN` - read a notification by its number, whether yours or one you were pointed at.
  It prints the question/summary, who raised it, and whether the captain has answered and with what.
  Pass `--json` for the raw record.

## Routine wake close-out

Most wakes need no narration: a watcher nudge, a turn-end check, a heartbeat, a scheduled or self-set check-in, a steer you simply carried out.
End that turn with the close-out command and nothing else:

    bin/fm-ping-ack.sh --origin script|agent [--wake <key>] [--note "<short>"]

`--origin` says who caused the wake and is never inferred: `script` for a mechanism (a watcher nudge, a turn-end check, a heartbeat, a scheduled check-in), `agent` for a person or agent (a supervisor steer, a worker escalation, a routed reply).
The command refuses without it, because a guessed origin mis-files the wake on the captain's dashboard.
`--note` is optional and holds a handful of words, not a sentence of narration.
The command prints the `%%dash-ping: <origin>%%` marker and records the close-out durably; the dashboard folds it under its own type so the captain's timeline shows work rather than acknowledgements.

Only ROUTINE acknowledgements move to the command.
A real finding, a decision, a failure, a blocker, or anything the captain must act on is still written in prose and still goes through the verbs above.
When you are unsure whether a wake is routine, it is not.

The close-out replaces the chat line, never firstmate's durable wake acknowledgement: the queue is still acknowledged exactly as the drain prints it.

## Marker rules

Put `%%dash-fin%%` on its own line immediately before the final answer of every substantive message, with any working narration above it.
That marker stays inline in the message; everything else goes through the verbs above.

An answer to your `ask` arrives later as an ordinary message in this session prefixed:

    %%dash-ans%% %%dash-ref: n47%% <the captain's words>

The `%%dash-ref: nNN%%` marker lets you match the answer to the question when two questions are open; pull the number with `/%%dash-ref:\s*([^%]*)%%/` (comma-separated if one reply answers several; absent on an older-style answer, which is fine).
Do not idle waiting for it when there is other work you can safely continue.

## Never use a harness-native picker for a captain decision

Do not use TUI select dialogs, interactive CLI prompts, or the `AskUserQuestion` tool to put a decision to the captain.
The captain is remote and watching the dashboard, so those surfaces cannot be seen or answered and will deadlock or drop the question.
Encode the choices in `--options` instead.

## One question per decision

If you need a human decision, pick either escalating to your supervisor or asking the captain directly, never both.
Exactly one question should reach the captain per decision.
A secondmate that asks the captain directly must tell the main firstmate it already asked.

## When a signal fails

Note the failure and keep working.
Never retry-loop or stall on a signal.
