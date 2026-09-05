#!/usr/bin/env bash
# Behavioral coverage for bin/fm-action-pins-check.sh, the repo invariant
# that every third-party GitHub Action reference is pinned to a commit SHA.
# Regression origin: c548 - a dependency sweep found actions/checkout,
# actions/upload-artifact, and actions/download-artifact pinned to mutable
# tags in .github/workflows.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-action-pins-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-action-pins-check)
SHA40=$(printf '%040d' 1)

# make_workflow <dir> <body> writes a minimal single-file workflow fixture
# under <dir>/.github/workflows/w.yml, so tests assert behavior for chosen
# `uses:` lines instead of the live workflow set.
make_workflow() {
  local dir=$1 body=$2
  mkdir -p "$dir/.github/workflows"
  {
    printf 'name: fixture\n'
    printf 'on: push\n'
    printf 'jobs:\n'
    printf '  job:\n'
    printf '    runs-on: ubuntu-latest\n'
    printf '    steps:\n'
    printf '%s\n' "$body"
  } > "$dir/.github/workflows/w.yml"
}

run_check() {
  local dir=$1
  shift
  "$CHECK" --root "$dir" "$@" 2>&1
}

test_mutable_tag_fails() {
  local dir="$TMP_ROOT/mutable" out rc
  make_workflow "$dir" "      - uses: actions/checkout@v6"
  set +e
  out=$(run_check "$dir")
  rc=$?
  set -e
  expect_code 1 "$rc" "a mutable tag reference should fail"
  assert_contains "$out" 'actions/checkout@v6' "the failure did not name the offending reference"
  assert_contains "$out" 'mutable ref' "the failure did not explain why it was rejected"
  pass "a third-party action pinned to a mutable tag fails the check"
}

test_unpinned_no_ref_fails() {
  local dir="$TMP_ROOT/noref" out rc
  make_workflow "$dir" "      - uses: actions/checkout"
  set +e
  out=$(run_check "$dir")
  rc=$?
  set -e
  expect_code 1 "$rc" "an action with no ref at all should fail"
  assert_contains "$out" 'no pinned ref' "the failure did not explain the missing ref"
  pass "a third-party action with no ref at all fails the check"
}

test_full_sha_passes() {
  local dir="$TMP_ROOT/pinned" out rc
  make_workflow "$dir" "      - uses: actions/checkout@${SHA40} # v6.1.0"
  set +e
  out=$(run_check "$dir")
  rc=$?
  set -e
  expect_code 0 "$rc" "a full commit SHA with a version comment should pass"
  assert_contains "$out" '1 third-party action reference(s) pinned' "the pass summary did not report the checked count"
  pass "a third-party action pinned to a full commit SHA passes the check"
}

test_short_sha_fails() {
  local dir="$TMP_ROOT/short" out rc
  make_workflow "$dir" "      - uses: actions/checkout@d234410"
  set +e
  out=$(run_check "$dir")
  rc=$?
  set -e
  expect_code 1 "$rc" "a short/abbreviated SHA should fail"
  assert_contains "$out" 'mutable ref' "the failure did not explain why a short SHA was rejected"
  pass "a third-party action pinned to a short SHA fails the check"
}

test_local_and_docker_actions_are_exempt() {
  local dir="$TMP_ROOT/exempt" out rc
  make_workflow "$dir" "      - uses: ./.github/actions/local-thing
      - uses: docker://alpine@sha256:deadbeef"
  set +e
  out=$(run_check "$dir")
  rc=$?
  set -e
  expect_code 0 "$rc" "local and docker:// action references should never be checked"
  assert_contains "$out" '0 third-party action reference(s) pinned' "local/docker refs were not correctly exempted"
  pass "local composite actions and docker:// actions are exempt from the pin check"
}

test_multiple_workflow_files_are_all_checked() {
  local dir="$TMP_ROOT/multi" out rc
  mkdir -p "$dir/.github/workflows"
  {
    printf 'name: a\non: push\njobs:\n  job:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - uses: actions/checkout@%s # v6.1.0\n' "$SHA40"
  } > "$dir/.github/workflows/a.yml"
  {
    printf 'name: b\non: push\njobs:\n  job:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - uses: actions/upload-artifact@v4\n'
  } > "$dir/.github/workflows/b.yml"
  set +e
  out=$(run_check "$dir")
  rc=$?
  set -e
  expect_code 1 "$rc" "a violation in any workflow file should fail the whole check"
  assert_contains "$out" 'b.yml' "the failing file was not identified"
  pass "every workflow file under .github/workflows is checked, not just the first"
}

test_usage_errors_are_refused() {
  local dir="$TMP_ROOT/usage" out rc
  set +e
  out=$(run_check "$TMP_ROOT/does-not-exist" 2>&1; echo "rc=$?")
  set -e
  assert_contains "$out" 'rc=2' "a missing --root directory should be a usage error"

  mkdir -p "$dir"
  set +e
  out=$("$CHECK" --root "$dir" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an empty workflow directory should refuse rather than silently pass"
  assert_contains "$out" 'no GitHub workflow files found' "the empty-directory case did not name the cause"
  pass "usage and empty-input errors are refused rather than silently passing"
}

test_mutable_tag_fails
test_unpinned_no_ref_fails
test_full_sha_passes
test_short_sha_fails
test_local_and_docker_actions_are_exempt
test_multiple_workflow_files_are_all_checked
test_usage_errors_are_refused

echo '# all fm-action-pins-check tests passed'
