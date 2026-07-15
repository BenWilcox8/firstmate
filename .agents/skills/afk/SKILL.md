---
name: afk
description: Enter away-mode supervision. Use when the user invokes /afk (e.g. "/afk", "/afk back in an hour", "going afk"). Sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate captain-relevant events plus bounded declared-external-wait rechecks as batched digests, cutting supervision token cost during walk-away stretches. Exit is automatic; any real (unmarked) message returns to full per-wake responsiveness.
user-invocable: true
metadata:
  internal: true
---

# afk

Away-mode supervision. `/afk` makes the daemon's token-saving tradeoff **consented** and **explicit**: with the captain stepping away, the sub-supervisor may triage routine wakes in bash instead of waking firstmate's LLM for each one, and escalations still reach the captain but as one pre-read batched digest rather than per-wake injections.

## What it does

1. **Enter the lifecycle through `bin/fm-afk-launch.sh`.**
   This owns the durable state write, session-scoped stale-artifact clearing, terminal record, and rollback.
   The flag survives a firstmate restart, so recovery re-enters afk when it is present.

2. **Ensure the sub-supervisor daemon runs as a tracked background process.** Its hosting differs by harness:
   - **Harness WITH a native in-pane tracked-background tool** (e.g. claude's background bash, grok's background tool): first run `bin/fm-afk-launch.sh start-native`, then run `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` through that native tool - a deliberate no-separate-terminal exception (the harness-hosted job mutates no layout, and a shell launcher cannot invoke a harness-native tool).
     If the native launch fails, run `bin/fm-afk-launch.sh stop` to roll back.
     Do not wrap it in `nohup ... &` (Codex/herdr can reap fire-and-forget shell children after a tool call returns).
   - **Harness WITHOUT one** (e.g. pi): run `bin/fm-afk-launch.sh start`.
     It is the single owner of the daemon terminal: it creates a NON-VISIBLE tracked terminal (a herdr dedicated `--no-focus` workspace, or a detached tmux session), records its id, and passes the captain pane in as `FM_SUPERVISOR_TARGET` so the daemon injects into the captain, not its own new pane.
     **Never manufacture a terminal by splitting the captain's active pane** (`herdr pane split`): a split co-tenants the tab and visibly shrinks the captain's pane (docs/herdr-backend.md "Away-mode daemon terminal launch").
   Both paths share `bin/fm-afk-start.sh` as the daemon entry, which execs `bin/fm-supervise-daemon.sh` unless the identity-backed daemon lock already names a live process.
   The daemon is **presence-gated**: it injects escalations only while `state/.afk` exists, and stays quiet otherwise.

3. **Do not separately arm `fm-watch.sh`.** The daemon manages the watcher as its child; the singleton lock no-ops a stray arm harmlessly.

4. **Acknowledge** to the captain that away-mode is active.
   The daemon self-handles routine wakes, escalates captain-relevant events and bounded declared-external-wait rechecks, and lets the captain exit with any real message.

## How to exit afk

No `/back` is needed. The first genuine message is the return signal:

- A message **without** the sentinel marker and **not** starting with `/afk` -> the captain is back.
  Run `bin/fm-afk-return.sh` before acting on the message that brought the captain back.
  That script owns correct-ordered daemon shutdown, durable wake draining, escalation and wedge evidence, and the return-catch-up gate.
  If it reports a firstmate-actionable `blocked:` event, remediate it immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/fm-afk-return.sh check`.
  Once the daemon stops, resume full per-wake responsiveness through the emitted primary-harness supervision protocol while blocker handling proceeds, so the gate never creates a blind wait.
  Do not answer a Bearings request or perform any other ordinary captain work until the check exits successfully.
- A message **with** the sentinel marker (`FM_INJECT_MARK`, U+2063 INVISIBLE SEPARATOR) -> it is a daemon escalation; stay afk and process it.
- Re-invoking `/afk` while already away -> stay afk (refresh the flag); this does **not** trigger an exit.

Bias ambiguous cases toward exit: a present captain beats token savings, and a false exit is self-correcting (the captain re-runs `/afk`).

## Orthogonal to approval authority

afk changes how aggressively firstmate surfaces things, **not who approves what**; "away" never means "approves more."
A PR ready for merge, a needs-decision finding, or anything destructive still waits for the captain's explicit word - the daemon just batches the notification.

## Sentinel marker contract

The daemon prefixes every injection with `FM_INJECT_MARK` (U+2063 INVISIBLE SEPARATOR), which has no keyboard keystroke and survives terminal transport as UTF-8 text - how firstmate tells a daemon escalation apart from a real message in the same pane.
The marker travels with the message text; it does not rely on harness-level typed-vs-injected detection, which is not portable across harnesses.
`strip_injection_marker` removes the sentinel before classification or relay, so the digest text firstmate sees is clean.

## Injection safety

The daemon never injects into an in-use pane.
Before every injection (via `bin/fm-backend.sh` for its own tmux or herdr backend) it checks `pane_is_busy` (the harness busy footer, `FM_BUSY_REGEX`-overridable) and reads the full `empty`/`pending`/`unknown` composer verdict from `fm_backend_composer_state`, injecting only when the composer is affirmatively `empty`.
`pending` (real unsubmitted text) and `unknown` (an unreadable pane or a bare post-exit shell prompt) both defer.
The shared `bin/fm-composer-lib.sh` owns that empty/pending/unknown decision and its ghost stripping (dim/faint plus dark-TRUECOLOR placeholder, `FM_COMPOSER_IDLE_RE`-overridable after stripping); `docs/herdr-backend.md` "Composer-emptiness safety" owns the complete contract, including why a narrower `pane_input_pending` is insufficient here.

Either condition, or any verdict other than `empty`, defers; the buffered escalation survives in `state/.subsuper-escalations` and retries next housekeeping tick, guarding the captain-return race, a dead shell, and a prior unsent injection.
The digest is typed **once** and submitted with Enter, retried Enter-only (never a retype) until the backend's submit primitive confirms it landed; the per-backend confirmation is owned by `docs/herdr-backend.md` "Native agent-state submit confirmation" (the same primitive `fm-send.sh` uses, which exits non-zero when a steer's Enter is positively swallowed).

**Max-defer escape (the daemon must never silently wedge).**
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon attempts one normal flush (still requiring an idle pane and an affirmatively empty composer).
If that submit cannot be confirmed, it raises a loud, rate-limited wedge alarm - an ERROR in the daemon log, a durable `state/.subsuper-inject-wedged` marker (surface it on the "while you were out" catch-up), and the active-alert channels owned by `docs/wedge-alarm.md`, so a guard false-positive is always a visible stall.

The daemon resolves and logs its own supervisor backend and target, refusing any backend other than tmux or herdr (no zellij, orca, cmux) loudly rather than misapply tmux primitives to a non-tmux pane; the override variables and detection order are owned by `docs/configuration.md` "Away-mode supervisor backend" and `docs/herdr-backend.md` "Away-mode daemon: herdr supervisor-pane support".

## Classification policy

The daemon wraps `fm-watch.sh`, classifies each wake in bash, and self-handles the routine majority without a firstmate turn.
The predicates live in the shared `bin/fm-classify-lib.sh`, the same library the always-on watcher uses when afk is off, so the two modes apply one identical policy; while `state/.afk` exists the daemon owns the watcher (reverted to one-shot) so the two never triage at once.
`classify_signal` and `classify_stale` both check the seen-status marker before escalating, so a status escalated by one path is not re-escalated by another in the same digest.
It classifies each wake this way:

- `signal` with no captain-relevant verb (`done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged`) -> self-handle; captain-relevant verb -> escalate.
- `signal` or `stale` for a declared `paused:` external wait -> self-handle and track the pause rather than a wedge; if it stays declared and idle past `FM_PAUSE_RESURFACE_SECS` (default 3600s), housekeeping sends one awaiting-external recheck and resets the pause window.
- `check` -> always escalate. Check scripts print only when firstmate should wake.
- `stale` with a terminal status -> escalate. Non-terminal stale is transient: record a marker and self-handle; if the pane is still idle past `FM_STALE_ESCALATE_SECS` (default 240s), housekeeping escalates it as a possible wedge - a bounded delay, never a loss.
- `heartbeat` -> self-handle. The daemon runs a cheap bash fleet scan every `FM_HEARTBEAT_SCAN_SECS` (default 300s) as the catch-all for a captain-relevant status the per-wake classifier might miss.
- Unknown reason, or any uncertainty -> escalate fail-safe.

Escalations are buffered up to `FM_ESCALATE_BATCH_SECS` (default 90s; 0 = immediate) and flushed as one single-line digest (embedded newlines collapsed to a literal separator) prefixed with the sentinel marker, carrying pre-read status summaries and a recommended action.
`FM_INJECT_SKIP` (default `heartbeat`) force-self-handles matching kinds, overriding classification. Use it sparingly.

## Stale-artifact lifecycle

Treat `state/.subsuper-escalations`, its `.since` sidecar, and `state/.subsuper-inject-wedged` as session-scoped delivery artifacts, not the durable work record: always enter through `bin/fm-afk-launch.sh` (which clears prior-session artifacts only on a fresh entry and preserves the current buffer on refresh) and exit through `bin/fm-afk-launch.sh stop` (which keeps `state/.afk` present through the shutdown flush and clears it last).
`docs/herdr-backend.md` "Stale-artifact lifecycle fix" owns the mechanism and verification evidence.

## Reliability properties

Nothing is lost: the durable queue plus `fm-wake-drain.sh` recover any missed or crashed injection, and the daemon preserves crash-loop backoff, a pane-gone guard, and a signal-trapped shutdown that flushes buffered escalations before exit.
