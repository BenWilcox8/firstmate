#!/usr/bin/env bash
# tests/fm-ping-ack.test.sh - the routine-wake close-out contract: the
# bin/fm-ping-ack.sh command, and the two existing mechanisms that now carry
# the agent-origin marker themselves (the steering doorbell a supervisor rings,
# and the wake bin/fm-watch.sh authors for a worker's own status escalation).
#
# Every assertion here runs against a real command, a real library function, or
# a real watcher subprocess; nothing reads the source of what it tests.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ACK="$ROOT/bin/fm-ping-ack.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-ping-ack-tests)

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

# Run the close-out command against a private home and echo its stdout.
run_ack() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ACK" "$@"
}

record_log() {  # <home>
  printf '%s' "$1/state/ping-acks.log"
}

# One field of the Nth record line, by the documented six-field order.
record_field() {  # <home> <line-number> <field-number>
  awk -F '\t' -v n="$2" -v f="$3" 'NR == n { print $f }' "$(record_log "$1")"
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s' "$home"
}

# Call one library function of bin/fm-task-inbox-lib.sh in a scoped subshell,
# the same way tests/fm-task-inbox.test.sh drives that owner.
inbox_lib() {  # <state> <fn> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    shift
    "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# --- the close-out command --------------------------------------------------

test_origin_is_required_and_never_inferred() {
  local home out rc
  home=$(new_home origin-required)
  out=$(run_ack "$home" --note "watcher nudge" 2>/dev/null); rc=$?
  [ "$rc" -eq 2 ] || fail "a close-out with no origin exited $rc, not 2"
  [ -z "$out" ] || fail "a refused close-out still printed a marker: $out"
  [ ! -e "$(record_log "$home")" ] || fail "a refused close-out still wrote a durable record"

  out=$(run_ack "$home" --origin robot 2>/dev/null); rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown origin exited $rc, not 2"
  [ -z "$out" ] || fail "an unknown origin still printed a marker: $out"
  [ ! -e "$(record_log "$home")" ] || fail "an unknown origin still wrote a durable record"

  out=$(run_ack "$home" --origin 2>/dev/null); rc=$?
  [ "$rc" -eq 2 ] || fail "a bare --origin exited $rc, not 2"
  pass "close-out: the origin is required, checked against the vocabulary, and never guessed"
}

test_each_origin_prints_its_exact_marker() {
  local home
  home=$(new_home origins)
  [ "$(run_ack "$home" --origin script)" = '%%dash-ping: script%%' ] \
    || fail "the script origin did not print its exact marker"
  [ "$(run_ack "$home" --origin agent)" = '%%dash-ping: agent%%' ] \
    || fail "the agent origin did not print its exact marker"
  pass "close-out: each origin prints exactly the marker the dashboard classifies"
}

test_note_rides_after_the_marker_on_one_line() {
  local home out lines
  home=$(new_home note-shape)
  out=$(run_ack "$home" --origin script --note "supervision resumed")
  [ "$out" = '%%dash-ping: script%% supervision resumed' ] \
    || fail "the note did not follow the marker on one line: $out"
  out=$(run_ack "$home" --origin agent --note "$(printf 'steer\tdone\nnothing to report')")
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lines" = 1 ] || fail "a multi-line note produced $lines close-out lines"
  case "$out" in
    '%%dash-ping: agent%% steer done nothing to report') ;;
    *) fail "a note with a tab and a newline was not collapsed to spaces: $out" ;;
  esac
  pass "close-out: the note follows the marker and is always exactly one line"
}

test_empty_note_is_refused_rather_than_recorded_blank() {
  local home rc
  home=$(new_home empty-note)
  run_ack "$home" --origin script --note "" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "--note with no text exited $rc, not 2"
  [ ! -e "$(record_log "$home")" ] || fail "an empty note still wrote a durable record"
  pass "close-out: an empty note is refused instead of recorded as a blank one"
}

test_durable_record_keeps_its_documented_shape() {
  local home fields wake note epoch
  home=$(new_home record-shape)
  run_ack "$home" --origin agent --wake t1.status --note "read and handled" >/dev/null \
    || fail "a valid close-out failed"
  [ -s "$(record_log "$home")" ] || fail "no durable record was appended"
  fields=$(awk -F '\t' 'NR == 1 { print NF }' "$(record_log "$home")")
  [ "$fields" = 6 ] || fail "the record has $fields tab-separated fields, not the documented 6"
  [ "$(record_field "$home" 1 1)" = fm-ping-ack.v1 ] || fail "the record lost its schema field"
  epoch=$(record_field "$home" 1 2)
  case "$epoch" in
    ''|*[!0-9]*) fail "the record's epoch field is not a number: $epoch" ;;
  esac
  case "$(record_field "$home" 1 3)" in
    ????-??-??T??:??:??Z) ;;
    *) fail "the record's timestamp is not the documented UTC ISO-8601 shape" ;;
  esac
  [ "$(record_field "$home" 1 4)" = agent ] || fail "the record lost its origin"
  wake=$(record_field "$home" 1 5)
  [ "$wake" = t1.status ] || fail "the record lost the wake key: $wake"
  note=$(record_field "$home" 1 6)
  [ "$note" = "read and handled" ] || fail "the record lost the note: $note"

  run_ack "$home" --origin script >/dev/null || fail "a close-out with no wake or note failed"
  [ "$(wc -l < "$(record_log "$home")" | tr -d ' ')" = 2 ] \
    || fail "the second close-out did not append a second line"
  [ "$(record_field "$home" 2 5)" = '-' ] || fail "an unnamed wake was not recorded as -"
  [ -z "$(record_field "$home" 2 6)" ] || fail "an absent note was not recorded as empty"
  pass "close-out: every record is one appended line in the documented six-field shape"
}

test_long_note_warns_and_still_records() {
  local home err out long
  home=$(new_home long-note)
  err="$home/warn.err"
  long=$(printf 'x%.0s' $(seq 1 200))
  out=$(run_ack "$home" --origin script --note "$long" 2> "$err") \
    || fail "an over-long note was refused instead of warned about"
  case "$out" in
    '%%dash-ping: script%% '*) ;;
    *) fail "an over-long note lost its marker" ;;
  esac
  grep -q 'characters' "$err" || fail "an over-long note produced no warning on stderr"
  [ -s "$(record_log "$home")" ] || fail "an over-long note was warned about but not recorded"
  pass "close-out: an over-long note warns on stderr and is still recorded"
}

test_note_past_the_hard_bound_is_refused() {
  local home rc huge
  home=$(new_home hard-bound)
  huge=$(printf 'y%.0s' $(seq 1 900))
  run_ack "$home" --origin script --note "$huge" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "a note past the hard bound exited $rc, not 2"
  [ ! -e "$(record_log "$home")" ] || fail "a note past the hard bound was still recorded"
  pass "close-out: a note long enough to be a report is refused, not recorded"
}

test_help_states_the_origin_contract() {
  local home out rc
  home=$(new_home help)
  out=$(run_ack "$home" --help); rc=$?
  [ "$rc" -eq 0 ] || fail "--help exited $rc"
  printf '%s' "$out" | grep -q -- '--origin script|agent' \
    || fail "the help does not show the origin argument"
  printf '%s' "$out" | grep -q 'never inferred' \
    || fail "the help does not state that the origin is never inferred"
  [ ! -e "$(record_log "$home")" ] || fail "--help wrote a durable record"
  pass "close-out: the help documents the origin contract without recording anything"
}

test_unknown_argument_is_refused() {
  local home rc
  home=$(new_home unknown-arg)
  run_ack "$home" --origin script --shout loudly >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown argument exited $rc, not 2"
  [ ! -e "$(record_log "$home")" ] || fail "an unknown argument still wrote a durable record"
  pass "close-out: an unrecognised argument is refused rather than ignored"
}

# --- the marker owner (bin/fm-ping-lib.sh) ----------------------------------

# The three consumers - the command, the doorbell, and the watcher - all render
# the marker through this one owner, so its refusal is what keeps a mis-typed
# origin from reaching the dashboard as a valid classification.
ping_lib() {  # <fn> [args...]
  bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    shift
    "$@"
  ' _ "$ROOT/bin/fm-ping-lib.sh" "$@"
}

test_marker_owner_refuses_an_origin_it_does_not_know() {
  local out rc
  [ "$(ping_lib fm_ping_marker script)" = '%%dash-ping: script%%' ] \
    || fail "the marker owner did not render the script origin"
  [ "$(ping_lib fm_ping_marker agent)" = '%%dash-ping: agent%%' ] \
    || fail "the marker owner did not render the agent origin"
  out=$(ping_lib fm_ping_marker "" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "the marker owner accepted an empty origin"
  [ -z "$out" ] || fail "a refused origin still produced marker bytes: $out"
  out=$(ping_lib fm_ping_marker supervisor 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "the marker owner accepted an origin outside its vocabulary"
  [ -z "$out" ] || fail "an unknown origin still produced marker bytes: $out"
  pass "marker owner: only script and agent render, and a refusal produces no bytes"
}

# --- the steering doorbell --------------------------------------------------

test_doorbell_carries_the_agent_origin_marker() {
  local state rec doorbell
  state="$TMP_ROOT/doorbell/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please rebase onto main") \
    || fail "the steer could not be recorded"
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  case "$doorbell" in
    *'%%dash-ping: agent%%'*) ;;
    *) fail "the doorbell carries no agent-origin marker: $doorbell" ;;
  esac
  case "$doorbell" in
    *$'\n'*) fail "the marker broke the doorbell into more than one line" ;;
  esac
  case "$doorbell" in
    'Firstmate instruction waiting: list '*) ;;
    *) fail "the doorbell lost its self-describing opening: $doorbell" ;;
  esac
  pass "doorbell: a supervisor's steer rings with the agent-origin marker on one line"
}

# The doorbell fm-send actually types at a worker, over a stubbed terminal, so
# the marker is proven to survive the real ring rather than only the builder.
test_doorbell_marker_reaches_the_worker_through_fm_send() {
  local dir fb typed
  dir="$TMP_ROOT/doorbell-send"; fb="$dir/fakebin"; typed="$dir/send.log"
  mkdir -p "$dir/home/state" "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  : > "$typed"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_SEND_LOG="$typed" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" t1 "please rebase onto main" >/dev/null 2>"$dir/send.err" \
    || fail "fm-send could not enqueue and ring the steer:"$'\n'"$(cat "$dir/send.err")"
  grep -qF '%%dash-ping: agent%%' "$typed" \
    || fail "the marker never reached the worker's terminal:"$'\n'"$(cat "$typed")"
  if grep -qF 'please rebase onto main' "$typed"; then
    fail "the steer payload was typed instead of being left in the durable record"
  fi
  pass "doorbell: the marker travels with the real doorbell fm-send types at the worker"
}

# --- the wake the watcher authors for a worker escalation -------------------

watch_bg() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

wait_for_exit() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-100} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

# The payload of the queued signal record whose key is <key>.
queued_signal_payload() {  # <state> <key>
  awk -F '\t' -v key="$2" 'NF >= 5 && $3 == "signal" && $4 == key { print $5 }' \
    "$1/.wake-queue"
}

test_worker_status_escalation_wake_carries_the_agent_marker() {
  local dir state fakebin out pid payload
  dir=$(make_case worker-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'blocked: cannot reach the registry\n' > "$state/task.status"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher never surfaced the worker's escalation"
  payload=$(queued_signal_payload "$state" task.status)
  [ -n "$payload" ] || fail "the worker's escalation was not queued as a signal record"
  case "$payload" in
    *'%%dash-ping: agent%%'*) ;;
    *) fail "the worker-escalation wake carries no trace of the worker: $payload" ;;
  esac
  case "$payload" in
    'signal:'*) ;;
    *) fail "the marker replaced the wake reason instead of riding with it: $payload" ;;
  esac
  pass "watcher: the wake it authors for a worker's own status escalation is marked agent-origin"
}

test_turn_end_wake_is_left_unmarked() {
  local dir state fakebin out pid payload
  dir=$(make_case turn-end-unmarked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  : > "$state/task.turn-ended"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher never surfaced the turn-end signal"
  payload=$(queued_signal_payload "$state" task.turn-ended)
  [ -n "$payload" ] || fail "the turn-end signal was not queued"
  case "$payload" in
    *'%%dash-ping:'*) fail "a hook-authored turn-end wake was labelled as an agent's: $payload" ;;
  esac
  pass "watcher: a hook-authored turn-end wake stays unmarked rather than claiming an agent origin"
}

test_origin_is_required_and_never_inferred
test_each_origin_prints_its_exact_marker
test_note_rides_after_the_marker_on_one_line
test_empty_note_is_refused_rather_than_recorded_blank
test_durable_record_keeps_its_documented_shape
test_long_note_warns_and_still_records
test_note_past_the_hard_bound_is_refused
test_help_states_the_origin_contract
test_unknown_argument_is_refused
test_marker_owner_refuses_an_origin_it_does_not_know
test_doorbell_carries_the_agent_origin_marker
test_doorbell_marker_reaches_the_worker_through_fm_send
test_worker_status_escalation_wake_carries_the_agent_marker
test_turn_end_wake_is_left_unmarked
