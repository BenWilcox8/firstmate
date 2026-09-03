#!/usr/bin/env bash
# tests/fm-send-busy-doorbell.test.sh - steering a worker whose pane is
# mid-turn must report the delivery it actually made.
#
# The defect these cases pin: on herdr, the rendered busy footer was allowed to
# answer the queued-Enter question only when the PRE-Enter native read was
# legibly idle. Live Claude keeps agent_status idle through a whole turn, so
# that footer is the only busy signal such a pane has; one non-idle or failed
# baseline read therefore disabled it, and a steer that had landed in a
# mid-turn pane was reported as a swallowed Enter.
#
# Every case drives a PUBLIC entry point over synthetic captures:
#   1. herdr, delivered while busy: the doorbell text is visible as queued
#      input in a mid-turn pane, and fm-send reports success.
#   2. herdr, provable swallow: the same queued text in an IDLE pane with no
#      busy footer still reports the unconfirmed submission.
#   3. herdr, durable record: a steer to a recorded task writes its inbox
#      record BEFORE the doorbell, keeps it whatever the doorbell verdict is,
#      and never types the payload itself.
#   4. tmux, unchanged: the reference backend keeps its busy and idle verdicts.
#   5. fm_composer_queued_enter_verdict, unchanged: the shared classifier stays
#      the one owner of the policy, converting only on a positive busy signal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

herdr_forget_inherited_pane
herdr_forget_inherited_home
unset HERDR_ENV HERDR_PANE_ID

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-busy-doorbell)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# --- synthetic captures ------------------------------------------------------
# A Claude-shaped pane, mid-turn, with the steer visible as queued input: the
# spinner row carries the verified busy token and the composer row holds the
# text. This is the capture the false swallow was read from.
screen_busy_with_queued_text() {  # <text>
  printf '%b\n' '\xe2\x9c\xbb Herding\xe2\x80\xa6 (esc to interrupt)'
  printf '  \xe2\x9d\xaf %s\n' "$1"
}

# The same composer row on a pane that is NOT working: no busy token anywhere,
# so the text sitting there is a provable swallow.
screen_idle_with_stuck_text() {  # <text>
  printf '  \xe2\x9d\xaf %s\n' "$1"
}

screen_idle_empty() {
  printf '  \xe2\x9d\xaf\n'
}

# The tmux reference backend reads a bordered composer box under its own
# cursor-aware classifier, so its captures carry that shape instead.
tmux_composer_box() {  # <text>
  local text=$1 width=30 pad i
  pad=$(printf '%*s' "$((width - 3 - ${#text}))" '')
  printf '\xe2\x95\xad'
  for ((i = 0; i < width; i++)); do printf '\xe2\x94\x80'; done
  printf '\xe2\x95\xae\n'
  printf '\xe2\x94\x82 > %s%s\xe2\x94\x82\n' "$text" "$pad"
  printf '\xe2\x95\xb0'
  for ((i = 0; i < width; i++)); do printf '\xe2\x94\x80'; done
  printf '\xe2\x95\xaf\n'
}

tmux_screen_busy_with_queued_text() {  # <text>
  tmux_composer_box "$1"
  printf '\xe2\x9c\xbb Working\xe2\x80\xa6 (esc to interrupt)\n'
}

tmux_screen_idle_with_stuck_text() {  # <text>
  tmux_composer_box "$1"
}

tmux_screen_idle_empty() {
  tmux_composer_box ""
}

# --- a behavior-driven fake herdr CLI ---------------------------------------
# Unlike the call-numbered fake in tests/fm-backend-herdr.test.sh, this one
# answers by BEHAVIOR, so a case stays readable when fm-send makes its own
# extra calls (endpoint validation, target-gone checks) around the submit.
#   FM_FAKE_SCREEN         file whose contents every `pane read` returns
#   FM_FAKE_AGENT_STATUS   file of agent_status answers, one per line, consumed
#                          in order with the last line sticky; an EMPTY line is
#                          a failed read (the CLI exits nonzero)
#   FM_FAKE_TYPED          file each `pane send-text` payload is appended to
#   FM_FAKE_KEYS           file each `pane send-keys` key is appended to
#   FM_FAKE_INBOX_DIR      optional; on every send-text the stub records how
#                          many durable inbox records exist at that moment, so
#                          write-before-doorbell ordering is observable
make_herdr_stub() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
cmd=${1:-}; sub=${2:-}; pane=${3:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.8.2","protocol":16},"server":{"running":true}}\n'
    exit 0 ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"t1","workspace_id":"w1"}}}\n' "$pane"
    exit 0 ;;
  "agent get")
    line=""
    if [ -n "${FM_FAKE_AGENT_STATUS:-}" ] && [ -f "$FM_FAKE_AGENT_STATUS" ]; then
      idx_file="$FM_FAKE_AGENT_STATUS.idx"
      idx=$(( $(cat "$idx_file" 2>/dev/null || echo 0) + 1 ))
      total=$(wc -l < "$FM_FAKE_AGENT_STATUS")
      [ "$idx" -le "$total" ] || idx=$total
      printf '%s\n' "$idx" > "$idx_file"
      line=$(sed -n "${idx}p" "$FM_FAKE_AGENT_STATUS")
    fi
    [ -n "$line" ] || exit 1
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$line"
    exit 0 ;;
  "pane read")
    cat "${FM_FAKE_SCREEN:?}"
    exit 0 ;;
  "pane send-text")
    printf '%s\n' "${4:-}" >> "${FM_FAKE_TYPED:?}"
    if [ -n "${FM_FAKE_INBOX_DIR:-}" ]; then
      n=0
      for f in "$FM_FAKE_INBOX_DIR"/*.msg; do [ -e "$f" ] && n=$((n + 1)); done
      printf 'records-at-doorbell=%s\n' "$n" >> "${FM_FAKE_TYPED:?}"
    fi
    exit 0 ;;
  "pane send-keys")
    printf '%s\n' "${4:-}" >> "${FM_FAKE_KEYS:?}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# A tmux stub with the same shape: the pane screen comes from a file, literal
# text is logged, and Enter is deliberately swallowed so the composer keeps
# holding the text through the whole retry budget.
make_tmux_stub() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    cat "${FM_FAKE_SCREEN:?}"; exit 0 ;;
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "${FM_FAKE_TYPED:?}"
    else
      printf '%s\n' "${1:-}" >> "${FM_FAKE_KEYS:?}"
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# count_records: how many durable inbox records the task holds.
count_records() {  # <inbox-dir>
  local dir=$1 n=0 f
  for f in "$dir"/*.msg; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

setup_case() {  # <name> -> echoes case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state"
  : > "$dir/typed"
  : > "$dir/keys"
  printf '%s\n' "$dir"
}

# run_send: fm-send with this case's stubbed backend, echoing its exit status.
run_send() {  # <case-dir> <err-file> [env=val...] -- <fm-send args...>
  local dir=$1 err=$2 status=0
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_FAKE_SCREEN="$dir/screen" FM_FAKE_TYPED="$dir/typed" FM_FAKE_KEYS="$dir/keys" \
    FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.01 \
    FM_BACKEND_HERDR_SUBMIT_POLLS=1 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err" || status=$?
  printf '%s' "$status"
}

# --- 1. herdr: delivered while busy -----------------------------------------

test_herdr_busy_pane_reports_the_delivery_it_made() {
  local dir status err
  dir=$(setup_case herdr-busy-native-flip)
  make_herdr_stub "$dir" >/dev/null
  err="$dir/err"
  screen_busy_with_queued_text "steer the fix" > "$dir/screen"
  # A genuinely mid-turn pane: native reports working before the Enter, then
  # falls back to the idle it keeps for most of a live Claude turn.
  printf 'working\nidle\n' > "$dir/agent-status"
  status=$(run_send "$dir" "$err" FM_FAKE_AGENT_STATUS="$dir/agent-status" -- default:w1:p2 "steer the fix")
  [ "$status" -eq 0 ] \
    || fail "a steer into a mid-turn herdr pane must exit successfully, got $status: $(cat "$err")"
  assert_not_contains "$(cat "$err")" "unconfirmed" "a delivered steer must not be reported as an unconfirmed submission"
  assert_contains "$(cat "$dir/typed")" "steer the fix" "the steer was never typed into the pane"
  pass "fm-send (herdr): a steer into a mid-turn pane whose queued text is still rendered reports success"
}

test_herdr_busy_pane_survives_an_unreadable_baseline_read() {
  local dir status err
  dir=$(setup_case herdr-busy-unreadable-baseline)
  make_herdr_stub "$dir" >/dev/null
  err="$dir/err"
  screen_busy_with_queued_text "steer the fix" > "$dir/screen"
  # The pre-Enter native read fails outright (an empty line is a failed read).
  # An unreadable baseline is not evidence the pane is free, so the rendered
  # busy footer must still be allowed to answer the queued-Enter question.
  printf '\nidle\n' > "$dir/agent-status"
  status=$(run_send "$dir" "$err" FM_FAKE_AGENT_STATUS="$dir/agent-status" -- default:w1:p2 "steer the fix")
  [ "$status" -eq 0 ] \
    || fail "one failed pre-Enter read must not turn a delivered steer into a swallow, got $status: $(cat "$err")"
  pass "fm-send (herdr): a failed pre-Enter native read does not disable the busy evidence a mid-turn pane still shows"
}

# --- 2. herdr: the provable swallow still fails ------------------------------

test_herdr_idle_pane_still_reports_the_swallow() {
  local dir status err
  dir=$(setup_case herdr-idle-swallow)
  make_herdr_stub "$dir" >/dev/null
  err="$dir/err"
  # Same queued text, no busy token anywhere, and native state agrees the pane
  # is idle: the Enter was swallowed and the caller must be told.
  screen_idle_with_stuck_text "steer the fix" > "$dir/screen"
  printf 'idle\n' > "$dir/agent-status"
  status=$(run_send "$dir" "$err" FM_FAKE_AGENT_STATUS="$dir/agent-status" -- default:w1:p2 "steer the fix")
  [ "$status" -eq 3 ] \
    || fail "text still held by an idle composer after the retry budget must stay unconfirmed, got $status: $(cat "$err")"
  assert_contains "$(cat "$err")" "unconfirmed" "the provable swallow lost its unconfirmed-delivery report"
  pass "fm-send (herdr): text provably left in an IDLE composer after the retry budget still reports the swallow"
}

test_herdr_busy_and_idle_verdicts_differ_on_the_same_composer_text() {
  local dir busy_status idle_status err
  dir=$(setup_case herdr-divergence)
  make_herdr_stub "$dir" >/dev/null
  err="$dir/err"
  printf 'working\nidle\n' > "$dir/agent-status"
  # Non-vacuity: the two halves differ ONLY in the pane's busy evidence, never
  # in the composer text or the native answers, so neither verdict can be
  # coming from a softened composer read.
  screen_busy_with_queued_text "steer the fix" > "$dir/screen"
  busy_status=$(run_send "$dir" "$err" FM_FAKE_AGENT_STATUS="$dir/agent-status" -- default:w1:p2 "steer the fix")
  printf '0\n' > "$dir/agent-status.idx"   # replay the same native answers for the idle half
  screen_idle_with_stuck_text "steer the fix" > "$dir/screen"
  idle_status=$(run_send "$dir" "$err" FM_FAKE_AGENT_STATUS="$dir/agent-status" -- default:w1:p2 "steer the fix")
  [ "$busy_status" -eq 0 ] || fail "the busy half of the divergence should succeed, got $busy_status"
  [ "$idle_status" -eq 3 ] || fail "the idle half of the divergence should stay unconfirmed, got $idle_status"
  pass "fm-send (herdr): the busy footer alone separates a delivered steer from a swallow on identical composer text"
}

# --- 3. herdr: the durable record owns the delivery --------------------------

test_herdr_task_steer_records_before_the_doorbell_and_keeps_it() {
  local dir status err records
  dir=$(setup_case herdr-task-record)
  make_herdr_stub "$dir" >/dev/null
  err="$dir/err"
  fm_write_meta "$dir/home/state/t1.meta" \
    "window=default:w1:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p2" \
    "endpoint_task_id=t1" "kind=ship" "harness=claude"
  # The worker is mid-turn with its composer clear, so the doorbell is rung.
  screen_busy_with_queued_text "" > "$dir/screen"
  printf 'working\nidle\n' > "$dir/agent-status"
  status=$(run_send "$dir" "$err" FM_FAKE_AGENT_STATUS="$dir/agent-status" \
    FM_FAKE_INBOX_DIR="$dir/home/state/t1.inbox" -- t1 "act on the queued instruction")
  [ "$status" -eq 0 ] || fail "a steer to a recorded task must exit 0, got $status: $(cat "$err")"
  records=$(count_records "$dir/home/state/t1.inbox")
  [ "$records" -eq 1 ] || fail "expected exactly one durable inbox record, found $records"
  assert_contains "$(cat "$dir/home/state/t1.inbox"/001.msg)" "act on the queued instruction" \
    "the durable record lost the steer's payload"
  assert_not_contains "$(cat "$dir/typed")" "act on the queued instruction" \
    "the payload was typed into the pane instead of being recorded"
  assert_contains "$(cat "$dir/typed")" "records-at-doorbell=1" \
    "the doorbell was rung before the durable record existed"
  pass "fm-send (herdr): a steer to a mid-turn worker records durably before the doorbell and keeps the record"
}

test_herdr_task_steer_keeps_its_record_when_the_doorbell_is_unconfirmed() {
  local dir status err records
  dir=$(setup_case herdr-task-record-swallow)
  make_herdr_stub "$dir" >/dev/null
  err="$dir/err"
  fm_write_meta "$dir/home/state/t1.meta" \
    "window=default:w1:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p2" \
    "endpoint_task_id=t1" "kind=ship" "harness=claude"
  # An idle pane whose composer holds leftover text: the doorbell is skipped or
  # unconfirmed, and the record must survive that verdict untouched.
  screen_idle_with_stuck_text "leftover" > "$dir/screen"
  printf 'idle\n' > "$dir/agent-status"
  status=$(run_send "$dir" "$err" FM_FAKE_AGENT_STATUS="$dir/agent-status" -- t1 "act on the queued instruction")
  [ "$status" -eq 0 ] || fail "the durable record is the delivery, so the send must still exit 0, got $status"
  records=$(count_records "$dir/home/state/t1.inbox")
  [ "$records" -eq 1 ] || fail "a doorbell verdict must never remove the durable record, found $records record(s)"
  pass "fm-send (herdr): no doorbell verdict removes the durable steering record"
}

# --- 4. tmux: the reference backend is unchanged -----------------------------

test_tmux_busy_and_idle_verdicts_are_unchanged() {
  local dir busy_status idle_status err
  dir=$(setup_case tmux-verdicts)
  make_tmux_stub "$dir" >/dev/null
  err="$dir/err"
  # tmux reads one busy signal, its rendered footer, and this change does not
  # touch it: a busy pane holding the typed text is a queued Enter, an idle one
  # is a swallow.
  tmux_screen_busy_with_queued_text "steer the fix" > "$dir/screen"
  busy_status=$(run_send "$dir" "$err" -- sess:win "steer the fix")
  [ "$busy_status" -eq 0 ] || fail "tmux busy-pane delivery should still exit 0, got $busy_status: $(cat "$err")"
  tmux_screen_idle_with_stuck_text "steer the fix" > "$dir/screen"
  idle_status=$(run_send "$dir" "$err" -- sess:win "steer the fix")
  [ "$idle_status" -eq 3 ] || fail "tmux idle-pane swallow should still exit 3, got $idle_status: $(cat "$err")"
  assert_contains "$(cat "$err")" "unconfirmed" "tmux lost its unconfirmed-delivery report"
  pass "fm-send (tmux): busy-queued Enter and provable swallow keep their existing verdicts"
}

test_tmux_landed_submit_is_unchanged() {
  local dir status err
  dir=$(setup_case tmux-landed)
  make_tmux_stub "$dir" >/dev/null
  err="$dir/err"
  tmux_screen_idle_empty > "$dir/screen"
  status=$(run_send "$dir" "$err" -- sess:win "steer the fix")
  [ "$status" -eq 0 ] || fail "a cleared tmux composer should still confirm delivery, got $status: $(cat "$err")"
  pass "fm-send (tmux): a cleared composer still confirms delivery"
}

# --- 5. the shared classifier keeps owning the policy ------------------------

test_queued_enter_verdict_policy_is_unchanged() {
  local out
  out=$(fm_composer_queued_enter_verdict pending busy)
  [ "$out" = empty ] || fail "proven pending plus busy must convert to empty, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending idle)
  [ "$out" = pending ] || fail "proven pending plus idle must stay a swallow, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending unknown)
  [ "$out" = pending ] || fail "an unreadable busy signal is not proof of a queue, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending)
  [ "$out" = pending ] || fail "a missing busy signal must never convert, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending-unproven busy)
  [ "$out" = pending-unproven ] || fail "an unproven composer must never receive the conversion, got '$out'"
  out=$(fm_composer_queued_enter_verdict unknown busy)
  [ "$out" = unknown ] || fail "an unreadable composer must never receive the conversion, got '$out'"
  out=$(fm_composer_queued_enter_verdict empty idle)
  [ "$out" = empty ] || fail "a cleared composer must pass through unchanged, got '$out'"
  pass "fm_composer_queued_enter_verdict: converts only on a positive busy signal, and only for proven pending text"
}

test_herdr_busy_pane_reports_the_delivery_it_made
test_herdr_busy_pane_survives_an_unreadable_baseline_read
test_herdr_idle_pane_still_reports_the_swallow
test_herdr_busy_and_idle_verdicts_differ_on_the_same_composer_text
test_herdr_task_steer_records_before_the_doorbell_and_keeps_it
test_herdr_task_steer_keeps_its_record_when_the_doorbell_is_unconfirmed
test_tmux_busy_and_idle_verdicts_are_unchanged
test_tmux_landed_submit_is_unchanged
test_queued_enter_verdict_policy_is_unchanged
