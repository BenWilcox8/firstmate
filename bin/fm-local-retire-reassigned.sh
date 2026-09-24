#!/usr/bin/env bash
# Retire one finished record after Treehouse leased its slot to another live task.
# Usage: FM_HOME=<home> fm-local-retire-reassigned.sh <id> --live-task <id>
#        [--live-home <home>]
#
# This explicit repair never returns a slot, changes a worktree, deletes a Git
# ref, stops an endpoint, or reaps a process. Normal teardown stays unchanged.
# The old endpoint must be dead or missing, its last outcome must be done, and
# it must have no open decision. The pool slot, live record, and live endpoint
# must agree: Treehouse records the slot owner as owner_pid and owner_started_at
# (epoch milliseconds). That process must still run with that start time, and
# every foreground process of the live endpoint must descend from it. The proof
# reads /proc, so a host without it refuses.
# All reads and retirement hold the project and both task locks.
# A scout needs its report and the existing captain-call completion gate.
# A ship also needs a clean shared worktree and its retained fm/<id> branch
# reachable from a remote, or from local main/master in local-only mode.
# Missing proof refuses: a done line or a merged PR alone cannot prove that
# subsequent edits landed. Uncommitted ship work always refuses.
#
# The command archives the old metadata and status under
# data/<id>/retired-reassigned before removing either active record. It closes
# the backlog through the existing recovery marker. Before retirement it closes
# only the old Atlas ticket through bin/fm-atlas-hook.sh land, the teardown
# discharge: complete the ticket, release its node, and land the node when no
# other open ticket remains on it. The hook state must then read completed.
# A refused completion takes the hook's keyed blocker line in the old status log
# and retains the active record. A refused node landing is written to a fresh
# status log after retirement, as teardown does. No approval is inferred from a
# done line.
# Task check files and other volatile records move into the same archive.
# Global hook registrations and tasktmp remain untouched for manual inspection.
# Legacy records without spawn_gen refuse when automatic backlog closure applies.
# FM_HOME must be explicit. FM_*_OVERRIDE paths follow the normal teardown seam.
set -eu
export LC_ALL=C GIT_OPTIONAL_LOCKS=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
esac
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }
[ -n "${FM_HOME:-}" ] || refuse 'set FM_HOME to the record-owning home'
FM_HOME=$(cd "$FM_HOME" && pwd -P)
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
ID=${1:-}; [ "$#" -eq 0 ] || shift
LIVE_ID=''
LIVE_HOME=$FM_HOME
while [ "$#" -gt 0 ]; do
  case "$1" in
    --live-task) [ "$#" -ge 2 ] || refuse 'missing live task'; LIVE_ID=$2; shift 2 ;;
    --live-home) [ "$#" -ge 2 ] || refuse 'missing live home'; LIVE_HOME=$2; shift 2 ;;
    *) refuse "unknown argument: $1" ;;
  esac
done
fm_task_id_path_safe "$ID" || refuse 'invalid task identity'
fm_task_id_path_safe "$LIVE_ID" || refuse 'invalid live task identity'
[ "$ID" != "$LIVE_ID" ] || refuse 'the two task identities must differ'
LIVE_HOME=$(cd "$LIVE_HOME" && pwd -P) || refuse 'cannot read the live home'
[ "$(fm_firstmate_root_home "$LIVE_HOME")" = "$(fm_firstmate_root_home "$FM_HOME")" ] \
  || refuse 'the homes do not share the project lock authority'
LIVE_STATE=$LIVE_HOME/state
[ "$LIVE_HOME" != "$FM_HOME" ] || LIVE_STATE=$STATE
META=$STATE/$ID.meta
LIVE_META=$LIVE_STATE/$LIVE_ID.meta
fm_refuse_if_gate_agent
fm_lease_guard "$ID" 'retire reassigned record'
LOCKS=()
cleanup() {
  local i
  for ((i=${#LOCKS[@]}-1; i>=0; i--)); do fm_lock_release "${LOCKS[$i]}" || true; done
  fm_lease_guard_release || true
}
trap cleanup EXIT
lock() {
  fm_lock_try_acquire "$1" || refuse "another lifecycle action holds $1"
  LOCKS+=("$1")
}
record() {
  fm_backlog_record_present "$1" 'task record' "$2" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
  awk -F= 'NF && ++seen[$1]>1 {exit 1}' "$1" || refuse "duplicate metadata fields in $1"
}
canonical() { (cd "$1" && pwd -P); }
proc_field() {  # <pid> <index after the command name>
  local stat fields
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a fields <<< "${stat##*)}"
  [ -n "${fields[$2]:-}" ] || return 1
  printf '%s\n' "${fields[$2]}"
}
lease_owner_live() {
  local ticks btime hz
  ticks=$(proc_field "$OWNER_PID" 19) || return 1
  btime=$(awk '$1 == "btime" {print $2}' /proc/stat 2>/dev/null) || return 1
  hz=$(getconf CLK_TCK 2>/dev/null) || return 1
  [ -n "$btime" ] && [ -n "$hz" ] || return 1
  [ "$((btime * 1000 + ticks * 1000 / hz))" = "$OWNER_STARTED" ]
}
descends_from_owner() {  # <pid>
  local pid=$1 depth
  for ((depth=0; depth<64; depth++)); do
    [ "$pid" != "$OWNER_PID" ] || return 0
    [ "$pid" -gt 1 ] 2>/dev/null || return 1
    pid=$(proc_field "$pid" 1) || return 1
  done
  return 1
}
record "$META" "$STATE"
PROJ=$(canonical "$(fm_meta_get "$META" project)") || refuse 'cannot resolve the project'
lock "$(fm_treehouse_project_lock_path "$PROJ")"
lock "$STATE/.control-$ID.lock"
lock "$LIVE_STATE/.control-$LIVE_ID.lock"
lock "$(fm_meta_lock_path "$META")"
lock "$(fm_meta_lock_path "$LIVE_META")"
record "$META" "$STATE"
record "$LIVE_META" "$LIVE_STATE"
if [ -e "$STATE/$ID.busy-gen" ] || [ -L "$STATE/$ID.busy-gen" ]; then
  fm_backlog_record_present "$STATE/$ID.busy-gen" 'busy generation' "$STATE" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
  BUSY_GEN=$(fm_busy_current_gen "$STATE" "$ID") || refuse 'cannot read the old busy generation'
  [ "$BUSY_GEN" = "$(fm_meta_get "$META" busy_gen)" ] || refuse 'old busy generation no longer matches its record'
fi
[ "$(canonical "$(fm_meta_get "$META" project)")" = "$PROJ" ] || refuse 'project identity changed'
[ "$(canonical "$(fm_meta_get "$LIVE_META" project)")" = "$PROJ" ] || refuse 'live record names another project'
WT=$(canonical "$(fm_meta_get "$META" worktree)") || refuse 'cannot resolve the shared worktree'
[ "$(canonical "$(fm_meta_get "$LIVE_META" worktree)")" = "$WT" ] || refuse 'records do not share a worktree'
[ "$WT" != "$PROJ" ] || refuse 'the recorded worktree is the primary checkout'
COMMON=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)
[ "$(canonical "$COMMON")" = "$(canonical "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")" ] \
  || refuse 'worktree and project have different Git identities'
POOL=$(dirname "$(dirname "$WT")")/treehouse-state.json
[ -f "$POOL" ] && [ ! -L "$POOL" ] || refuse 'no regular Treehouse pool record'
LEASE=$(jq -cer --arg wt "$WT" \
  '[.worktrees[] | select(.path==$wt)] | select(length==1) | .[0]
   | select((.owner_pid|type)=="number" and (.owner_started_at|type)=="number")' "$POOL") \
  || refuse 'pool slot has no recorded owner process'
OWNER_PID=$(printf '%s' "$LEASE" | jq -r '.owner_pid')
OWNER_STARTED=$(printf '%s' "$LEASE" | jq -r '.owner_started_at')
lease_owner_live || refuse 'pool slot owner is not the live process Treehouse recorded'
fm_backend_validate_task_endpoint "$META" "$ID" || refuse 'invalid old endpoint'
OLD_BACKEND=$FM_BACKEND_VALIDATED_BACKEND OLD_TARGET=$FM_BACKEND_VALIDATED_TARGET
case "$(fm_backend_agent_state "$OLD_BACKEND" "$OLD_TARGET")" in
  dead|missing) ;;
  *) refuse 'old endpoint is not confidently dead or missing' ;;
esac
fm_backend_validate_task_endpoint "$LIVE_META" "$LIVE_ID" || refuse 'invalid live endpoint'
LIVE_BACKEND=$FM_BACKEND_VALIDATED_BACKEND LIVE_TARGET=$FM_BACKEND_VALIDATED_TARGET
[ "$OLD_BACKEND:$OLD_TARGET" != "$LIVE_BACKEND:$LIVE_TARGET" ] || refuse 'records share an endpoint'
[ "$(fm_backend_agent_state "$LIVE_BACKEND" "$LIVE_TARGET")" = alive ] || refuse 'lease owner is not confidently live'
LIVE_PIDS=$(fm_backend_foreground_pids "$LIVE_BACKEND" "$LIVE_TARGET") || LIVE_PIDS=
[ -n "$LIVE_PIDS" ] || refuse 'cannot read the live endpoint processes'
for pid in $LIVE_PIDS; do
  descends_from_owner "$pid" || refuse 'pool slot owner does not belong to the named live task'
done
fm_backlog_record_present "$STATE/$ID.status" 'task status' "$STATE" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
case "$(last_status_line "$STATE/$ID.status")" in done:*|done\ \[*\]:*) ;; *) refuse 'old record is not finished' ;; esac
[ -z "$(status_open_decisions "$STATE/$ID.status")" ] || refuse 'old record has open decisions'
KIND=$(fm_meta_get "$META" kind)
BACKLOG_ARGS=()
case "$KIND" in
  scout)
    REPORT=$DATA/$ID/report.md
    fm_backlog_record_present "$REPORT" 'scout report' "$DATA" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
    "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" >/dev/null || refuse 'scout completion gate failed'
    EVIDENCE=$REPORT
    DATA_RELATIVE=$(fm_backlog_data_relative "$DATA") || refuse 'report path is not replayable'
    BACKLOG_ARGS=(--report "$DATA_RELATIVE/$ID/report.md")
    ;;
  ship|'')
    DIRTY=$(git -C "$WT" status --porcelain --untracked-files=all) || refuse 'cannot inspect shared worktree for uncommitted ship work'
    [ -z "$DIRTY" ] || refuse 'uncommitted ship work may exist only in the shared worktree'
    BRANCH="refs/heads/fm/$ID"
    HEAD=$(git -C "$PROJ" rev-parse --verify "$BRANCH^{commit}") || refuse 'old task branch is missing; landed work cannot be proved'
    [ "$(git -C "$WT" symbolic-ref -q HEAD || true)" != "$BRANCH" ] || refuse 'old branch is still checked out in the shared worktree'
    UNLANDED=$(git -C "$PROJ" rev-list "$HEAD" --not --remotes --) || refuse 'cannot inspect old commits'
    if [ -n "$UNLANDED" ] && [ "$(fm_meta_get "$META" mode)" = local-only ]; then
      DEFAULT=$(git -C "$PROJ" symbolic-ref -q refs/remotes/origin/HEAD || true)
      DEFAULT=${DEFAULT#refs/remotes/origin/}
      if [ -z "$DEFAULT" ]; then
        if git -C "$PROJ" show-ref --verify --quiet refs/heads/main; then DEFAULT=main; else DEFAULT=master; fi
      fi
      UNLANDED=$(git -C "$PROJ" rev-list "$HEAD" --not "refs/heads/$DEFAULT" --) || refuse 'cannot inspect local landing'
    fi
    [ -z "$UNLANDED" ] || refuse 'old task branch has unlanded work'
    EVIDENCE="Retained branch $BRANCH at $HEAD is reachable from a remote or the local default branch."
    PR_URL=$(fm_meta_get "$META" pr)
    if [ "$(fm_meta_get "$META" mode)" = local-only ]; then
      BACKLOG_ARGS=(--note 'local main')
    elif [ -n "$PR_URL" ]; then
      BACKLOG_ARGS=(--pr "$PR_URL")
    fi
    ;;
  *) refuse 'only ship and scout records can be retired' ;;
esac
# The normal public-reply guard still applies. A Relay-enabled home needs the
# full teardown resolver, so this narrow repair refuses it without changing state.
ROOT_HOME=$(fm_firstmate_root_home "$FM_HOME") || refuse 'cannot resolve the local parent home'
for home in "$FM_HOME" "$ROOT_HOME"; do
  [ ! -s "$home/.env" ] || refuse 'Relay configuration requires normal public-reply reconciliation first'
done
"$SCRIPT_DIR/fm-inactive-reconcile.sh" report "$ID" || refuse 'final outcome has not reached the parent channel'
BACKLOG=0
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  BACKLOG=1
  fm_backlog_meta_spawn_gen "$META" "$STATE" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
  rc=0
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || refuse 'captain-held or unreadable backlog item requires normal reconciliation'
else
  rc=$?
  [ "$rc" = 1 ] || refuse "$FM_BACKLOG_TRANSITION_ERROR"
fi
ARCHIVE=$DATA/$ID/retired-reassigned
for dir in "$DATA" "$DATA/$ID" "$ARCHIVE"; do
  [ ! -L "$dir" ] || refuse "archive path is a symlink: $dir"
done
mkdir -p "$ARCHIVE"
ARTIFACTS=(".$ID.branch-outcome-index")
for suffix in turn-ended check.sh check-trust pr-poll pr-poll-registration pr-poll-retirement \
  pr-poll-merge-notified busy-state busy-gen busy-events pi-ext.ts pi-session omp-ext.ts grok-turnend-token \
  kimi-turnend-token muse-session muse-session-current cursor-session gemini-settings.json herdr-presentation \
  control-relaunch control-relaunch.meta-prior control-relaunch.brief-prior control-relaunch.note reconcile-nudged inbox; do
  ARTIFACTS+=("$ID.$suffix")
done
for name in "${ARTIFACTS[@]}"; do
  source=$STATE/$name
  target=$ARCHIVE/$name
  [ -e "$source" ] || [ -L "$source" ] || continue
  [ ! -e "$target" ] && [ ! -L "$target" ] || refuse "archive already contains $name"
  if [ "$name" = "$ID.inbox" ]; then
    [ -d "$source" ] && [ ! -L "$source" ] || refuse 'unsafe task inbox'
  else
    fm_backlog_record_present "$source" 'task artifact' "$STATE" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
  fi
done
# Existing evidence copies must match, so retries cannot overwrite evidence from
# another dispatch. The copies are made after the Atlas close, because a refused
# completion appends its blocker line to the active status log.
archive_evidence() {  # [copy]
  local source target
  for source in "$META" "$STATE/$ID.status"; do
    target=$ARCHIVE/$(basename "$source")
    if [ -e "$target" ] || [ -L "$target" ]; then
      fm_backlog_record_present "$target" 'archive record' "$DATA" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
      cmp -s "$source" "$target" || refuse 'archive belongs to a different record; inspect it before retry'
    elif [ "${1:-}" = copy ]; then
      cp -p "$source" "$target"
    fi
  done
}
archive_evidence
ATLAS_GATE_LINE=
TICKET=$(fm_meta_get "$META" atlas_ticket)
if [ -n "$TICKET" ]; then
  [ "$TICKET" != "$(fm_meta_get "$LIVE_META" atlas_ticket)" ] || refuse 'the live record names the same Atlas ticket'
  # The hook owns repository resolution and all mutations. This repair also
  # proves the recorded ticket still belongs to the old task before calling it.
  ATLAS_REPO=$("$SCRIPT_DIR/fm-atlas-hook.sh" wired)
  [ -n "$ATLAS_REPO" ] || refuse 'Atlas ticket has no readable home pointer'
  TICKET_JSON=$(fm_run_timed 20 atlas-axi --repo "$ATLAS_REPO" --by fm-local-retire-reassigned ticket show "$TICKET" --json) \
    || refuse 'cannot read the Atlas ticket identity'
  printf '%s' "$TICKET_JSON" | jq -e --arg id "$ID" --arg ticket "$TICKET" \
    '.change.id==$ticket and .change.task==$id and (.change.state=="started" or .change.state=="completed")' >/dev/null \
    || refuse 'Atlas ticket does not name this finished leg'
  ATLAS_GATE_LINE=$("$SCRIPT_DIR/fm-atlas-hook.sh" land "$ID" --actor fm-local-retire-reassigned --defer-status \
    --evidence "$EVIDENCE" \
    --summary 'Retired the finished task record after its pool slot was reassigned. Preserved the live task and its slot.')
  if [ "$("$SCRIPT_DIR/fm-atlas-hook.sh" state "$ID" --actor fm-local-retire-reassigned)" != completed ]; then
    [ -z "$ATLAS_GATE_LINE" ] || printf '%s\n' "$ATLAS_GATE_LINE" >> "$STATE/$ID.status"
    refuse 'Atlas completion refused or unconfirmed; active record retained'
  fi
fi
archive_evidence copy
# Recheck the external lease immediately before local retirement.
if [ "$LEASE" != "$(jq -c --arg wt "$WT" '.worktrees[] | select(.path==$wt)' "$POOL")" ] || ! lease_owner_live; then
  refuse 'pool lease changed during retirement'
fi
if [ "$BACKLOG" = 1 ]; then
  fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$FM_BACKLOG_META_SPAWN_GEN" ${BACKLOG_ARGS[@]+"${BACKLOG_ARGS[@]}"} \
    || refuse "$FM_BACKLOG_TRANSITION_ERROR"
  fm_backlog_atomic_transition close "$META" "$STATE/$ID.backlog-close" "$DATA" "$ID" "$STATE" ${BACKLOG_ARGS[@]+"${BACKLOG_ARGS[@]}"} \
    || refuse "backlog close requires recovery: $FM_BACKLOG_TRANSITION_ERROR"
else
  fm_backlog_atomic_transition remove "$META" 'task record' "$STATE" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
fi
status_retire_presentation_task "$STATE" "$ID" || refuse 'task retired; status archive exists but presentation cleanup needs repair'
for name in "${ARTIFACTS[@]}"; do
  source=$STATE/$name
  [ -e "$source" ] || [ -L "$source" ] || continue
  mv "$source" "$ARCHIVE/"
done
# The retired log is gone, so a refused node landing starts a fresh one that the
# watcher surfaces until the supervisor resolves its key.
if [ -n "$ATLAS_GATE_LINE" ]; then
  printf '%s\n' "$ATLAS_GATE_LINE" >> "$STATE/$ID.status" \
    || echo "warning: the refused Atlas close-out could not be recorded: $ATLAS_GATE_LINE" >&2
fi
printf 'retired %s; live task %s and slot %s unchanged; evidence %s\n' "$ID" "$LIVE_ID" "$WT" "$ARCHIVE"
