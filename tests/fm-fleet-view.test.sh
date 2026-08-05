#!/usr/bin/env bash
# tests/fm-fleet-view.test.sh - behavior tests for fm-fleet-view.sh title truncation.
#
# Coverage:
#   - long backlog titles are truncated to 120 chars with an ellipsis by default
#   - short titles pass through unchanged
#   - FM_SESSION_START_VERBOSE=1 restores full untruncated titles
#   - title truncation does not drop any structured row from the table
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-view-tests)
fm_git_identity fmtest fmtest@example.invalid

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# --- title truncation in lean mode ------------------------------------------

test_backlog_title_truncation() {
  local home long_title short_title truncated_prefix out
  home=$(make_home title-truncation)
  long_title="Implement the comprehensive authentication flow refactoring with detailed error messages and proper session management for all user account types"
  short_title="Fix login bug"
  cat > "$home/data/backlog.md" <<BACKLOG
## In flight

## Queued
- [ ] long-task - ${long_title} (repo: myapp)
- [ ] short-task - ${short_title} (repo: myapp)

## Done
BACKLOG

  truncated_prefix=$(printf '%s' "$long_title" | head -c 120)

  out=$(FM_HOME="$home" "$VIEW")
  assert_not_contains "$out" "$long_title" "lean mode did not truncate the long backlog title"
  assert_contains "$out" "$truncated_prefix" "lean mode truncated too aggressively (first 120 chars missing)"
  assert_contains "$out" "…" "lean mode did not append ellipsis after truncation"
  assert_contains "$out" "$short_title" "lean mode incorrectly truncated a short title"
  assert_contains "$out" "long-task" "row id was dropped by title truncation"
  assert_contains "$out" "short-task" "short-task row was dropped by title truncation"

  pass "fleet-view: long titles truncated at 120 chars with ellipsis; short titles unchanged"
}

# --- verbose flag restores full titles ---------------------------------------

test_verbose_flag_restores_full_titles() {
  local home long_title out
  home=$(make_home title-verbose)
  long_title="Implement the comprehensive authentication flow refactoring with detailed error messages and proper session management for all user account types including administrator and read-only roles"
  cat > "$home/data/backlog.md" <<BACKLOG
## In flight

## Queued
- [ ] long-task - ${long_title} (repo: myapp)

## Done
BACKLOG

  out=$(FM_SESSION_START_VERBOSE=1 FM_HOME="$home" "$VIEW")
  assert_contains "$out" "$long_title" "FM_SESSION_START_VERBOSE=1 did not restore the full backlog title"

  pass "FM_SESSION_START_VERBOSE=1 restores full untruncated titles in fleet-view"
}

test_backlog_title_truncation
test_verbose_flag_restores_full_titles
