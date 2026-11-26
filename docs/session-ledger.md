# Agent session ledger and restore

The session ledger is a durable record of each agent session that runs in a Herdr pane on this machine.
After a Herdr crash or a reboot, one manual command reads the ledger and resumes every session that was live.
Each session comes back in its own conversation, in its own pane.
`bin/fm-session-ledger.sh` owns the ledger, its hooks, and the restore, and its header comment is the full contract.

## What the ledger records

The ledger has one entry for each agent session.
An entry records the Herdr session, the workspace, tab, and pane ids and labels, and the split layout of the tab.
It also records the working directory, the agent type, the session id, and the transcript path.
It records the launch arguments without the initial prompt, and the launch environment that the agent needs (`FM_*` and `CLAUDE_CODE_*` variables, never a credential).
For a fleet agent, it records the fleet task id or second mate id and the home that holds its record.
It also records the busy state (working or idle) and the time of the last update.

Claude Code hooks update the ledger.
`SessionStart` writes the entry when a session starts, resumes, clears, or compacts, so a new session id is recorded at once.
`UserPromptSubmit` sets the state to working, and `Stop` and `StopFailure` set it to idle.
`SessionEnd` removes the entry only for a deliberate end: `/exit`, end of input, logout, `/clear`, or `/resume`.

A crash also sends `SessionEnd`, with the reason `other`, because the dying terminal stops each agent.
The ledger keeps the entry for that reason, so a crash leaves every live session restorable.
It removes such an entry only when Herdr still answers, the pane is gone, and nothing is stopping, which is a pane closed by hand.
A new session in the same pane, or a fresh relaunch of the same fleet agent, replaces the older entry.
The primary is only the session that the endpoint record of the primary home (`state/.primary-endpoint`) names by its pane or its process.
Another session in the primary home is a session opened by hand.
A resumed or compacted primary session stays the primary, also in a new pane.
A non-interactive run (`claude -p`) and an agent that another agent starts, for example from a tool call, are not recorded.
Thus a `claude -p` that an agent runs in its pane does not replace the entry of that agent.

Each hook returns in about 20 ms and hands the write to a detached writer.
The hook prints nothing, always exits 0, and does not need python3.
Each write goes to a temporary file that is then renamed over the entry, so a crash at any moment leaves every entry valid.

## Where the ledger is

The ledger is outside every firstmate home, at `${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/session-ledger/`.
`entries/` holds one JSON file for each session, `events.log` records each applied event, and `restore.log` records each restore run.
`FM_SESSION_LEDGER_DIR` moves it.

To see the ledger, run:

```sh
~/firstmate/bin/fm-session-ledger.sh list
```

## Install the hooks

The hooks are user-level Claude Code hooks, so they also cover sessions that you open by hand.
Install them from the primary home after this change merges:

```sh
~/firstmate/bin/fm-session-ledger.sh install-hooks
```

The command is idempotent and keeps every other hook in `~/.claude/settings.json`.
To remove the hooks, run `~/firstmate/bin/fm-session-ledger.sh uninstall-hooks`.

## After a Herdr crash or a reboot

The restore never starts by itself.
Run it from a plain SSH shell or from any pane of the restarted Herdr server.

1. Make sure that the Herdr server runs again (`systemctl --user status herdr-server`).
2. See what the restore will do:

   ```sh
   ~/firstmate/bin/fm-session-ledger.sh restore --dry-run
   ```

3. Run the restore:

   ```sh
   ~/firstmate/bin/fm-session-ledger.sh restore
   ```

4. Read the summary line.
   If it reports a failed or missing session, read the line for that session above the summary.

The restore resumes each live session with its native resume of the recorded session id.
For Claude, it types the recorded launch arguments plus `--resume <session id>`, with the recorded environment, in the recorded working directory.
If the recorded pane still exists and holds only a shell, the session resumes in that pane.
If the pane runs something else, that pane is left alone and the session resumes in a new split of the same tab.
If the pane is gone, the restore creates the workspace, tab, split arrangement, and pane names again, then resumes the session in its own rebuilt pane.

The restore starts three sessions at a time, waits until each one runs, and then pauses 20 seconds before the next three (`--batch`, `--wait`, `--pause`).
A session that already runs is left alone, so a second restore run does nothing.
A session whose transcript is missing is reported and is never replaced by a fresh session.
An entry of a named Herdr session that no longer exists, for example a finished lab, is reported and removed.

For a fleet agent, the restore moves the task record in its home to the new pane when the pane changed, and sets its busy state to idle.
A fleet worker or second mate that was working at the crash then gets one short message in its steering inbox.
The message tells it that a Herdr restart stopped it, that this is its original conversation, that its background shells are gone, and that it must check the state and carry on.
Idle agents, agents that wait on a decision, the primary, and sessions opened by hand get no message.

## Automatic recovery

The restore is the only path that brings back the session of an agent that the ledger can resume.
The automatic recovery paths never start a fresh session for such an agent:

- The restart recovery pass (`bin/fm-local-restart-recovery.sh run`) leaves the second mate or primary down and notes the restore command.
- The worker restore at session start (`bin/fm-local-worker-restore.sh run`) reports the worker as resumable from the ledger, with the restore command.
- The session-start liveness sweep prints a `SECONDMATE_LIVENESS` line with the restore command for the second mate.

Each path asks `fm-session-ledger.sh can-resume`, which answers yes only for a live entry whose transcript exists and whose session does not run.
An agent with no ledger entry, for example one that ran before the hooks were installed, keeps the earlier recovery behavior.

The `firstmate-restart-recovery.service` user unit that `bin/fm-local-restart-recovery.sh` names is not installed on this machine.
With a manual restore, that unit is not necessary for agents that the ledger can resume.
It is still useful only to start worker restore and restart recovery for agents with no ledger entry.

## Why Herdr's own restore is not enough

Herdr 0.8.2 restores the saved layout and resumes an agent only when that agent's Herdr integration reported a native session.
The Herdr Claude hook needs python3, so on this machine it records nothing, and every Claude pane comes back as a plain shell.
Herdr's resume also uses a bare `claude --resume <id>`, without the launch flags or the fleet environment, and it starts automatically.
After a shutdown that stops the panes before Herdr saves, Herdr restores no layout at all.
The ledger therefore reuses Herdr's ids, labels, and split layout, read from one `herdr api snapshot` call, and keeps its own copy for the restore.
The same restore works on Herdr 0.9.5.

## Memory guard for the Herdr server

On 2026-11-25 the kernel killed one runaway `shellcheck` process that ran in a Herdr pane.
Because `herdr-server.service` used the default `OOMPolicy=stop`, systemd then stopped the whole unit and every agent in it.
The guard is a proposed change to `herdr-server.service` in the dotfiles.
It is not applied yet, so the unit still uses `OOMPolicy=stop`, and one runaway job can still stop the Herdr server.
The change restarts the live Herdr server when it is activated, and the rebuild needs sudo, so the ledger change does not apply it.
The exact diff is in the pull request that added the ledger.
The proposed change has two parts:

- `OOMPolicy=continue` keeps the unit and every other agent alive when the kernel kills one process in it.
- `MemoryHigh`, `MemoryMax`, and `MemorySwapMax` on the unit make the kernel act inside the unit before the whole machine runs out of memory.
  It then kills the largest process in the unit, which is the runaway job and not the small Herdr server.

`OOMScoreAdjust` is not part of the guard.
Each pane process inherits the value from the server, so the value cannot protect the server alone, and a user unit cannot set a value below its user manager.
Run heavy test, lint, and build jobs in their own capped `systemd-run --user --scope` units, so that one job cannot fill the unit.

## Limits

Only Claude Code sessions are recorded and restored.
`install-hooks` installs Claude Code hooks only.
Herdr's own Pi integration already records a Pi session and resumes it when the server starts.
No Codex hook is installed, so Codex sessions are not in the ledger.
The `hook` verb accepts `codex` and `pi` events, but the restore reports such entries as having no verified resume and does not start them.
The tab layout is the one recorded at the newest session event in that tab, so a split made later without a new session is not in the record.
The automated tests are in `tests/fm-session-ledger.test.sh`, and the live crash evidence is in the pull request that added the ledger.
