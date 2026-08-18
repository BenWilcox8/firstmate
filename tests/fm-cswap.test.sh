#!/usr/bin/env bash
# Behavior tests for firstmate's claude-swap integration.
#
# Both subjects are driven through their real interfaces against a fake cswap
# executable, so the account-pin contract and the rotation check's output
# contract are pinned without any live credential, network call, or account
# switch. The fake is selected through FM_CSWAP_BIN, the same seam a home uses
# when cswap is not on the spawn PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-cswap-lib.sh"
ROTATE="$ROOT/bin/fm-cswap-rotate.sh"
TMP_ROOT=$(fm_test_tmproot fm-cswap)

# A fake cswap that replays canned stdout for one subcommand. FM_FAKE_CSWAP_OUT
# holds the bytes to print, FM_FAKE_CSWAP_RC the exit status, and every
# invocation is logged so a test can assert which cswap call was made.
make_fake_cswap() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_CSWAP_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_CSWAP_LOG"
[ -z "${FM_FAKE_CSWAP_SLEEP:-}" ] || sleep "$FM_FAKE_CSWAP_SLEEP"
[ -z "${FM_FAKE_CSWAP_OUT:-}" ] || printf '%s\n' "$FM_FAKE_CSWAP_OUT"
exit "${FM_FAKE_CSWAP_RC:-0}"
SH
  chmod +x "$path"
}

# The two-account listing the captain's own machine reports, trimmed to the
# fields resolution actually reads.
ACCOUNTS_JSON='{"schemaVersion":1,"activeAccountNumber":1,"accounts":[
  {"number":1,"email":"one@example.com","alias":"primary","active":true},
  {"number":2,"email":"two@example.com","alias":"parent","active":false}]}'

FAKE_CSWAP="$TMP_ROOT/cswap"
make_fake_cswap "$FAKE_CSWAP"

# resolve <pin> [json] -> prints "<number> <label>" or the error, sets RC
resolve() {
  local pin=$1 json=${2:-$ACCOUNTS_JSON}
  RESOLVE_OUT=$(
    FM_CSWAP_BIN="$FAKE_CSWAP" FM_FAKE_CSWAP_OUT="$json" \
      bash -c '. "$1"; fm_cswap_resolve_account "$2"' _ "$LIB" "$pin" 2>&1
  )
  RC=$?
}

test_pin_resolves_by_number_alias_and_email() {
  resolve 2
  expect_code 0 "$RC" "a slot-number pin should resolve"
  assert_contains "$RESOLVE_OUT" "2 parent" "a slot-number pin should resolve to its canonical alias"

  resolve parent
  expect_code 0 "$RC" "an alias pin should resolve"
  assert_contains "$RESOLVE_OUT" "2 parent" "an alias pin should resolve to the same account"

  resolve two@example.com
  expect_code 0 "$RC" "an email pin should resolve"
  assert_contains "$RESOLVE_OUT" "2 parent" "an email pin should resolve to the same account"

  resolve PARENT
  expect_code 0 "$RC" "an alias pin should resolve case-insensitively"
  assert_contains "$RESOLVE_OUT" "2 parent" "alias matching should not depend on case"

  pass "an account pin resolves by slot number, alias, or email to one canonical account"
}

test_unresolvable_pin_fails_loudly() {
  resolve nosuchaccount
  [ "$RC" -ne 0 ] || fail "an unknown account pin must not resolve"
  assert_contains "$RESOLVE_OUT" "unknown Claude account 'nosuchaccount'" \
    "an unknown pin should name the pin that failed"
  assert_contains "$RESOLVE_OUT" "primary, parent" \
    "an unknown pin should list the accounts cswap does know"

  resolve 9
  [ "$RC" -ne 0 ] || fail "a slot number no account occupies must not resolve"
  assert_contains "$RESOLVE_OUT" "unknown Claude account '9'" \
    "an unoccupied slot number should be rejected, not passed through"

  pass "an unresolvable account pin fails loudly and names what cswap knows"
}

test_ambiguous_and_empty_account_sets_fail() {
  resolve dup@example.com '{"accounts":[
    {"number":1,"email":"dup@example.com","alias":""},
    {"number":2,"email":"dup@example.com","alias":""}]}'
  [ "$RC" -ne 0 ] || fail "an email matching two accounts must not resolve"
  assert_contains "$RESOLVE_OUT" "ambiguous" "an ambiguous email should say so"
  assert_contains "$RESOLVE_OUT" "1, 2" "an ambiguous email should name both slots"

  resolve primary '{"accounts":[]}'
  [ "$RC" -ne 0 ] || fail "an empty account set must not resolve a pin"
  assert_contains "$RESOLVE_OUT" "manages no Claude accounts" \
    "an empty account set should say cswap has no accounts registered"

  pass "ambiguous and empty account sets are refused rather than guessed"
}

test_resolution_survives_a_failing_or_absent_cswap() {
  RESOLVE_OUT=$(
    FM_CSWAP_BIN="$FAKE_CSWAP" FM_FAKE_CSWAP_OUT='' FM_FAKE_CSWAP_RC=1 \
      bash -c '. "$1"; fm_cswap_resolve_account primary' _ "$LIB" 2>&1
  )
  RC=$?
  [ "$RC" -ne 0 ] || fail "a failing cswap must not resolve an account"
  assert_contains "$RESOLVE_OUT" "could not list its Claude accounts" \
    "a failing cswap should be reported as a listing failure"

  RESOLVE_OUT=$(
    FM_CSWAP_BIN="$TMP_ROOT/definitely-not-here" \
      bash -c '. "$1"; fm_cswap_resolve_account primary' _ "$LIB" 2>&1
  )
  RC=$?
  [ "$RC" -ne 0 ] || fail "an absent cswap must not resolve an account"
  assert_contains "$RESOLVE_OUT" "cswap is not installed" \
    "an absent cswap should name the missing tool"

  pass "a failing or absent cswap refuses to resolve instead of degrading"
}

test_cswap_calls_are_time_bounded() {
  local start end elapsed out rc
  start=$(date +%s)
  out=$(
    FM_CSWAP_BIN="$FAKE_CSWAP" FM_CSWAP_TIMEOUT=1 FM_FAKE_CSWAP_SLEEP=10 \
      bash -c '. "$1"; fm_cswap_run list --json' _ "$LIB" 2>&1
  )
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$rc" -ne 0 ] || fail "a cswap call that outlives its bound must not report success"
  [ "$elapsed" -lt 8 ] || fail "a cswap call should be cut off at its bound, took ${elapsed}s"
  assert_not_contains "$out" "should never print" "a timed-out call should not deliver output"
  pass "a slow cswap call is cut off at its configured bound instead of wedging the caller"
}

# rotate [args...] -> prints the check's stdout, sets RC
rotate() {
  local out=$1
  shift
  ROTATE_OUT=$(
    FM_CSWAP_BIN="$FAKE_CSWAP" FM_FAKE_CSWAP_OUT="$out" FM_FAKE_CSWAP_RC="${FM_FAKE_RC:-0}" \
      FM_FAKE_CSWAP_LOG="${FM_FAKE_CSWAP_LOG:-}" "$ROTATE" "$@" 2>&1
  )
  RC=$?
}

test_quiet_tick_prints_nothing() {
  rotate '{"schemaVersion":1,"event":"poll","threshold":90.0}
{"schemaVersion":1,"event":"no-switch","reason":"below-threshold","detail":"16% < 90%"}'
  expect_code 0 "$RC" "a no-action tick should exit 0"
  [ -z "$ROTATE_OUT" ] || fail "a tick that changed nothing must print nothing, got: $ROTATE_OUT"
  pass "a rotation tick that changed nothing stays completely silent"
}

test_switch_is_reported_in_one_line() {
  rotate '{"schemaVersion":1,"event":"poll","threshold":90.0}
{"schemaVersion":1,"event":"switch","trigger":"proactive","from":{"number":1,"email":"one@example.com"},"to":{"number":2,"email":"two@example.com"},"warnings":[],"dryRun":false}'
  expect_code 0 "$RC" "a switching tick should still exit 0"
  [ "$(printf '%s\n' "$ROTATE_OUT" | wc -l)" -eq 1 ] \
    || fail "a switch should report exactly one line, got: $ROTATE_OUT"
  assert_contains "$ROTATE_OUT" "switched from account 1 (one@example.com) to account 2 (two@example.com)" \
    "a switch line should name both accounts"
  assert_contains "$ROTATE_OUT" "proactive" "a switch line should name what triggered it"
  pass "a completed switch is reported as exactly one line naming both accounts"
}

test_blockers_are_reported() {
  rotate '{"schemaVersion":1,"event":"all-exhausted","earliestResetAt":"2026-08-19T12:00:00Z"}'
  assert_contains "$ROTATE_OUT" "every account is out of headroom" \
    "an exhausted fleet should be reported"
  assert_contains "$ROTATE_OUT" "2026-08-19T12:00:00Z" \
    "an exhausted fleet should carry the earliest reset"

  rotate '{"schemaVersion":1,"event":"account-quarantined","number":"2","email":"two@example.com","reason":"invalid-grant"}'
  assert_contains "$ROTATE_OUT" "account 2 (two@example.com) dropped out of rotation: invalid-grant" \
    "a quarantined account should be reported with its reason"

  rotate '{"schemaVersion":1,"event":"error","message":"usage read failed","transient":true}'
  assert_contains "$ROTATE_OUT" "rotation error: usage read failed" \
    "a tick error should be reported"

  pass "an exhausted fleet, a quarantined account, and a tick error each wake the supervisor"
}

test_dry_run_is_labelled_and_passed_through() {
  local log="$TMP_ROOT/dry-run.log"
  : > "$log"
  FM_FAKE_CSWAP_LOG="$log" rotate '{"schemaVersion":1,"event":"switch","trigger":"proactive","from":{"number":1,"email":"one@example.com"},"to":{"number":2,"email":"two@example.com"},"dryRun":true}' --dry-run
  assert_contains "$ROTATE_OUT" "would switch from account 1" \
    "a dry-run switch should read as hypothetical, not as a completed switch"
  assert_grep "auto --once --json --dry-run" "$log" \
    "--dry-run should reach cswap's own auto tick"
  pass "a dry-run tick reaches cswap as a dry run and reports a hypothetical switch"
}

test_tick_runs_cswap_auto_once() {
  local log="$TMP_ROOT/auto.log"
  : > "$log"
  FM_FAKE_CSWAP_LOG="$log" rotate '{"schemaVersion":1,"event":"no-switch","reason":"cooldown"}'
  assert_grep "auto --once --json" "$log" "the check should run exactly one cswap auto tick"
  assert_no_grep "switch " "$log" "the check must never switch the live login itself"
  pass "the rotation check runs one bounded cswap auto tick and never switches by itself"
}

test_unusable_tick_output_is_reported() {
  rotate ''
  expect_code 0 "$RC" "an empty tick should still exit 0 so the watcher keeps polling"
  assert_contains "$ROTATE_OUT" "produced no result" \
    "a tick with no output at all should be reported, not silently swallowed"
  pass "a tick that produces nothing is reported rather than read as healthy silence"
}

test_pin_resolves_by_number_alias_and_email
test_unresolvable_pin_fails_loudly
test_ambiguous_and_empty_account_sets_fail
test_resolution_survives_a_failing_or_absent_cswap
test_cswap_calls_are_time_bounded
test_quiet_tick_prints_nothing
test_switch_is_reported_in_one_line
test_blockers_are_reported
test_dry_run_is_labelled_and_passed_through
test_tick_runs_cswap_auto_once
test_unusable_tick_output_is_reported
