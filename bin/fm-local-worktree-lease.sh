#!/usr/bin/env bash
# fm-local-worktree-lease.sh - the worktree lease check for worker relaunches.
#
# A relaunch or resume launches a worker into its recorded worktree. That
# worktree may now be leased to other work: after a restart, a Treehouse slot
# can go to a new task, and a recorded pane id can name another task's pane.
# This script is the one owner of the check that refuses such a launch. The
# worktree-lease hook in bin/fm-spawn.sh runs it before every relaunch and
# resume launches anything, so bin/fm-control.sh relaunch and resume re-check
# the lease too.
#
# Usage:
#   fm-local-worktree-lease.sh check <task-id>
#
#   check  Exit 0 when <task-id>'s recorded worktree can take its worker again,
#          and exit 1 with the reason on stderr when it is leased to other
#          work. Only positive evidence counts: another record in this fleet
#          (the root home or one of its local second mate homes) names the
#          same worktree and either was spawned after this task (by spawn_gen)
#          or has a live agent at its recorded endpoint that is not proven to
#          sit outside the worktree, or the Treehouse pool records a live owner
#          process for the slot that is not this task's own endpoint. An older
#          record for the slot, such as a finished task not yet cleaned up,
#          does not count. A recorded pane is a record's own only when it sits
#          in the record's worktree.
#
# Environment:
#   FM_HOME   the home whose record is checked (default: this code root)
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
# shellcheck source=bin/fm-local-pane-lib.sh
. "$SCRIPT_DIR/fm-local-pane-lib.sh"
# shellcheck source=bin/fm-local-treehouse-lib.sh
. "$SCRIPT_DIR/fm-local-treehouse-lib.sh"

WL_LEASE_REASON=

wl_canonical() {  # <dir>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# wl_gen <meta>: the spawn epoch from spawn_gen=s<epoch>.<pid>.<n>, or nothing.
wl_gen() {
  local gen
  gen=$(fm_meta_get "$1" spawn_gen)
  gen=${gen#s}
  gen=${gen%%.*}
  case "$gen" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$gen"
}

# wl_fleet_homes: this home, the root home, and the root's local second mate
# homes, one canonical path per line.
wl_fleet_homes() {
  local root meta home
  {
    wl_canonical "$FM_HOME"
    root=$(fm_firstmate_root_home "$FM_HOME" 2>/dev/null) || root=
    if [ -n "$root" ]; then
      printf '%s\n' "$root"
      for meta in "$root"/state/*.meta; do
        [ -f "$meta" ] || continue
        [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
        [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
        home=$(fm_meta_get "$meta" home)
        [ -n "$home" ] || home=$(fm_meta_get "$meta" worktree)
        [ -n "$home" ] && wl_canonical "$home"
      done
    fi
  } | awk 'NF && !seen[$0]++'
}

# wl_endpoint <meta>: set WL_EP_STATE to the state of the record's own
# endpoint, and WL_EP_TARGET to its target when that pane is proven the
# record's own. A restart can give a recorded Herdr pane id to another pane, so
# a pane that sits outside the record's worktree is not its own and reads
# missing, and a live pane whose location cannot be read reads unlocated.
wl_endpoint() {
  local meta=$1 backend target seen
  WL_EP_TARGET=
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  WL_EP_STATE=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || WL_EP_STATE=unreadable
  case "$WL_EP_STATE" in alive|dead) ;; *) return 0 ;; esac
  seen=$(fm_backend_current_path "$backend" "$target" 2>/dev/null) || seen=
  if [ -z "$seen" ]; then
    [ "$WL_EP_STATE" = dead ] || WL_EP_STATE=unlocated
  elif fm_local_pane_path_within "$seen" "$(fm_meta_get "$meta" worktree)"; then
    WL_EP_TARGET=$target
  else
    WL_EP_STATE=missing
  fi
}

# wl_lease_other <id> <meta>: 0 with WL_LEASE_REASON set when the recorded
# worktree is leased to other work, 1 when nothing shows that it is.
wl_lease_other() {
  local id=$1 meta=$2 wt mine home own other gen pool lease owner started pid
  WL_LEASE_REASON=
  wt=$(wl_canonical "$(fm_meta_get "$meta" worktree)") || return 1
  mine=$(wl_gen "$meta")
  own=$(wl_canonical "$FM_HOME")
  while IFS= read -r home; do
    for other in "$home"/state/*.meta; do
      [ -f "$other" ] || continue
      [ "$home" != "$own" ] || [ "$(basename "$other" .meta)" != "$id" ] || continue
      [ "$(fm_meta_get "$other" kind)" != secondmate ] || continue
      [ -z "$(fm_meta_get "$other" remote_host)" ] || continue
      [ "$(wl_canonical "$(fm_meta_get "$other" worktree)")" = "$wt" ] || continue
      gen=$(wl_gen "$other")
      if [ -n "$mine" ] && [ -n "$gen" ] && [ "$gen" -gt "$mine" ]; then
        WL_LEASE_REASON="its worktree is now recorded for $(basename "$other" .meta) in $home"
        return 0
      fi
      wl_endpoint "$other"
      case "$WL_EP_STATE" in
        alive)
          WL_LEASE_REASON="$(basename "$other" .meta) in $home runs an agent in its worktree"
          return 0
          ;;
        unlocated)
          WL_LEASE_REASON="$(basename "$other" .meta) in $home runs an agent whose pane location cannot be read"
          return 0
          ;;
      esac
    done
  done < <(wl_fleet_homes)
  pool="$(dirname "$(dirname "$wt")")/treehouse-state.json"
  [ -f "$pool" ] && [ ! -L "$pool" ] || return 1
  lease=$(jq -cr --arg wt "$wt" '[.worktrees[]? | select(.path == $wt)] | .[0] // {}
    | select((.owner_pid | type) == "number" and (.owner_started_at | type) == "number")
    | "\(.owner_pid) \(.owner_started_at)"' "$pool" 2>/dev/null) || {
    WL_LEASE_REASON="its Treehouse pool record $pool cannot be read"
    return 0
  }
  [ -n "$lease" ] || return 1
  owner=${lease%% *}
  started=${lease#* }
  fm_local_treehouse_owner_live "$owner" "$started" || return 1
  wl_endpoint "$meta"
  if [ -n "$WL_EP_TARGET" ]; then
    for pid in $(fm_backend_foreground_pids "$(fm_backend_of_meta "$meta")" "$WL_EP_TARGET" 2>/dev/null); do
      fm_local_descends_from "$pid" "$owner" && return 1
    done
  fi
  WL_LEASE_REASON="Treehouse leases it to live process $owner, which is not this worker's endpoint"
  return 0
}

cmd_check() {
  local id=${1:-} meta
  case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) echo "error: invalid task id '$id'" >&2; return 1 ;; esac
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "error: no record for task $id in this home" >&2; return 1; }
  if wl_lease_other "$id" "$meta"; then
    printf 'task %s: %s\n' "$id" "$WL_LEASE_REASON" >&2
    return 1
  fi
  return 0
}

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
