#!/usr/bin/env bash
# Tests for the Pi-harness claim gate in bin/fm-wake-drain.sh.
# The claim block (claim_main_rows_locked + .main-eligible-rows) is Pi-only
# machinery: non-Pi homes (Claude, Codex) skip it on every drain and produce
# no .main-eligible-rows file. Pi homes with an active branch-session/ run
# the claim block without change.
#
# Matrix:
#   (a) non-Pi home: drain presents all wake rows without a .main-eligible-rows file
#   (b) non-Pi home: .main-eligible-rows is not created after the drain
#   (c) Pi home (branch-session/ present): drain proceeds with the claim block
#   (d) Pi home: .main-eligible-rows is written after the drain
#   (e) non-Pi home: ack still removes handled rows through the cutoff
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-pi-gate-tests)

test_non_pi_drain_presents_wakes_without_claim_file() {
  local dir state out err
  dir=$(make_case non-pi-presents-wakes)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  append_wake "$state" signal "task1" "working: something"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "non-pi-presents-wakes: drain failed unexpectedly"

  grep -F 'task1' "$out" > /dev/null \
    || fail "non-pi-presents-wakes: wake row was not presented"
  assert_absent "$state/.main-eligible-rows" \
    "non-pi-presents-wakes: .main-eligible-rows was created in a non-Pi home"
  pass "non-Pi drain presents all wake rows without producing .main-eligible-rows"
}

test_non_pi_drain_produces_no_claim_file() {
  local dir state out err
  dir=$(make_case non-pi-no-claim-file)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  # Multiple distinct rows to exercise the full awk pass.
  append_wake "$state" signal "task2" "working: a"
  append_wake "$state" heartbeat "" ""

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "non-pi-no-claim-file: drain failed unexpectedly"

  assert_absent "$state/.main-eligible-rows" \
    "non-pi-no-claim-file: .main-eligible-rows was created despite no Pi branch"
  pass "non-Pi drain never writes .main-eligible-rows"
}

test_pi_home_drain_uses_claim_block() {
  local dir state out err
  dir=$(make_case pi-home-claim-runs)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  # Create the branch-session directory that signals Pi harness presence.
  mkdir -p "$state/branch-session"
  append_wake "$state" signal "task3" "working: pi-task"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "pi-home-claim-runs: drain failed unexpectedly"

  grep -F 'task3' "$out" > /dev/null \
    || fail "pi-home-claim-runs: wake row was not presented in Pi home"
  assert_present "$state/.main-eligible-rows" \
    "pi-home-claim-runs: .main-eligible-rows was not written for a Pi home"
  pass "Pi drain writes .main-eligible-rows when branch-session/ is present"
}

test_non_pi_ack_removes_rows_through_cutoff() {
  local dir state out err seq generation
  dir=$(make_case non-pi-ack-removes-rows)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  append_wake "$state" signal "task4" "working: ack-test"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "non-pi-ack-removes-rows: drain failed unexpectedly"

  # Capture the ack command from stderr and run it.
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] \
    || fail "non-pi-ack-removes-rows: drain did not print WAKE_ACK_REQUIRED"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation" \
    > /dev/null 2>&1 \
    || fail "non-pi-ack-removes-rows: ack command failed"

  # After ack, the queue must be empty.
  [ ! -s "$state/.wake-queue" ] \
    || fail "non-pi-ack-removes-rows: rows were not removed by the ack in a non-Pi home"
  pass "non-Pi ack removes handled rows through the cutoff without a claim file"
}

test_non_pi_drain_presents_wakes_without_claim_file
test_non_pi_drain_produces_no_claim_file
test_pi_home_drain_uses_claim_block
test_non_pi_ack_removes_rows_through_cutoff
