#!/usr/bin/env bash
# Verify wake presentation and acknowledgement with and without Pi history.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-preservation)

test_drain_and_ack_preserve_later_rows() {
  local history=$1 dir state out err seq generation
  dir=$(make_case "history-$history")
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  if [ "$history" = pi ]; then
    mkdir -p "$state/branch-session"
  fi
  append_wake "$state" check first-result 'check: first-result'
  append_wake "$state" check second-result 'check: second-result'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "$history: drain failed"
  assert_grep 'first-result' "$out" "$history: first wake was not presented"
  assert_grep 'second-result' "$out" "$history: second wake was not presented"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail "$history: acknowledgement instruction missing"

  # A result that arrives after presentation is not part of this acknowledgement.
  append_wake "$state" check later-result 'check: later-result'
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation" \
    >/dev/null 2>&1 || fail "$history: acknowledgement failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "$history: second drain failed"
  assert_no_grep 'first-result' "$out" "$history: acknowledged first wake replayed"
  assert_no_grep 'second-result' "$out" "$history: acknowledged second wake replayed"
  assert_grep 'later-result' "$out" "$history: acknowledgement lost the later wake"
  pass "$history: presentation and acknowledgement preserve later wake rows"
}

test_drain_and_ack_preserve_later_rows absent
test_drain_and_ack_preserve_later_rows pi
