#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the merge-authority guard that reads yolo=
# from the task's state/<id>.meta and refuses when the value is off or absent.
#
# Matrix:
#   (a) yolo=off refuses before any git operation
#   (b) a missing yolo= field is treated as yolo=off (safe default)
#   (c) yolo=on allows the merge to proceed
#   (d) --captain-authorized overrides yolo=off for an explicit captain merge word
#   (e) --captain-authorized is not passed through to any git command
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# make_case <name> [yolo=<val>]: a state dir with a task meta for a local-only
# task. The project dir is a real git repo so the script's git checks pass.
make_case() {
  local name=$1 yolo=${2:-on} dir proj branch
  dir="$TMP_ROOT/$name"
  proj="$dir/project"
  branch="fm/task-x1"
  mkdir -p "$dir/state" "$proj"
  git -C "$proj" init -q
  fm_git_identity fmtest fmtest@example.invalid
  git -C "$proj" commit --allow-empty -q -m "init"
  git -C "$proj" checkout -q -b "$branch"
  git -C "$proj" commit --allow-empty -q -m "task work"
  git -C "$proj" checkout -q main 2>/dev/null || git -C "$proj" checkout -q master 2>/dev/null
  git -C "$proj" remote add origin "$proj" 2>/dev/null || true
  # Set origin/HEAD so default_branch() resolves via symbolic-ref.
  git -C "$proj" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null \
    || git -C "$proj" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master 2>/dev/null \
    || true
  fm_write_meta "$dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$dir/wt" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=$yolo"
  printf '%s\n' "$dir"
}

run_merge_local() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$ROOT}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

test_yolo_off_refuses_before_git() {
  local dir rc before after proj
  dir=$(make_case yolo-off-refuses off)
  proj="$dir/project"
  before=$(git -C "$proj" rev-parse --short main 2>/dev/null || git -C "$proj" rev-parse --short master 2>/dev/null)

  set +e
  run_merge_local "$dir" task-x1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "yolo-off: should refuse when yolo=off"
  assert_grep 'merge refused for task task-x1' "$dir/stderr" \
    "yolo-off: refusal did not name the task id"
  assert_grep 'yolo=off' "$dir/stderr" \
    "yolo-off: refusal did not name the value found"
  assert_grep 'captain-authorized' "$dir/stderr" \
    "yolo-off: refusal did not name the override flag"
  # The fast-forward must not have happened.
  after=$(git -C "$proj" rev-parse --short main 2>/dev/null || git -C "$proj" rev-parse --short master 2>/dev/null)
  [ "$before" = "$after" ] \
    || fail "yolo-off: the fast-forward ran despite the refusal"
  pass "fm-merge-local refuses before any git operation when yolo=off"
}

test_yolo_missing_refuses_safe_default() {
  local dir rc
  dir=$(make_case yolo-missing-refuses off)
  # Overwrite meta to omit yolo= entirely.
  fm_write_meta "$dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=local-only"

  set +e
  run_merge_local "$dir" task-x1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "yolo-missing: should refuse when yolo= is absent"
  assert_grep 'merge refused for task task-x1' "$dir/stderr" \
    "yolo-missing: refusal did not name the task id"
  assert_grep 'yolo=<missing>' "$dir/stderr" \
    "yolo-missing: refusal did not identify the missing field"
  pass "fm-merge-local treats a missing yolo= field as yolo=off (safe default)"
}

test_yolo_on_allows_merge() {
  local dir rc
  dir=$(make_case yolo-on-proceeds on)
  local proj
  proj="$dir/project"
  local default_branch
  default_branch=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|^origin/||' || echo "main")

  set +e
  run_merge_local "$dir" task-x1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "yolo-on: merge should succeed when yolo=on"
  assert_grep 'merged fm/task-x1' "$dir/stdout" \
    "yolo-on: merged line was not printed"
  assert_grep 'merged_local=' "$dir/state/task-x1.meta" \
    "yolo-on: merged_local= was not recorded in the task meta"
  pass "fm-merge-local proceeds when the task meta has yolo=on"
}

test_captain_authorized_overrides_yolo_off() {
  local dir rc
  dir=$(make_case explicit-word-override off)

  set +e
  run_merge_local "$dir" task-x1 --captain-authorized > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "captain-authorized: merge should succeed with --captain-authorized even when yolo=off"
  assert_grep 'merged fm/task-x1' "$dir/stdout" \
    "captain-authorized: merged line was not printed"
  assert_grep 'merged_local=' "$dir/state/task-x1.meta" \
    "captain-authorized: merged_local= was not recorded in the task meta"
  assert_no_grep 'captain-authorized' "$dir/stdout" \
    "captain-authorized: flag leaked into stdout"
  pass "fm-merge-local passes through --captain-authorized as the yolo=off override"
}

test_yolo_off_refuses_before_git
test_yolo_missing_refuses_safe_default
test_yolo_on_allows_merge
test_captain_authorized_overrides_yolo_off
