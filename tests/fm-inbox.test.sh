#!/usr/bin/env bash
# tests/fm-inbox.test.sh - captain inbox capture, receipts, replies, readiness.
#
# Covers the durable order contract: request-id idempotency, the crash window
# between save and announce, saved-but-unannounced repair, the unknown
# announced state of notes that predate the marker, bounded receipts JSON with
# omission disclosure, the reply cursor's strict order, and the readiness
# projection's model-aware verdict and unknown path. Human note/list/drain
# behaviour stays unchanged when the new flags are omitted. `say` and `ask` are
# covered with a fake aws: the WAV header that `say` builds, the duration, and
# each request body. The machine-readable subcommands also run under a minimal
# non-login PATH that finds node only in /opt/homebrew/bin or /usr/local/bin,
# and a node on that PATH still wins over the node in those directories.
# Without any node, they stop before they write a note, a wake or a reply.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox)
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
LOCK_BIN="$ROOT/bin/fm-lock.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_inbox() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" "$@"
}

run_lock() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LOCK_BIN" "$@"
}

# Prints the JSON value at the key path: strings bare, booleans as true or
# false, null as null. A digit-only key indexes into an array. A key or an
# index that is not there fails with no output, so an absent value never
# passes for a null one.
json_get() {
  jq -r --args '
    reduce $ARGS.positional[] as $k (.;
      if type == "array" and ($k | test("^-?[0-9]+$"))
        and (($k | tonumber) as $i | $i < length and $i >= -length)
      then .[$k | tonumber]
      elif type == "object" and has($k) then .[$k]
      else error("no \($k) in the JSON value") end)
    | tostring' "$@"
}

count_notes() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

count_wakes() {
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

# --- human note path is unchanged without the new flags ---------------------

home=$(make_home human)
out=$(run_inbox "$home" note "hello from the terminal") \
  || fail "plain note should succeed"
assert_contains "$out" "queued " "plain note should print queued <id>"
assert_contains "$out" "firstmate will pick this up at its next check." \
  "plain note should keep its human announcement line"
assert_equals "1" "$(count_notes "$home")" "plain note should write one record"
assert_equals "1" "$(count_wakes "$home")" "plain note should append one wake"
list_out=$(run_inbox "$home" list) || fail "list should succeed"
assert_contains "$list_out" "hello from the terminal" "list should show the body"
pass "plain note, list, and wake stay on the historical human path"

# A saved note whose wake fails still exits 1 for callers that omit the new flags.
isolated="$TMP_ROOT/isolated"
mkdir -p "$isolated/bin"
cp "$INBOX_BIN" "$isolated/bin/fm-inbox.sh"
chmod +x "$isolated/bin/fm-inbox.sh"
home=$(make_home human-wake-fail)
set +e
fail_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note "saved but not announced" 2>&1)
fail_code=$?
set -e
expect_code 1 "$fail_code" "plain note still exits 1 when announcement fails"
assert_equals "1" "$(count_notes "$home")" \
  "plain note is saved even when announcement fails"
assert_contains "$fail_out" "queued " "plain note still prints queued before the failure"
assert_contains "$fail_out" "NOT woken" "plain note still reports the wake failure"
pass "plain note keeps exit 1 for a saved-but-unannounced failure"

# --- duplicate request id returns the original identity ---------------------

home=$(make_home idempotent)
body=$'line one\nline two\n'
first=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "first request-id note should succeed"
first_id=$(printf '%s' "$first" | json_get id)
assert_equals "created" "$(printf '%s' "$first" | json_get outcome)" \
  "first submission is created"
assert_equals "true" "$(printf '%s' "$first" | json_get saved)" \
  "first submission is saved"
assert_equals "true" "$(printf '%s' "$first" | json_get announced)" \
  "first submission is announced"
assert_equals "req-1" "$(printf '%s' "$first" | json_get request_id)" \
  "receipt carries the request id"

second=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "replay of the same request id should succeed"
assert_equals "replay" "$(printf '%s' "$second" | json_get outcome)" \
  "repeat request id is a replay, not a second create"
assert_equals "$first_id" "$(printf '%s' "$second" | json_get id)" \
  "replay returns the original note id"
assert_equals "1" "$(count_notes "$home")" \
  "the same request id must not create a second note"
assert_equals "1" "$(count_wakes "$home")" \
  "replay of an already-announced note must not append a second wake"
replay_human=$(run_inbox "$home" note --request-id req-1 "line one") \
  || fail "human replay should succeed"
assert_contains "$replay_human" "replay $first_id" \
  "human replay is distinguishable from queued"
assert_equals "1" "$(count_notes "$home")" "human replay still does not duplicate"
pass "the same request id returns the original note as a distinguishable replay"

# --- crash window: reservation exists, note not yet published ---------------

home=$(make_home crash-reserve)
mkdir -p "$home/state/inbox/.requests"
crash_id="1700000000-crashwin"
printf '%s\n' "$crash_id" > "$home/state/inbox/.requests/crash-rid"
assert_absent "$home/state/inbox/$crash_id.note" \
  "fixture starts with a reservation and no published note"
crash_out=$(run_inbox "$home" note --request-id crash-rid --json "recover me") \
  || fail "retry after a reservation-only crash should complete the original note"
assert_equals "replay" "$(printf '%s' "$crash_out" | json_get outcome)" \
  "completing a reserved request id is a replay of that request"
assert_equals "$crash_id" "$(printf '%s' "$crash_out" | json_get id)" \
  "the reserved note id is reused"
assert_present "$home/state/inbox/$crash_id.note" \
  "the retry publishes the reserved note rather than minting a new id"
assert_equals "1" "$(count_notes "$home")" \
  "crash-window retry leaves exactly one note"
assert_grep "recover me" "$home/state/inbox/$crash_id.note" \
  "the completed note carries the caller's body"
pass "a crash between recording the request id and publishing the note reuses the original id"

# --- saved-but-unannounced, then repair without a second note ---------------

home=$(make_home announce-fail)
set +e
saved_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
saved_code=$?
set -e
expect_code 3 "$saved_code" "request-id note exits 3 when saved but not announced"
assert_equals "created" "$(printf '%s' "$saved_out" | json_get outcome)" \
  "first isolated submit is created"
assert_equals "true" "$(printf '%s' "$saved_out" | json_get saved)" \
  "isolated submit saved the note"
assert_equals "false" "$(printf '%s' "$saved_out" | json_get announced)" \
  "isolated submit could not announce"
saved_id=$(printf '%s' "$saved_out" | json_get id)
assert_equals "1" "$(count_notes "$home")" "isolated submit wrote one note"
assert_equals "0" "$(count_wakes "$home")" "isolated submit wrote no wake"

set +e
replay_fail=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
replay_fail_code=$?
set -e
expect_code 3 "$replay_fail_code" "replay while still unannounced also exits 3"
assert_equals "replay" "$(printf '%s' "$replay_fail" | json_get outcome)" \
  "retry with the same request id is a replay"
assert_equals "$saved_id" "$(printf '%s' "$replay_fail" | json_get id)" \
  "unannounced retry keeps the original id"
assert_equals "1" "$(count_notes "$home")" \
  "unannounced retry must not create a second note"

repair=$(run_inbox "$home" note --request-id repair-1 --json "please announce") \
  || fail "replay with a working announcer should repair the wake"
assert_equals "replay" "$(printf '%s' "$repair" | json_get outcome)" \
  "repair is still a replay"
assert_equals "true" "$(printf '%s' "$repair" | json_get announced)" \
  "repair announces the existing note"
assert_equals "$saved_id" "$(printf '%s' "$repair" | json_get id)" \
  "repair keeps the original id"
assert_equals "1" "$(count_notes "$home")" "repair does not create a second note"
assert_equals "1" "$(count_wakes "$home")" "repair appends exactly one wake"

already=$(run_inbox "$home" announce --json "$saved_id") \
  || fail "announce of an already-announced note should succeed"
assert_equals "replay" "$(printf '%s' "$already" | json_get outcome)" \
  "second announce is already-announced"
assert_equals "1" "$(count_wakes "$home")" \
  "already-announced must not append another wake"
home=$(make_home announce-repair)
set +e
unannounced=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-2 --json "announce me" 2>/dev/null)
set -e
unannounced_id=$(printf '%s' "$unannounced" | json_get id)
assert_equals "0" "$(count_wakes "$home")" "the isolated submit wrote no wake"
repaired=$(run_inbox "$home" announce "$unannounced_id") \
  || fail "announce should repair a note this version saved but could not announce"
assert_contains "$repaired" "announced $unannounced_id" "the repair reports the announcement"
assert_equals "1" "$(count_wakes "$home")" "repairing appends exactly one wake"
pass "saved-but-unannounced notes are repairable without creating a second note"

# A note firstmate already acknowledged needs no wake, so neither the repair
# path nor a request-id replay appends one.
home=$(make_home announce-acked)
set +e
acked=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id acked-1 --json "drained before repair" 2>/dev/null)
set -e
acked_id=$(printf '%s' "$acked" | json_get id)
run_inbox "$home" drain --ack "$acked_id" >/dev/null || fail "drain --ack failed"
acked_repair=$(run_inbox "$home" announce --json "$acked_id") \
  || fail "announce of an acknowledged note should succeed without waking"
assert_equals "true" "$(printf '%s' "$acked_repair" | json_get acknowledged)" \
  "announce reports the note as already acknowledged"
assert_equals "false" "$(printf '%s' "$acked_repair" | json_get announced)" \
  "announce does not claim a wake it never appended"
acked_human=$(run_inbox "$home" announce "$acked_id") \
  || fail "human announce of an acknowledged note should succeed"
assert_contains "$acked_human" "already-acknowledged $acked_id" \
  "human announce names the acknowledgement"
acked_replay=$(run_inbox "$home" note --request-id acked-1 --json "drained before repair") \
  || fail "replay of an acknowledged note should exit 0"
assert_equals "replay" "$(printf '%s' "$acked_replay" | json_get outcome)" \
  "retry of an acknowledged note is a replay"
assert_equals "true" "$(printf '%s' "$acked_replay" | json_get acknowledged)" \
  "replay reports the note as already acknowledged"
assert_equals "0" "$(count_wakes "$home")" \
  "an acknowledged note never gets a repair wake"
pass "repair and replay do not wake firstmate for an already-acknowledged note"

# --- bounded receipts JSON, omission disclosure, reply cursor ---------------

json_len() {  # <key> - fails with no output unless the key holds a list, object, or string
  jq -r --arg k "$1" '
    if type == "object" and has($k)
      and (.[$k] | type | . == "array" or . == "object" or . == "string")
    then .[$k] | length
    else error("no sized \($k) in the JSON value") end'
}

home=$(make_home receipts)
ids=""
i=0
while [ "$i" -lt 21 ]; do
  ids="$ids $(run_inbox "$home" note --request-id "bulk-$i" "bulk body $i" \
    | sed -n 's/^queued //p')"
  i=$((i + 1))
done

receipts=$(run_inbox "$home" receipts) || fail "receipts should succeed"
assert_equals "fm-inbox-receipts.v1" "$(printf '%s' "$receipts" | json_get schema)" \
  "receipts use the receipts schema"
assert_equals "20" "$(printf '%s' "$receipts" | json_len pending)" \
  "pending list is bounded without a reveal flag"
assert_contains "$receipts" "pending notes omitted by bound: 1" \
  "receipts disclose how many pending notes they omitted"
assert_contains "$receipts" "pass --all-pending" \
  "omission names the flag that reveals pending notes"
assert_contains "$receipts" '"acknowledged":false' "pending notes are not acknowledged"

all_receipts=$(run_inbox "$home" receipts --all-pending) \
  || fail "unbounded receipts should succeed"
assert_equals "21" "$(printf '%s' "$all_receipts" | json_len pending)" \
  "--all-pending reveals every pending note"
assert_equals "[]" "$(printf '%s' "$all_receipts" | json_get omitted)" \
  "revealing every row leaves omitted empty"

# shellcheck disable=SC2086 # deliberate word splitting: one id per --ack arg.
run_inbox "$home" drain --ack $ids >/dev/null || fail "drain --ack of the bulk notes failed"
handled_receipts=$(run_inbox "$home" receipts) || fail "receipts after drain should succeed"
assert_equals "20" "$(printf '%s' "$handled_receipts" | json_len handled)" \
  "handled list is bounded without a reveal flag"
assert_contains "$handled_receipts" "handled notes omitted by bound: 1" \
  "receipts disclose how many handled notes they omitted"
assert_contains "$handled_receipts" "pass --all-handled" \
  "omission names the flag that reveals handled notes"
assert_equals "21" "$(run_inbox "$home" receipts --all-handled | json_len handled)" \
  "--all-handled reveals every handled note"
assert_contains "$handled_receipts" '"acknowledged":true' "handled notes are acknowledged"
pass "receipts JSON is bounded by fixed bounds and discloses what it omitted"

# A note written before this home tracked announcement markers already appended
# its own wake, and nothing proves that, so receipts say unknown rather than
# false and the repair path refuses it instead of appending a second wake.
home=$(make_home preexisting)
run_inbox "$home" note "establish the inbox" >/dev/null || fail "seed note failed"
legacy="1700000000-legacy"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\n--\nfrom before the marker\n' \
  "$legacy" > "$home/state/inbox/$legacy.note"
legacy_announced=$(run_inbox "$home" receipts --all-pending | jq -c --arg id "$legacy" '
  [.pending[] | select(.id == $id)]
  | if length > 0 then last else error("no pending note \($id)") end
  | if has("announced") then .announced else error("no announced in the note \($id)") end')
assert_equals "null" "$legacy_announced" \
  "a note that predates the marker reports announced as unknown, not false"
fresh_announced=$(run_inbox "$home" receipts --all-pending | jq -c --arg id "$legacy" '[.pending[] | select(.id != $id) | .announced]')
assert_equals "[true]" "$fresh_announced" \
  "a note this version wrote still reports a definite announced state"
before_wakes=$(count_wakes "$home")
set +e
legacy_out=$(run_inbox "$home" announce "$legacy" 2>&1)
legacy_code=$?
set -e
expect_code 1 "$legacy_code" "announcing a note with an unknown announced state is refused"
assert_contains "$legacy_out" "UNKNOWN" "the refusal says the announced state is unknown"
assert_equals "$before_wakes" "$(count_wakes "$home")" \
  "the refused repair must not append a second wake"
pass "notes that predate the announcement marker are unknown, not re-announced"

# Reply cursor: replies recorded within the same second are both readable, in
# recording order, even when the later note id sorts below the earlier one.
home=$(make_home cursor)
mkdir -p "$home/state/inbox"
later="1700000000-aaaaaa"
earlier="1700000000-zzzzzz"
for nid in "$earlier" "$later"; do
  printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder %s\n' \
    "$nid" "$nid" > "$home/state/inbox/$nid.note"
done
run_inbox "$home" reply "$earlier" "answer one" >/dev/null || fail "first reply failed"
run_inbox "$home" reply "$later" "answer two" >/dev/null || fail "second reply failed"
replies=$(run_inbox "$home" receipts --all-replies) || fail "receipts with replies should succeed"
assert_equals "2" "$(printf '%s' "$replies" | json_len replies)" \
  "both replies appear without a cursor"
order=$(printf '%s' "$replies" | jq -r '[.replies[].id] | join(" ")')
assert_equals "$earlier $later" "$order" "replies are ordered by when they were recorded"
first_cursor=$(printf '%s' "$replies" | json_get replies 0 cursor)
after=$(run_inbox "$home" receipts --all-replies --after "$first_cursor") \
  || fail "receipts --after should succeed"
assert_equals "1" "$(printf '%s' "$after" | json_len replies)" \
  "--after returns only replies recorded later"
after_id=$(printf '%s' "$after" | json_get replies 0 id)
assert_equals "$later" "$after_id" \
  "a same-second reply recorded after the cursor is still delivered"

set +e
conflict=$(run_inbox "$home" reply "$earlier" "answer one" 2>&1)
conflict_code=$?
set -e
expect_code 1 "$conflict_code" "a second reply for the same note is refused"
assert_contains "$conflict" "already recorded" "the refusal names the existing record"
pass "the reply channel is durable and its cursor is a strict order"

# A lost sequence counter must not move the cursor backwards: the next reply
# still sorts after every reply a client has already read.
lost_cursor=$(printf '%s' "$replies" | json_get reply_cursor)
rm -f "$home/state/inbox/.replies/.seq"
third="1700000000-mmmmmm"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder three\n' \
  "$third" > "$home/state/inbox/$third.note"
run_inbox "$home" reply "$third" "answer three" >/dev/null || fail "third reply failed"
after_lost=$(run_inbox "$home" receipts --after "$lost_cursor") \
  || fail "receipts after a lost counter should succeed"
assert_equals "$third" "$(printf '%s' "$after_lost" | json_get replies 0 id)" \
  "a reply recorded after the counter was lost is still after the client cursor"
pass "the reply cursor never goes backwards when the sequence counter is lost"

# A reply without a valid sequence is malformed: it gets no invented position
# and receipts say so instead of silently ordering it.
home=$(make_home malformed-reply)
mkdir -p "$home/state/inbox/.replies"
bad="1700000000-badseq"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder\n' \
  "$bad" > "$home/state/inbox/$bad.note"
printf 'id=%s\nat=2026-01-01T00:00:00Z\n--\nno sequence here\n' \
  "$bad" >"$home/state/inbox/.replies/$bad"
malformed=$(run_inbox "$home" receipts) || fail "receipts with a malformed reply should succeed"
assert_equals "0" "$(printf '%s' "$malformed" | json_len replies)" \
  "a reply without a sequence is not placed in the reply stream"
assert_contains "$malformed" "malformed replies without a valid sequence: 1 ($bad)" \
  "receipts name the malformed reply"
pass "a reply without a valid sequence is reported as malformed"

# One undecodable note must not fail the whole receipts view.
home=$(make_home non-utf8)
run_inbox "$home" note "readable note" >/dev/null || fail "seed note failed"
printf 'id=1700000000-binary\nat=2026-01-01T00:00:00Z\nsource=text\n--\n\377\376 bytes\n' \
  > "$home/state/inbox/1700000000-binary.note"
binary=$(run_inbox "$home" receipts) || fail "receipts must survive a non-UTF-8 note"
assert_equals "2" "$(printf '%s' "$binary" | json_len pending)" \
  "the undecodable note and the readable note are both listed"
pass "a non-UTF-8 note does not break the receipts view"

# --- readiness projection, including unknown -------------------------------

home=$(make_home ready-free)
ready=$(run_inbox "$home" ready) || fail "ready should succeed with no lock"
assert_equals "fm-primary-ready.v1" "$(printf '%s' "$ready" | json_get schema)" \
  "ready uses the readiness schema"
assert_equals "free" "$(printf '%s' "$ready" | json_get lock state)" \
  "no lock file is free, not live"
assert_equals "false" "$(printf '%s' "$ready" | json_get can_receive)" \
  "a free lock cannot receive work"
assert_equals "present" "$(printf '%s' "$ready" | json_get posture state)" \
  "no away flag is present posture"

# A live non-harness pid in the lock file must not be treated as a live primary.
home=$(make_home ready-unknown)
printf '%s\n' "$$" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for an unclassified pid"
lock_state=$(printf '%s' "$ready" | json_get lock state)
assert_equals "unknown" "$lock_state" \
  "a live process that is not a verified harness is unknown, not held"
live=$(printf '%s' "$ready" | json_get lock live_harness)
assert_equals "false" "$live" "a bash test pid is not a live harness"
can=$(printf '%s' "$ready" | json_get can_receive)
[ "$can" = "false" ] || [ "$can" = "unknown" ] \
  || fail "unknown lock must not claim can_receive true (got $can)"

human_lock=$(run_lock "$home" status) || fail "lock status should succeed"
assert_contains "$human_lock" "stale (pid $$ dead or not a harness)" \
  "human lock status keeps its historical stale wording"

# Dead pid is stale, not held.
home=$(make_home ready-stale)
printf '%s\n' "999999" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a dead pid"
assert_equals "stale" "$(printf '%s' "$ready" | json_get lock state)" \
  "a dead recorded pid is stale"
assert_equals "false" "$(printf '%s' "$ready" | json_get can_receive)" \
  "a stale lock cannot receive work"

# Existence of a pane-like leftover must not become liveness: unreadable lock.
home=$(make_home ready-unreadable)
mkdir -p "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a directory lock"
assert_equals "unreadable" "$(printf '%s' "$ready" | json_get lock state)" \
  "a non-file lock is unreadable rather than held"
# A Claude primary mid-turn runs no watcher process - its watcher is armed at
# turn end - so the model-aware supervision verdict, not the pid-strict watcher
# check, owns whether the wake will be drained.
home=$(make_home ready-midturn)
touch "$home/state/.last-watcher-beat"
midturn=$(FM_SUPERVISION_MODEL=autoarm run_inbox "$home" ready) \
  || fail "ready should succeed for a mid-turn autoarm primary"
assert_equals "healthy" "$(printf '%s' "$midturn" | json_get wake_consumer state)" \
  "a mid-turn autoarm primary with a fresh beacon has a healthy wake consumer"

# A home that never ran a watcher has no observation, so it reports no age
# rather than the missing-path sentinel. With no lock holder the model is
# unknown for this home, which is the honest caller path.
home=$(make_home ready-no-beacon)
nobeat=$(run_inbox "$home" ready) || fail "ready should succeed with no beacon"
assert_equals "supervision-model-unknown-for-home" \
  "$(printf '%s' "$nobeat" | json_get wake_consumer reason)" \
  "no lock holder means the home's supervision model is unknown"
assert_equals "null" "$(printf '%s' "$nobeat" | json_get wake_consumer beacon_age_seconds)" \
  "a beacon that does not exist has no age"

# The intended caller (HTTP backend, ssh host fm-inbox.sh ready) does not set
# FM_SUPERVISION_MODEL. A live non-harness lock pid must not invent a model
# from the caller's own process tree.
home=$(make_home ready-no-override)
printf '%s\n' "$$" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
no_override=$(run_inbox "$home" ready) || fail "ready should succeed with no model override"
assert_equals "unknown" "$(printf '%s' "$no_override" | json_get wake_consumer state)" \
  "without a lock-holder harness, wake-consumer is unknown"
assert_equals "supervision-model-unknown-for-home" \
  "$(printf '%s' "$no_override" | json_get wake_consumer reason)" \
  "the unknown reason names that the model could not be determined for this home"
can=$(printf '%s' "$no_override" | json_get can_receive)
assert_equals "unknown" "$can" "unknown lock plus unknown consumer is not can_receive true"

# A live lock holder whose ancestry names a known harness, plus a fresh
# beacon, is the yes path: the inspected home can receive work.
home=$(make_home ready-holder)
# A process whose ps comm is the harness name, so lock inspect and
# fm-harness.sh ancestry both classify it without PATH tricks.
perl -e '$0="claude"; sleep 60' &
holder_pid=$!
# Give ps a moment to report the renamed comm.
sleep 0.2
kill_holder() {
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}
trap 'kill_holder; fm_test_cleanup' EXIT
printf '%s\n' "$holder_pid" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
held=$(run_inbox "$home" ready) || fail "ready should succeed for a lock-holder harness"
assert_equals "held" "$(printf '%s' "$held" | json_get lock state)" \
  "a live claude-named holder is a held lock"
assert_equals "healthy" "$(printf '%s' "$held" | json_get wake_consumer state)" \
  "lock-holder ancestry plus a fresh beacon is a healthy wake consumer"
assert_equals "true" "$(printf '%s' "$held" | json_get can_receive)" \
  "a held lock with a healthy wake consumer can receive work"
kill_holder
trap fm_test_cleanup EXIT
pass "readiness says unknown (or not-receivable) instead of inferring liveness from a lock"

# --- invalid input ----------------------------------------------------------

home=$(make_home invalid)
set +e
empty_out=$(run_inbox "$home" note --request-id x --json "   " 2>&1)
empty_code=$?
bad_out=$(run_inbox "$home" note --request-id '../etc/passwd' --json "nope" 2>&1)
bad_code=$?
# An empty request id must be refused, never treated as "no request id given":
# falling through to the non-idempotent path would make a retry a second note.
blank_out=$(run_inbox "$home" note --request-id '' --json "silently duplicated" 2>&1)
blank_code=$?
set -e
expect_code 1 "$empty_code" "empty body is still refused"
expect_code 1 "$bad_code" "path-like request ids are refused"
expect_code 1 "$blank_code" "an empty request id is refused, not ignored"
assert_contains "$empty_out" "empty" "empty-body refusal says the note was empty"
assert_contains "$bad_out" "invalid request id" "unsafe request ids are rejected by name"
assert_contains "$blank_out" "invalid request id" "an empty request id is rejected by name"
assert_equals "0" "$(count_notes "$home")" "refusals must not write a note"
pass "empty bodies and unsafe request ids are refused"

# The voice handover passes a raw transcript as the first argument, so a body
# that opens with a double dash is text, not an option.
home=$(make_home dash-body)
transcript="--- handover: ship the console backend --now"
dash_out=$(run_inbox "$home" note "$transcript") \
  || fail "a note body opening with dashes should be queued"
assert_contains "$dash_out" "queued " "a dash-leading body is queued like any other"
assert_equals "1" "$(count_notes "$home")" "a dash-leading body writes one note"
dash_body=$(run_inbox "$home" receipts --all-pending | json_get pending 0 body)
assert_equals "$transcript" "$dash_body" "the transcript is stored verbatim"
escaped=$(run_inbox "$home" note -- "--request-id is body text here") \
  || fail "-- should end option parsing"
assert_contains "$escaped" "queued " "-- escapes a body that looks like a flag"
pass "a note body that opens with a double dash is queued as text"

# --- drain still acks by moving the note ------------------------------------

home=$(make_home drain)
queued=$(run_inbox "$home" note "ack me") || fail "note for drain failed"
did=${queued#queued }
did=${did%%$'\n'*}
run_inbox "$home" drain --ack "$did" >/dev/null || fail "drain --ack failed"
assert_absent "$home/state/inbox/$did.note" "acked note leaves pending"
assert_present "$home/state/inbox/handled/$did.note" "acked note is in handled"
pass "drain --ack still moves the note to handled"

# --- say: audio wrapping and the model request ------------------------------
#
# `say` needs a model call, so a fake aws on PATH records the request body the
# real CLI would have sent. HOME points at the test home so a developer's own
# toolbox directories cannot shadow the fake.

home=$(make_home say)
fakebin="$home/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/aws" <<'AWS'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  [ "$prev" = "--messages" ] && cp "${arg#file://}" "$FAKE_AWS_DIR/messages.json"
  prev=$arg
done
printf 'fake transcript\n'
AWS
chmod +x "$fakebin/aws"

run_say() {  # <audio-file> - stdout and stderr merged
  HOME="$home" PATH="$fakebin:$PATH" FAKE_AWS_DIR="$home" FM_INBOX_REGION=us-east-1 \
    FM_INBOX_STT_MODEL=fake-stt FM_INBOX_PROFILE="" run_inbox "$home" say "$1" 2>&1
}

# The audio the fake aws received, decoded from the request body.
sent_audio() {
  json_get 0 content 0 audio source bytes <"$home/messages.json" | base64 -d
}

hex_head() {  # <file> - the first 44 bytes as hex
  od -An -tx1 -N44 "$1" | tr -d ' \n'
}

# 16kHz mono s16le PCM, 4000 frames: a quarter of a second.
head -c 8000 /dev/zero | tr '\0' 'A' >"$home/pcm-quarter"
out=$(run_say "$home/pcm-quarter") || fail "say should accept headerless PCM: $out"
assert_contains "$out" "input looked like raw PCM, wrapped as 16kHz mono WAV" \
  "headerless PCM is reported as wrapped"
assert_contains "$out" "0.25s of audio, transcribing with fake-stt in us-east-1" \
  "the duration of the wrapped audio is 0.25 seconds"
sent_audio >"$home/sent.wav"
# RIFF, size 36 + 8000, WAVE, a 16 byte fmt chunk (PCM, 1 channel, 16000 Hz,
# 32000 bytes per second, block align 2, 16 bits), then the 8000 byte data chunk.
expected_header="52494646 641f0000 57415645 666d7420 10000000 0100 0100 803e0000 007d0000 0200 1000 64617461 401f0000"
assert_equals "${expected_header// /}" "$(hex_head "$home/sent.wav")" \
  "the wrapped WAV has the canonical 44 byte header for the PCM it received"
assert_equals "8044" "$(wc -c <"$home/sent.wav" | tr -d ' ')" \
  "the wrapped WAV is the header plus every PCM byte"
tail -c 8000 "$home/sent.wav" | cmp -s - "$home/pcm-quarter" \
  || fail "the PCM bytes after the header must be the input unchanged"
assert_equals "Transcribe the speech exactly. Output only the transcript, nothing else." \
  "$(json_get 0 content 1 text <"$home/messages.json")" \
  "the request carries the transcription instruction"
assert_equals "wav" "$(json_get 0 content 0 audio format <"$home/messages.json")" \
  "the request names the audio format as wav"
assert_equals '[{"role": "user", "content": [{"audio": {"format": "wav", "source": {"bytes": "B"}}}, {"text": "Transcribe the speech exactly. Output only the transcript, nothing else."}]}]' \
  "$(sed 's/"bytes": "[^"]*"/"bytes": "B"/' "$home/messages.json")" \
  "the request body keeps the JSON layout of Python json.dump"
assert_contains "$out" "heard: fake transcript" "the model transcript is reported"
assert_contains "$(cat "$home"/state/inbox/*.note)" "audio_seconds=0.25" \
  "the queued note records the audio duration"
pass "say wraps headerless PCM in a WAV header and sends it with the right duration"

# A WAV is passed through untouched, and its duration is read from its header.
out=$(run_say "$home/sent.wav") || fail "say should accept a WAV: $out"
assert_contains "$out" "input is WAV, passing through" "a WAV is passed through"
assert_contains "$out" "0.25s of audio" "a WAV reports its own duration"
sent_audio | cmp -s - "$home/sent.wav" || fail "a WAV must reach the model byte for byte"
pass "say passes a WAV through unchanged"

# A WAVE_FORMAT_EXTENSIBLE WAV is PCM when its SubFormat is the PCM GUID, and
# its duration comes from the same header fields. Any other SubFormat is refused.
extensible_wav() {  # <first SubFormat byte, octal escape> <file>
  printf 'RIFF\174\037\000\000WAVEfmt \050\000\000\000\376\377\001\000\200\076\000\000\000\175\000\000\002\000\020\000\026\000\020\000\004\000\000\000%b\000\000\000\000\000\020\000\200\000\000\252\000\070\233\161data\100\037\000\000' "$1" >"$2"
  head -c 8000 /dev/zero >>"$2"
}
extensible_wav '\001' "$home/extensible.wav"
out=$(run_say "$home/extensible.wav") || fail "say should accept extensible PCM: $out"
assert_contains "$out" "0.25s of audio" "extensible PCM reports its own duration"
sent_audio | cmp -s - "$home/extensible.wav" || fail "an extensible WAV must reach the model byte for byte"
extensible_wav '\003' "$home/extensible-float.wav"
set +e
float_out=$(run_say "$home/extensible-float.wav")
float_code=$?
set -e
expect_code 1 "$float_code" "say refuses an extensible WAV that is not PCM"
assert_contains "$float_out" "unknown extended format" "the refusal names the extended format"
pass "say reads extensible PCM and refuses other extended formats"

# A trailing odd byte is not a whole sample and is dropped. Durations print as
# a rounded float: whole seconds keep one decimal, and an exact tie rounds to
# even (0.125 is 0.12).
head -c 8001 /dev/zero >"$home/pcm-odd"
out=$(run_say "$home/pcm-odd") || fail "say should accept odd-length PCM: $out"
sent_audio >"$home/sent.wav"
assert_equals "8044" "$(wc -c <"$home/sent.wav" | tr -d ' ')" \
  "an odd trailing byte is dropped from the wrapped audio"
head -c 32000 /dev/zero >"$home/pcm-second"
out=$(run_say "$home/pcm-second") || fail "say should accept one second of PCM: $out"
assert_contains "$out" "1.0s of audio" "whole seconds keep one decimal"
head -c 4000 /dev/zero >"$home/pcm-tie"
out=$(run_say "$home/pcm-tie") || fail "say should accept 0.125 seconds of PCM: $out"
assert_contains "$out" "0.12s of audio" "an exact rounding tie rounds to even"
pass "say drops a partial sample and prints durations as rounded floats"

# Compressed audio is refused before any model call.
rm -f "$home/messages.json"
printf 'OggS\000\002rest of an ogg stream' >"$home/audio.ogg"
set +e
ogg_out=$(run_say "$home/audio.ogg")
ogg_code=$?
set -e
expect_code 1 "$ogg_code" "say refuses Ogg audio"
assert_contains "$ogg_out" "got Ogg/FLAC/MP3; re-encode to WAV first" \
  "the refusal tells the user to re-encode"
assert_absent "$home/messages.json" "refused audio never reaches the model"
pass "say refuses compressed audio"

# --- ask: the side-question request ----------------------------------------
#
# The same fake aws records the request body of `ask`. A question that starts
# with a dash is text: it must reach the request body unchanged, and the node
# program that writes the body must not read it as an option of its own.

home=$(make_home ask)
run_ask() {  # <question-word>... - stdout and stderr merged
  HOME="$home" PATH="$fakebin:$PATH" FAKE_AWS_DIR="$home" FM_INBOX_REGION=us-east-1 \
    FM_INBOX_ASK_MODEL=fake-ask FM_INBOX_PROFILE="" run_inbox "$home" ask "$@" 2>&1
}

out=$(run_ask -- why did the café build fail) \
  || fail "ask should accept a question that starts with --: $out"
assert_contains "$out" "fake transcript" "ask prints the model answer"
assert_equals "-- why did the café build fail" "$(json_get 0 content 0 text <"$home/messages.json")" \
  "a question that starts with -- reaches the model unchanged"
assert_equals "user" "$(json_get 0 role <"$home/messages.json")" "the question is the user turn"
assert_equals '[{"role": "user", "content": [{"text": "-- why did the caf\u00e9 build fail"}]}]' \
  "$(cat "$home/messages.json")" "the request body keeps the JSON layout and ASCII escapes of Python json.dump"
rm -f "$home/messages.json"
out=$(run_ask --version) || fail "ask should accept the question --version: $out"
assert_equals "--version" "$(json_get 0 content 0 text <"$home/messages.json")" \
  "a question that looks like a node option reaches the model unchanged"
pass "ask sends a question that starts with a dash as text"

# --- machine-readable output under a non-login ssh PATH ---------------------
#
# `ssh host fm-inbox.sh ready` gets the non-login PATH of the host. On macOS
# that PATH has no Homebrew or nvm tools. The script appends /opt/homebrew/bin
# and /usr/local/bin when they exist, so a node in one of them serves the
# machine-readable subcommands, and a node that the PATH already holds still
# wins. This case uses the node of this host in one of those directories, and
# it skips when neither directory has a node.

std_node_dir=
for dir in /opt/homebrew/bin /usr/local/bin; do
  if [ -x "$dir/node" ]; then
    std_node_dir=$dir
    break
  fi
done
if [ -z "$std_node_dir" ]; then
  printf '# skip: no node in /opt/homebrew/bin or /usr/local/bin, so node from a standard directory under a non-login PATH is unverified here\n'
else
  core_path=$(fm_test_core_path)
  PATH=$core_path command -v node >/dev/null 2>&1 \
    && fail "the minimal PATH must not hold node"
  home=$(make_home ssh-path)
  run_bare() {
    HOME="$home" PATH="$core_path" run_inbox "$home" "$@"
  }
  noted=$(run_bare note --json "from a non-login shell") \
    || fail "note --json must find node in $std_node_dir: $noted"
  assert_equals "created" "$(printf '%s' "$noted" | json_get outcome)" "note --json under the minimal PATH"
  nid=$(printf '%s' "$noted" | json_get id)
  replied=$(run_bare reply --json "$nid" "an answer") \
    || fail "reply --json must find node in $std_node_dir: $replied"
  assert_equals "fm-inbox-reply.v1" "$(printf '%s' "$replied" | json_get schema)" \
    "reply --json under the minimal PATH"
  receipts=$(run_bare receipts) || fail "receipts must find node in $std_node_dir: $receipts"
  assert_equals "$nid" "$(printf '%s' "$receipts" | json_get replies 0 id)" \
    "receipts under the minimal PATH"
  readiness=$(run_bare ready) || fail "ready must find node in $std_node_dir: $readiness"
  printf '%s' "$readiness" | jq -e 'has("can_receive")' >/dev/null \
    || fail "ready under the minimal PATH did not print the readiness JSON: $readiness"
  pass "machine-readable subcommands find node in $std_node_dir under a non-login PATH"

  shimbin="$home/shimbin"
  mkdir -p "$shimbin"
  cat >"$shimbin/node" <<'NODE'
#!/usr/bin/env bash
printf '%s\n' "$#" >>"$SHIM_NODE_LOG"
exec "$REAL_NODE" "$@"
NODE
  chmod +x "$shimbin/node"
  : >"$home/shim-node.log"
  readiness=$(SHIM_NODE_LOG="$home/shim-node.log" REAL_NODE="$std_node_dir/node" \
    HOME="$home" PATH="$shimbin:$core_path" run_inbox "$home" ready) \
    || fail "ready must run with the node of the caller PATH: $readiness"
  printf '%s' "$readiness" | jq -e 'has("can_receive")' >/dev/null \
    || fail "ready with a node on the caller PATH did not print the readiness JSON: $readiness"
  [ -s "$home/shim-node.log" ] \
    || fail "the node on the caller PATH must win over the node in $std_node_dir"
  pass "a node on the caller PATH wins over the node in $std_node_dir"
fi

# --- no node: the machine-readable subcommands write nothing ----------------
#
# Without node, `note --json`, `announce --json` and `reply --json` stop with
# exit 1 before they write a note, a wake or a reply. The error names where the
# script looks for node and how to link one. A host with node in
# /opt/homebrew/bin or /usr/local/bin always finds it, so this case skips there.

if [ -n "$std_node_dir" ]; then
  printf '# skip: fm-inbox.sh always finds the node in %s, so a host without node is unverified here\n' "$std_node_dir"
else
  core_path=$(fm_test_core_path)
  home=$(make_home no-node)
  run_nodeless() {
    HOME="$home" PATH="$core_path" run_inbox "$home" "$@"
  }
  set +e
  nodeless_out=$(run_nodeless note --json "needs node" 2>&1)
  nodeless_code=$?
  set -e
  expect_code 1 "$nodeless_code" "note --json without node fails"
  assert_contains "$nodeless_out" "PATH or in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin" \
    "the error names where fm-inbox.sh looks for node"
  assert_contains "$nodeless_out" "~/.local/bin/node" "the error tells how to link a node"
  assert_equals "0" "$(count_notes "$home")" "note --json without node must not save a note"
  assert_equals "0" "$(count_wakes "$home")" "note --json without node must not append a wake"

  plain=$(run_nodeless note "saved without node") || fail "a plain note must not need node: $plain"
  nid=$(printf '%s\n' "$plain" | sed -n 's/^queued //p')
  [ -n "$nid" ] || fail "a plain note without node printed no id: $plain"
  rm -f "$home/state/inbox/.announced/$nid"
  wakes=$(count_wakes "$home")
  set +e
  nodeless_out=$(run_nodeless announce --json "$nid" 2>&1)
  nodeless_code=$?
  set -e
  expect_code 1 "$nodeless_code" "announce --json without node fails"
  assert_contains "$nodeless_out" "~/.local/bin/node" "the announce error tells how to link a node"
  assert_equals "$wakes" "$(count_wakes "$home")" "announce --json without node must not append a wake"
  [ ! -e "$home/state/inbox/.announced/$nid" ] \
    || fail "announce --json without node must not mark the note announced"

  set +e
  nodeless_out=$(run_nodeless reply --json "$nid" "an answer" 2>&1)
  nodeless_code=$?
  set -e
  expect_code 1 "$nodeless_code" "reply --json without node fails"
  assert_contains "$nodeless_out" "~/.local/bin/node" "the reply error tells how to link a node"
  [ ! -e "$home/state/inbox/.replies/$nid" ] || fail "reply --json without node must not record a reply"
  pass "without node, note, announce and reply --json stop before they write anything"
fi
