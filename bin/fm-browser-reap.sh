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
# The leak this clears: an agent drives a headless browser, the agent's session
# dies, and the browser survives it. A launcher-started Chrome calls setsid, so
# nothing in the process tree notices the owner leaving. Observed 2026-08-18 as
# about fifty nine-day-old browser processes holding roughly 11 GB of resident
# memory, with load at 80 and the machine swapping.
#
# WHAT IS RECOGNISED. One kind of process, and no other command is ever
# signalled: the PROGRAM the command line runs is a Chrome or Chromium main
# binary, AND the command line carries an automation marker (--headless,
# --remote-debugging-port, --remote-debugging-pipe, or --type=). Both halves are
# required. A browser the captain launched to read with never enters the family,
# because it carries no automation marker; and no process merely MENTIONING a
# browser enters it either, because the program itself must be the browser. That
# second half matters in this repo, where a crewmate's whole brief is its argv.
#
# The chrome-devtools-axi bridge is deliberately out of scope even though it
# leaks the same way. `ensureBridge` reuses a live bridge across agent sessions,
# so the launching agent recorded in that bridge's environment is not its owner:
# the bridge outliving its first session may be serving its third. Reaping a
# bridge safely needs its own session registration as the in-use signal, which
# is a separate change.
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
#      reaper - pid 1, or the per-user manager identified by its
#      user@<uid>.service/init.scope cgroup, which adopts this account's orphans
#      instead of init on a systemd login session - AND the root is not itself
#      inside a systemd user unit. A process the user manager STARTED sits in
#      that unit's own .service cgroup and has a live owner; only an adopted
#      orphan keeps the cgroup of whatever launched it.
#
# A Chrome main process overwrites its own environment block, so signal 1 cannot
# read it and a real browser is decided on signal 2. The agent session id
# embedded in a browser profile path was measured as an unsound substitute:
# every other process the dead session left behind inherits that same id, so a
# live holder of it proves nothing about the session. What signal 2 cannot
# separate is a browser a LIVE agent deliberately detached and then held past the
# age gate; the automation-marker family and that gate are the whole bound on it.
#
# WHAT HAPPENS. An orphaned chain older than --max-age is sent SIGTERM whole,
# polled for up to --grace seconds, and only then sent SIGKILL. Immediately
# before the first signal each member must still present the command line the
# scan saw and is bound to a reuse-proof identity that is rechecked before the
# second, so a pid that dies and is recycled between the scan and the signal is
# never touched.
#
# LOG. Each reap appends one line to state/browser-reap.log (override with
# FM_BROWSER_REAP_LOG), carrying the pid, the age in seconds, and the reason:
#   <iso8601> reap pid=<pid> age=<n>s reason=<reason> chain=<n>
#             members=<pid,pid,...> program=<basename> result=<result>
# A run that cannot start at all appends one `abort` line there for the same
# reason: the watcher runs this detached and discards its output, so a sweep
# that never works again must leave a record of its own.
# --dry-run appends nothing.
#
# One sweep at a time per home, through a lock in that home's own state
# directory. Concurrent homes may sweep at once; that is safe because a chain
# the other home already stopped fails the identity recheck instead of being
# signalled, and costs only a duplicate log line.
#
# Prints one line per candidate and nothing when there is nothing to do. Exits 0
# unless the process scan itself could not run, so a caller can sweep without
# risking its own outcome. Verified against Linux `ps`; `--dry-run` is the safe
# way to confirm the field spellings on a new platform.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

REAP_LOG=${FM_BROWSER_REAP_LOG:-$STATE/browser-reap.log}
REAP_LOCK=${FM_BROWSER_REAP_LOCK:-$STATE/.browser-reap.lock}
REAP_PROC_ROOT=${FM_PROC_ROOT_OVERRIDE:-/proc}
REAP_OWNER_VARS=${FM_BROWSER_REAP_OWNER_VARS:-CLAUDE_PID}
MAX_AGE=${FM_BROWSER_REAP_MAX_AGE:-86400}
GRACE=${FM_BROWSER_REAP_GRACE:-10}
DRY_RUN=0
ONLY_PIDS=

reap_log_append() { # <line>
  local dir
  dir=$(dirname "$REAP_LOG")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$REAP_LOG" 2>/dev/null || true
}

# A sweep that cannot run is durable, not just noisy: the watcher throws this
# script's output away, so stderr alone would hide a permanently broken sweep.
reap_die() {
  printf 'fm-browser-reap: %s\n' "$1" >&2
  [ "$DRY_RUN" -eq 1 ] || reap_log_append "abort reason=$1"
  exit 2
}

reap_usage() {
  cat <<'TXT'
Usage: fm-browser-reap.sh [--dry-run] [--max-age <seconds>] [--grace <seconds>]
                          [--pid <pid>]...

Stop headless browser chains left behind by a dead agent session: a
Chrome/Chromium process carrying an automation flag whose owning session is
provably gone and which is older than the age gate. A chain with a live owner
is never touched at any age.

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
# all read one consistent view of the machine; each member is then re-read from
# the live process immediately before it is signalled.

REAP_PIDS=()
REAP_PPIDS=()
REAP_AGES=()
REAP_CMDS=()
REAP_FAMILY=()

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

# The command line runs a browser under automation. The program test comes
# first and is what keeps a process that merely names a browser in its own
# arguments - a crewmate brief, a log tail, an installer - out of the family.
reap_is_browser() { # <command>
  local command=$1 program
  program=$(reap_program_path "$command")
  case "${program##*/}" in
    chrome|chromium|chromium-browser|chrome-browser|google-chrome|google-chrome-stable|\
    headless_shell|msedge|microsoft-edge|microsoft-edge-stable|brave|brave-browser) ;;
    *) return 1 ;;
  esac
  case "$command" in
    *--headless*|*--remote-debugging-port=*|*--remote-debugging-pipe*|*--type=*) return 0 ;;
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
  local uid scan pid ppid etime command age family
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
    family=''
    reap_is_browser "$command" && family=1
    REAP_PIDS+=("$pid")
    REAP_PPIDS+=("$ppid")
    REAP_AGES+=("$age")
    REAP_CMDS+=("$command")
    REAP_FAMILY+=("$family")
  done <<EOF
$scan
EOF
}

# --- ownership --------------------------------------------------------------

reap_cgroup_of() { # <pid>
  cat "$REAP_PROC_ROOT/$1/cgroup" 2>/dev/null
}

# A process that adopts this account's orphans: init, or the per-user manager,
# recognised by the cgroup it alone occupies rather than by its name.
reap_is_reaper() { # <pid>
  local pid=$1
  [ "$pid" = 1 ] && return 0
  case "$(reap_cgroup_of "$pid")" in
    *"user@"*".service/init.scope"*) return 0 ;;
  esac
  return 1
}

# The process sits inside a systemd user unit, so the user manager is its
# supervisor rather than the reaper that adopted it. A unit's processes live in
# that unit's own .service cgroup; an adopted orphan keeps the .scope cgroup of
# whatever launched it, which is why the leaf suffix is the whole test.
reap_in_managed_unit() { # <pid>
  local cgroup
  cgroup=$(reap_cgroup_of "$1")
  case "$cgroup" in
    *"user@"*".service/"*) ;;
    *) return 1 ;;
  esac
  case "${cgroup##*/}" in
    *.service) return 0 ;;
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

# alive | gone for the session that owns a chain root. Only `gone` authorizes a
# signal, so every unreadable or ambiguous case answers alive.
reap_owner_state() { # <index>
  local pid=${REAP_PIDS[$1]} ppid=${REAP_PPIDS[$1]} age=${REAP_AGES[$1]}
  local owner owner_index owner_age
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
  reap_is_reaper "$ppid" || { printf '%s\n' alive; return 0; }
  reap_in_managed_unit "$pid" && { printf '%s\n' alive; return 0; }
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
# not a member of its own process group, and it still presents the command line
# the scan read. That last test is what closes the window between the snapshot
# and the signal, in which a scanned pid can exit and be reused.
reap_signallable() { # <pid> <scanned-command>
  local pid=$1 want=$2 pgid live
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  [ "$pid" != "$$" ] || return 1
  reap_is_self_or_ancestor "$pid" && return 1
  if [ -n "$REAP_OWN_PGID" ]; then
    pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)
    [ "$pgid" != "$REAP_OWN_PGID" ] || return 1
  fi
  live=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  read -r live <<EOF
$live
EOF
  [ "$live" = "$want" ] || return 1
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

# --- sweep ------------------------------------------------------------------

reap_sweep() {
  local i=0 pid age command owner chain program result count parent_index member
  local member_index members_csv
  local -a members
  reap_scan
  while [ "$i" -lt "${#REAP_PIDS[@]}" ]; do
    pid=${REAP_PIDS[$i]}
    age=${REAP_AGES[$i]}
    command=${REAP_CMDS[$i]}
    i=$((i + 1))
    [ -n "${REAP_FAMILY[$((i - 1))]}" ] || continue
    # Only chain roots are judged; a recognised child rides its root's verdict.
    if parent_index=$(reap_index_of "${REAP_PPIDS[$((i - 1))]}"); then
      [ -n "${REAP_FAMILY[$parent_index]}" ] && continue
    fi
    if [ -n "$ONLY_PIDS" ]; then
      case " $ONLY_PIDS " in *" $pid "*) ;; *) continue ;; esac
    fi
    owner=$(reap_owner_state "$((i - 1))")
    [ "$owner" = gone ] || continue
    [ "$age" -ge "$MAX_AGE" ] || continue
    reap_signallable "$pid" "$command" || continue
    chain=$(reap_descendants "$pid")
    # Every member passes the same self-protection and identity test as the
    # root, so no descendant can carry the sweep into this process, its
    # ancestry, its own process group, or a pid that has since been reused.
    members=("$pid")
    for member in $chain; do
      member_index=$(reap_index_of "$member") || continue
      reap_signallable "$member" "${REAP_CMDS[$member_index]}" || continue
      members+=("$member")
    done
    count=${#members[@]}
    program=$(reap_program_path "$command")
    program=${program##*/}
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would reap orphaned browser chain %s (age %ss, chain of %s, owner session gone, %s)\n' \
        "$pid" "$age" "$count" "$program"
      continue
    fi
    result=$(reap_stop_chain "${members[@]}")
    members_csv=$(printf '%s,' "${members[@]}")
    reap_log_append "reap pid=$pid age=${age}s reason=owner-session-gone chain=$count members=${members_csv%,} program=$program result=$result"
    if [ "$result" = survived ]; then
      printf 'warning: orphaned browser chain %s survived reaping (age %ss, %s)\n' \
        "$pid" "$age" "$program" >&2
    else
      printf 'reaped orphaned browser chain %s (age %ss, chain of %s, %s, %s)\n' \
        "$pid" "$age" "$count" "$program" "$result"
    fi
  done
}

# A dry run signals nothing, so it never contends for the sweep lock.
if [ "$DRY_RUN" -eq 1 ]; then
  reap_sweep
  exit 0
fi

fm_lock_try_acquire "$REAP_LOCK" || exit 0
trap 'fm_lock_release "$REAP_LOCK"' EXIT
reap_sweep
