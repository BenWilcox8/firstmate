#!/usr/bin/env bash
# tests/fm-agent-count-live-e2e.test.sh - live guard for bin/fm-agent-count.sh.
# It opens real agent panes (every installed Claude, Codex, and Pi) in an
# isolated Herdr lab session, then closes one pane and exits one agent, and
# checks the count follows each change. No prompt is ever submitted, so the
# guard spends no model tokens and runs by default wherever its tools exist.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_AGENT_COUNT_LIVE_E2E herdr jq

LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || fail "the guarded Herdr lab helper is not executable"
SESSION=$("$LAB_HELPER" name agent-count) || fail "the guarded Herdr lab name could not be created"
TMP_ROOT=$(fm_test_tmproot fm-agent-count-live)
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
mkdir -p "$FAKEBIN"
TEARDOWN_PENDING=1

cleanup_all() {  # <exit-status>
  local status=$1
  trap - EXIT INT TERM
  if [ "$TEARDOWN_PENDING" -eq 1 ]; then
    if ! "$LAB_HELPER" teardown "$SESSION"; then
      printf 'not ok - the lab teardown or default-session tripwire failed during cleanup\n' >&2
      status=1
    fi
  fi
  fm_test_cleanup
  exit "$status"
}

trap 'cleanup_all $?' EXIT
trap 'cleanup_all 130' INT
trap 'cleanup_all 143' TERM

"$LAB_HELPER" provision "$SESSION" || fail "the isolated Herdr lab session could not be provisioned"

# The count under test calls `herdr ... --session <lab>`. This wrapper routes
# each call through the lab helper, which adds the lab session itself, and
# refuses any call that names another session.
export LAB_HELPER SESSION ORIGINAL_PATH
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

HOME_DIR="$TMP_ROOT/home"
WORK="$TMP_ROOT/work"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$WORK"

CREATE=$(lab workspace create --cwd "$WORK" --label fm-agent-count --no-focus) \
  || fail "the lab workspace could not be created"
SHELL_PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "the lab workspace pane could not be read"
WORKSPACE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.workspace_id') \
  || fail "the lab workspace id could not be read"

record_task() {  # <task> <harness> <pane>
  fm_write_meta "$HOME_DIR/state/$1.meta" "window=$SESSION:$3" "kind=ship" "harness=$2" \
    "backend=herdr" "worktree=$WORK" "herdr_session=$SESSION"
}

# A shell pane recorded as a task, and a parked task whose pane is closed:
# neither may ever count.
record_task shell-task claude "$SHELL_PANE"
record_task parked-task claude "$WORKSPACE:p999"

HARNESSES=()
PANES=()
for harness in claude codex pi; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf 'skip: live: %s absent\n' "$harness"
    continue
  fi
  out=$(lab tab create --workspace "$WORKSPACE" --cwd "$WORK" --label "fm-$harness" --no-focus) \
    || fail "a lab tab for $harness could not be created"
  pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id') \
    || fail "the lab pane for $harness could not be read: $out"
  lab pane run "$pane" "$harness" >/dev/null || fail "$harness could not be started in its lab pane"
  record_task "task-$harness" "$harness" "$pane"
  HARNESSES+=("$harness")
  PANES+=("$pane")
done
[ "${#HARNESSES[@]}" -gt 0 ] || fail "no agent harness is installed, so the live count checked nothing"

count_doc() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    PATH="$FAKEBIN:$ORIGINAL_PATH" "$ROOT/bin/fm-agent-count.sh" --json --session "$SESSION"
}

# wait_for_count <n> <label>: poll until the count is n, for up to 90 seconds.
wait_for_count() {
  local want=$1 label=$2 doc='' i
  for i in $(seq 1 90); do
    doc=$(count_doc 2>&1) && [ "$(printf '%s' "$doc" | jq -r '.count' 2>/dev/null)" = "$want" ] && {
      DOC=$doc
      return 0
    }
    sleep 1
  done
  fail "$label: the count did not reach $want within 90s"$'\n'"$doc"
}

wait_for_count "${#HARNESSES[@]}" "every open agent pane"
for i in "${!HARNESSES[@]}"; do
  [ "$(printf '%s' "$DOC" | jq -r --arg p "${PANES[$i]}" '.agents[] | select(.pane == $p) | .task')" = "task-${HARNESSES[$i]}" ] \
    || fail "the ${HARNESSES[$i]} pane was not counted as its task: $DOC"
done
assert_not_contains "$DOC" shell-task "a task pane running only a shell was counted"
assert_not_contains "$DOC" parked-task "a parked task with a closed pane was counted"
pass "live: every open agent pane (${HARNESSES[*]}) counts, and a shell pane and a parked task do not"

lab pane close "${PANES[0]}" >/dev/null || fail "the ${HARNESSES[0]} pane could not be closed"
wait_for_count $((${#HARNESSES[@]} - 1)) "after closing the ${HARNESSES[0]} pane"
assert_not_contains "$DOC" "task-${HARNESSES[0]}" "a closed pane still counted"
pass "live: closing the ${HARNESSES[0]} pane removes it from the count"

if [ "${#HARNESSES[@]}" -ge 2 ]; then
  info=$(lab pane process-info --pane "${PANES[1]}") || fail "the ${HARNESSES[1]} pane process could not be read"
  pgid=$(printf '%s' "$info" | jq -er '.result.process_info.foreground_process_group_id') \
    || fail "the ${HARNESSES[1]} foreground process group could not be read: $info"
  kill -TERM -- "-$pgid" 2>/dev/null || fail "the ${HARNESSES[1]} agent could not be stopped"
  wait_for_count $((${#HARNESSES[@]} - 2)) "after the ${HARNESSES[1]} agent exited"
  assert_not_contains "$DOC" "task-${HARNESSES[1]}" "a pane whose agent exited still counted"
  pass "live: an agent that exits in an open pane leaves the count"
fi

TEARDOWN_PENDING=0
"$LAB_HELPER" teardown "$SESSION" || fail "the lab teardown or default-session tripwire failed"
pass "live: the lab session was torn down and the default session is unchanged"
