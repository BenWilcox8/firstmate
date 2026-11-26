#!/usr/bin/env bash
# fm-session-ledger.sh - the ONE owner of the machine-level agent session
# ledger: which agent session runs in which Herdr pane, how to resume that
# exact session, and the one manual restore command that brings every session
# that was live back after a Herdr crash or a reboot.
#
# Why it exists. When the Herdr server stops (an out-of-memory kill, a
# restart, a reboot), every agent process in it stops. Herdr 0.8.2 restores
# the layout and resumes an agent only when that agent's Herdr integration
# reported a native session reference. The Herdr Claude hook needs python3,
# so on a machine without python3 it records nothing, and every Claude pane
# comes back as a plain shell. Herdr's own resume also runs a bare
# `claude --resume <id>`: it drops the recorded launch flags and the fleet
# environment (FM_HOME, FM_TASK_ID, ...), and it starts automatically. After a
# reboot that stopped the panes before Herdr saved them, Herdr restores no
# layout at all. This ledger keeps its own record of every agent session in a
# Herdr pane, reuses Herdr's own identity and layout model for the location
# (one `herdr api snapshot` read), and resumes each session only on request.
#
# Usage:
#   fm-session-ledger.sh hook <claude|codex|pi>
#   fm-session-ledger.sh list [--json] [--session <herdr-session>]
#   fm-session-ledger.sh restore [--dry-run] [--session <herdr-session>]
#                                [--batch <n>] [--pause <seconds>]
#                                [--wait <seconds>]
#   fm-session-ledger.sh can-resume (--task <id> --home <home> | --primary <home>)
#   fm-session-ledger.sh restore-command
#   fm-session-ledger.sh install-hooks [--settings <claude-settings.json>]
#   fm-session-ledger.sh uninstall-hooks [--settings <claude-settings.json>]
#
#   hook       The agent hook entry point. Claude Code calls it for
#              SessionStart (startup, resume, clear, compact), UserPromptSubmit,
#              Stop, StopFailure, and SessionEnd, with the hook JSON on stdin.
#              It acts only inside a Herdr pane (HERDR_PANE_ID and
#              HERDR_SOCKET_PATH set), never needs python3, prints nothing,
#              always exits 0, and returns in a few milliseconds: it reads
#              stdin, finds the agent process, and hands the event to a
#              detached writer. Every event produces exactly one write, ordered
#              by its nanosecond event time under a per-entry lock, so the
#              ledger is updated deterministically, not by polling.
#   list       Print the entries, one line each, or the raw entries as a JSON
#              array with --json.
#   restore    The one restore command. It never runs by itself. For every
#              entry that was live and whose session is not running now, it
#              resumes that exact session with the agent's native resume, from
#              the recorded launch arguments without the initial prompt, plus
#              the resume selector (Claude: --resume <session id>), with the
#              recorded launch environment, in the recorded working directory.
#              It never starts a fresh session. Placement:
#                same-pane  the recorded pane still exists (same workspace,
#                           tab, and pane id) and holds only its shell;
#                split      the recorded pane runs another process, so it is
#                           left alone and a new pane is split in its tab;
#                rebuild    the pane is gone (a reboot, or a restored layout
#                           without it): the recorded workspace, tab, split
#                           arrangement, and names are created again from the
#                           newest recorded layout of that tab, then the
#                           session resumes in its own rebuilt pane.
#              Skipped and reported: a session already running (idempotence),
#              a missing transcript (never replaced by a fresh session), a
#              fleet task whose record no longer exists in its home, an agent
#              type with no verified resume, and a Herdr session that is not
#              running. An entry of a named Herdr session whose directory no
#              longer exists (a deleted lab) is reported and removed.
#              Sessions launch --batch at a time (default 3) with a
#              --pause (default 20 s) between batches, and each launch waits
#              up to --wait seconds (default 90) for the resumed session to
#              run. After a fleet agent runs again, its task record in its own
#              home is moved to the new pane when the pane changed, its busy
#              state is set idle, and only a fleet worker or second mate that
#              was working at the crash gets one short durable carry-on
#              message through its steering inbox (bin/fm-send.sh). Idle
#              agents, agents waiting on a decision, the primary, and sessions
#              opened by hand get no message. --dry-run prints the plan and
#              changes nothing. It prints one summary line.
#   can-resume Exit 0 and print the restore command when the ledger holds a
#              live entry for that fleet agent (a task or second mate record
#              id in <home>, or the primary of <home>) whose transcript
#              exists and whose session is not running. The automatic
#              recovery paths call it before they relaunch anything: an agent
#              the ledger can resume is never started fresh by them.
#   restore-command  Print the one restore command line.
#   install-hooks / uninstall-hooks  Add or remove this script's Claude Code
#              hooks in the user settings file (default
#              ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json). Both are
#              idempotent, keep every other hook, and replace the file
#              atomically.
#
# Entry lifecycle. One entry per agent session, keyed <agent>-<session id>;
# the pane is an attribute. SessionStart writes the full entry: the Herdr
# session, its server start (the API socket modification time), the
# workspace, tab, and pane ids and labels, the tab's split layout and its
# panes, the working directory, the agent type, the session id and
# transcript, the launch arguments without the initial prompt, the resume
# arguments, the launch environment (the allowlist in ledger_env_filter), the
# fleet identity (worker, second mate, or primary, with its record home), and
# the busy state. A new session in the same pane under the same server start
# (/clear, /resume, a new agent) replaces the older entry of that pane.
# UserPromptSubmit sets the state to working; Stop and StopFailure set idle.
# SessionEnd removes the entry only for a deliberate end: /exit or an end of
# input (prompt_input_exit), logout, clear, resume, or
# bypass_permissions_disabled. Any other end (a signal from a dying server or
# a stopping system) keeps the entry, because a crash must leave it
# restorable; the entry is removed only when, two seconds later, Herdr still
# answers, reports the pane gone, and neither the system nor the Herdr unit is
# stopping (a pane closed by hand).
#
# Storage. ${FM_SESSION_LEDGER_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/session-ledger}
#   entries/<agent>-<session id>.json   one entry, replaced by rename
#   entries/.<agent>-<session id>.lock  its writer lock
#   events.log                          bounded log of applied events
#   restore.log                         bounded log of restore runs
# Each write goes to a temporary file in the same directory and is renamed
# over the entry, so a crash at any moment leaves every entry valid.
#
# Environment:
#   FM_SESSION_LEDGER=off            disable the hook (it then does nothing)
#   FM_SESSION_LEDGER_DIR            ledger directory (above)
#   FM_SESSION_LEDGER_HERDR          Herdr CLI (default: HERDR_BIN_PATH from the
#                                    pane, else herdr)
#   FM_SESSION_LEDGER_PRIMARY_HOME   the primary firstmate home (default: this
#                                    script's code root)
#   FM_SESSION_LEDGER_PROC           /proc override, for tests only
#   FM_SESSION_LEDGER_SETTLE         seconds a hand-closed pane is re-checked (2)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF="$SCRIPT_DIR/fm-session-ledger.sh"
LEDGER_SCHEMA=fm-session-ledger/v1
LEDGER=${FM_SESSION_LEDGER_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/session-ledger}
ENTRIES="$LEDGER/entries"
PROC=${FM_SESSION_LEDGER_PROC:-/proc}
PRIMARY_HOME=${FM_SESSION_LEDGER_PRIMARY_HOME:-$FM_ROOT}

ledger_herdr_bin() {
  if [ -n "${FM_SESSION_LEDGER_HERDR:-}" ]; then
    printf '%s' "$FM_SESSION_LEDGER_HERDR"
  elif [ -n "${HERDR_BIN_PATH:-}" ] && [ -x "$HERDR_BIN_PATH" ]; then
    printf '%s' "$HERDR_BIN_PATH"
  else
    printf 'herdr'
  fi
}

# One Herdr call, always scoped by a trailing --session.
ledger_herdr() {  # <session> <herdr arguments...>
  local session=$1
  shift
  timeout "${FM_SESSION_LEDGER_HERDR_TIMEOUT:-10}" "$(ledger_herdr_bin)" "$@" --session "$session"
}

# The Herdr session name a pane's API socket belongs to.
ledger_session_from_socket() {  # <socket-path>
  local path=$1 dir
  case "$path" in
    */sessions/*/herdr.sock)
      dir=${path%/herdr.sock}
      printf '%s' "${dir##*/}"
      ;;
    *) printf 'default' ;;
  esac
}

ledger_mtime() {  # <path>
  stat -c '%.9Y' -- "$1" 2>/dev/null || stat -c '%Y' -- "$1" 2>/dev/null
}

ledger_realpath() {  # <path>
  (cd -P -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

ledger_log() {  # <file> <line>
  local file="$LEDGER/$1"
  printf '%s\t%s\n' "$(date +%s)" "$2" >>"$file" 2>/dev/null || return 0
  # Keep each log bounded without a reader-side lock: trim only when large.
  if [ "$(stat -c %s -- "$file" 2>/dev/null || echo 0)" -gt 262144 ]; then
    tail -n 1000 "$file" >"$file.tmp.$$" 2>/dev/null && mv -f "$file.tmp.$$" "$file" 2>/dev/null
    rm -f "$file.tmp.$$" 2>/dev/null
  fi
  return 0
}

# Field 22 of /proc/<pid>/stat (process start time), parsed after the last ')'.
ledger_proc_start() {  # <pid>
  local stat rest
  read -r stat <"$PROC/$1/stat" 2>/dev/null || return 1
  rest=${stat##*) }
  # shellcheck disable=SC2086 # Word splitting of the stat fields is intended.
  set -- $rest
  [ "$#" -ge 20 ] || return 1
  printf '%s' "${20}"
}

ledger_proc_ppid() {  # <pid>
  local stat rest
  read -r stat <"$PROC/$1/stat" 2>/dev/null || return 1
  rest=${stat##*) }
  # shellcheck disable=SC2086 # Word splitting of the stat fields is intended.
  set -- $rest
  printf '%s' "${2:-}"
}

ledger_claude_config() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# The agent process a hook runs under: the nearest ancestor that the agent
# itself marks. Claude Code keeps <config>/sessions/<pid>.json for each live
# process; codex and pi are matched by the executable name.
ledger_agent_pid() {  # <agent> <start-pid>
  local agent=$1 pid=$2 depth=0 cfg name
  cfg=$(ledger_claude_config)
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 12 ]; do
    case "$agent" in
      claude)
        if [ -f "$cfg/sessions/$pid.json" ]; then
          printf '%s' "$pid"
          return 0
        fi
        ;;
      codex | pi)
        name=; read -r name <"$PROC/$pid/comm" 2>/dev/null
        if [ "$name" = "$agent" ]; then
          printf '%s' "$pid"
          return 0
        fi
        ;;
    esac
    pid=$(ledger_proc_ppid "$pid") || return 1
    depth=$((depth + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# jq programs.

# The Claude launch arguments without the initial prompt and without any
# session selector, mirroring the CLI's own option table (claude --help,
# 2.1.x): options that take one value, options with an optional value,
# variadic options, and switches. An unknown option is kept as a switch and
# reported in .unknown.
# shellcheck disable=SC2016 # jq program text, not shell.
LEDGER_JQ_CLAUDE_ARGS='
def claude_resume_args:
  def vf: ["--agent","--agents","--append-system-prompt","--append-system-prompt-file","--autocompact","--debug-file","--effort","--environment","--fallback-model","--input-format","--json-schema","--max-budget-usd","--model","-n","--name","--output-format","--permission-mode","--permission-prompts","--permission-prompt-tool","--plugin-dir","--plugin-url","--remote-control-session-name-prefix","--session-id","--setting-sources","--settings","--system-prompt","--system-prompt-file","--system-prompt-snapshot"];
  def of: ["-r","--resume","--from-pr","--cloud","-d","--debug","--prompt-suggestions","--remote-control","--teleport","-w","--worktree"];
  def mf: ["--add-dir","--allowedTools","--allowed-tools","--betas","--disallowedTools","--disallowed-tools","--file","--mcp-config","--tools"];
  def bf: ["--allow-dangerously-skip-permissions","--ax-screen-reader","--bg","--background","--bare","--brief","--chrome","-c","--continue","--dangerously-skip-permissions","--desktop","--disable-slash-commands","--exclude-dynamic-system-prompt-sections","--fork-session","--forward-subagent-text","--ide","--include-hook-events","--include-partial-messages","--no-chrome","--no-session-persistence","-p","--print","--replay-user-messages","--restricted","--safe-mode","--strict-mcp-config","--tmux","--verbose"];
  def drop: ["-r","--resume","-c","--continue","--session-id","--fork-session","--from-pr","--teleport","-p","--print","--bg","--background","--cloud","-w","--worktree","--tmux"];
  def isflag: (startswith("-") and (. != "-"));
  def keep($acc; $toks; $f):
    if ($f | IN(drop[])) then $acc else $acc + {argv: ($acc.argv + $toks)} end;
  def go($i; $acc):
    if $i >= length then $acc
    else .[$i] as $t
    | if $t == "--" then $acc + {prompt: true}
      elif ($t | isflag | not) then go($i + 1; $acc + {prompt: true})
      elif ($t | test("^--[^=]+=")) then go($i + 1; keep($acc; [$t]; ($t | sub("=.*$"; ""))))
      elif ($t | IN(vf[])) then
        if $i + 1 < length then go($i + 2; keep($acc; [$t, .[$i + 1]]; $t))
        else go($i + 1; keep($acc; [$t]; $t)) end
      elif ($t | IN(of[])) then
        if ($i + 1 < length) and (.[$i + 1] | isflag | not) then go($i + 2; keep($acc; [$t, .[$i + 1]]; $t))
        else go($i + 1; keep($acc; [$t]; $t)) end
      elif ($t | IN(mf[])) then
        ((first(range($i + 1; length) as $j | select(.[$j] | isflag) | $j)) // length) as $k
        | go($k; keep($acc; .[$i:$k]; $t))
      elif ($t | IN(bf[])) then go($i + 1; keep($acc; [$t]; $t))
      else go($i + 1; $acc + {argv: ($acc.argv + [$t]), unknown: ($acc.unknown + [$t])}) end
    end;
  go(0; {argv: [], unknown: [], prompt: false});
'

# The launch environment the ledger records: firstmate and Claude Code
# launch variables, never a credential.
# shellcheck disable=SC2016 # jq program text, not shell.
LEDGER_JQ_ENV='
def ledger_env_filter:
  with_entries(select(
    (.key | test("^(FM_[A-Z0-9_]+|CLAUDE_CODE_[A-Z0-9_]+|CLAUDE_CONFIG_DIR|COMPACT_ADVISER_DISABLE|GOTMPDIR|ATLAS_AXI_BY|ATLAS_REPO|LAVISH_AXI_HOST|ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODEL|GEMINI_CLI_SYSTEM_SETTINGS_PATH|OPENCODE_CONFIG_CONTENT|PI_[A-Z0-9_]+)$"))
    and (.key | test("TOKEN|SECRET|PASSWORD|PASSWD|KEY|AUTH|CREDENTIAL|COOKIE") | not)
    and (.key | IN("CLAUDE_CODE_SESSION_ID","CLAUDE_CODE_CHILD_SESSION","CLAUDE_CODE_BRIDGE_SESSION_ID","CLAUDE_CODE_CHILD_NOTES_DIR","CLAUDE_CODE_EXECPATH","CLAUDE_CODE_ENTRYPOINT","CLAUDE_CODE_SESSION_ATTENDED","CLAUDE_CODE_MESSAGING_SOCKET","FM_SESSION_LEDGER_PROC") | not)
  ));
'

# Rebuild steps for one recorded tab layout: the root pane, then one split per
# recorded split node in preorder. Herdr names each split split_<n>_<path>,
# where <path> is the child-index path from the root ("root" for the root),
# and lists the panes in the same left-to-right tree order. A split keeps the
# first fraction (ratio) in the pane it splits and gives the rest to the new
# pane. A layout that does not fit this shape degrades to one split per pane.
# shellcheck disable=SC2016 # jq program text, not shell.
LEDGER_JQ_REPLAY='
def replay_ops:
  . as $l
  | ([$l.panes[]?.pane_id]) as $leaves
  | (reduce ($l.splits // [])[] as $s ({};
       . + {(($s.id | capture("^split_[0-9]+_(?<p>.*)$").p) | if . == "root" then "" else . end): $s})) as $int
  | def leafpaths($p): if $int[$p] then (leafpaths($p + "0"), leafpaths($p + "1")) else $p end;
    ([leafpaths("")]) as $lp
  | if ($lp | length) != ($leaves | length) or ($leaves | length) == 0 then
      {root: $leaves[0], ops: [ $leaves[1:][] as $p | {from: $leaves[0], new: $p, direction: "right", ratio: 0.5} ]}
    else
      (reduce range(0; $lp | length) as $i ({}; . + {($lp[$i]): $leaves[$i]})) as $leafpane
      | def first_leaf($p): if $int[$p] then first_leaf($p + "0") else $leafpane[$p] end;
        def ops($p): if $int[$p] then
            ({from: first_leaf($p), new: first_leaf($p + "1"), direction: $int[$p].direction, ratio: $int[$p].ratio},
             ops($p + "0"), ops($p + "1"))
          else empty end;
        {root: first_leaf(""), ops: [ops("")]}
    end;
'

# ---------------------------------------------------------------------------
# hook: the agent-side entry point. Fast, silent, never fails the agent.

cmd_hook() {  # <agent>
  local agent=${1:-} payload pid seq
  if [ "${FM_SESSION_LEDGER:-on}" = off ] || [ -z "${HERDR_PANE_ID:-}" ] || [ -z "${HERDR_SOCKET_PATH:-}" ]; then
    cat >/dev/null 2>&1
    return 0
  fi
  case "$agent" in claude | codex | pi) ;; *) cat >/dev/null 2>&1; return 0 ;; esac
  mkdir -p "$ENTRIES" 2>/dev/null || { cat >/dev/null 2>&1; return 0; }
  payload=$(mktemp "$LEDGER/.event.XXXXXX" 2>/dev/null) || { cat >/dev/null 2>&1; return 0; }
  cat >"$payload" 2>/dev/null || true
  seq=$(date +%s%N)
  pid=$(ledger_agent_pid "$agent" "$PPID" 2>/dev/null) || pid=0
  setsid -f "$SELF" record "$agent" "$payload" "$pid" "$seq" </dev/null >/dev/null 2>&1 \
    || rm -f "$payload" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# record: the detached writer. One event, one atomic write.

ledger_entry_name() {  # <agent> <session-id>
  printf '%s-%s' "$1" "$2"
}

ledger_write_entry() {  # <file> <json>
  local file=$1 json=$2 tmp
  tmp=$(mktemp "$ENTRIES/.tmp.XXXXXX") || return 1
  if printf '%s\n' "$json" | jq -e . >"$tmp" 2>/dev/null; then
    chmod 0600 "$tmp" 2>/dev/null
    mv -f -- "$tmp" "$file" && return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# The fleet identity of a launch environment, as JSON (null when none).
ledger_fleet_json() {  # <env-json> <cwd> <pane-id>
  local env=$1 cwd=$2 pane=$3 task home fhome parent sm_id kind cand meta found=
  task=$(printf '%s' "$env" | jq -r '.FM_TASK_ID // empty')
  fhome=$(printf '%s' "$env" | jq -r '.FM_HOME // empty')
  if [ -n "$task" ]; then
    case "$task" in *[!A-Za-z0-9._-]*) printf 'null'; return 0 ;; esac
    for cand in $( { [ -n "$fhome" ] && printf '%s\n' "$fhome"; printf '%s\n' "$PRIMARY_HOME"; \
        grep -l '^kind=secondmate$' "$PRIMARY_HOME"/state/*.meta 2>/dev/null \
        | while IFS= read -r meta; do sed -n 's/^home=//p' "$meta" | head -n 1; done; } | awk 'NF && !seen[$0]++'); do
      meta="$cand/state/$task.meta"
      [ -f "$meta" ] || continue
      if [ "$(sed -n 's/^herdr_pane_id=//p' "$meta" | head -n 1)" = "$pane" ] \
        || [ "$(ledger_realpath "$(sed -n 's/^worktree=//p' "$meta" | head -n 1)")" = "$(ledger_realpath "$cwd")" ]; then
        found=$cand
        break
      fi
    done
    kind=
    [ -z "$found" ] || kind=$(sed -n 's/^kind=//p' "$found/state/$task.meta" | head -n 1)
    jq -cn --arg task "$task" --arg home "$found" --arg kind "$kind" \
      '{role: "worker", task_id: $task, home: (if $home == "" then null else $home end), kind: (if $kind == "" then null else $kind end)}'
    return 0
  fi
  if [ -n "$fhome" ] && [ -f "$fhome/.fm-secondmate-home" ]; then
    sm_id=$(head -n 1 "$fhome/.fm-secondmate-home" 2>/dev/null | tr -d '[:space:]')
    parent=$(printf '%s' "$env" | jq -r '.FM_PUBLIC_FOLLOWUP_PRIMARY_HOME // empty')
    [ -n "$parent" ] || parent=$PRIMARY_HOME
    home=
    [ ! -f "$parent/state/$sm_id.meta" ] || home=$parent
    jq -cn --arg task "$sm_id" --arg home "$home" --arg own "$fhome" \
      '{role: "secondmate", task_id: $task, home: (if $home == "" then null else $home end), kind: "secondmate", own_home: $own}'
    return 0
  fi
  if [ "$(ledger_realpath "$cwd")" = "$(ledger_realpath "$PRIMARY_HOME")" ] && [ ! -f "$PRIMARY_HOME/.fm-secondmate-home" ]; then
    jq -cn --arg home "$PRIMARY_HOME" '{role: "primary", task_id: null, home: $home, kind: "primary"}'
    return 0
  fi
  printf 'null'
}

# The Herdr location of a pane from one live snapshot, as JSON.
ledger_location_json() {  # <session> <socket> <pane-id>
  local session=$1 socket=$2 pane=$3 snap start
  start=$(ledger_mtime "$socket")
  snap=$(ledger_herdr "$session" api snapshot 2>/dev/null) || snap=
  printf '%s' "$snap" | jq -e . >/dev/null 2>&1 || snap='{}'
  printf '%s' "$snap" | jq -c --arg session "$session" --arg socket "$socket" --arg start "$start" \
    --arg pane "$pane" --arg tab "${HERDR_TAB_ID:-}" --arg ws "${HERDR_WORKSPACE_ID:-}" '
    (.result.snapshot // {}) as $s
    | (([$s.panes[]? | select(.pane_id == $pane)] | first) // {pane_id: $pane, tab_id: $tab, workspace_id: $ws}) as $p
    | ([$s.workspaces[]? | select(.workspace_id == $p.workspace_id)] | first) as $w
    | ([$s.tabs[]? | select(.tab_id == $p.tab_id)] | first) as $t
    | {
        session: $session, socket: $socket, server_start: $start,
        workspace_id: $p.workspace_id, workspace_label: ($w.label // null), workspace_number: ($w.number // null),
        tab_id: $p.tab_id, tab_label: ($t.label // null), tab_number: ($t.number // null),
        pane_id: $pane, pane_label: ($p.label // null),
        located: ($s.panes != null and ([$s.panes[]? | select(.pane_id == $pane)] | length) == 1),
        tab_layout: (([$s.layouts[]? | select(.tab_id == $p.tab_id) | {splits, panes: [.panes[] | {pane_id, rect}]}] | first) // null),
        tab_panes: [$s.panes[]? | select(.tab_id == $p.tab_id) | {pane_id, cwd: (.cwd // null), label: (.label // null)}]
      }' 2>/dev/null || jq -cn --arg session "$session" --arg socket "$socket" --arg start "$start" \
      --arg pane "$pane" --arg tab "${HERDR_TAB_ID:-}" --arg ws "${HERDR_WORKSPACE_ID:-}" \
      '{session: $session, socket: $socket, server_start: $start, workspace_id: $ws, tab_id: $tab, pane_id: $pane, located: false, tab_layout: null, tab_panes: []}'
}

# Build the full entry for a session event.
ledger_build_entry() {  # <agent> <payload-json> <pid> <seq> <state> <old-entry-or-empty>
  local agent=$1 payload=$2 pid=$3 seq=$4 state=$5 old=$6
  local session socket location cmdline_json env_json fleet pid_start cwd
  socket=$HERDR_SOCKET_PATH
  session=$(ledger_session_from_socket "$socket")
  location=$(ledger_location_json "$session" "$socket" "$HERDR_PANE_ID")
  cmdline_json='[]'
  env_json='{}'
  pid_start=
  if [ "$pid" != 0 ] && [ -r "$PROC/$pid/cmdline" ]; then
    cmdline_json=$(jq -Rsc 'split("\u0000") | if length > 0 and .[-1] == "" then .[:-1] else . end' <"$PROC/$pid/cmdline" 2>/dev/null) || cmdline_json='[]'
    env_json=$(jq -Rsc "$LEDGER_JQ_ENV"'split("\u0000") | map(select(test("^[A-Za-z_][A-Za-z0-9_]*=")) | capture("^(?<key>[^=]+)=(?<value>.*)$"; "s")) | from_entries | ledger_env_filter' \
      <"$PROC/$pid/environ" 2>/dev/null) || env_json='{}'
    pid_start=$(ledger_proc_start "$pid" 2>/dev/null) || pid_start=
  fi
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
  [ -n "$cwd" ] || cwd=$(readlink "$PROC/$pid/cwd" 2>/dev/null || true)
  fleet=$(ledger_fleet_json "$env_json" "$cwd" "$HERDR_PANE_ID")
  jq -cn \
    --arg schema "$LEDGER_SCHEMA" --arg agent "$agent" --argjson payload "$payload" \
    --argjson seq "$seq" --arg state "$state" --arg pid "$pid" --arg pid_start "$pid_start" \
    --arg cwd "$cwd" --argjson location "$location" --argjson cmdline "$cmdline_json" \
    --argjson env "$env_json" --argjson fleet "$fleet" --argjson old "${old:-null}" "$LEDGER_JQ_CLAUDE_ARGS"'
    ($cmdline | if length > 0 and ((.[0] | split("/") | last) | IN("node", "nodejs", "bun")) then .[2:] else .[1:] end) as $args
    | (if $agent == "claude" then ($args | claude_resume_args) else {argv: [], unknown: [], prompt: false} end) as $parsed
    | ([$agent] + $parsed.argv) as $argv
    | {
        schema: $schema, agent: $agent,
        session_id: $payload.session_id,
        transcript: ($payload.transcript_path // $old.transcript // null),
        seq: $seq, updated_at: ($seq / 1000000000 | floor),
        updated: ($seq / 1000000000 | floor | todate),
        event: ($payload.hook_event_name // null),
        start_source: ($payload.source // $old.start_source // null),
        state: $state,
        end: null,
        cwd: $cwd,
        pid: ($pid | tonumber? // null), pid_start: (if $pid_start == "" then null else $pid_start end),
        argv: $argv,
        resume_argv: (if $agent == "claude" then $argv + ["--resume", $payload.session_id] else null end),
        argv_unknown_options: $parsed.unknown,
        initial_prompt_dropped: $parsed.prompt,
        env: $env,
        herdr: $location,
        fleet: $fleet
      }'
}

ledger_apply_state() {  # <old-entry> <state> <seq> <event>
  printf '%s' "$1" | jq -c --arg state "$2" --argjson seq "$3" --arg event "$4" \
    '.state = $state | .seq = $seq | .event = $event | .updated_at = ($seq / 1000000000 | floor) | .updated = ($seq / 1000000000 | floor | todate)'
}

# Remove the older entries a new session replaces: one of the same pane under
# the same server start (/clear, /resume, a new agent in that pane), and one
# of the same fleet agent (a task or second mate record in a home, or a home's
# primary), which runs as exactly one session, wherever it was relaunched.
ledger_dedupe_pane() {  # <keep-name> <entry-json>
  local keep=$1 entry=$2 file
  for file in "$ENTRIES"/*.json; do
    [ -f "$file" ] || continue
    [ "${file##*/}" != "$keep.json" ] || continue
    if jq -e --argjson e "$entry" '.seq < $e.seq and (
        (.herdr.session == $e.herdr.session and .herdr.pane_id == $e.herdr.pane_id
          and .herdr.server_start == $e.herdr.server_start)
        or ($e.fleet != null and .fleet != null and $e.fleet.home != null
          and .fleet.home == $e.fleet.home and .fleet.role == $e.fleet.role
          and .fleet.task_id == $e.fleet.task_id))' "$file" >/dev/null 2>&1; then
      rm -f -- "$file"
      ledger_log events.log "replaced ${file##*/} by $keep.json (same pane or same fleet agent)"
    fi
  done
}

# True when a pane was closed while Herdr kept running normally.
ledger_pane_closed_by_hand() {  # <session> <pane-id>
  local session=$1 pane=$2 code
  [ "$(systemctl is-system-running 2>/dev/null)" != stopping ] || return 1
  if [ "$session" = default ] && command -v systemctl >/dev/null 2>&1; then
    case "$(systemctl --user show -p ActiveState --value herdr-server.service 2>/dev/null)" in
      deactivating | failed) return 1 ;;
    esac
  fi
  code=$(ledger_herdr "$session" pane get "$pane" 2>/dev/null | jq -r '.error.code // "present"' 2>/dev/null) || return 1
  [ "$code" = pane_not_found ] || return 1
  sleep "${FM_SESSION_LEDGER_SETTLE:-2}"
  ledger_herdr "$session" pane list >/dev/null 2>&1 || return 1
  code=$(ledger_herdr "$session" pane get "$pane" 2>/dev/null | jq -r '.error.code // "present"' 2>/dev/null) || return 1
  [ "$code" = pane_not_found ]
}

cmd_record() {  # <agent> <payload-file> <pid> <seq>
  local agent=$1 payload_file=$2 pid=$3 seq=$4 payload fields event sid source reason subagent name file old state entry
  # shellcheck disable=SC2064 # Expand the payload path now.
  trap "rm -f -- '$payload_file'" EXIT
  payload=$(jq -c 'if type == "object" then . else error("not an object") end' "$payload_file" 2>/dev/null) || return 0
  fields=$(printf "%s" "$payload" | jq -r '[.hook_event_name // "", .session_id // "", .source // "", .reason // "", (.agent_id // "")] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")') || return 0
  IFS=$'\x1f' read -r event sid source reason subagent <<<"$fields"
  [ -z "$subagent" ] || return 0
  case "$sid" in '' | *[!A-Za-z0-9._:-]*) return 0 ;; esac
  [ "${#sid}" -le 200 ] || return 0
  mkdir -p "$ENTRIES" || return 0
  name=$(ledger_entry_name "$agent" "$sid")
  file="$ENTRIES/$name.json"
  exec 9>"$ENTRIES/.$name.lock" || return 0
  flock -w 20 9 || return 0
  old=
  [ ! -f "$file" ] || old=$(jq -c . "$file" 2>/dev/null) || old=
  if [ -n "$old" ] && [ "$(printf '%s' "$old" | jq -r '.seq // 0')" -ge "$seq" ] 2>/dev/null; then
    return 0
  fi
  case "$event" in
    SessionStart)
      state=idle
      if [ -n "$old" ] && [ "$source" = compact ]; then
        state=$(printf '%s' "$old" | jq -r '.state // "idle"')
      fi
      entry=$(ledger_build_entry "$agent" "$payload" "$pid" "$seq" "$state" "$old") || return 0
      ledger_write_entry "$file" "$entry" || return 0
      ledger_dedupe_pane "$name" "$entry"
      ledger_log events.log "$event/$source $name pane=${HERDR_PANE_ID} state=$state"
      ;;
    UserPromptSubmit | Stop | StopFailure)
      state=idle
      [ "$event" != UserPromptSubmit ] || state=working
      if [ -n "$old" ]; then
        entry=$(ledger_apply_state "$old" "$state" "$seq" "$event") || return 0
        ledger_write_entry "$file" "$entry" || return 0
      else
        # Hooks installed mid-session: the first event builds the entry.
        entry=$(ledger_build_entry "$agent" "$payload" "$pid" "$seq" "$state" "") || return 0
        ledger_write_entry "$file" "$entry" || return 0
        ledger_dedupe_pane "$name" "$entry"
      fi
      ledger_log events.log "$event $name state=$state"
      ;;
    SessionEnd)
      [ -n "$old" ] || return 0
      case "$reason" in
        prompt_input_exit | logout | clear | resume | bypass_permissions_disabled)
          rm -f -- "$file"
          ledger_log events.log "$event/$reason $name removed (deliberate end)"
          ;;
        *)
          # A crash-class end keeps the entry live. Release the lock while
          # the hand-close check settles, then re-check the seq before removal.
          flock -u 9
          if ledger_pane_closed_by_hand "$(printf '%s' "$old" | jq -r '.herdr.session')" "$(printf '%s' "$old" | jq -r '.herdr.pane_id')"; then
            flock -w 20 9 || return 0
            if [ -f "$file" ] && [ "$(jq -r '.seq // 0' "$file" 2>/dev/null)" = "$(printf '%s' "$old" | jq -r '.seq')" ]; then
              rm -f -- "$file"
              ledger_log events.log "$event/${reason:-unknown} $name removed (pane closed while Herdr ran)"
            fi
          else
            flock -w 20 9 || return 0
            if [ -f "$file" ] && [ "$(jq -r '.seq // 0' "$file" 2>/dev/null)" = "$(printf '%s' "$old" | jq -r '.seq')" ]; then
              entry=$(printf '%s' "$old" | jq -c --arg reason "${reason:-unknown}" --argjson at "$(date +%s)" \
                '.end = {reason: $reason, at: $at, kept: "not a deliberate end; restorable"}')
              ledger_write_entry "$file" "$entry"
            fi
            ledger_log events.log "$event/${reason:-unknown} $name kept (not a deliberate end)"
          fi
          ;;
      esac
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Reading the ledger.

ledger_entries_json() {  # [<herdr-session>]
  local want=${1:-} files=()
  shopt -s nullglob
  files=("$ENTRIES"/*.json)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  jq -cs --arg want "$want" '[.[] | select(type == "object" and .schema == "fm-session-ledger/v1")
    | select($want == "" or .herdr.session == $want)]
    | sort_by(.herdr.session, (.herdr.workspace_number // 0), (.herdr.tab_number // 0), .herdr.pane_id, .seq)' "${files[@]}" 2>/dev/null || printf '[]'
}

cmd_list() {
  local json=0 session=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --session) session=${2:-}; shift ;;
      *) echo "fm-session-ledger: unknown list option: $1" >&2; return 2 ;;
    esac
    shift
  done
  if [ "$json" = 1 ]; then
    ledger_entries_json "$session"
    echo
    return 0
  fi
  ledger_entries_json "$session" | jq -r '
    if length == 0 then "ledger is empty" else .[] |
    "\(.herdr.session) \(.herdr.workspace_label // .herdr.workspace_id)/\(.herdr.tab_label // .herdr.tab_id)/\(.herdr.pane_id)\(if .herdr.pane_label then " (" + .herdr.pane_label + ")" else "" end)  \(.agent) \(.session_id)  \(.state)\(if .end then " ended:" + .end.reason else "" end)  \(if .fleet then .fleet.role + (if .fleet.task_id then ":" + .fleet.task_id else "" end) else "hand" end)  \(.cwd)  updated \(.updated)" end'
}

# Sessions running now: "<agent>\t<session-id>" lines.
ledger_running_sessions() {
  local cfg pid start sid seen=" "
  for cfg in "$(ledger_claude_config)" $(ledger_entries_json | jq -r '.[].env.CLAUDE_CONFIG_DIR // empty' | sort -u); do
    case "$seen" in *" $cfg "*) continue ;; esac
    seen="$seen$cfg "
    [ -d "$cfg/sessions" ] || continue
    while IFS=$'\x1f' read -r pid start sid; do
      [ -n "$sid" ] || continue
      [ -d "$PROC/$pid" ] || continue
      [ -z "$start" ] || [ "$(ledger_proc_start "$pid" 2>/dev/null)" = "$start" ] || continue
      printf 'claude\t%s\n' "$sid"
    done < <(cat "$cfg"/sessions/*.json 2>/dev/null | jq -r 'select(type == "object" and .sessionId != null) | [(.pid | tostring), (.procStart // "" | tostring), .sessionId] | join("\u001f")' 2>/dev/null)
  done
}

ledger_restore_command() {
  printf '%s restore' "$SELF"
}

# ---------------------------------------------------------------------------
# can-resume: the no-fresh-session gate for automatic recovery.

cmd_can_resume() {
  local task='' home='' primary='' entries running
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift ;;
      --home) home=${2:-}; shift ;;
      --primary) primary=${2:-}; shift ;;
      *) echo "fm-session-ledger: unknown can-resume option: $1" >&2; return 2 ;;
    esac
    shift
  done
  if [ -n "$primary" ]; then
    home=$primary
  elif [ -z "$task" ] || [ -z "$home" ]; then
    echo "fm-session-ledger: can-resume needs --task <id> --home <home> or --primary <home>" >&2
    return 2
  fi
  home=$(ledger_realpath "$home")
  running=$(ledger_running_sessions | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | .[1])')
  entries=$(ledger_entries_json | jq -c --arg task "$task" --arg home "$home" --argjson running "$running" '
    [.[] | select(.fleet != null and .fleet.home != null)
     | select(if $task == "" then .fleet.role == "primary" else .fleet.task_id == $task end)
     | select(.session_id | IN($running[]) | not)]')
  while IFS=$'\t' read -r ehome transcript; do
    [ -n "$transcript" ] && [ -f "$transcript" ] || continue
    [ "$(ledger_realpath "$ehome")" = "$home" ] || continue
    ledger_restore_command
    echo
    return 0
  done < <(printf '%s' "$entries" | jq -r '.[] | [.fleet.home, (.transcript // "")] | @tsv')
  return 1
}

# ---------------------------------------------------------------------------
# restore

ledger_shell_quote() {  # <value>
  case "$1" in
    '' | *[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The command typed into the target pane for one entry.
ledger_launch_command() {  # <entry-json>
  local entry=$1 cwd cmd k v arg
  cwd=$(printf '%s' "$entry" | jq -r '.cwd')
  cmd="cd -- $(ledger_shell_quote "$cwd") && env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_BRIDGE_SESSION_ID"
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    cmd="$cmd $k=$(ledger_shell_quote "$(printf '%b' "$v")")"
  done < <(printf '%s' "$entry" | jq -r '.env | to_entries[] | [.key, (.value | gsub("\\\\"; "\\\\") | gsub("\n"; "\\n") | gsub("\t"; "\\t"))] | @tsv' 2>/dev/null)
  while IFS= read -r -d '' arg; do
    cmd="$cmd $(ledger_shell_quote "$arg")"
  done < <(printf '%s' "$entry" | jq -j '.resume_argv[] | (. + "\u0000")')
  printf '%s' "$cmd"
}

ledger_fleet_record_ok() {  # <entry-json> -> prints reason on failure
  local entry=$1 role task home
  role=$(printf '%s' "$entry" | jq -r '.fleet.role // empty')
  task=$(printf '%s' "$entry" | jq -r '.fleet.task_id // empty')
  home=$(printf '%s' "$entry" | jq -r '.fleet.home // empty')
  case "$role" in
    '' | primary) return 0 ;;
  esac
  if [ -z "$home" ] || [ ! -f "$home/state/$task.meta" ]; then
    printf 'fleet record %s is gone from %s' "$task" "${home:-its home}"
    return 1
  fi
  return 0
}

# Whether a live pane holds only its shell, from Herdr's process info.
ledger_pane_shell_only() {  # <session> <pane-id>
  ledger_herdr "$1" pane process-info --pane "$2" 2>/dev/null \
    | jq -e '.result.process_info | .foreground_process_group_id == .shell_pid' >/dev/null 2>&1
}

ledger_wait_running() {  # <session-id> <seconds>
  local sid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if ledger_running_sessions | grep -qxF "claude	$sid"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Carry-on decision for a fleet agent that was working at the crash.
ledger_carry_on_wanted() {  # <entry-json> <worker-classes>
  local entry=$1 classes=$2 role task state class
  role=$(printf '%s' "$entry" | jq -r '.fleet.role // empty')
  task=$(printf '%s' "$entry" | jq -r '.fleet.task_id // empty')
  state=$(printf '%s' "$entry" | jq -r '.state')
  [ "$state" = working ] || return 1
  case "$role" in
    worker)
      class=$(printf '%s\n' "$classes" | awk -F'\t' -v id="$task" '$1 == id { print $2; exit }')
      case "$class" in '' | working | running) return 0 ;; esac
      return 1
      ;;
    secondmate) return 0 ;;
  esac
  return 1
}

# Move a fleet task record to the pane its agent runs in now. The record is
# rewritten under its own meta lock (fm_meta_lock_path) and renamed into
# place, the same guarded publication other record writers use.
ledger_rebind_record() {  # <home> <task> <session> <workspace> <tab> <pane>
  local home=$1 task=$2 session=$3 ws=$4 tab=$5 pane=$6
  (
    FM_HOME=$home
    STATE="$home/state"
    export FM_HOME STATE
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh" || exit 1
    meta="$STATE/$task.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || exit 1
    lock=$(fm_meta_lock_path "$meta") || exit 1
    fm_lock_acquire_wait_bounded "$lock" 30 || exit 1
    tmp=$(mktemp "$STATE/.ledger-meta.XXXXXX") || { fm_lock_release "$lock"; exit 1; }
    awk -F= '$1 != "window" && $1 != "herdr_session" && $1 != "herdr_workspace_id" && $1 != "herdr_tab_id" && $1 != "herdr_pane_id"' "$meta" >"$tmp" \
      && printf 'window=%s:%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
        "$session" "$pane" "$session" "$ws" "$tab" "$pane" >>"$tmp" \
      && chmod --reference="$meta" "$tmp" 2>/dev/null; true
    if [ -s "$tmp" ] && mv -f -- "$tmp" "$meta"; then
      rc=0
    else
      rm -f -- "$tmp"
      rc=1
    fi
    fm_lock_release "$lock"
    exit "$rc"
  )
}

ledger_carry_on_text() {
  printf '%s' "Herdr restarted and stopped you in the middle of your task. This is your original conversation, resumed with its full history. Background shells, servers, and monitors you had started are gone. Check the current state of your work, then carry on."
}

cmd_restore() {
  local dry=0 only='' batch=3 pause=20 wait=90
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --session) only=${2:-}; shift ;;
      --batch) batch=${2:-}; shift ;;
      --pause) pause=${2:-}; shift ;;
      --wait) wait=${2:-}; shift ;;
      -h | --help) sed -n '2,120p' "$SELF" | sed -n '/^# Usage:/,/^# Entry lifecycle/p' | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "fm-session-ledger: unknown restore option: $1" >&2; return 2 ;;
    esac
    shift
  done
  case "$batch$pause$wait" in *[!0-9]*) echo "fm-session-ledger: --batch, --pause, and --wait take whole numbers" >&2; return 2 ;; esac
  [ "$batch" -ge 1 ] || batch=1
  command -v jq >/dev/null 2>&1 || { echo "fm-session-ledger: jq is required" >&2; return 1; }

  local entries running total
  entries=$(ledger_entries_json "$only")
  total=$(printf '%s' "$entries" | jq 'length')
  if [ "$total" = 0 ]; then
    echo "restore: the ledger holds no agent session${only:+ for Herdr session $only}; nothing to do"
    return 0
  fi
  running=$(ledger_running_sessions | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | .[1])')

  # Per-session Herdr state, read once.
  local -A SNAP=() UP=()
  local s
  for s in $(printf '%s' "$entries" | jq -r '[.[].herdr.session] | unique[]'); do
    if SNAP[$s]=$(ledger_herdr "$s" api snapshot 2>/dev/null) && printf '%s' "${SNAP[$s]}" | jq -e '.result.snapshot' >/dev/null 2>&1; then
      UP[$s]=1
    else
      UP[$s]=0
    fi
  done

  # Worker classes per fleet home, read before anything launches.
  local -A CLASSES=()
  local h
  for h in $(printf '%s' "$entries" | jq -r '[.[] | select(.fleet.role == "worker" and .fleet.home != null) | .fleet.home] | unique[]'); do
    if [ -x "$h/bin/fm-local-worker-restore.sh" ]; then
      CLASSES[$h]=$(FM_HOME=$h "$h/bin/fm-local-worker-restore.sh" classify 2>/dev/null || true)
    else
      CLASSES[$h]=$(FM_HOME=$h "$SCRIPT_DIR/fm-local-worker-restore.sh" classify 2>/dev/null || true)
    fi
  done

  # Classify every entry.
  local plan=() i entry key sid agent session transcript reason class ws tab pane wslabel live
  local n_running=0 n_missing=0 n_closed=0 n_unsupported=0 n_down=0 n_deleted=0 sockdir
  local report=()
  for ((i = 0; i < total; i++)); do
    entry=$(printf '%s' "$entries" | jq -c ".[$i]")
    sid=$(printf '%s' "$entry" | jq -r '.session_id')
    agent=$(printf '%s' "$entry" | jq -r '.agent')
    session=$(printf '%s' "$entry" | jq -r '.herdr.session')
    transcript=$(printf '%s' "$entry" | jq -r '.transcript // empty')
    key="$agent $sid"
    # A named Herdr session whose directory is gone was deleted (a finished
    # lab, for example): nothing can be restored there, so its entry goes.
    sockdir=$(printf '%s' "$entry" | jq -r '.herdr.socket // empty')
    sockdir=${sockdir%/*}
    if [ "$session" != default ] && [ -n "$sockdir" ] && [ ! -d "$sockdir" ]; then
      report+=("deleted      $key: Herdr session $session no longer exists; entry $( [ "$dry" = 1 ] && printf 'would be' || printf 'was' ) removed")
      n_deleted=$((n_deleted + 1))
      [ "$dry" = 1 ] || rm -f -- "$ENTRIES/$agent-$sid.json"
      continue
    fi
    if [ "$agent" != claude ] || ! printf '%s' "$entry" | jq -e '.resume_argv | type == "array" and length > 2' >/dev/null; then
      report+=("unsupported  $key: no verified resume for agent type $agent; restore it by hand")
      n_unsupported=$((n_unsupported + 1))
      continue
    fi
    if printf '%s' "$running" | jq -e --arg sid "$sid" 'index($sid) != null' >/dev/null; then
      report+=("running      $key: already running; left alone")
      n_running=$((n_running + 1))
      continue
    fi
    if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
      report+=("missing      $key: transcript ${transcript:-unrecorded} is missing; not resumed and never replaced by a fresh session")
      n_missing=$((n_missing + 1))
      continue
    fi
    if ! reason=$(ledger_fleet_record_ok "$entry"); then
      report+=("closed       $key: $reason; not resumed")
      n_closed=$((n_closed + 1))
      continue
    fi
    if [ "${UP[$session]:-0}" != 1 ]; then
      report+=("herdr-down   $key: Herdr session $session is not running; start it, then run the restore again")
      n_down=$((n_down + 1))
      continue
    fi
    ws=$(printf '%s' "$entry" | jq -r '.herdr.workspace_id // empty')
    tab=$(printf '%s' "$entry" | jq -r '.herdr.tab_id // empty')
    pane=$(printf '%s' "$entry" | jq -r '.herdr.pane_id // empty')
    wslabel=$(printf '%s' "$entry" | jq -c '.herdr.workspace_label')
    live=$(printf '%s' "${SNAP[$session]}" | jq -r --arg ws "$ws" --arg tab "$tab" --arg pane "$pane" --argjson wl "$wslabel" '
      .result.snapshot as $s
      | if ([$s.workspaces[] | select(.workspace_id == $ws and (.label // null) == $wl)] | length) == 0 then "rebuild-workspace"
        elif ([$s.tabs[] | select(.tab_id == $tab and .workspace_id == $ws)] | length) == 0 then "rebuild-tab"
        elif ([$s.panes[] | select(.pane_id == $pane and .tab_id == $tab)] | length) == 0 then "rebuild-pane"
        else "present" end')
    class=$live
    if [ "$live" = present ]; then
      if ledger_pane_shell_only "$session" "$pane"; then
        class=same-pane
      else
        class='split'
      fi
    fi
    plan+=("$class	$i")
  done

  # Print the plan.
  local line cls idx desc
  echo "restore plan (${#plan[@]} to resume, $total in ledger):"
  for line in "${plan[@]}"; do
    cls=${line%%$'\t'*}
    idx=${line#*$'\t'}
    entry=$(printf '%s' "$entries" | jq -c ".[$idx]")
    desc=$(printf '%s' "$entry" | jq -r '"\(.agent) \(.session_id) [\(if .fleet then .fleet.role + (if .fleet.task_id then ":" + .fleet.task_id else "" end) else "hand" end), \(.state)] \(.herdr.session) \(.herdr.workspace_label // .herdr.workspace_id)/\(.herdr.tab_label // .herdr.tab_id)/\(.herdr.pane_id)"')
    case "$cls" in
      same-pane) echo "  resume in same pane   $desc" ;;
      split) echo "  resume in new split   $desc (recorded pane runs something else)" ;;
      rebuild-workspace) echo "  rebuild workspace     $desc" ;;
      rebuild-tab) echo "  rebuild tab           $desc" ;;
      rebuild-pane) echo "  rebuild pane          $desc" ;;
    esac
    [ "$dry" = 0 ] || echo "      command: $(ledger_launch_command "$entry" | cut -c1-400)"
  done
  for line in "${report[@]}"; do
    echo "  $line"
  done

  if [ "$dry" = 1 ]; then
    echo "restore summary (dry run): ${#plan[@]} would resume, $n_running already running, $n_missing missing transcript, $n_closed fleet record gone, $n_unsupported unsupported, $n_down Herdr not running, $n_deleted in a deleted Herdr session; nothing was changed"
    return 0
  fi

  # Placement: resolve a target pane for every planned entry.
  local -A PANEMAP=() WSMAP=() TABMAP=() TARGET=() TTAB=() TWS=()
  local out newpane newtab newws ops root from new dir ratio label tabcwd tablabel
  local resumed=0 failed=0 messaged=0 rebound=0 cmd role task home newp b
  local summary_lines=() pending=() batchset=()
  for line in "${plan[@]}"; do
    cls=${line%%$'\t'*}
    idx=${line#*$'\t'}
    entry=$(printf '%s' "$entries" | jq -c ".[$idx]")
    session=$(printf '%s' "$entry" | jq -r '.herdr.session')
    ws=$(printf '%s' "$entry" | jq -r '.herdr.workspace_id')
    tab=$(printf '%s' "$entry" | jq -r '.herdr.tab_id')
    pane=$(printf '%s' "$entry" | jq -r '.herdr.pane_id')
    case "$cls" in
      same-pane)
        TARGET[$idx]=$pane
        TTAB[$idx]=$tab
        TWS[$idx]=$ws
        ;;
      split)
        out=$(ledger_herdr "$session" pane split "$pane" --direction right --cwd "$(printf '%s' "$entry" | jq -r '.cwd')" 2>/dev/null) || out=
        newpane=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
        if [ -n "$newpane" ]; then
          TARGET[$idx]=$newpane
          TTAB[$idx]=$tab
          TWS[$idx]=$ws
        fi
        ;;
      rebuild-*)
        # A pane already rebuilt for an earlier entry of the same tab.
        if [ -n "${PANEMAP[$session|$pane]:-}" ]; then
          TARGET[$idx]=${PANEMAP[$session|$pane]}
          TTAB[$idx]=${TABMAP[$session|$tab]}
          TWS[$idx]=${WSMAP[$session|$ws]}
          continue
        fi
        # The newest recorded layout of this tab, across every entry.
        local tabinfo
        tabinfo=$(printf '%s' "$entries" | jq -c --arg s "$session" --arg tab "$tab" '
          [.[] | select(.herdr.session == $s and .herdr.tab_id == $tab and .herdr.tab_layout != null)] | sort_by(.seq) | last
          | {layout: .herdr.tab_layout, panes: .herdr.tab_panes, tab_label: .herdr.tab_label, workspace_label: .herdr.workspace_label}')
        [ "$tabinfo" != null ] || tabinfo=$(printf '%s' "$entry" | jq -c '{layout: {splits: [], panes: [{pane_id: .herdr.pane_id}]}, panes: [{pane_id: .herdr.pane_id, cwd: .cwd, label: .herdr.pane_label}], tab_label: .herdr.tab_label, workspace_label: .herdr.workspace_label}')
        ops=$(printf '%s' "$tabinfo" | jq -c "$LEDGER_JQ_REPLAY"'.layout | replay_ops')
        root=$(printf '%s' "$ops" | jq -r '.root')
        tabcwd=$(printf '%s' "$tabinfo" | jq -r --arg root "$root" --arg cwd "$(printf '%s' "$entry" | jq -r '.cwd')" '([.panes[]? | select(.pane_id == $root) | .cwd] | first) // $cwd')
        [ -d "$tabcwd" ] || tabcwd=$HOME
        tablabel=$(printf '%s' "$tabinfo" | jq -r '.tab_label // empty')
        if [ "$cls" = rebuild-pane ]; then
          # The tab survives without this pane: split a pane of that tab.
          newws=$ws
          newtab=$tab
          from=$(printf '%s' "${SNAP[$session]}" | jq -r --arg tab "$tab" '[.result.snapshot.panes[] | select(.tab_id == $tab) | .pane_id] | first // empty')
          out=$(ledger_herdr "$session" pane split "$from" --direction right --cwd "$(printf '%s' "$entry" | jq -r '.cwd')" 2>/dev/null) || out=
          newpane=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
          [ -z "$newpane" ] || PANEMAP[$session|$pane]=$newpane
          TABMAP[$session|$tab]=$newtab
          WSMAP[$session|$ws]=$newws
        else
          if [ "$cls" = rebuild-workspace ] && [ -z "${WSMAP[$session|$ws]:-}" ]; then
            wslabel=$(printf '%s' "$tabinfo" | jq -r '.workspace_label // empty')
            out=$(ledger_herdr "$session" workspace create --cwd "$tabcwd" ${wslabel:+--label "$wslabel"} --no-focus 2>/dev/null) || out=
            newws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
            newtab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
            newpane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
            [ -n "$newws" ] || { summary_lines+=("failed       $(printf '%s' "$entry" | jq -r '"\(.agent) \(.session_id)"'): could not create workspace"); failed=$((failed + 1)); continue; }
            WSMAP[$session|$ws]=$newws
          else
            newws=${WSMAP[$session|$ws]:-$ws}
            out=$(ledger_herdr "$session" tab create --workspace "$newws" --cwd "$tabcwd" ${tablabel:+--label "$tablabel"} --no-focus 2>/dev/null) || out=
            newtab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
            newpane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
          fi
          [ -n "$newtab" ] && [ -n "$newpane" ] || { summary_lines+=("failed       $(printf '%s' "$entry" | jq -r '"\(.agent) \(.session_id)"'): could not create tab"); failed=$((failed + 1)); continue; }
          [ -z "$tablabel" ] || ledger_herdr "$session" tab rename "$newtab" "$tablabel" >/dev/null 2>&1 || true
          TABMAP[$session|$tab]=$newtab
          PANEMAP[$session|$root]=$newpane
          while IFS=$'\t' read -r from new dir ratio; do
            [ -n "${PANEMAP[$session|$from]:-}" ] || continue
            label=$(printf '%s' "$tabinfo" | jq -r --arg p "$new" '([.panes[]? | select(.pane_id == $p) | .cwd] | first) // empty')
            [ -n "$label" ] && [ -d "$label" ] || label=$tabcwd
            out=$(ledger_herdr "$session" pane split "${PANEMAP[$session|$from]}" --direction "$dir" --ratio "$ratio" --cwd "$label" 2>/dev/null) || out=
            newpane=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
            [ -z "$newpane" ] || PANEMAP[$session|$new]=$newpane
          done < <(printf '%s' "$ops" | jq -r '.ops[] | [.from, .new, .direction, (.ratio | tostring)] | @tsv')
          # Pane names from the recorded tab.
          while IFS=$'\t' read -r from label; do
            [ -n "$label" ] && [ -n "${PANEMAP[$session|$from]:-}" ] || continue
            ledger_herdr "$session" pane rename "${PANEMAP[$session|$from]}" "$label" >/dev/null 2>&1 || true
          done < <(printf '%s' "$tabinfo" | jq -r '.panes[]? | select(.label != null) | [.pane_id, .label] | @tsv')
        fi
        if [ -n "${PANEMAP[$session|$pane]:-}" ]; then
          TARGET[$idx]=${PANEMAP[$session|$pane]}
          TTAB[$idx]=${TABMAP[$session|$tab]}
          TWS[$idx]=${WSMAP[$session|$ws]:-$ws}
        fi
        ;;
    esac
  done

  # Launch in batches: type up to --batch resumes, wait for each to run, then
  # reconcile its fleet record, and pause before the next batch.
  for line in "${plan[@]}"; do
    idx=${line#*$'\t'}
    if [ -z "${TARGET[$idx]:-}" ]; then
      summary_lines+=("failed       $(printf '%s' "$entries" | jq -r ".[$idx] | \"\\(.agent) \\(.session_id)\""): no pane could be placed for it")
      failed=$((failed + 1))
      continue
    fi
    pending+=("$idx")
  done
  for ((b = 0; b < ${#pending[@]}; b += batch)); do
    [ "$b" = 0 ] || sleep "$pause"
    batchset=()
    for idx in "${pending[@]:b:batch}"; do
      entry=$(printf '%s' "$entries" | jq -c ".[$idx]")
      sid=$(printf '%s' "$entry" | jq -r '.session_id')
      session=$(printf '%s' "$entry" | jq -r '.herdr.session')
      key=$(printf '%s' "$entry" | jq -r '"\(.agent) \(.session_id)"')
      # Re-check right before typing: a session started meanwhile is left alone.
      if ledger_running_sessions | grep -qxF "claude	$sid"; then
        summary_lines+=("running      $key: started meanwhile; left alone")
        continue
      fi
      cmd=$(ledger_launch_command "$entry")
      if ! ledger_herdr "$session" pane run "${TARGET[$idx]}" "$cmd" >/dev/null 2>&1; then
        summary_lines+=("failed       $key: could not type the resume into pane ${TARGET[$idx]}")
        failed=$((failed + 1))
        continue
      fi
      batchset+=("$idx")
    done
    for idx in ${batchset[@]+"${batchset[@]}"}; do
      ledger_restore_settle "$idx"
    done
  done

  for line in ${summary_lines[@]+"${summary_lines[@]}"}; do
    echo "  $line"
  done
  local summary="restore summary: $resumed resumed, $failed failed, $n_running already running, $n_missing missing transcript, $n_closed fleet record gone, $n_unsupported unsupported, $n_down Herdr not running, $n_deleted in a deleted Herdr session; $rebound fleet records moved, $messaged carry-on messages"
  echo "$summary"
  mkdir -p "$LEDGER" 2>/dev/null && ledger_log restore.log "$summary"
  [ "$failed" = 0 ]
}

# One launched entry of cmd_restore: wait for it to run, then reconcile its
# fleet record and send the carry-on message when it was working. Uses and
# updates cmd_restore's locals through bash dynamic scope.
ledger_restore_settle() {  # <entry-index>
  local idx=$1 send_opts=()
  entry=$(printf '%s' "$entries" | jq -c ".[$idx]")
  sid=$(printf '%s' "$entry" | jq -r '.session_id')
  session=$(printf '%s' "$entry" | jq -r '.herdr.session')
  key=$(printf '%s' "$entry" | jq -r '"\(.agent) \(.session_id)"')
  newp=${TARGET[$idx]}
  if ! ledger_wait_running "$sid" "$wait"; then
    summary_lines+=("failed       $key: launched in pane $newp but not running after ${wait}s")
    failed=$((failed + 1))
    return 0
  fi
  resumed=$((resumed + 1))
  summary_lines+=("resumed      $key in $session pane $newp")
  role=$(printf '%s' "$entry" | jq -r '.fleet.role // empty')
  task=$(printf '%s' "$entry" | jq -r '.fleet.task_id // empty')
  home=$(printf '%s' "$entry" | jq -r '.fleet.home // empty')
  case "$role" in
      worker | secondmate)
        if [ "$(sed -n 's/^herdr_pane_id=//p' "$home/state/$task.meta" | head -n 1)" != "$newp" ] \
          || [ "$(sed -n 's/^herdr_session=//p' "$home/state/$task.meta" | head -n 1)" != "$session" ]; then
          if ledger_rebind_record "$home" "$task" "$session" "${TWS[$idx]}" "${TTAB[$idx]}" "$newp"; then
            rebound=$((rebound + 1))
            summary_lines+=("record       $task in $home now names pane $newp")
          else
            summary_lines+=("record       $task in $home could not be moved to pane $newp; repair it by hand")
          fi
        fi
        "$SCRIPT_DIR/fm-busy-event.sh" apply "$home/state" "$task" idle --current-gen --source fm-recovery --event ledger-restore >/dev/null 2>&1 || true
        if ledger_carry_on_wanted "$entry" "${CLASSES[$home]:-}"; then
          # A second mate would otherwise owe a routed reply to a message
          # that asks for none, so its carry-on is sent fire-and-forget.
          send_opts=()
          [ "$role" != secondmate ] \
            || send_opts=(--fire-and-forget "$(printf 'ledger-restore %s %s' "$sid" "$(date +%s%N)" | sha256sum | cut -c1-16)")
          if FM_HOME=$home "$SCRIPT_DIR/fm-send.sh" "$task" ${send_opts[@]+"${send_opts[@]}"} "$(ledger_carry_on_text)" >/dev/null 2>&1; then
            messaged=$((messaged + 1))
            summary_lines+=("carry-on     $task: sent the interrupted-task message")
          else
            summary_lines+=("carry-on     $task: the carry-on message could not be recorded; send it by hand")
          fi
        fi
        ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Hook installation in the Claude user settings.

ledger_settings_file() {  # [<explicit>]
  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
  else
    printf '%s/settings.json' "$(ledger_claude_config)"
  fi
}

ledger_settings_rewrite() {  # <file> <jq-program> [jq args...]
  local file=$1 program=$2 tmp
  shift 2
  if [ ! -f "$file" ]; then
    mkdir -p "$(dirname "$file")" || return 1
    printf '{}\n' >"$file" || return 1
  fi
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { echo "fm-session-ledger: $file is not a JSON object; not changed" >&2; return 1; }
  tmp=$(mktemp "$(dirname "$file")/.settings.ledger.XXXXXX") || return 1
  if jq "$@" "$program" "$file" >"$tmp" 2>/dev/null && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    chmod --reference="$file" "$tmp" 2>/dev/null
    mv -f -- "$tmp" "$file"
    return
  fi
  rm -f -- "$tmp"
  echo "fm-session-ledger: could not rewrite $file; not changed" >&2
  return 1
}

# shellcheck disable=SC2016 # jq program text, not shell.
LEDGER_JQ_UNHOOK='
def unhook:
  if .hooks then
    .hooks |= (with_entries(.value |= (map(.hooks |= map(select((.command // "") | contains("fm-session-ledger.sh") and contains(" hook ") | not)))
      | map(select((.hooks | length) > 0))))
      | with_entries(select((.value | length) > 0)))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  else . end;
'

cmd_install_hooks() {
  local file=
  [ "${1:-}" != --settings ] || file=${2:-}
  file=$(ledger_settings_file "$file")
  # shellcheck disable=SC2016 # jq program text, not shell.
  ledger_settings_rewrite "$file" "$LEDGER_JQ_UNHOOK"'
    unhook
    | reduce ("SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd") as $ev (.;
        .hooks[$ev] = ((.hooks[$ev] // []) + [{matcher: "", hooks: [{type: "command", command: $cmd, timeout: 10}]}]))' \
    --arg cmd "$(ledger_shell_quote "$SELF") hook claude" || return 1
  echo "installed the session ledger hooks in $file"
}

cmd_uninstall_hooks() {
  local file=
  [ "${1:-}" != --settings ] || file=${2:-}
  file=$(ledger_settings_file "$file")
  [ -f "$file" ] || { echo "no settings file at $file; nothing to remove"; return 0; }
  ledger_settings_rewrite "$file" "$LEDGER_JQ_UNHOOK"'unhook' || return 1
  echo "removed the session ledger hooks from $file"
}

usage() {
  sed -n '/^# Usage:/,/^#   hook /p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

case "${1:-}" in
  hook) shift; cmd_hook "$@"; exit 0 ;;
  record) shift; cmd_record "$@"; exit 0 ;;
  list) shift; cmd_list "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  can-resume) shift; cmd_can_resume "$@" ;;
  restore-command) ledger_restore_command; echo ;;
  install-hooks) shift; cmd_install_hooks "$@" ;;
  uninstall-hooks) shift; cmd_uninstall_hooks "$@" ;;
  -h | --help | help) sed -n '/^# Usage:/,/^# Entry lifecycle/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
