#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# After the fast-forward succeeds, the landing is recorded in the task's own
# metadata as merged_local=<before>..<after>, so cleanup can tell landed work
# from a leg that produced nothing without depending on the Atlas being up.
# The task's recorded Atlas ticket (atlas_ticket= in its meta) is discharged
# with the before..after range this script already computed. That call goes
# through bin/fm-atlas-hook.sh, which owns the best-effort contract and can
# never fail a merge that has already landed; a task with no recorded ticket, or
# a home with no Atlas, makes no call at all. Pass `--captain-word <words>` or
# `--captain-word=<words>` with the captain's exact words from chat to record
# them as the Atlas approval before the ticket is completed; the hook's header
# owns a refused close-out.
# Merge authority: reads yolo= from the task's state/<id>.meta at entry and
# refuses when the value is off or the field is absent (safe default). Pass
# --captain-authorized to override the guard with an
# explicit current captain merge instruction.
# Usage: fm-merge-local.sh <task-id> [--captain-authorized]
#        [--captain-word <words>|--captain-word=<words>]
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-atlas-word-lib.sh
. "$SCRIPT_DIR/fm-atlas-word-lib.sh"
# --captain-authorized: explicit current captain merge instruction; passes
# through the yolo= guard below. Never modifies the git operation itself.
# --captain-word <words>: the captain's exact words, recorded as the Atlas
# approval before the ticket is completed.
CAPTAIN_AUTHORIZED=false
CAPTAIN_WORD=
if [ "$#" -lt 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --captain-authorized) CAPTAIN_AUTHORIZED=true; shift ;;
    --captain-word|--captain-word=*)
      if ! fm_atlas_parse_captain_word "$1" "${2-}"; then
        echo "error: --captain-word needs non-empty words, not another option" >&2
        exit 2
      fi
      CAPTAIN_WORD=$FM_ATLAS_CAPTAIN_WORD
      shift "$FM_ATLAS_CAPTAIN_WORD_CONSUMED"
      ;;
    *) echo "error: invalid local merge request" >&2; exit 2 ;;
  esac
done
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

# Merge-authority guard: refuse unless yolo=on is recorded in the task meta or
# the caller supplied --captain-authorized (a current, explicit captain merge
# word). A missing yolo= field is treated as yolo=off (safe default).
if [ "$CAPTAIN_AUTHORIZED" != true ]; then
  YOLO_VAL=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ "$YOLO_VAL" != on ]; then
    printf 'error: merge refused for task %s: yolo=%s (expected on or --captain-authorized for an explicit captain merge instruction)\n' \
      "$ID" "${YOLO_VAL:-<missing>}" >&2
    exit 1
  fi
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null || merge_status=$?
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

# The fast-forward is the proof, and this script is holding it. Record it in the
# task's own metadata FIRST, as merged_local=<before>..<after>: a landing whose
# only record is an Atlas call would be invisible to cleanup whenever that
# best-effort call missed, and cleanup would then read a branch the default
# branch already contains as a leg that produced nothing.
MERGED_LOCAL_LOCK=$(fm_meta_lock_path "$META") || {
  echo "error: could not resolve the task metadata lock for $ID" >&2
  exit 1
}
fm_lock_acquire_wait "$MERGED_LOCAL_LOCK"
if ! grep -q '^merged_local=' "$META" 2>/dev/null; then
  printf 'merged_local=%s..%s\n' "$before" "$after" >> "$META" || {
    fm_lock_release "$MERGED_LOCAL_LOCK"
    echo "error: could not record the local landing in $META" >&2
    exit 1
  }
fi
fm_lock_release "$MERGED_LOCAL_LOCK"

# Discharge the task's recorded Atlas ticket with the shas it already computed.
# Best effort by contract: bin/fm-atlas-hook.sh never fails a merge that already
# landed.
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
  "$FM_ROOT/bin/fm-atlas-hook.sh" complete "$ID" \
  --actor fm-merge-local \
  --restage merge \
  ${CAPTAIN_WORD:+--captain-word="$CAPTAIN_WORD"} \
  --evidence "$before..$after on $DEFAULT" \
  --summary "Task $ID landed on local $DEFAULT as a fast-forward of $BRANCH." || true
