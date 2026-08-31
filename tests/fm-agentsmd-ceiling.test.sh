#!/usr/bin/env bash
# Behavioral coverage for the tracked AGENTS.md token ceiling: its safe parser,
# the reported accounting, and the check that CI runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agentsmd-ceiling)
CEILING="$ROOT/bin/fm-agentsmd-ceiling.sh"

# make_repo <dir> <agents-md-bytes> [<ceiling>]
# Builds a minimal fake repo root the script can be pointed at, so the tests
# assert behavior for chosen sizes instead of the live AGENTS.md.
make_repo() {
  local dir=$1 bytes=$2 ceiling=${3:-}
  mkdir -p "$dir"
  if [ "$bytes" -gt 0 ]; then
    head -c "$bytes" /dev/zero | tr '\0' 'a' > "$dir/AGENTS.md"
  else
    : > "$dir/AGENTS.md"
  fi
  [ -z "$ceiling" ] || printf '%s\n' "$ceiling" > "$dir/.agentsmd-ceiling"
}

run_ceiling() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir" "$CEILING" "$@" 2>&1
}

test_read_prints_the_tracked_ceiling() {
  local dir="$TMP_ROOT/read" out rc
  make_repo "$dir" 30 25000
  out=$(run_ceiling "$dir" read)
  [ "$out" = 25000 ] || fail "read printed '$out' instead of the tracked ceiling"

  # An absent ceiling is a concrete configuration error, never an inferred
  # default: a silently defaulted ceiling would stop enforcing anything.
  rm -f "$dir/.agentsmd-ceiling"
  set +e
  out=$(run_ceiling "$dir" read)
  rc=$?
  set -e
  expect_code 2 "$rc" "absent ceiling should be a configuration error"
  assert_contains "$out" 'file is absent' "absent ceiling did not name the cause"
  pass "read prints the tracked ceiling and refuses an absent one"
}

test_parser_rejects_ambiguous_and_unsafe_ceilings() {
  local dir="$TMP_ROOT/parse" out rc value
  make_repo "$dir" 30 25000
  for value in '' '0' '007' '25000 ' 'lots' '2.5' '25000
25001'; do
    printf '%s\n' "$value" > "$dir/.agentsmd-ceiling"
    set +e
    out=$(run_ceiling "$dir" read)
    rc=$?
    set -e
    expect_code 2 "$rc" "ceiling '$value' should be rejected"
    assert_contains "$out" 'agentsmd-ceiling:' "rejection of '$value' was not reported by the script"
  done

  printf '25000' > "$dir/.agentsmd-ceiling"
  set +e
  out=$(run_ceiling "$dir" read)
  rc=$?
  set -e
  expect_code 2 "$rc" "a ceiling without its terminating newline should be rejected"

  printf '%s\n' 25000 > "$TMP_ROOT/outside-ceiling"
  rm -f "$dir/.agentsmd-ceiling"
  ln -s "$TMP_ROOT/outside-ceiling" "$dir/.agentsmd-ceiling"
  set +e
  out=$(run_ceiling "$dir" read)
  rc=$?
  set -e
  expect_code 2 "$rc" "a symlinked ceiling should be rejected"
  assert_contains "$out" 'file is symlinked' "symlinked ceiling did not name the cause"
  pass "the ceiling parser rejects ambiguous and unsafe values"
}

test_check_passes_under_the_ceiling_and_names_the_overage() {
  local dir="$TMP_ROOT/check" out rc
  # 300 bytes is ceil(300/3) = 100 estimated tokens exactly, so the boundary
  # itself is asserted rather than approached.
  make_repo "$dir" 300 100
  set +e
  out=$(run_ceiling "$dir" check)
  rc=$?
  set -e
  expect_code 0 "$rc" "AGENTS.md exactly at the ceiling should pass"
  assert_contains "$out" 'within ceiling' "passing check did not report the result"

  printf '%s\n' 99 > "$dir/.agentsmd-ceiling"
  set +e
  out=$(run_ceiling "$dir" check)
  rc=$?
  set -e
  expect_code 1 "$rc" "AGENTS.md over the ceiling should fail"
  assert_contains "$out" 'is 100 estimated tokens' "failure did not name the estimated size"
  assert_contains "$out" 'over the ceiling 99' "failure did not name the ceiling"
  assert_contains "$out" 'by 1 tokens' "failure did not name the overage"
  pass "check passes at the ceiling and fails naming the overage"
}

test_check_is_the_default_verb_and_report_accounts_for_the_file() {
  local dir="$TMP_ROOT/report" out rc
  make_repo "$dir" 300 99
  set +e
  out=$(run_ceiling "$dir")
  rc=$?
  set -e
  expect_code 1 "$rc" "the default verb should be the failing check"
  assert_contains "$out" 'by 1 tokens' "the default verb did not run check"

  out=$(run_ceiling "$dir" report)
  assert_contains "$out" 'ceiling_tokens=99' "report omitted the ceiling"
  assert_contains "$out" 'file=AGENTS.md bytes=300 estimated_tokens=100' "report omitted the accounting"
  assert_contains "$out" 'ceiling_status=over-ceiling' "report omitted the status"
  assert_contains "$out" 'overage_tokens=1' "report omitted the overage"

  printf '%s\n' 100 > "$dir/.agentsmd-ceiling"
  out=$(run_ceiling "$dir" report)
  assert_contains "$out" 'ceiling_status=within-ceiling' "report omitted the passing status"
  assert_contains "$out" 'headroom_tokens=0' "report omitted the headroom"
  pass "check is the default verb and report accounts for AGENTS.md"
}

test_absent_agents_md_is_an_error_not_a_pass() {
  local dir="$TMP_ROOT/absent" out rc
  make_repo "$dir" 300 100
  rm -f "$dir/AGENTS.md"
  set +e
  out=$(run_ceiling "$dir" check)
  rc=$?
  set -e
  expect_code 2 "$rc" "an absent AGENTS.md should be an error, not a silent pass"
  assert_contains "$out" 'AGENTS.md' "absent AGENTS.md was not named"
  pass "an unreadable AGENTS.md fails as a configuration error"
}
test_usage_dispatch_prints_the_whole_header_and_refuses_unknown_input() {
  local dir="$TMP_ROOT/usage" out rc
  make_repo "$dir" 300 100
  out=$(run_ceiling "$dir" --help)
  # The usage text is sliced out of the header comment by line number, so it
  # drifts silently when the header grows.  Pin both ends of that slice.
  assert_contains "$out" 'Hold AGENTS.md under its tracked token ceiling.' "--help omitted the header's first line"
  assert_contains "$out" 'command never reads, writes, or repairs the startup-memory budget.' "--help omitted the header's last line"
  assert_contains "$out" 'fm-agentsmd-ceiling.sh report' "--help omitted a verb"
  case "$out" in
    *'set -eu'*) fail "--help printed past the end of the header comment" ;;
  esac

  for arg in bogus 'read extra' 'report extra' 'check extra'; do
    set +e
    # shellcheck disable=SC2086 # Deliberate word splitting to pass extra arguments.
    out=$(run_ceiling "$dir" $arg)
    rc=$?
    set -e
    expect_code 2 "$rc" "'$arg' should be refused as usage"
    assert_contains "$out" 'Usage:' "'$arg' did not print usage"
  done
  pass "usage dispatch prints the whole header and refuses unknown input"
}

test_usage_dispatch_prints_the_whole_header_and_refuses_unknown_input
test_read_prints_the_tracked_ceiling
test_parser_rejects_ambiguous_and_unsafe_ceilings
test_check_passes_under_the_ceiling_and_names_the_overage
test_check_is_the_default_verb_and_report_accounts_for_the_file
test_absent_agents_md_is_an_error_not_a_pass

echo '# all fm-agentsmd-ceiling tests passed'
