# Harness-neutrality audit

Date: 2026-07-23.
Base: local `main` at `2b7da16`.
Reason: the captain is switching his default primary harness from Claude Code to pi (`@earendil-works/pi-coding-agent`) and wants the workflow identical on any of the five verified adapters (`claude`, `codex`, `opencode`, `pi`, `grok`).

2026-09-05: Ultracode mode was retired because it was available only in Claude Code.

This audit sweeps the repo for Claude-Code-specific coupling and separates two categories:

- **Correctly scoped** - claude-specific code that lives behind the claude adapter boundary (a `claude` case, `.claude/` glue, a claude-only doc section, a claude verification record).
  These are the intended design and are left unchanged.
- **Leak** - a claude assumption sitting in shared/general code or prose, where claude stands in for "the harness" or is treated as the default/reference adapter.
  These are the migration targets.

The guiding rule: remove claude-**first** defaults and claude-**only** paths; never remove claude support.
Where pi lacked parity with claude glue, build the pi equivalent.

## Headline

The core runtime is already harness-neutral by construction.
Harness detection (`bin/fm-harness.sh`), supervision rendering (`bin/fm-supervision-instructions.sh`), launch/dispatch (`bin/fm-spawn.sh`, `bin/fm-dispatch-select.sh`), and teardown (`bin/fm-teardown.sh`) all resolve the harness from the recorded `harness=` meta / config / process detection and dispatch per-adapter, falling back to `unknown` (never to claude).
Pi has full functional parity with claude on every supervision-glue capability, and is ahead of claude on active watch-arming.

The residue is small: one dead claude env-var reference in a grok-only script, a README skill-invocation caveat that omits pi/opencode, a claude-first ordering in README prose, and one liveness-detection coverage gap that pi could not previously close.

## Parity matrix - the four supervision-glue capabilities x five adapters

| Capability | claude | codex | opencode | pi | grok |
| --- | --- | --- | --- | --- | --- |
| Turn-end guard (primary) | `.claude/settings.json` Stop | `.codex/hooks.json` Stop | `.opencode/plugins/fm-primary-turnend-guard.js` | `.pi/extensions/fm-primary-turnend-guard.ts` | `.grok/hooks/fm-primary-turnend-guard.json` + `bin/fm-turnend-guard-grok.sh` |
| Session-start nudge | instruction | instruction | instruction | instruction | instruction |
| Watch-arm continuity | PreToolUse arm | PreToolUse arm | plugin active-arm + pretool | extension active-arm + pretool | PreToolUse arm |
| Per-task crewmate turn-end hook | `bin/fm-spawn.sh` `.claude/settings.local.json` | `bin/fm-spawn.sh` `-c notify=[...]` | `bin/fm-spawn.sh` `.opencode/plugins/fm-turn-end.js` | `bin/fm-spawn.sh` `state/<id>.pi-ext.ts` via `-e` | `bin/fm-spawn.sh` global hook + per-task token |

All five share the single harness-neutral predicate `bin/fm-turnend-guard.sh`.
claude and codex block a turn-end synchronously (native Stop exit-2); opencode, pi, and grok cannot block a Stop and instead force one bounded follow-up turn.
That difference is a property of each harness's event model, not a firstmate parity gap.

**Session-start nudge is uniform.** No adapter ships a native session-open hook that runs `bin/fm-session-start.sh`; every harness reads the shared `AGENTS.md`/`CLAUDE.md` instruction to run it once at session start.
So this capability is uniformly instruction-delivered across all five - parity holds by having no per-harness native mechanism at all.
(The stale `docs/sessionstart-nudge.md` pointer that claimed a native session-open adapter mechanism was already removed from `AGENTS.md` section 3 in commit `566c26c`, before this base.)

## Findings

### Confirmed leaks (migrated)

**L1 - `bin/fm-turnend-guard-grok.sh:17` - claude env var in a grok-only script.**
```
ROOT=${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}
```
This is the grok turn-end adapter.
The grok hook that invokes it (`.grok/hooks/fm-primary-turnend-guard.json`) already guards on `GROK_WORKSPACE_ROOT` and execs with it set, so the `CLAUDE_PROJECT_DIR` fallback never fires - it is dead code, and the only genuine claude env var embedded in non-claude adapter code.
Fix: drop the fallback to `ROOT=${GROK_WORKSPACE_ROOT:-}`; the very next line (`[ -n "$ROOT" ] || exit 0`) already fails safe.

**L2 - `README.md` skill-invocation caveat omits pi and opencode.**
> "Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`."

The "Built-in skills" table lists every skill in the `/afk` slash form, but the caveat maps only claude/grok/codex, silently omitting pi and opencode and presenting the claude/grok slash form as the canonical display.
Fix: state that invocation syntax varies per harness, cover all five, and defer to the authoritative `harness-adapters` skill.

**L3 - `README.md` claude-first ordering (Requirements, Recommended harnesses, launch snippets).**
The harness list, the co-primary sentence, and the three launch snippets all consistently lead with Claude Code.
The prose is factually correct (the three are equal co-primaries), but always-claude-first ordering reads as reference-harness primacy now that pi is the default.
Fix: reorder so pi (the new default) leads, without changing the equal-co-primary claim.

### Built pi parity (evidence-backed)

**E1 - `bin/backends/tmux.sh` `fm_backend_tmux_agent_alive` could not positively confirm a live pi agent.**
The alive classifier whitelisted `claude`, `codex`, `opencode`, `grok` but not `pi`, because `docs/tmux-backend.md` recorded pi as exec'ing into a generic `node` process with no attributable command name.
Empirically re-verified against pi 0.81.1 on this box (2026-07-23): pi is a `#!/usr/bin/env node` script that sets its process title to `pi`, so both `tmux #{pane_current_command}` and `ps -o comm=` report `pi` stably across the process tree and over time.
Fix: add an exact-match `pi` arm to the alive whitelist.
This is monotonic-safe: a config where pi still reports `node` falls through to `unknown` (unchanged), a bare shell still reports `dead`, and the secondmate-liveness sweep respawns on `dead`/`missing` only - so there is no false-respawn or false-unhealthy risk, only a fleet/bearings accuracy gain for pi.
`docs/tmux-backend.md` is updated with the new empirical evidence.

### Correctly scoped - verified, left unchanged

These carry `claude` in shared code but are correctly behind the adapter boundary; each was inspected and confirmed harness-safe.

- **`bin/fm-harness.sh:32-37`** - `detect_own` checks `CLAUDECODE` first, but every harness has a distinct env/ancestry marker and no match returns `unknown`, never a claude default.
  Ordering only.
- **`bin/fm-supervision-instructions.sh`** - resolves the harness from `fm-harness.sh`, renders a per-harness `docs/supervision-protocols/<harness>.md` snippet, and falls back to `unknown.md`.
  All five snippets plus `unknown.md` exist.
- **`bin/fm-spawn.sh` launch templates and per-task turn-end hooks** - one distinct `claude|codex|opencode|pi|grok` branch each; no empty/default-to-claude path (an unset harness resolves through `fm-harness.sh crew`/`secondmate`, and a harness with no template aborts the spawn).
- **`bin/fm-spawn.sh:339-348`** - `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` is inside the `claude)` launch branch, scoped to firstmate-launched claude agents.
- **`bin/fm-arm-pretool-check.sh` / `bin/fm-cd-pretool-check.sh`** - `CLAUDE_MODE` / `--claude` gate the claude-shaped JSON-on-stdout decision format; codex/opencode/pi/grok use the exit-2 + stderr path.
  A per-harness output switch, not claude primacy.
- **`bin/fm-composer-lib.sh`** - the shared composer classifier knows the `❯` (claude) and `›` (codex) agent glyphs and strips dim-SGR2 ghost (claude/codex) and dark-truecolor placeholder (grok).
  Pi's separator-pair composer is handled correctly on tmux without a pi-specific branch - see the empirical note below.
- **Busy-signature union** (`bin/fm-tmux-lib.sh:52`, `bin/fm-watch.sh:122`, and the daemon's `FM_BUSY_REGEX`) - `esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel` is an OR of every harness footer, applied harness-agnostically.
  Pi's `Working...` is present and correct.
- **`bin/fm-dispatch-select.sh:175`** - per-harness quota reset windows (`claude` -> five_hour/seven_day, `codex` -> five_hour/weekly, others empty) are provider-quota semantics, not a claude default.
- **`bin/fm-ensure-agents-md.sh`** - enforces the correct general contract (AGENTS.md is the real file; CLAUDE.md is an additive relative symlink).
  claude is the one harness with a differently-named memory file, so the CLAUDE.md compat symlink is legitimately claude-specific and additive; pi/codex/opencode/grok read AGENTS.md directly.
- **`bin/fm-teardown.sh:656,986-1110`** - the dirty-check ignore of untracked `.claude/`/`.fm-grok-turnend`, and the per-adapter hook-file cleanup (`.claude/settings.local.json`, `.opencode/plugins/fm-turn-end.js`, `.fm-grok-turnend`), clean exactly the files each adapter creates.
  Pi's turn-end ext lives under `state/` and is cleaned with the state files; codex's rides the launch command with no file.
- **`.claude/settings.json` `$CLAUDE_PROJECT_DIR`** - claude-only file; Claude Code sets that variable.
  Other adapters resolve their own root (grok `GROK_WORKSPACE_ROOT`, opencode/pi via extension path / `git rev-parse`).
- **Docs and skills** - `docs/turnend-guard.md`, `docs/arm-pretool-check.md`, `docs/cd-guard.md`, `docs/herdr-backend.md`, `docs/cmux-backend.md`, and `.agents/skills/harness-adapters/SKILL.md` describe claude specifics inside explicitly claude/adapter-scoped sections.
  `docs/architecture.md`, `docs/scripts.md`, `docs/configuration.md`, `CONTRIBUTING.md`, `AGENTS.md`, and `.agents/skills/filesystem-map/SKILL.md` state the AGENTS.md-is-real / CLAUDE.md-is-a-symlink contract correctly.

### Empirical note - pi composer on the tmux backend

An earlier reasoned concern was that pi's composer (a horizontal-separator-pair region with no side border or prompt glyph, recognized on the herdr backend by `fm_backend_herdr_pi_composer_find` cross-checking native `agent get` identity) would be misread on the tmux backend, which has no native identity query and reads only the single `#{cursor_y}` row.
Empirically re-verified against pi 0.81.1 in tmux 3.7b (2026-07-23), this does **not** reproduce:

- tmux anchors `#{cursor_y}` to pi's input row, which sits **between** the two separator rows - never on a separator.
- An idle-empty pi composer input row (`ESC[7mESC[39m ESC[0m`, a reverse-video cursor cell) classifies as `empty` - safe to inject.
- An input row with unsubmitted text classifies as `pending` - correctly defers injection and correctly withholds a submit confirmation.
- The dark-truecolor (`38;2;80;80;80`, luminance 80) separator rows never reach the classifier because the cursor is never on them.

The architectural reason tmux needs no pi-specific branch: `#{cursor_y}` points directly at the live input row, so there is no transcript-vs-live ambiguity that would require the herdr backend's separator-pair scan and identity cross-check.
No change was needed here; the concern is recorded as verified-safe with evidence in `docs/tmux-backend.md`.

## Migration summary

| Item | File | Change |
| --- | --- | --- |
| L1 | `bin/fm-turnend-guard-grok.sh` | drop the `CLAUDE_PROJECT_DIR` fallback |
| L2 | `README.md` | rewrite the skill-invocation caveat for all five harnesses |
| L3 | `README.md` | reorder harness lists/snippets so pi is not always last-behind-claude |
| E1 | `bin/backends/tmux.sh`, `docs/tmux-backend.md` | add evidence-backed pi liveness detection |

Tests: `tests/tmux-agent-alive.test.sh` (extended for pi) and `tests/turnend-guard-grok.test.sh` (grok root resolution) cover the shared-path changes.
</content>
</invoke>
