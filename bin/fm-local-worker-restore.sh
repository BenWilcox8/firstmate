#!/usr/bin/env bash
# fm-local-worker-restore.sh - bring back the workers that a restart stopped
# while they were working.
#
# A machine reboot or a Herdr restart stops every agent. Restart recovery
# (bin/fm-local-restart-recovery.sh) relaunches the primary firstmate and the
# authorized second mates. This script is the one owner of the next step: each
# home, at its first locked session start after the restart, classifies its own
# worker records and relaunches only the workers that were working.
#
# Usage:
#   fm-local-worker-restore.sh classify
#   fm-local-worker-restore.sh run [--key <restart-key>] [--restart <label>]
#   fm-local-worker-restore.sh lease-check <task-id>
#
#   classify     Print one line per local ship or scout record in this home:
#                "<id><TAB><class><TAB><reason>". Read-only. The first class
#                that matches wins:
#                  running          its own endpoint has a live agent
#                  unreadable       its endpoint state cannot be classified,
#                                   or a live agent runs at its recorded
#                                   endpoint in a pane whose location cannot
#                                   be read
#                  parked           its record carries a park
#                                   (bin/fm-control.sh park); it stays down,
#                                   and `bin/fm-control.sh <id> resume` reopens
#                                   its native session when its wait clears
#                  gone             its recorded worktree is missing
#                  finished         its validation run (attributed by
#                                   bin/fm-crew-state.sh) passed or failed, or,
#                                   with no run, its newest state line is done
#                                   or failed
#                  captain-waiting  its validation run waits at a gate with an
#                                   open decision or blocker, or, with no run,
#                                   it has an open decision or blocker or its
#                                   newest state line is captain-held
#                  slot-reused      lease-check finds its worktree leased to
#                                   other work
#                  working          anything else: it was working when it
#                                   stopped, including a validation run that
#                                   waits at a gate with no open decision
#                An active validation run (running, fixing, or in CI) is
#                authoritative, as in bin/fm-crew-state.sh: it overrides an
#                older open decision, blocker, or captain-held line, and the
#                worker is working, because it must come back to drive its run.
#                A restart can give a recorded Herdr pane id to another pane,
#                so an endpoint is the worker's own only when its pane sits in
#                the worker's recorded worktree. A pane elsewhere reads as
#                gone, and the worker is classified by its records.
#                A remote record, a second mate, and any other kind are not
#                listed: their own host or home recovers them.
#   run          Classify, then relaunch each working worker, one at a time,
#                through `bin/fm-control.sh <id> relaunch --note`, in its own
#                recorded worktree. The control plane owns the mechanics: on
#                Herdr a gone pane is recreated in the worker's recorded slot
#                (bin/fm-local-pane-lib.sh), and a task that carries a park
#                record is resumed in its native session instead of started
#                fresh. Right before each relaunch the worker is classified
#                again, so a worker the supervisor relaunched by hand, or whose
#                slot was just taken, is left alone. The note tells the new
#                worker that a restart stopped the previous one and where to
#                pick up.
#                It prints one summary line - restored, skipped by class, and
#                failed, with reasons - and queues it as one `check` wake.
#                With --key, a restart is restored once: a second run for the
#                same key does nothing. One run at a time per home.
#   lease-check  Exit 0 when <task-id>'s recorded worktree can take its worker
#                again, and exit 1 with the reason on stderr when it is leased
#                to other work. Only positive evidence counts: another record
#                in this fleet (the root home or one of its local second mate
#                homes) names the same worktree and either was spawned after
#                this task (by spawn_gen) or has a live agent in its own pane
#                there, or the Treehouse pool records a live owner process for
#                the slot that is not this task's own endpoint. An older record for the slot, such
#                as a finished task not yet cleaned up, does not count.
#                The worktree-lease hook in bin/fm-spawn.sh runs it
#                before every relaunch and resume launches anything, so
#                bin/fm-control.sh relaunch and resume re-check the lease too.
#
# The restart-record hook starts `run` detached, keyed to the restart, when
# bin/fm-local-restart-recovery.sh record detects a restart.
#
# Files, in this home's state/:
#   .worker-restore.lock   single-flight lock of one run
#   .worker-restore.log    ledger: epoch, event, restart key, detail (bounded)
#
# Environment:
#   FM_HOME                        the home to restore (default: this code root)
#   FM_WORKER_RESTORE_CONTROL      control plane (bin/fm-control.sh); tests only
#   FM_WORKER_RESTORE_CREW_STATE   current-state reader (bin/fm-crew-state.sh);
#                                  tests only
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-local-pane-lib.sh
. "$SCRIPT_DIR/fm-local-pane-lib.sh"
# shellcheck source=bin/fm-local-treehouse-lib.sh
. "$SCRIPT_DIR/fm-local-treehouse-lib.sh"

WR_CONTROL=${FM_WORKER_RESTORE_CONTROL:-$SCRIPT_DIR/fm-control.sh}
WR_CREW_STATE=${FM_WORKER_RESTORE_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}
WR_LOCK="$STATE/.worker-restore.lock"
WR_LEDGER="$STATE/.worker-restore.log"
WR_NOTE="A restart of the machine or of Herdr stopped your previous session while you were working. Your local copy, branch, and commits are as that session left them. Check git status and git log, re-read your instructions, and continue from where the work stands. If a no-mistakes run was active, reattach to it with no-mistakes axi status; do not start a second run."
WR_CLASS=
WR_REASON=
WR_LEASE_REASON=

wr_canonical() {  # <dir>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

wr_first_line() {
  printf '%s\n' "$1" | awk 'NF { print; exit }'
}

# wr_gen <meta>: the spawn epoch from spawn_gen=s<epoch>.<pid>.<n>, or nothing.
wr_gen() {
  local gen
  gen=$(fm_meta_get "$1" spawn_gen)
  gen=${gen#s}
  gen=${gen%%.*}
  case "$gen" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$gen"
}

# wr_fleet_homes: this home, the root home, and the root's local second mate
# homes, one canonical path per line.
wr_fleet_homes() {
  local root meta home
  {
    wr_canonical "$FM_HOME"
    root=$(fm_firstmate_root_home "$FM_HOME" 2>/dev/null) || root=
    if [ -n "$root" ]; then
      printf '%s\n' "$root"
      for meta in "$root"/state/*.meta; do
        [ -f "$meta" ] || continue
        [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
        [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
        home=$(fm_meta_get "$meta" home)
        [ -n "$home" ] || home=$(fm_meta_get "$meta" worktree)
        [ -n "$home" ] && wr_canonical "$home"
      done
    fi
  } | awk 'NF && !seen[$0]++'
}

# wr_endpoint <meta>: set WR_EP_STATE to the state of the record's own
# endpoint, and WR_EP_TARGET to its target when that pane is proven the
# record's own. A restart can give a recorded Herdr pane id to another pane, so
# a pane that sits outside the record's worktree is not its own and reads
# missing, and a live pane whose location cannot be read reads unlocated.
wr_endpoint() {
  local meta=$1 backend target seen
  WR_EP_TARGET=
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  WR_EP_STATE=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || WR_EP_STATE=unreadable
  case "$WR_EP_STATE" in alive|dead) ;; *) return 0 ;; esac
  seen=$(fm_backend_current_path "$backend" "$target" 2>/dev/null) || seen=
  if [ -z "$seen" ]; then
    [ "$WR_EP_STATE" = dead ] || WR_EP_STATE=unlocated
  elif fm_local_pane_path_within "$seen" "$(fm_meta_get "$meta" worktree)"; then
    WR_EP_TARGET=$target
  else
    WR_EP_STATE=missing
  fi
}

# wr_lease_other <id> <meta>: 0 with WR_LEASE_REASON set when the recorded
# worktree is leased to other work, 1 when nothing shows that it is.
wr_lease_other() {
  local id=$1 meta=$2 wt mine home own other gen pool lease owner started pid
  WR_LEASE_REASON=
  wt=$(wr_canonical "$(fm_meta_get "$meta" worktree)") || return 1
  mine=$(wr_gen "$meta")
  own=$(wr_canonical "$FM_HOME")
  while IFS= read -r home; do
    for other in "$home"/state/*.meta; do
      [ -f "$other" ] || continue
      [ "$home" != "$own" ] || [ "$(basename "$other" .meta)" != "$id" ] || continue
      [ "$(fm_meta_get "$other" kind)" != secondmate ] || continue
      [ -z "$(fm_meta_get "$other" remote_host)" ] || continue
      [ "$(wr_canonical "$(fm_meta_get "$other" worktree)")" = "$wt" ] || continue
      gen=$(wr_gen "$other")
      if [ -n "$mine" ] && [ -n "$gen" ] && [ "$gen" -gt "$mine" ]; then
        WR_LEASE_REASON="its worktree is now recorded for $(basename "$other" .meta) in $home"
        return 0
      fi
      wr_endpoint "$other"
      if [ "$WR_EP_STATE" = alive ]; then
        WR_LEASE_REASON="$(basename "$other" .meta) in $home runs an agent in its worktree"
        return 0
      fi
    done
  done < <(wr_fleet_homes)
  pool="$(dirname "$(dirname "$wt")")/treehouse-state.json"
  [ -f "$pool" ] && [ ! -L "$pool" ] || return 1
  lease=$(jq -cr --arg wt "$wt" '[.worktrees[]? | select(.path == $wt)] | .[0] // {}
    | select((.owner_pid | type) == "number" and (.owner_started_at | type) == "number")
    | "\(.owner_pid) \(.owner_started_at)"' "$pool" 2>/dev/null) || {
    WR_LEASE_REASON="its Treehouse pool record $pool cannot be read"
    return 0
  }
  [ -n "$lease" ] || return 1
  owner=${lease%% *}
  started=${lease#* }
  fm_local_treehouse_owner_live "$owner" "$started" || return 1
  wr_endpoint "$meta"
  if [ -n "$WR_EP_TARGET" ]; then
    for pid in $(fm_backend_foreground_pids "$(fm_backend_of_meta "$meta")" "$WR_EP_TARGET" 2>/dev/null); do
      fm_local_descends_from "$pid" "$owner" && return 1
    done
  fi
  WR_LEASE_REASON="Treehouse leases it to live process $owner, which is not this worker's endpoint"
  return 0
}

# wr_last_state_line <status-file>: the newest line whose verb states the
# worker's state (not a resolution, note, or other annotation).
wr_last_state_line() {
  local line verb found=
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    verb=$(status_line_verb "$line")
    case "$verb" in
      working|done|failed|paused|blocked|needs-decision|captain-held) found=$line ;;
    esac
  done < "$1"
  printf '%s' "$found"
}

# wr_classify <id> <meta>: set WR_CLASS and WR_REASON (contract in the header).
wr_classify() {
  local id=$1 meta=$2 wt crew source run open line verb
  WR_CLASS=
  WR_REASON=
  wr_endpoint "$meta"
  case "$WR_EP_STATE" in
    alive) WR_CLASS=running; WR_REASON="its agent is running"; return 0 ;;
    dead|missing) ;;
    unlocated) WR_CLASS=unreadable; WR_REASON="an agent runs at its recorded endpoint, but where that pane sits cannot be read"; return 0 ;;
    *) WR_CLASS=unreadable; WR_REASON="its endpoint reads $WR_EP_STATE"; return 0 ;;
  esac
  if [ -n "$(fm_meta_get "$meta" parked)" ]; then
    WR_CLASS=parked
    WR_REASON="parked: $(fm_meta_get "$meta" parked_reason)"
    return 0
  fi
  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    WR_CLASS=gone
    WR_REASON="its worktree ${wt:-(none)} is missing"
    return 0
  fi
  open=$(status_open_decisions "$STATE/$id.status")
  crew=$(FM_HOME="$FM_HOME" "$WR_CREW_STATE" "$id" 2>/dev/null | head -n 1)
  source=$(printf '%s' "$crew" | sed -n 's/.*· source: \([a-z-]*\).*/\1/p')
  run=$(printf '%s' "$crew" | sed -n 's/^state: \([a-z]*\).*/\1/p')
  if [ "$source" = run-step ]; then
    case "$run" in
      done) WR_CLASS=finished; WR_REASON="its validation run passed" ;;
      failed) WR_CLASS=finished; WR_REASON="its validation run failed" ;;
      parked) [ -z "$open" ] || { WR_CLASS=captain-waiting; WR_REASON="its validation run waits on an open decision"; } ;;
    esac
    [ -z "$WR_CLASS" ] || return 0
  else
    line=$(wr_last_state_line "$STATE/$id.status")
    verb=$(status_line_verb "$line")
    case "$verb" in
      done|failed) WR_CLASS=finished; WR_REASON="it reported $verb"; return 0 ;;
    esac
    if [ -n "$open" ]; then
      WR_CLASS=captain-waiting
      WR_REASON="open decision: $(printf '%s\n' "$open" | cut -f1 | paste -sd, -)"
      return 0
    fi
    if [ "$verb" = captain-held ]; then
      WR_CLASS=captain-waiting
      WR_REASON="captain-held"
      return 0
    fi
  fi
  if wr_lease_other "$id" "$meta"; then
    WR_CLASS='slot-reused'
    WR_REASON=$WR_LEASE_REASON
    return 0
  fi
  WR_CLASS=working
  WR_REASON="it was working when it stopped"
}

# wr_workers: the ids of this home's local ship and scout records.
wr_workers() {
  local meta kind
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    case "$kind" in ship|scout|'') ;; *) continue ;; esac
    basename "$meta" .meta
  done
}

cmd_classify() {
  local id
  while IFS= read -r id; do
    wr_classify "$id" "$STATE/$id.meta"
    printf '%s\t%s\t%s\n' "$id" "$WR_CLASS" "$WR_REASON"
  done < <(wr_workers)
}

wr_ledger() {  # <event> <key> [detail]
  local tmp
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$(printf '%s' "${3:-}" | tr '\t\n' '  ')" >> "$WR_LEDGER"
  if [ "$(wc -l < "$WR_LEDGER")" -gt 200 ]; then
    tmp=$(mktemp "$STATE/.worker-restore.log.XXXXXX") || return 0
    tail -n 100 "$WR_LEDGER" > "$tmp" && mv -f "$tmp" "$WR_LEDGER"
  fi
}

wr_ledger_done() {  # <key>
  [ -f "$WR_LEDGER" ] && awk -F '\t' -v k="$1" '$2 == "done" && $3 == k { f=1 } END { exit !f }' "$WR_LEDGER"
}

# wr_list <label> <ids...>: "<label> <n>" plus " (<ids>)" when there are any.
wr_list() {
  local label=$1
  shift
  if [ "$#" -eq 0 ]; then
    printf '%s 0' "$label"
  else
    printf '%s %s (%s)' "$label" "$#" "$(printf '%s\n' "$@" | paste -sd, - | sed 's/,/, /g')"
  fi
}

cmd_run() {
  local key='' label='a restart' id out summary class skipped='' c
  local -a working=() restored=() failed=() order=(running unreadable parked gone finished captain-waiting slot-reused)
  local -A by_class=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key) key=${2:-}; shift 2 ;;
      --restart) label=${2:-}; shift 2 ;;
      *) echo "error: unknown argument: $1" >&2; return 1 ;;
    esac
  done
  mkdir -p "$STATE" || return 1
  if ! fm_lock_try_acquire "$WR_LOCK"; then
    echo "worker restore: another run is in progress (pid ${FM_LOCK_HELD_PID:-unknown}); leaving it to that run"
    return 0
  fi
  trap 'fm_lock_release "$WR_LOCK" || true' EXIT
  if [ -n "$key" ] && wr_ledger_done "$key"; then
    echo "worker restore: this restart was already restored"
    return 0
  fi
  wr_ledger start "${key:--}" "$label"
  while IFS= read -r id; do
    wr_classify "$id" "$STATE/$id.meta"
    if [ "$WR_CLASS" = working ]; then
      working+=("$id")
    else
      by_class[$WR_CLASS]+="$id${WR_REASON:+: $WR_REASON}"$'\n'
    fi
  done < <(wr_workers)
  for id in ${working[@]+"${working[@]}"}; do
    # Read again right before acting: a supervisor may have relaunched it by
    # hand, or another task may have taken its slot, since the first read.
    wr_classify "$id" "$STATE/$id.meta"
    if [ "$WR_CLASS" != working ]; then
      by_class[$WR_CLASS]+="$id${WR_REASON:+: $WR_REASON}"$'\n'
      continue
    fi
    if out=$(FM_HOME="$FM_HOME" FM_SPAWN_NO_GUARD=1 "$WR_CONTROL" "$id" relaunch --note "$WR_NOTE" 2>&1 </dev/null); then
      restored+=("$id")
    else
      failed+=("$id: $(wr_first_line "$out")")
    fi
  done
  for class in "${order[@]}"; do
    [ -n "${by_class[$class]:-}" ] || continue
    c=$(printf '%s' "${by_class[$class]}" | grep -c .)
    case "$class" in
      running|finished|parked) skipped="$skipped${skipped:+; }$class $c" ;;
      *) skipped="$skipped${skipped:+; }$class $c ($(printf '%s' "${by_class[$class]}" | paste -sd'|' - | sed 's/|/; /g'))" ;;
    esac
  done
  summary="worker restore after $label: $(wr_list restored ${restored[@]+"${restored[@]}"}); skipped: ${skipped:-none}; $(wr_list failed ${failed[@]+"${failed[@]}"})"
  printf '%s\n' "$summary"
  fm_wake_append check "worker-restore:$(date +%s)" "check: $summary" \
    || echo "worker restore: could not queue the summary wake" >&2
  wr_ledger 'done' "${key:--}" "$summary"
}

cmd_lease_check() {
  local id=${1:-} meta
  case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) echo "error: invalid task id '$id'" >&2; return 1 ;; esac
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "error: no record for task $id in this home" >&2; return 1; }
  if wr_lease_other "$id" "$meta"; then
    printf 'task %s: %s\n' "$id" "$WR_LEASE_REASON" >&2
    return 1
  fi
  return 0
}

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  classify) cmd_classify ;;
  run) shift; cmd_run "$@" ;;
  lease-check) shift; cmd_lease_check "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
