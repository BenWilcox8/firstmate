#!/usr/bin/env bash
# Reap headless browser chains whose owning agent session is gone.
#
# Usage: fm-browser-reap.sh [--dry-run] [--max-age <seconds>] [--grace <seconds>]
#                           [--pid <pid>]...
#   --dry-run          list the candidates and signal nothing
#   --max-age <secs>   age gate for an orphaned chain (default 86400, one day;
#                      also FM_BROWSER_REAP_MAX_AGE)
#   --grace <secs>     seconds to wait after TERM before KILL (default 10; also
#                      FM_BROWSER_REAP_GRACE)
#   --pid <pid>        judge only this chain root, repeatable. Every rule below
#                      still applies, so a named pid that is not a chain root,
#                      has a live owner, or is too young is still left alone.
#
# The leak this clears: an agent drives a headless browser through
# chrome-devtools-axi, the agent's session dies, and the browser survives it.
# Both halves of that stack detach themselves at birth - the bridge is spawned
# with `detached: true` and a launcher-started Chrome calls setsid - so nothing
# in the process tree ever notices the owner leaving. Observed 2026-08-18 as
# about fifty nine-day-old browser processes holding roughly 11 GB of resident
# memory, with load at 80 and the machine swapping.
#
# WHAT IS RECOGNISED. Only two kinds of process, and no other command is ever
# signalled:
#   browser  the program is a Chrome/Chromium main binary AND the command line
#            carries an automation marker (--headless, --remote-debugging-port,
#            --remote-debugging-pipe, or --type=). A browser the captain
#            launched to read with therefore never enters the family.
#   bridge   the command line names chrome-devtools-axi-bridge or
#            chrome-devtools-mcp - the control chain that holds a browser open.
# Chrome's crashpad handler is deliberately excluded: it detaches itself, and
# carries nothing that binds it to the browser it serves, so a chain root test
# on it would be a guess. It is reaped only as a descendant of a reaped chain.
#
# WHO OWNS A CHAIN. A chain root is a recognised process whose parent is not
# itself recognised; the chain is that root plus every descendant. Ownership is
# structural and is the FIRST gate - a chain with a live owner is never touched
# at any age. Signals are tried strongest first:
#   1. recorded owner pid. The launching agent's pid, read from the root's own
#      environment (CLAUDE_PID by default; FM_BROWSER_REAP_OWNER_VARS overrides
#      the list). The owner counts as alive only when that pid exists AND is at
#      least as old as the chain root, so a recycled pid reads as gone.
#   2. parent lineage. The owner is gone when the root has been reparented to a
#      reaper: pid 1, or the per-user manager identified by its
#      user@<uid>.service/init.scope cgroup, which adopts this account's orphans
#      instead of init on a systemd login session.
# A bridge is detached from birth, so its parent is a reaper while its owner is
# perfectly alive; signal 2 is therefore never applied to a bridge. A bridge
# whose recorded owner cannot be read at all is left alone.
#
# A Chrome main process overwrites its own environment block, so signal 1 cannot
# read it and a browser is decided on signal 2. The agent session id embedded in
# a browser profile path was measured as an unsound substitute: every other
# process the dead session left behind inherits that same id, so a live holder
# of it proves nothing about the session. What signal 2 cannot separate is a
# browser a LIVE agent deliberately detached and then held past the age gate;
# the automation-flag family and that gate are the whole bound on it.
#
# WHAT HAPPENS. An orphaned chain older than --max-age is sent SIGTERM whole,
# polled for up to --grace seconds, and only then sent SIGKILL. Every pid is
# bound to a reuse-proof identity before the first signal and rechecked before
# the second, so a pid that dies and is recycled mid-sweep is never killed.
#
# LOG. Each reap appends one line to state/browser-reap.log (override with
# FM_BROWSER_REAP_LOG), carrying the pid, the age in seconds, and the reason:
#   <iso8601> reap pid=<pid> age=<n>s reason=<reason> kind=<kind> chain=<n>
#             program=<basename> result=terminated|killed|survived
# --dry-run writes nothing there.
#
# The sweep is machine-wide by nature, so concurrent Firstmate homes serialize
# on one per-account lock and a home that cannot take it exits quietly. Prints
# one line per candidate and nothing when there is nothing to do. Exits 0 unless
# the process scan itself could not run, so a caller can sweep without risking
# its own outcome.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

REAP_LOG=${FM_BROWSER_REAP_LOG:-$STATE/browser-reap.log}
REAP_LOCK=${FM_BROWSER_REAP_LOCK:-${TMPDIR:-/tmp}/.fm-browser-reap.$(id -u 2>/dev/null || echo 0).lock}
REAP_PROC_ROOT=${FM_PROC_ROOT_OVERRIDE:-/proc}
REAP_OWNER_VARS=${FM_BROWSER_REAP_OWNER_VARS:-CLAUDE_PID}
MAX_AGE=${FM_BROWSER_REAP_MAX_AGE:-86400}
GRACE=${FM_BROWSER_REAP_GRACE:-10}
DRY_RUN=0
ONLY_PIDS=

reap_die() { printf 'fm-browser-reap: %s\n' "$1" >&2; exit 2; }

reap_usage() {
  cat <<'TXT'
Usage: fm-browser-reap.sh [--dry-run] [--max-age <seconds>] [--grace <seconds>]
                          [--pid <pid>]...

Stop headless browser chains left behind by a dead agent session: a
Chrome/Chromium process carrying an automation flag, or a chrome-devtools-axi
bridge, whose owning session is provably gone and which is older than the age
gate. A chain with a live owner is never touched at any age.

  --dry-run          list the candidates and signal nothing
  --max-age <secs>   age gate for an orphaned chain (default 86400)
  --grace <secs>     seconds between SIGTERM and SIGKILL (default 10)
  --pid <pid>        judge only this chain root, repeatable

Each reap is appended to state/browser-reap.log. Read this script's header for
the ownership rule and the recognised process family.
TXT
}

reap_require_seconds() { # <flag> <value>
  case "$2" in
    ''|*[!0-9]*) reap_die "$1 requires a whole number of seconds" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --max-age) [ "$#" -ge 2 ] || reap_die "--max-age requires a value"
      reap_require_seconds --max-age "$2"; MAX_AGE=$2; shift 2 ;;
    --grace) [ "$#" -ge 2 ] || reap_die "--grace requires a value"
      reap_require_seconds --grace "$2"; GRACE=$2; shift 2 ;;
    --pid) [ "$#" -ge 2 ] || reap_die "--pid requires a value"
      case "$2" in ''|*[!0-9]*) reap_die "--pid requires a pid" ;; esac
      ONLY_PIDS="$ONLY_PIDS $2"; shift 2 ;;
    -h|--help) reap_usage; exit 0 ;;
    *) reap_die "unexpected argument: $1" ;;
  esac
done
reap_require_seconds FM_BROWSER_REAP_MAX_AGE "$MAX_AGE"
reap_require_seconds FM_BROWSER_REAP_GRACE "$GRACE"

# --- process table ----------------------------------------------------------
#
# One `ps` snapshot, held as index-aligned arrays. Every later question about a
# pid is answered from this snapshot, so the family, the chain, and the age gate
# all read one consistent view of the machine; identity is rechecked against the
# live process immediately before each signal.

REAP_PIDS=()
REAP_PPIDS=()
REAP_AGES=()
REAP_CMDS=()
REAP_KINDS=()

# Elapsed seconds from the portable `ps -o etime=` shapes: SS, MM:SS, HH:MM:SS,
# and DD-HH:MM:SS. `etimes` would be one field read but is procps-only.
reap_etime_seconds() { # <etime>
  local etime=$1 days=0 rest hh=0 mm=0 ss=0
  case "$etime" in
    *-*) days=${etime%%-*}; rest=${etime#*-} ;;
    *) rest=$etime ;;
  esac
  case "$rest" in
    *:*:*) hh=${rest%%:*}; rest=${rest#*:}; mm=${rest%%:*}; ss=${rest##*:} ;;
    *:*) mm=${rest%%:*}; ss=${rest##*:} ;;
    *) ss=$rest ;;
  esac
  case "$days$hh$mm$ss" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( ((10#$days * 24 + 10#$hh) * 60 + 10#$mm) * 60 + 10#$ss ))"
}

# The program a command line runs, with a leading interpreter dropped only when
# that token really is an executable file and the next token is an absolute
# path. A wrapper script therefore reports the script it runs, while a binary
# whose own path is the first token reports itself.
reap_program_path() { # <command>
  local command=$1 leading rest
  leading=${command%% *}
  rest=${command#"$leading" }
  if [ "$rest" != "$command" ] && [ -f "$leading" ] && [ -x "$leading" ]; then
    case "$rest" in /*) command=$rest ;; esac
  fi
  printf '%s\n' "${command%% *}"
}

# browser | bridge for a recognised command line, empty for everything else.
reap_kind_of() { # <command>
  local command=$1 program
  case "$command" in
    *chrome-devtools-axi-bridge*|*chrome-devtools-mcp*) printf '%s\n' bridge; return 0 ;;
  esac
  program=$(reap_program_path "$command")
  case "${program##*/}" in
    chrome|chromium|chromium-browser|chrome-browser|google-chrome|google-chrome-stable|\
    headless_shell|msedge|microsoft-edge|microsoft-edge-stable|brave|brave-browser) ;;
    *) return 1 ;;
  esac
  case "$command" in
    *--headless*|*--remote-debugging-port=*|*--remote-debugging-pipe*|*--type=*)
      printf '%s\n' browser; return 0 ;;
  esac
  return 1
}

reap_index_of() { # <pid>
  local pid=$1 i=0
  while [ "$i" -lt "${#REAP_PIDS[@]}" ]; do
    [ "${REAP_PIDS[$i]}" = "$pid" ] && { printf '%s\n' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

reap_scan() {
  local uid scan pid ppid etime command age kind
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) reap_die "cannot resolve the current uid" ;; esac
  # Only this account's processes, and the same field spelling the sibling
  # orphan sweep already runs on both supported platforms. ps pads the numeric
  # columns to the widest value on the host, so the fields are read by word
  # splitting rather than at fixed offsets.
  scan=$(ps -u "$uid" -o pid=,ppid=,etime=,command= 2>/dev/null) ||
    reap_die "cannot scan this account's processes for browser chains"
  while read -r pid ppid etime command; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$ppid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$command" ] || continue
    age=$(reap_etime_seconds "$etime") || continue
    kind=$(reap_kind_of "$command" || true)
    REAP_PIDS+=("$pid")
    REAP_PPIDS+=("$ppid")
    REAP_AGES+=("$age")
    REAP_CMDS+=("$command")
    REAP_KINDS+=("$kind")
  done <<EOF
$scan
EOF
}

# --- ownership --------------------------------------------------------------

# A process that adopts this account's orphans: init, or the per-user manager,
# recognised by the cgroup it alone occupies rather than by its name.
reap_is_reaper() { # <pid>
  local pid=$1 cgroup
  [ "$pid" = 1 ] && return 0
  cgroup=$(cat "$REAP_PROC_ROOT/$pid/cgroup" 2>/dev/null) || return 1
  case "$cgroup" in
    *"user@"*".service/init.scope"*) return 0 ;;
  esac
  return 1
}

# One environment value from a live process, empty when it is not readable.
# An environ whose mode looks readable can still be refused by the kernel's
# ptrace access rules, and that refusal is reported by the redirecting shell
# rather than by tr, so the whole substitution is quieted, not just the command
# inside it.
reap_environ_value() { # <pid> <name>
  local pid=$1 name=$2 line
  [ -r "$REAP_PROC_ROOT/$pid/environ" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "$name="*) printf '%s\n' "${line#"$name="}"; return 0 ;;
    esac
  done < <({ tr '\0' '\n' < "$REAP_PROC_ROOT/$pid/environ"; } 2>/dev/null)
  return 1
}

# The pid the launching agent recorded in the chain root's own environment.
reap_recorded_owner() { # <pid>
  local pid=$1 name value
  for name in $REAP_OWNER_VARS; do
    value=$(reap_environ_value "$pid" "$name" 2>/dev/null) || continue
    case "$value" in ''|*[!0-9]*) continue ;; esac
    [ "$value" -gt 1 ] || continue
    printf '%s\n' "$value"
    return 0
  done
  return 1
}

# alive | gone | unknown for the session that owns a chain root. `unknown` is
# treated exactly like `alive`: it never authorizes a signal.
reap_owner_state() { # <index>
  local pid=${REAP_PIDS[$1]} kind=${REAP_KINDS[$1]} ppid=${REAP_PPIDS[$1]}
  local age=${REAP_AGES[$1]} owner owner_index owner_age
  if owner=$(reap_recorded_owner "$pid"); then
    if owner_index=$(reap_index_of "$owner"); then
      owner_age=${REAP_AGES[$owner_index]}
      # A pid younger than the chain it supposedly launched is a recycled pid,
      # not the owner.
      if [ "$owner_age" -ge "$age" ]; then
        printf '%s\n' alive
        return 0
      fi
    fi
    printf '%s\n' gone
    return 0
  fi
  # A bridge is spawned detached, so its parent says nothing about its owner.
  [ "$kind" = bridge ] && { printf '%s\n' unknown; return 0; }
  reap_is_reaper "$ppid" || { printf '%s\n' alive; return 0; }
  printf '%s\n' gone
}

# --- chains -----------------------------------------------------------------

# Every pid descended from <root> in this snapshot, deepest last, root excluded.
reap_descendants() { # <root>
  local frontier=$1 next found='' depth=0 i pid ppid
  while [ -n "$frontier" ] && [ "$depth" -lt 32 ]; do
    next=''
    i=0
    while [ "$i" -lt "${#REAP_PIDS[@]}" ]; do
      pid=${REAP_PIDS[$i]}
      ppid=${REAP_PPIDS[$i]}
      i=$((i + 1))
      case " $frontier " in *" $ppid "*) ;; *) continue ;; esac
      case " $found $frontier " in *" $pid "*) continue ;; esac
      next="$next $pid"
    done
    found="$found$next"
    frontier=${next# }
    depth=$((depth + 1))
  done
  printf '%s\n' "${found# }"
}

# --- signalling -------------------------------------------------------------

reap_is_self_or_ancestor() { # <pid>
  local pid=$1 walk=$$ i=0
  while [ "$walk" -gt 1 ] && [ "$i" -lt 64 ]; do
    [ "$walk" != "$pid" ] || return 0
    walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 0
    case "$walk" in ''|*[!0-9]*) return 1 ;; esac
    i=$((i + 1))
  done
  return 1
}

REAP_OWN_PGID=$(ps -p "$$" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)

# This sweep may signal <pid>: it is not this process, not an ancestor of it,
# and not a member of its own process group.
reap_signallable() { # <pid>
  local pid=$1 pgid
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  [ "$pid" != "$$" ] || return 1
  reap_is_self_or_ancestor "$pid" && return 1
  if [ -n "$REAP_OWN_PGID" ]; then
    pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)
    [ "$pgid" != "$REAP_OWN_PGID" ] || return 1
  fi
  return 0
}

# Stop a whole chain: SIGTERM every member, poll for <grace> seconds, then
# SIGKILL whatever is still alive AND still the same process. Echoes
# terminated, killed, or survived.
reap_stop_chain() { # <pid>...
  local pids=("$@") identities=() alive_pids pid ident i deadline killed=0 result
  for pid in "${pids[@]}"; do
    identities+=("$(fm_pid_identity "$pid" 2>/dev/null || true)")
  done
  i=0
  for pid in "${pids[@]}"; do
    [ -n "${identities[$i]}" ] && kill -TERM "$pid" 2>/dev/null
    i=$((i + 1))
  done
  deadline=$(( $(date +%s) + GRACE ))
  while :; do
    alive_pids=''
    i=0
    for pid in "${pids[@]}"; do
      ident=${identities[$i]}
      i=$((i + 1))
      [ -n "$ident" ] || continue
      fm_pid_alive "$pid" || continue
      [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$ident" ] || continue
      alive_pids="$alive_pids $pid"
    done
    [ -n "$alive_pids" ] || break
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 0.2
  done
  if [ -n "$alive_pids" ]; then
    killed=1
    i=0
    for pid in "${pids[@]}"; do
      ident=${identities[$i]}
      i=$((i + 1))
      case " $alive_pids " in *" $pid "*) ;; *) continue ;; esac
      [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$ident" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 0.2
  fi
  result=terminated
  [ "$killed" -eq 1 ] && result=killed
  i=0
  for pid in "${pids[@]}"; do
    ident=${identities[$i]}
    i=$((i + 1))
    [ -n "$ident" ] || continue
    fm_pid_alive "$pid" || continue
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$ident" ] || continue
    result=survived
  done
  printf '%s\n' "$result"
}

reap_log_line() { # <pid> <age> <reason> <kind> <chain-size> <program> <result>
  local dir
  dir=$(dirname "$REAP_LOG")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s reap pid=%s age=%ss reason=%s kind=%s chain=%s program=%s result=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >>"$REAP_LOG" 2>/dev/null || true
}

# --- sweep ------------------------------------------------------------------

reap_sweep() {
  local i=0 pid kind ppid age command owner chain program result count parent_index member
  local -a members
  reap_scan
  while [ "$i" -lt "${#REAP_PIDS[@]}" ]; do
    pid=${REAP_PIDS[$i]}
    kind=${REAP_KINDS[$i]}
    ppid=${REAP_PPIDS[$i]}
    age=${REAP_AGES[$i]}
    command=${REAP_CMDS[$i]}
    i=$((i + 1))
    [ -n "$kind" ] || continue
    # Only chain roots are judged; a recognised child rides its root's verdict.
    if parent_index=$(reap_index_of "$ppid"); then
      [ -n "${REAP_KINDS[$parent_index]}" ] && continue
    fi
    if [ -n "$ONLY_PIDS" ]; then
      case " $ONLY_PIDS " in *" $pid "*) ;; *) continue ;; esac
    fi
    owner=$(reap_owner_state "$((i - 1))")
    [ "$owner" = gone ] || continue
    [ "$age" -ge "$MAX_AGE" ] || continue
    reap_signallable "$pid" || continue
    chain=$(reap_descendants "$pid")
    # Every member passes the same self-protection test as the root, so no
    # descendant can carry the sweep into this process, its ancestry, or its
    # own process group.
    members=("$pid")
    for member in $chain; do
      reap_signallable "$member" || continue
      members+=("$member")
    done
    program=$(reap_program_path "$command")
    program=${program##*/}
    count=${#members[@]}
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would reap orphaned %s chain %s (age %ss, chain of %s, owner session gone, %s)\n' \
        "$kind" "$pid" "$age" "$count" "$program"
      continue
    fi
    result=$(reap_stop_chain "${members[@]}")
    reap_log_line "$pid" "$age" owner-session-gone "$kind" "$count" "$program" "$result"
    if [ "$result" = survived ]; then
      printf 'warning: orphaned %s chain %s survived reaping (age %ss, %s)\n' \
        "$kind" "$pid" "$age" "$program" >&2
    else
      printf 'reaped orphaned %s chain %s (age %ss, chain of %s, %s, %s)\n' \
        "$kind" "$pid" "$age" "$count" "$program" "$result"
    fi
  done
}

# A dry run reads only, so it never contends for the machine-wide lock.
if [ "$DRY_RUN" -eq 1 ]; then
  reap_sweep
  exit 0
fi

fm_lock_try_acquire "$REAP_LOCK" || exit 0
trap 'fm_lock_release "$REAP_LOCK"' EXIT
reap_sweep
