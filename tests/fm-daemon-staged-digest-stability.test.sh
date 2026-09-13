#!/usr/bin/env bash
# Reproduce staged-note recursion through the daemon queue and receipt boundary.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

TMP_ROOT=$(fm_test_tmproot fm-daemon-staged-digest)
HOME_ROOT="$TMP_ROOT/home"
STATE="$HOME_ROOT/state"
FAKE_NOW=1700000000
SUBMIT_RESULT=failed
SUBMIT_LOG="$TMP_ROOT/submits"
FM_SUPERVISOR_BACKEND=herdr
FM_DAEMON_PRIMARY_HARNESS=codex

mkdir -p "$STATE"
: > "$STATE/.afk"
: > "$SUBMIT_LOG"

_now() {
  printf '%s\n' "$FAKE_NOW"
}

inject_msg() {
  printf '%s\n' "$1" >> "$SUBMIT_LOG"
  [ "$SUBMIT_RESULT" = delivered ]
}

note_count() {
  find "$STATE/inbox" -maxdepth 1 -name '*.note' -print 2>/dev/null | wc -l | tr -d ' '
}

active_note_id() {
  awk -F '\t' 'NR == 1 { print $2 }' "$STATE/.subsuper-inject-fallback"
}

note_body() {
  awk 'body { print } /^--$/ { body=1 }' "$1"
}

run_pending_cycle() {
  FAKE_NOW=$((FAKE_NOW + 61))
  FM_HOME="$HOME_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_ESCALATE_BATCH_SECS=60 FM_MAX_DEFER_SECS=0 \
    FM_HEARTBEAT_SCAN_SECS=9999999999 housekeeping "$STATE"
}

handle_pending_wakes() {
  FM_HOME="$HOME_ROOT" FM_STATE_OVERRIDE="$STATE" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes "check: rearm-resurface" "$STATE" >/dev/null 2>&1
}

original_event='done: original worker result remains pending'
escalate_add "$STATE" "$original_event"
original_digest=$(escalate_digest "$STATE") || fail "the original digest was not available"

run_pending_cycle
[ "$(note_count)" -eq 1 ] || fail "the first pending cycle did not create one staged note"
first_id=$(active_note_id)
first_note="$STATE/inbox/$first_id.note"
assert_present "$first_note" "the first staged note was not durable"
assert_absent "$STATE/.subsuper-staged-delivered-inbox-$first_id" \
  "a failed submit created a delivery receipt"
[ "$(note_body "$first_note")" = "$original_digest" ] \
  || fail "the first staged note did not contain the original digest"
assert_grep "inbox:$first_id" "$STATE/.wake-queue" \
  "the first staged note did not keep its public wake"

handle_pending_wakes || fail "the daemon did not route the staged presentation wake"
[ ! -s "$STATE/.wake-queue" ] || fail "the routed staged presentation wake was not acknowledged"
[ "$(escalate_digest "$STATE")" = "$original_digest" ] \
  || fail "the staged presentation changed its own digest identity"

run_pending_cycle
[ "$(note_count)" -eq 1 ] || fail "the first rearm cycle created a recursive staged note"
[ "$(active_note_id)" = "$first_id" ] || fail "the first rearm cycle changed the staged note identity"
[ "$(note_body "$first_note")" = "$original_digest" ] \
  || fail "the first rearm cycle changed the staged note body"
assert_absent "$STATE/.subsuper-staged-delivered-inbox-$first_id" \
  "a pending rearm cycle created a delivery receipt"
[ -s "$STATE/.subsuper-escalations" ] \
  || fail "a pending rearm cycle lost the original escalation buffer"

run_pending_cycle
[ "$(note_count)" -eq 1 ] || fail "the second rearm cycle created a recursive staged note"
[ "$(active_note_id)" = "$first_id" ] || fail "the second rearm cycle changed the staged note identity"

printf 'done: new worker result arrived\n' > "$STATE/worker-r1.status"
append_wake "$STATE" signal worker-r1.status "signal: $STATE/worker-r1.status"
assert_grep "signal: $STATE/worker-r1.status" "$STATE/.wake-queue" \
  "the real worker event was not durable before handling"
handle_pending_wakes || fail "the daemon did not route the real worker event"
[ ! -s "$STATE/.wake-queue" ] || fail "the daemon acknowledged no real worker event"
changed_digest=$(escalate_digest "$STATE") || fail "the changed digest was not available"
assert_contains "$changed_digest" "$original_event" "the changed digest lost the original worker event"
assert_contains "$changed_digest" "done: new worker result arrived" "the changed digest lost the new worker event"
assert_not_contains "$changed_digest" "captain inbox note" \
  "the changed digest included its staged presentation wake"

run_pending_cycle
[ "$(note_count)" -eq 2 ] || fail "one genuine worker event did not create exactly one new staged note"
second_id=$(active_note_id)
[ "$second_id" != "$first_id" ] || fail "one genuine worker event did not change the staged note identity"
second_note="$STATE/inbox/$second_id.note"
[ "$(note_body "$second_note")" = "$changed_digest" ] \
  || fail "the replacement staged note did not contain both real worker events"
assert_absent "$STATE/.subsuper-staged-delivered-inbox-$second_id" \
  "the failed replacement submit created a delivery receipt"

SUBMIT_RESULT=delivered
run_pending_cycle
[ "$(note_count)" -eq 2 ] || fail "the successful retry created another staged note"
assert_present "$STATE/.subsuper-staged-delivered-inbox-$second_id" \
  "the successful retry did not record its real delivery receipt"
assert_absent "$STATE/.subsuper-staged-delivered-inbox-$first_id" \
  "the successful retry claimed that an older note was delivered"
[ ! -s "$STATE/.subsuper-escalations" ] \
  || fail "the successful retry did not clear the delivered escalation buffer"

handle_pending_wakes || fail "the daemon did not handle the receipted staged wake"
[ ! -s "$STATE/.wake-queue" ] || fail "the receipted staged wake remained in the queue"

# A receipt only authorizes the producer's exact "<id> - <summary>" wake.
# A different check that merely repeats a staged ID must stay actionable.
escalate_add "$STATE" "malformed-envelope fixture"
FM_HOME="$HOME_ROOT" FM_STATE_OVERRIDE="$STATE" FM_SUPERVISOR_BACKEND=herdr \
  FM_DAEMON_PRIMARY_HARNESS=codex escalate_flush "$STATE" busy-override \
  || fail "the malformed-envelope fixture could not be delivered"
malformed_id=${INJECT_DURABLE_NOTE_ID:-}
[ -n "$malformed_id" ] || fail "the malformed-envelope fixture returned no staged note ID"
assert_present "$STATE/.subsuper-staged-delivered-inbox-$malformed_id" \
  "the malformed-envelope fixture was not receipted"
handle_pending_wakes || fail "the daemon did not handle the receipted producer wake"
: > "$STATE/.subsuper-escalations"
malformed_reason="check: captain inbox note $malformed_id malformed-envelope"
append_wake "$STATE" check "inbox:$malformed_id-malformed" "$malformed_reason"
FM_HOME="$HOME_ROOT" FM_STATE_OVERRIDE="$STATE" FM_ESCALATE_BATCH_SECS=999 \
  handle_durable_wakes "check: rearm-resurface" "$STATE" >/dev/null 2>&1 \
  || fail "the daemon did not route the malformed staged-id wake"
assert_grep "$malformed_reason" "$STATE/.subsuper-escalations" \
  "a malformed staged-id wake was suppressed"

pass "pending staged digests stay stable, real worker events remain deliverable, receipts follow real submits, and malformed staged-id wakes remain actionable"
