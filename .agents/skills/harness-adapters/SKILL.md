---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, and grok.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.
Crewmate/secondmate harness resolution, precedence, and inheritance are owned by `AGENTS.md` sections 3 and 4 (and `secondmate-provisioning`); the Detection section below covers the `fm-harness.sh` accessors.
The one harness-relevant inheritance nuance to keep in mind here: `config/crew-harness` and `config/crew-dispatch.json` copy into secondmate homes as literal files, so a secondmate's own crewmates use the primary's crewmate harness only when `config/crew-harness` names a concrete adapter (e.g. `codex`) - an unset or `default` value falls back to the secondmate's own/detected harness.

The per-task mechanics (launch command, autonomy flag, crewmate turn-end hook) live in `bin/fm-spawn.sh`; the "no turn ends blind" guard contract in `docs/turnend-guard.md`; the PreToolUse arm seatbelt in `docs/arm-pretool-check.md`; and the primary watcher wake protocols in `docs/supervision-protocols/` (rendered by `bin/fm-supervision-instructions.sh`).
The supervision **knowledge** - busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks - lives here.

**Never dispatch a crewmate or secondmate on an unverified adapter.**
Verified adapters are `claude`, `codex`, `opencode`, `pi`, and `grok`.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain and fall back to firstmate's own harness until it is verified.
To verify a new harness the captain asks for: spawn a trivial supervised task via `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, the busy signature in `fm-watch.sh` and `bin/fm-tmux-lib.sh`, any `FM_COMPOSER_IDLE_RE` override plus novel bare-prompt glyphs in `bin/fm-composer-lib.sh`, the tmux agent-process liveness classification in `bin/backends/tmux.sh` (when the harness can launch a secondmate), and the verified knowledge here.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness (env markers first, then process ancestry).
`bin/fm-harness.sh crew` resolves the effective crewmate harness (absent/`default` `config/crew-harness` -> own); `bin/fm-harness.sh secondmate` resolves the secondmate-launch harness through `config/secondmate-harness` -> `config/crew-harness` -> own.
`bin/fm-spawn.sh` uses `crew` mode for a crewmate/scout launch and `secondmate` mode for `--secondmate`, re-resolving on every spawn; an explicit per-spawn harness arg overrides either.
On `unknown`, ask the captain instead of guessing; a captain override beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.
For stuck recovery, use the target window's `harness=` from `state/<id>.meta` for interrupt, exit, resume, and skill-invocation facts.

## Primary guards and watcher

Every verified primary harness has an empirically validated hook path for three things; the exact hook files, commands, transcripts, and fail-open tradeoffs are owned by the docs cited. Any hook change must be validated against the real harness in a scratch project or throwaway home before trusting it, then reflected in that doc and the per-harness fact below.

- **"No turn ends blind" guard** (`docs/turnend-guard.md`): `claude` and `codex` block directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`; `opencode`, `pi`, and `grok` expose passive lifecycle callbacks, so their adapters force one bounded follow-up or resume when the shared predicate blocks.
- **PreToolUse arm seatbelt** (`docs/arm-pretool-check.md`): every primary denies a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs. The per-harness hook mechanism (and grok's requirement that every `$VAR` in its hook `command` carry an inline `:-default` or the hook fails to launch) is owned by that doc.
- **Watcher supervision** (`docs/supervision-protocols/`): at session start `bin/fm-session-start.sh` prints exactly one watcher block for the detected primary; do not substitute another harness's wait shape. The exact wait shape per harness is in each harness's "guard fact" below.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values chosen by firstmate at intake; do not make the shell scripts parse natural-language dispatch rules.
The supported flags below are verified locally, with per-row evidence.

| Harness | Model flag | Effort flag | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | Verified on Claude Code 2.1.196. |
| codex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on codex-cli 0.142.1; the bundled catalog advertises only low/medium/high/xhigh, so `max` is omitted. |
| grok | `--model <model>` | `--reasoning-effort <low\|medium\|high>` | Verified on grok 0.2.99 (2026-07-13). `--effort` is an alias; the ceiling is `high`, and `xhigh`/`max` are rejected with `use one of: high, medium, low`, so firstmate omits them. |
| pi | `--model <model>` | `--thinking <low\|medium\|high\|xhigh>` | Verified on pi 0.80.2. `max` prints an invalid-thinking warning, so firstmate omits Pi effort when the requested effort is `max`. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag, preserving launch success instead of passing a known-bad value.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form (each harness's fact table below carries the exact form); natural language is acceptable if uncertain.
claude and grok use `/<skill>` (e.g. `/no-mistakes`); codex uses `$<skill>` and rejects `/<skill>` as "Unrecognized command"; opencode and pi have no separate verified form, so use natural language.
Verified end to end on grok: `/no-mistakes` discovers the user-level skill and drives a real `no-mistakes axi run`.
The codex (`$`/`/`) and grok (`/`) autocomplete popups swallow a too-fast Enter; each harness's section below has the handling, and the herdr fix plus the 2026-07-03 incident are in `docs/herdr-backend.md` "Incident (2026-07-03)".

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree may show a trust or bypass-permissions confirmation.
Peek the pane within about 20 seconds after every spawn; if such a dialog shows, accept it from an active firstmate session with `FM_HOME=<home> bin/fm-send.sh <window> --key Enter` (or the choice the dialog requires), then verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint ghost text in an otherwise-empty composer, which a plain `tmux capture-pane` cannot tell from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh` so it never touches the captain's global config (the CLI's `--prompt-suggestions` flag is print/SDK-mode only).
As defense in depth for panes that flag cannot reach (including the captain's own composer away-mode reads), the shared `fm_composer_strip_ghost` extractor in `bin/fm-composer-lib.sh` removes ghost/placeholder runs before pending-input classification (`docs/herdr-backend.md`'s 2026-07-10 incident); that styled capture is internal to the boolean detector only - `fm-peek` and every human/LLM-facing path stays plain `tmux capture-pane`.

**Primary-session guard fact (verified Claude Code 2.1.201-2.1.204).**
Separate from the per-task crewmate turn-end hook (which just `touch`es a marker in the task's own `.claude/settings.local.json`): the primary's own `.claude/settings.json` registers `bin/fm-turnend-guard.sh` as a Stop hook, and exit status 2 plus stderr forces the model to continue.
Firstmate launches the primary from the repo root because project `.claude/settings.json` applies only when that is the exact project root; the loop-guard (`stop_hook_active`) and `CLAUDE_PROJECT_DIR` anchoring are in `docs/turnend-guard.md`.
Watcher protocol: run `bin/fm-watch-arm.sh` as a Claude Code background task and treat completion as the wake.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` (shown as `• Working (Xs • esc to interrupt)`) |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; `fm-send` handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>` (e.g. `$no-mistakes`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

A `$<skill>` invocation opens a `$`-autocomplete popup (same hazard as `/`); `fm-send` gives it a longer settle (1.2s) before the first Enter, scoped to `harness=codex` (from target metadata) because a leading `$` commonly starts ordinary text - an explicit `session:window` target has no meta, so its harness is treated as non-codex.

Directory trust dialog on first run per repo root ("Do you trust the contents of this directory?"): accept with Enter. The decision persists for the repo, so later worktrees skip it.
Resume after exit with `codex resume <session-id>` (id printed on quit).

**Primary-session guard fact (verified codex-cli 0.142.1).**
The primary's own `.codex/hooks.json` registers a Stop hook piping Codex's Stop payload to `bin/fm-turnend-guard.sh`; Codex Stop hooks block on exit 2 like Claude, and the tracked hook anchors to `pwd -P` since Codex sets no root variable (`docs/turnend-guard.md`).
Watcher protocol: `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `bin/fm-watch-arm.sh` - deliberately foreground and bounded so Codex regains control regularly.

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.6)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note no "to") |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |

No trust dialog.
Opencode can auto-upgrade in the background and the running TUI can exit mid-task; if a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

**Primary-session guard fact (verified OpenCode 1.17.6).**
The primary's own `.opencode/plugins/fm-primary-turnend-guard.js` listens passively for `session.idle` and uses `client.session.promptAsync` to force one follow-up when `bin/fm-turnend-guard.sh` returns 2, while `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision.
The follow-up is verified in the interactive TUI; `opencode run` can exit before displaying a queued follow-up, so the adapter is fail-open in headless mode.

## pi (VERIFIED 2026-06-11)

| Fact | Value |
|---|---|
| Busy-pane signature | `Working...` (braille spinner prefix; no `esc to interrupt` text) |
| Exit command | `/quit` |
| Interrupt | single Escape |

Pi has no permission system, so crewmates are always autonomous.
Keep the brief as one positional argument; multiple positional args become separate queued messages (`fm-spawn`'s template handles this).
Project trust dialog can appear on the first pi run in any not-yet-trusted directory, even clean worktrees: accept with Enter. The decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same worktree slot skip it (`PI_CODING_AGENT=true` on its children is its harness-detection marker).
`fm-spawn` keeps the crewmate turn-end extension in `state/`, outside the worktree (project-local extension files worsen the trust gate); it must listen for pi's `turn_end` event, not `agent_end`, so the watcher wakes after each completed turn.

**Primary-session guard fact (verified Pi 0.80.5).**
The primary's own `.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled` (not per-tool-loop `turn_end`) and forces one guarded follow-up via `pi.sendUserMessage(..., { deliverAs: "followUp" })` when `bin/fm-turnend-guard.sh` returns 2 (`docs/turnend-guard.md`).
Watcher protocol: the tracked `.pi/extensions/fm-primary-pi-watch.ts` (same trust-once discovery); the model arms through `fm_watch_arm_pi`, never a foreground bash arm (`docs/supervision-protocols/pi.md`).
`bin/fm-session-start.sh` reports when the live Pi session has not loaded both extensions, pointing at plain `pi` after project trust (with `-e` as a trust-free fallback).
A Pi secondmate is launched with both extensions via `-e`, both already present in the secondmate home's git worktree.

## grok (VERIFIED grok 0.2.73; slash-submit re-verified 2026-07-03 on 0.2.82; effort ceiling re-verified 2026-07-13 on 0.2.99)

Grok Build TUI (`grok`), a Claude-Code-compatible CLI from xAI. Launch with a positional prompt: `grok --always-approve "$(cat <brief>)"`.
For supported reasoning-effort values and omission behavior, see the [launch-profile-axes table](#launch-profile-axes).

| Fact | Value |
|---|---|
| Busy-pane signature | `Ctrl+c:cancel` (the mid-turn cancel hint in grok's keybind bar, shown iff a turn is running; the spinner line is a braille glyph + `<status>… N.Ns` + `[stop]`). Idle keybind bar shows only `Shift+Tab:mode │ Ctrl+.:shortcuts`. The ASCII `Ctrl+c:cancel` is the busy regex (avoids locale fragility of matching braille). |
| Exit command | `Ctrl+Q` double-press within 1000ms (it is a confirmed destructive action). Prints `Resume this session with: grok --resume <session-id>`. `Ctrl+D` is the quit key in VS Code family terminals. NOT `/exit` and NOT `Ctrl+C`. |
| Interrupt | single `Ctrl+C` (cancels the current turn). `Esc` only moves focus to the scrollback, it does NOT interrupt. |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`), same as claude. Opens a slash-autocomplete popup; for an argument-taking command the first Enter expands the selection into an argument-hint placeholder (e.g. `/compact` -> `/compact compaction instructions`, live-verified) rather than submitting, so a genuine second Enter is required (see the no-mistakes skill invocation section). `fm-send`'s retried Enter handles it on both backends. |
| Autonomy | `--always-approve` (footer shows `· always-approve`); auto-approves every tool execution, verified unattended. `--permission-mode bypassPermissions` is the stronger equivalent. |
| Env marker | `GROK_AGENT=1`, set for child/tool processes. grok does NOT set `CLAUDECODE` despite Claude compatibility. |
| Resume | `grok --resume <session-id>` (id printed on exit) or `grok -c` / `--continue` (most recent for the cwd); `--fork-session` branches a new session id. |

Startup dialog: the "Run Grok Build in a project directory?" project picker appears ONLY when grok is launched from a non-project directory; `fm-spawn` launches inside the treehouse worktree (a git repo root), so it never appears. Pin `[hints] project_picker_disabled = true` in `~/.grok/config.toml` if a non-project launch ever needs to skip it.

Grok's composer slash-popup submit hazard, its dark-TRUECOLOR placeholder styling (dropped by `fm_composer_strip_ghost` below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128, on a dark theme), and a residual tmux-only `cursor_y` row-selection quirk in the pristine pre-typing state are all owned by `docs/herdr-backend.md` (2026-07-03 and 2026-07-10 incidents), with regression coverage in `tests/fm-composer-ghost.test.sh` and `tests/fm-backend-herdr.test.sh`.

Turn-end hook: grok fires a `Stop` hook at every turn boundary, giving firstmate a per-turn wake instead of only stale-pane detection.
Because grok trusts GLOBAL hooks in `~/.grok/hooks/` but requires opt-in folder trust for project hooks (and firstmate will not edit grok's managed trust store), `fm-spawn` installs ONE firstmate-owned global hook, a no-op for non-firstmate grok sessions that fires only when the workspace holds a per-task `.fm-grok-turnend` token pointer; `fm-teardown` removes the pointer before returning a pooled worktree, and secondmate spawns skip it (idle panes are healthy). The hook/pointer/registry mechanics are owned by `fm-spawn.sh`.

**Primary-session guard fact (verified Grok 0.2.91).**
The primary's own `.grok/hooks/fm-primary-turnend-guard.json` invokes `bin/fm-turnend-guard-grok.sh`; Grok Stop hooks are passive (exit 2 does not continue the model), so the adapter runs the shared predicate and, when it returns 2, forces one same-session follow-up with `grok --resume <sessionId> -p <guard-reason>` (setting `GROK_TURNEND_GUARD_ACTIVE=1` to prevent recursion).
It passes no `--permission-mode`, so the passive hook cannot escalate the primary's tool permissions.
Project-local Grok hooks require folder trust; if the primary checkout is not trusted the guard fails open and `fm-guard.sh` remains the next-command alarm.
Watcher protocol: Claude-shaped background-notify around `bin/fm-watch-arm.sh`; the passive Stop hook is only a backstop for blind turn ends.
