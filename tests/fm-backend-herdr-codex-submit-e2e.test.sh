#!/usr/bin/env bash
# Opt-in real Codex and Herdr regression for the durable short-wake transport.
set -u

if [ "${FM_CODEX_HERDR_SUBMIT_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_HERDR_SUBMIT_LIVE_E2E=1 to run the Codex Herdr submit regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/herdr-test-safety.sh disable=SC1091
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
herdr_forget_inherited_home

command -v codex >/dev/null 2>&1 || { echo "skip: codex not found"; exit 0; }
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name c610-submit)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-c610-codex-submit.XXXXXX")
PROJECT="$LAB/project"
PANE_ID=
TARGET=

cleanup() {
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  if [ -n "$PANE_ID" ]; then
    fm_herdr_lab_cli "$SESSION" agent read "$PANE_ID" --source recent-unwrapped --lines 120 >&2 || true
  fi
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

agent_text_contains() {
  fm_herdr_lab_cli "$SESSION" agent read "$PANE_ID" --source recent-unwrapped --lines 200 2>/dev/null \
    | grep -Fq "$1"
}

wait_for_text() {
  local text=$1 attempt=0
  while [ "$attempt" -lt 60 ]; do
    if agent_text_contains "$text"; then
      return 0
    fi
    sleep 0.5
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_working() {
  fm_herdr_lab_cli "$SESSION" agent wait "$PANE_ID" --until working --timeout 10000 >/dev/null 2>&1
}

wait_for_settled() {
  fm_herdr_lab_cli "$SESSION" agent wait "$PANE_ID" --until idle --until 'done' --timeout 30000 >/dev/null 2>&1
}

submit_and_require_response() {
  local name=$1 prompt=$2 response=$3 verdict
  verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$prompt" 3 0.4 0.3)
  if [ "$verdict" = empty ] && wait_for_text "$response"; then
    pass "$name submitted autonomously with a verified empty verdict"
    wait_for_settled || fail "$name did not settle after its verified response"
    return 0
  fi

  if ! agent_text_contains "$response"; then
    fm_herdr_lab_cli "$SESSION" agent send-keys "$PANE_ID" enter >/dev/null 2>&1 \
      || fail "$name could not send the isolated manual-success Enter"
    if wait_for_text "$response"; then
      fail "$name required a later Enter after verdict=$verdict"
    fi
  fi
  fail "$name did not produce a verified autonomous submission (verdict=$verdict)"
}

require_durable_short_wake() {
  local state=$1 padding=$2 verdict=failed notes expected expected_sha note_id
  local note saved saved_sha
  mkdir -p "$state"
  : > "$state/.afk"
  escalate_add "$state" \
    "FIRSTMATE_OP isolated transport test. Context: $padding After the active command, reply with the result of joining C610 BUSY LONG OK with underscore separators."
  expected=$(escalate_digest "$state") || fail "could not construct the expected durable digest"
  expected_sha=$(_sha256_text "$expected")

  FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-inbox.sh" note "C610 unrelated durable note" >/dev/null \
    || fail "could not seed the unrelated durable note"

  mkdir -p "$PROJECT/bin"
  # Expand these variables when the generated fixture runs.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -eu' \
    "expected='$expected_sha'" \
    'selected=' \
    "for note in '$state/inbox/'*.note; do" \
    '  saved=$(awk '\''seen { print } /^--$/ { seen=1 }'\'' "$note")' \
    '  actual=$(printf '\''%s'\'' "$saved" | sha256sum | cut -d '\'' '\'' -f1)' \
    '  if [ "$actual" = "$expected" ]; then selected=$note; break; fi' \
    'done' \
    '[ -n "$selected" ]' \
    'id=${selected##*/}' \
    'id=${id%.note}' \
    'printf '\''C610_DURABLE_DIGEST_OK note=%s sha256=%s\n'\'' "$id" "$actual"' \
    > "$PROJECT/bin/fm-wake-drain.sh"
  chmod +x "$PROJECT/bin/fm-wake-drain.sh"

  [ "$(fm_backend_herdr_busy_state "$TARGET")" = busy ] \
    || fail "Codex was not working when the record-specific short wake started"

  if FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$state" \
    FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" \
    FM_DAEMON_PRIMARY_HARNESS=codex \
    escalate_flush "$state" busy-override; then
    verdict=empty
  fi

  notes=$(find "$state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  note_id=$INJECT_DURABLE_NOTE_ID
  note="$state/inbox/$note_id.note"
  saved=$(awk 'seen { print } /^--$/ { seen=1 }' "$note" 2>/dev/null || true)
  saved_sha=$(_sha256_text "$saved")
  if [ "$verdict" != empty ] && [ -s "$state/.subsuper-escalations" ]; then
    fm_herdr_lab_cli "$SESSION" agent send-keys "$PANE_ID" enter >/dev/null 2>&1 \
      || fail "could not send the isolated manual-success Enter"
    if wait_for_text "C610_BUSY_LONG_OK"; then
      fail "busy long digest required a later Enter instead of a durable short wake (notes=$notes)"
    fi
  fi
  [ "$verdict" = empty ] || fail "durable short wake was not autonomously submitted (verdict=$verdict)"
  [ "$notes" -eq 2 ] || fail "durable transport did not retain one unrelated and one staged note (notes=$notes)"
  [ -n "$note_id" ] || fail "durable transport returned no note ID"
  [ "$saved" = "$expected" ] || fail "saved note bytes differed from the source digest"
  [ "$saved_sha" = "$expected_sha" ] || fail "saved note SHA-256 differed from the source digest"
  wait_for_text "Durable captain inbox note $note_id" \
    || fail "Codex transcript did not contain the record-specific short wake"
  wait_for_text "C610_DURABLE_DIGEST_OK" || fail "Codex did not read and verify the saved digest"
  wait_for_text "note=$note_id" || fail "Codex drain selected a different durable note"
  wait_for_text "$expected_sha" || fail "Codex did not surface the saved digest SHA-256"
  wait_for_settled || fail "controlled busy turn and durable short wake did not settle"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "confirmed short wake did not clear its source buffer"
  pass "busy long digest matched sha256=$expected_sha and Codex read it through note $note_id"
}

start_busy_turn() {
  local words=$1 response=$2
  fm_herdr_lab_cli "$SESSION" agent prompt "$PANE_ID" \
    "Run sleep 8 in the foreground. Then reply with the result of joining $words with underscore separators. Do not access project files." \
    >/dev/null 2>&1 || fail "could not start the controlled busy turn"
  wait_for_working || fail "Codex did not enter working state"
  agent_text_contains "$response" && fail "busy-turn response appeared before the submit probe"
}

mkdir -p "$PROJECT"
git -C "$PROJECT" init -q

fm_herdr_lab_provision "$SESSION" || fail "could not provision isolated Herdr lab session"

export HERDR_SESSION="$SESSION"
export FM_BACKEND_HERDR_AXI_BIN=
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6

# shellcheck source=bin/backends/herdr.sh disable=SC1091
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=bin/fm-supervise-daemon.sh disable=SC1091
. "$ROOT/bin/fm-supervise-daemon.sh"

workspace=$(fm_herdr_lab_cli "$SESSION" workspace create --cwd "$PROJECT" --label c610-submit --no-focus) \
  || fail "could not create the isolated workspace"
PANE_ID=$(printf '%s' "$workspace" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE_ID" ] || fail "workspace creation did not return a pane"
TARGET="$SESSION:$PANE_ID"

start_out=$(fm_herdr_lab_cli "$SESSION" agent start c610-submit-codex --kind codex --pane "$PANE_ID" --timeout 120000 -- \
  --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox \
  -c 'model_reasoning_effort="low"' 2>&1)
start_rc=$?
if [ "$start_rc" -ne 0 ]; then
  trust_screen=$(fm_herdr_lab_cli "$SESSION" agent read "$PANE_ID" --source visible --lines 40 2>/dev/null || true)
  case "$trust_screen" in
    *"Do you trust the contents of this directory?"*"1. Yes, continue"*) ;;
    *) fail "Codex startup failed outside the recognized trust dialog: $start_out" ;;
  esac
  fm_herdr_lab_cli "$SESSION" agent send-keys "$PANE_ID" enter >/dev/null 2>&1 \
    || fail "could not accept the isolated Codex trust dialog"
  fm_herdr_lab_cli "$SESSION" agent wait "$PANE_ID" --until idle --until 'done' --timeout 60000 >/dev/null 2>&1 \
    || fail "Codex did not become ready after the isolated trust decision"
fi

for _ in $(seq 1 60); do
  [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] && break
  sleep 0.5
done
[ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] \
  || fail "Codex composer did not become empty"

submit_and_require_response \
  "idle short prompt" \
  "Reply with the result of joining C610 IDLE SHORT OK with underscore separators. Do not access project files." \
  "C610_IDLE_SHORT_OK"

start_busy_turn "C610 BUSY ONE DONE" "C610_BUSY_ONE_DONE"
submit_and_require_response \
  "busy short prompt" \
  "After the active command, reply with the result of joining C610 BUSY SHORT OK with underscore separators." \
  "C610_BUSY_SHORT_OK"

wait_for_settled || fail "busy short prompt did not settle before the next turn"
start_busy_turn "C610 BUSY TWO DONE" "C610_BUSY_TWO_DONE"
padding=$(printf '%04096d' 0 | tr 0 x)
require_durable_short_wake "$LAB/state" "$padding"

pass "real Codex Herdr path preserved the full digest while submitting only the short wake"
