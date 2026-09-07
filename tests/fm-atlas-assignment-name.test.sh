#!/usr/bin/env bash
# Behavior tests for ticket-assignment names on managed Pi sessions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECEIVER="$ROOT/bin/fm-atlas-assignment-name.sh"
TMP_ROOT=$(fm_test_tmproot fm-atlas-assignment-name)

make_case() {
  local name=$1 harness=${2:-pi} dir home specs worktree project fakebin id
  id=assign-name-z1
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  specs="$dir/specs"
  worktree="$dir/worktree"
  project="$dir/project"
  fakebin=$(fm_fakebin "$dir/fake")
  mkdir -p "$home/state" "$home/config" "$specs/atlas" "$worktree" "$project"
  printf '%s\n' "$specs" > "$home/config/specs"
  cat > "$home/state/$id.meta" <<EOF
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$worktree
project=$project
harness=$harness
kind=ship
spawn_gen=test-generation
session_name=manual before assignment
EOF
  "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id" \
    --state idle --source pi-ext --event test-idle >/dev/null
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_FAKE_DIR:?}
printf '%s\037' "$@" >> "$D/calls"
printf '\n' >> "$D/calls"
case "${1:-}" in
  capture-pane)
    cat "$D/composer"
    ;;
  send-keys)
    case "$*" in
      *' -l '*)
        [ ! -e "$D/fail-send" ] || exit 1
        literal=${@: -1}
        printf '%s\n' "$literal" >> "$D/literal"
        case "$literal" in /name\ *) printf '%s\n' "${literal#/name }" > "$D/pending-native-name" ;; esac
        printf '╭────────────╮\n│ > pending  │\n╰────────────╯\n' > "$D/composer"
        ;;
      *' Enter'*)
        if [ "${FM_FAKE_NATIVE_NO_APPLY:-0}" != 1 ] && [ -f "$D/pending-native-name" ]; then
          mv "$D/pending-native-name" "$D/native-name"
        fi
        if [ "${FM_FAKE_EMIT_SESSION_INFO:-0}" = 1 ] && [ -f "$D/pending-native-name" ]; then
          {
            printf 'spawn_gen=%s\n' "$FM_NAME_GEN"
            printf 'name=%s\n' "$(cat "$D/pending-native-name")"
          } > "$FM_NAME_STATE/$FM_NAME_ID.pi-name-confirmation"
        fi
        if [ "${FM_FAKE_KEEP_PENDING:-0}" = 1 ]; then
          printf '╭────────────╮\n│ > pending  │\n╰────────────╯\n' > "$D/composer"
        else
          printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$D/composer"
        fi
        ;;
    esac
    ;;
  display-message)
    case "$*" in
      *pane_title*)
        if [ -f "$D/native-name" ]; then
          printf 'π - %s - worktree\n' "$(cat "$D/native-name")"
        else
          printf 'π - %s - worktree\n' "${FM_FAKE_NATIVE_NAME:-Default}"
        fi
        ;;
      *cursor_y*) printf '1\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  : > "$dir/fake/calls"
  : > "$dir/fake/literal"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/fake/composer"
  printf '%s\n' "$dir|$home|$specs|$worktree|$project|$fakebin|$id"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR SPECS_DIR WORKTREE_DIR PROJECT_DIR FAKEBIN_DIR ID <<EOF
$1
EOF
  : "$WORKTREE_DIR" "$PROJECT_DIR"
}

event_json() {
  local assignment_id=$1 order=$2 ticket=$3 title=$4
  jq -cn \
    --arg assignmentId "$assignment_id" \
    --arg assignmentOrder "$order" \
    --arg atlasIdentity "$(cd "$SPECS_DIR" && pwd -P)" \
    --arg targetAgent "fm-$ID" \
    --arg targetTask "$ID" \
    --arg ticketId "$ticket" \
    --arg title "$title" \
    '{schema:"atlas.assignment.v1",$assignmentId,$assignmentOrder,$atlasIdentity,$targetAgent,$targetTask,$ticketId,$title}'
}

run_receiver() {
  local event=$1
  printf '%s\n' "$event" | FM_HOME="$HOME_DIR" FM_FAKE_DIR="$CASE_DIR/fake" \
    FM_NAME_STATE="$HOME_DIR/state" \
    FM_NAME_ID="$ID" FM_NAME_GEN=test-generation \
    FM_ASSIGNMENT_SUBMIT_RETRIES=2 FM_ASSIGNMENT_SUBMIT_SLEEP=0 \
    FM_ASSIGNMENT_SUBMIT_SETTLE=0 FM_ASSIGNMENT_CONFIRM_SLEEP=0 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$RECEIVER" accept
}

test_new_assignment_sets_exact_native_name_without_changing_pane_label() {
  local rec title event out status=0
  rec=$(make_case accepted)
  read_case "$rec"
  title="Ticket \$(touch $CASE_DIR/pwned); O'Brien, v2!"
  event=$(event_json assignment-101 101 c101 "$title")

  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "new assignment receiver"
  [ "$(printf '%s\n' "$out" | jq -r '.schema')" = firstmate.atlas-assignment.ack.v1 ] \
    || fail "receiver did not return the acknowledgment schema: $out"
  [ "$(printf '%s\n' "$out" | jq -r '.assignmentId + " " + .result')" = "assignment-101 accepted" ] \
    || fail "receiver did not accept the assignment: $out"
  assert_grep "session_name=$title" "$HOME_DIR/state/$ID.meta" \
    "assignment title was not durable in task metadata"
  assert_grep "/name $title" "$CASE_DIR/fake/literal" \
    "receiver did not submit the exact native Pi name"
  assert_grep "window=firstmate:fm-$ID" "$HOME_DIR/state/$ID.meta" \
    "receiver changed the pane label identity"
  assert_no_grep "rename-window\|select-pane.*-T\|set-option.*title" "$CASE_DIR/fake/calls" \
    "receiver invoked a terminal label mutation"
  [ ! -e "$CASE_DIR/pwned" ] || fail "assignment title was evaluated as shell text"
  pass "a committed assignment applies its exact title without changing the pane label"
}

test_pi_signed_uses_the_same_assignment_receiver_contract() {
  local rec title event out status=0
  rec=$(make_case signed pi-signed)
  read_case "$rec"
  title="Signed Pi assignment title"
  event=$(event_json assignment-125 125 c125 "$title")

  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "Pi-signed assignment receiver"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = accepted ] \
    || fail "Pi-signed assignment was not accepted: $out"
  assert_grep "/name $title" "$CASE_DIR/fake/literal" \
    "Pi-signed did not use the native assignment title"
  pass "Pi-signed uses the same exact assignment-title contract as Pi"
}

test_native_name_observation_confirms_a_slash_command_when_submit_state_is_ambiguous() {
  local rec title event out status=0
  rec=$(make_case native-confirm)
  read_case "$rec"
  title="Native confirmation, exact!"
  event=$(event_json assignment-150 150 c150 "$title")

  out=$(FM_FAKE_KEEP_PENDING=1 FM_FAKE_NATIVE_NAME="$title" run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "native name confirmation"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = accepted ] \
    || fail "a visible native name did not confirm the slash command: $out"
  assert_grep "session_name=$title" "$HOME_DIR/state/$ID.meta" \
    "the natively confirmed name was not durable"
  pass "a native Pi title confirms an otherwise ambiguous slash-command submission"
}

test_session_info_confirmation_accepts_without_a_terminal_title() {
  local rec title event out status=0
  rec=$(make_case event-confirm)
  read_case "$rec"
  title="Event-confirmed assignment title"
  event=$(event_json assignment-160 160 c160 "$title")

  out=$(FM_FAKE_NATIVE_NO_APPLY=1 FM_FAKE_EMIT_SESSION_INFO=1 run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "session_info_changed confirmation"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = accepted ] \
    || fail "a durable native name event did not confirm the assignment: $out"
  "$ROOT/bin/fm-session-name-sync.sh" --event "$HOME_DIR/state" "$ID" test-generation "$title" \
    || fail "the session_info_changed synchronizer did not accept the current task generation"
  assert_grep "session_name=$title" "$HOME_DIR/state/$ID.meta" \
    "the confirmed native name was not durable"
  [ ! -e "$HOME_DIR/state/$ID.pi-name-confirmation" ] \
    || fail "the native name confirmation record was not cleaned up"
  pass "a session_info_changed event confirms the exact name without a terminal title"
}

test_submit_confirmation_without_the_native_name_requests_a_retry() {
  local rec title event out status=0
  rec=$(make_case native-required)
  read_case "$rec"
  title="Must be natively confirmed"
  event=$(event_json assignment-175 175 c175 "$title")

  out=$(FM_FAKE_NATIVE_NO_APPLY=1 run_receiver "$event" 2>&1) || status=$?
  expect_code 75 "$status" "native-name confirmation requirement"
  [ "$(printf '%s\n' "$out" | tail -1 | jq -r '.result')" = retry ] \
    || fail "missing native name did not request a retry: $out"
  [ "$(jq -r '.delivery' "$HOME_DIR/state/$ID.atlas-assignment-name.json")" = pending ] \
    || fail "unconfirmed assignment did not remain pending"
  pass "a submitted Enter is not acceptance until the native Pi name is visible"
}

test_duplicate_stale_and_equal_order_events_keep_the_latest_name() {
  local rec first second manual event out status=0
  rec=$(make_case ordering)
  read_case "$rec"
  first="First ticket, exact!"
  second="Second ticket: O'Brien"
  manual="Captain's manual name"
  event=$(event_json assignment-201 201 c201 "$first")
  run_receiver "$event" >/dev/null || fail "could not apply the first assignment"

  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-session-name-sync.sh" "$ID" "$manual" \
    || fail "could not record the manual name"
  : > "$CASE_DIR/fake/literal"
  event=$(printf '%s' "$event" | jq -c '{title,ticketId,targetTask,targetAgent,atlasIdentity,assignmentOrder,assignmentId,schema,extra:"future"}')
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "semantic duplicate assignment"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = duplicate ] \
    || fail "semantic duplicate was not acknowledged: $out"
  assert_grep "session_name=$manual" "$HOME_DIR/state/$ID.meta" \
    "a duplicate assignment replaced the later manual name"
  [ ! -s "$CASE_DIR/fake/literal" ] \
    || fail "a duplicate assignment resubmitted an older title"

  event=$(event_json assignment-202 202 c202 "$second")
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "newer assignment"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = accepted ] \
    || fail "newer assignment was not accepted: $out"
  assert_grep "session_name=$second" "$HOME_DIR/state/$ID.meta" \
    "a newer assignment did not replace the manual name"
  : > "$CASE_DIR/fake/literal"

  event=$(event_json assignment-201 201 c201 "$first")
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "stale assignment"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = superseded ] \
    || fail "stale assignment was not acknowledged as superseded: $out"
  assert_grep "session_name=$second" "$HOME_DIR/state/$ID.meta" \
    "a stale assignment rolled back the newer title"
  [ ! -s "$CASE_DIR/fake/literal" ] \
    || fail "a stale assignment reached the Pi session"

  event=$(event_json assignment-202-conflict 202 c203 "Conflicting title")
  status=0
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 64 "$status" "equal-order assignment conflict"
  [ "$(printf '%s\n' "$out" | tail -1 | jq -r '.result')" = rejected ] \
    || fail "equal-order conflict was not rejected: $out"
  assert_grep "session_name=$second" "$HOME_DIR/state/$ID.meta" \
    "an equal-order conflict changed the current title"
  [ ! -s "$CASE_DIR/fake/literal" ] \
    || fail "an equal-order conflict reached the Pi session"
  pass "duplicate, stale, and conflicting events cannot replace a newer or manual name"
}

test_128_digit_stale_order_cannot_replace_the_current_title() {
  local rec current_order stale_order current_title stale_title event out status=0
  rec=$(make_case long-ordering)
  read_case "$rec"
  current_order="1$(printf '%0126d' 0)1"
  stale_order="1$(printf '%0127d' 0)"
  current_title="128-digit current title"
  stale_title="128-digit stale title"

  event=$(event_json assignment-251 "$current_order" c251 "$current_title")
  run_receiver "$event" >/dev/null || fail "could not apply the 128-digit current assignment"
  : > "$CASE_DIR/fake/literal"

  event=$(event_json assignment-250 "$stale_order" c250 "$stale_title")
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "128-digit stale assignment"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = superseded ] \
    || fail "a one-unit stale 128-digit assignment was not superseded: $out"
  assert_grep "session_name=$current_title" "$HOME_DIR/state/$ID.meta" \
    "a stale 128-digit assignment replaced the current title"
  [ ! -s "$CASE_DIR/fake/literal" ] \
    || fail "a stale 128-digit assignment reached the Pi session"
  pass "a one-unit stale 128-digit order cannot replace the current title"
}

test_busy_assignment_is_durable_and_retries_only_after_idle() {
  local rec title event out status=0
  rec=$(make_case busy-retry)
  read_case "$rec"
  title="Busy-safe ticket name"
  event=$(event_json assignment-301 301 c301 "$title")
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$ID" busy \
    --current-gen --source pi-ext --event test-busy >/dev/null

  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 75 "$status" "assignment while Pi is busy"
  [ "$(printf '%s\n' "$out" | tail -1 | jq -r '.result')" = retry ] \
    || fail "busy assignment did not request retry: $out"
  [ ! -s "$CASE_DIR/fake/literal" ] \
    || fail "busy assignment injected a native command during active work"
  assert_grep "session_name=$title" "$HOME_DIR/state/$ID.meta" \
    "busy assignment did not preserve its recovery name"
  [ "$(jq -r '.delivery' "$HOME_DIR/state/$ID.atlas-assignment-name.json")" = pending ] \
    || fail "busy assignment was not retained as pending"

  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$ID" idle \
    --current-gen --source pi-ext --event test-idle >/dev/null
  status=0
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "pending assignment retry after Pi becomes idle"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = accepted ] \
    || fail "idle retry was not accepted: $out"
  assert_grep "/name $title" "$CASE_DIR/fake/literal" \
    "idle retry did not submit the retained title"
  [ "$(jq -r '.delivery' "$HOME_DIR/state/$ID.atlas-assignment-name.json")" = submitted ] \
    || fail "idle retry did not record confirmed submission"
  pass "a busy assignment stays durable and submits only after verified idle"
}

test_invalid_missing_and_unrelated_targets_do_not_mutate_sessions() {
  local rec event out status=0 before
  rec=$(make_case target-errors)
  read_case "$rec"
  before=$(cat "$HOME_DIR/state/$ID.meta")

  event=$(event_json assignment-401 401 c401 "Wrong task")
  event=$(printf '%s' "$event" | jq -c '.targetTask="missing-task" | .targetAgent="fm-missing-task"')
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 75 "$status" "missing owned target"
  [ "$(printf '%s\n' "$out" | tail -1 | jq -r '.result')" = retry ] \
    || fail "missing target did not request retry: $out"
  [ ! -s "$CASE_DIR/fake/literal" ] || fail "missing target reached another Pi session"
  [ "$(cat "$HOME_DIR/state/$ID.meta")" = "$before" ] \
    || fail "missing target changed the existing task record"

  rm -f "$HOME_DIR/config/specs"
  event=$(event_json assignment-402 402 c402 "No Atlas binding")
  status=0
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 75 "$status" "missing Atlas binding"
  assert_contains "$out" "home $HOME_DIR has no verifiable config/specs pointer" \
    "missing Atlas binding did not name the affected home"
  [ ! -s "$CASE_DIR/fake/literal" ] || fail "unbound Atlas event reached a Pi session"

  rec=$(make_case unrelated codex)
  read_case "$rec"
  before=$(cat "$HOME_DIR/state/$ID.meta")
  event=$(event_json assignment-403 403 c403 "Pi-only title")
  status=0
  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "unrelated harness assignment"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = not-applicable ] \
    || fail "unrelated harness was not acknowledged as inapplicable: $out"
  [ "$(cat "$HOME_DIR/state/$ID.meta")" = "$before" ] \
    || fail "unrelated harness metadata changed"
  [ ! -e "$HOME_DIR/state/$ID.atlas-assignment-name.json" ] \
    || fail "unrelated harness received assignment-name state"
  [ ! -s "$CASE_DIR/fake/literal" ] || fail "unrelated harness received Pi input"
  pass "invalid, unbound, and unrelated targets cannot mutate another session"
}

test_oversized_event_rejects_with_its_assignment_identity() {
  local rec title event out status=0
  rec=$(make_case oversized)
  read_case "$rec"
  title=$(printf '%065600d' 0 | tr 0 x)
  event=$(event_json assignment-425 425 c425 "$title")

  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 64 "$status" "oversized assignment event"
  [ "$(printf '%s\n' "$out" | tail -1 | jq -r '.assignmentId + " " + .result')" = \
      'assignment-425 rejected' ] \
    || fail "oversized event acknowledgment lost its assignment identity: $out"
  [ ! -s "$CASE_DIR/fake/literal" ] \
    || fail "oversized event reached the native session"
  pass "an oversized event is rejected with its stable assignment identity"
}

test_receiver_revalidates_the_target_after_waiting_for_its_lock() {
  local rec event out lock held release lock_pid receiver_pid status=0
  rec=$(make_case endpoint-race)
  read_case "$rec"
  event=$(event_json assignment-450 450 c450 "Endpoint race title")
  lock="$HOME_DIR/state/.meta-$ID.lock"
  held="$CASE_DIR/lock-held"
  release="$CASE_DIR/lock-release"

  bash -c '
    set -u
    . "$1"
    fm_lock_acquire_wait "$2"
    : > "$3"
    while [ ! -f "$4" ]; do sleep 0.02; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$held" "$release" &
  lock_pid=$!
  for _ in $(seq 1 100); do
    [ ! -f "$held" ] || break
    sleep 0.02
  done
  [ -f "$held" ] || fail "could not hold the target metadata lock"

  run_receiver "$event" > "$CASE_DIR/receiver.out" 2>&1 &
  receiver_pid=$!
  sleep 0.2
  awk -F= '$1 == "harness" { print "harness=claude"; next } { print }' \
    "$HOME_DIR/state/$ID.meta" > "$CASE_DIR/meta.next"
  mv "$CASE_DIR/meta.next" "$HOME_DIR/state/$ID.meta"
  : > "$release"
  wait "$lock_pid" || fail "metadata lock holder failed"
  wait "$receiver_pid" || status=$?
  out=$(cat "$CASE_DIR/receiver.out")

  expect_code 0 "$status" "endpoint revalidation"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = not-applicable ] \
    || fail "changed target was not revalidated after lock wait: $out"
  [ ! -s "$CASE_DIR/fake/literal" ] \
    || fail "receiver sent a native command using pre-lock endpoint evidence"
  assert_grep 'session_name=manual before assignment' "$HOME_DIR/state/$ID.meta" \
    "receiver changed metadata after its target evidence became stale"
  pass "the receiver revalidates target ownership after waiting for metadata custody"
}

test_local_secondmate_uses_its_authoritative_parent_atlas_binding() {
  local rec parent event out status=0 title
  rec=$(make_case secondmate-binding)
  read_case "$rec"
  parent="$CASE_DIR/parent"
  title="Second mate's assigned ticket"
  mkdir -p "$parent/config"
  printf '%s\n' "$SPECS_DIR" > "$parent/config/specs"
  printf 'atlas-core\n' > "$HOME_DIR/.fm-secondmate-home"
  cat > "$HOME_DIR/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$parent
EOF
  rm -f "$HOME_DIR/config/specs"
  event=$(event_json assignment-501 501 c501 "$title")

  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "local second mate Atlas binding"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = accepted ] \
    || fail "local second mate assignment was not accepted: $out"
  assert_grep "session_name=$title" "$HOME_DIR/state/$ID.meta" \
    "second mate assignment title was not durable"
  pass "a local second mate resolves the Atlas store through its authoritative parent binding"
}

test_primary_receiver_resolves_one_registered_local_secondmate_task() {
  local rec child parent event out status=0 title
  rec=$(make_case parent-resolution)
  read_case "$rec"
  child=$HOME_DIR
  parent="$CASE_DIR/parent"
  title="Routed child ticket"
  mkdir -p "$parent/data" "$parent/state" "$parent/config"
  printf '%s\n' "$SPECS_DIR" > "$parent/config/specs"
  printf 'atlas-core\n' > "$child/.fm-secondmate-home"
  cat > "$child/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$parent
EOF
  cat > "$parent/data/secondmates.md" <<EOF
- atlas-core - Dashboard domain (home: $child; scope: dashboard; projects: dashboard; added 2026-09-07)
EOF
  rm -f "$child/config/specs"
  event=$(event_json assignment-601 601 c601 "$title")
  HOME_DIR=$parent

  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "primary receiver routing to a registered local second mate"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = accepted ] \
    || fail "registered child assignment was not accepted: $out"
  assert_grep "session_name=$title" "$child/state/$ID.meta" \
    "primary receiver did not update the registered child task"
  [ ! -e "$parent/state/$ID.meta" ] \
    || fail "primary receiver invented a parent task record"
  pass "the primary receiver resolves one exact task in a registered local second-mate home"
}

test_retry_recovers_a_crash_between_event_and_name_publication() {
  local rec title event old out status=0
  rec=$(make_case crash-recovery)
  read_case "$rec"
  title="Recovered assignment title"
  old="manual before assignment"
  event=$(event_json assignment-701 701 c701 "$title")
  printf '%s' "$event" | jq -cS --arg priorName "$old" \
    '. + {delivery:"stored",$priorName}' > "$HOME_DIR/state/$ID.atlas-assignment-name.json"

  out=$(run_receiver "$event" 2>&1) || status=$?
  expect_code 0 "$status" "stored assignment crash recovery"
  [ "$(printf '%s\n' "$out" | jq -r '.result')" = accepted ] \
    || fail "stored assignment was not recovered: $out"
  assert_grep "session_name=$title" "$HOME_DIR/state/$ID.meta" \
    "crash recovery did not publish the assignment name"
  assert_grep "/name $title" "$CASE_DIR/fake/literal" \
    "crash recovery did not submit the assignment name"
  pass "a retry completes an assignment stored before a receiver crash"
}

test_new_assignment_sets_exact_native_name_without_changing_pane_label
test_pi_signed_uses_the_same_assignment_receiver_contract
test_native_name_observation_confirms_a_slash_command_when_submit_state_is_ambiguous
test_session_info_confirmation_accepts_without_a_terminal_title
test_submit_confirmation_without_the_native_name_requests_a_retry
test_duplicate_stale_and_equal_order_events_keep_the_latest_name
test_128_digit_stale_order_cannot_replace_the_current_title
test_busy_assignment_is_durable_and_retries_only_after_idle
test_invalid_missing_and_unrelated_targets_do_not_mutate_sessions
test_oversized_event_rejects_with_its_assignment_identity
test_receiver_revalidates_the_target_after_waiting_for_its_lock
test_local_secondmate_uses_its_authoritative_parent_atlas_binding
test_primary_receiver_resolves_one_registered_local_secondmate_task
test_retry_recovers_a_crash_between_event_and_name_publication

echo "# all Atlas assignment-name tests passed"
