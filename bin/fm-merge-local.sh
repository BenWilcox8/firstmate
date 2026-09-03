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
# a home with no Atlas, makes no call at all.
# Merge authority: reads yolo= from the task's state/<id>.meta at entry and
# refuses when the value is off or the field is absent (safe default). Pass
# --captain-authorized as the second argument to override the guard with an
# explicit current captain merge instruction.
# Usage: fm-merge-local.sh <task-id> [--captain-authorized]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
ID=${1:?usage: fm-merge-local.sh <task-id>}
# --captain-authorized: explicit current captain merge instruction; passes
# through the yolo= guard below. Never modifies the git operation itself.
CAPTAIN_AUTHORIZED=false
[ "${2:-}" != --captain-authorized ] || CAPTAIN_AUTHORIZED=true
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

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
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
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
  --evidence "$before..$after on $DEFAULT" \
  --summary "Task $ID landed on local $DEFAULT as a fast-forward of $BRANCH." || true
