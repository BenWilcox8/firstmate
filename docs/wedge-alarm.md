# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

## The delivery ladder behind the alarm

Past `FM_MAX_DEFER_SECS` the daemon makes two bounded delivery attempts before it stops depending on the pane.

1. One ordinary flush, which defers on a busy pane exactly as every other flush does.
2. One busy-override flush, but only when the pane has read busy on every attempt since the digest was buffered.
   That override skips the busy heuristic and reads the input box again.
   A pane that never once read free for a whole defer window is where the heuristic is most likely wrong.
   A finished turn's footer can sit in the scrollback and keep matching.
   The override does not relax the input-box guard.
   Only a box that classifies as empty is ever typed into, so the captain's own half-typed text is never merged with an escalation.
3. If neither attempt can prove delivery, the alarm fires and the digest goes to the captain's durable inbox with `bin/fm-inbox.sh note`.
   That inbox writes an atomic record and appends one `check` wake.
   The escalation is then presented at Firstmate's next turn boundary, and it stays pending until it is acknowledged.
   The per-task steering inbox (`bin/fm-task-inbox-lib.sh`) is not used for this, because it addresses a spawned worker rather than the primary session.

The escalation buffer is kept through all of it, so the pane path still delivers the digest at the next proven-idle moment.
One digest queues one durable note, however many defer windows the stall survives.
A newly buffered event becomes durable in its turn.

## What the alarm names

Every alarm carries the last delivery classification: the input-box verdict, the busy verdict, and the busy SOURCE that produced it.
The source is one of four values:

- `native` - the backend reported its own agent state (herdr today).
- `rendered` - a harness-scoped busy footer matched in the pane tail.
- `rendered-none` - the tail was read and matched nothing.
- `capture-failed` - the tail could not be read at all.

Without the source, "the pane was busy" never separated a real turn from a stale footer.
That difference decides whether the stall needs a captain or a fix.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
This is deliberate because the alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon is sourced as a library, that seam defaults to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
It also covers the delivery ladder above on both supported supervisor backends: the busy-override delivery, the durable inbox fallback and its one-note-per-digest rule, the never-type-into-a-pending-box guard, and the busy source the alarm names.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
