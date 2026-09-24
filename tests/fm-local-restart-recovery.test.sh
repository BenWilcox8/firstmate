#!/usr/bin/env bash
# Behavior coverage for the restart-recovery fork seams.
#
# bin/fm-local-restart-recovery.sh owns restart detection and the boot unit's
# recovery pass; bin/fm-local-dormant.sh owns the durable dormant marker. This
# suite drives both through their CLIs with a fake Herdr that answers only the
# status and session reads, plus the upstream seams through the real scripts
# that carry their hook lines:
#   - restart-record: bin/fm-session-start.sh records the restart fingerprint at
#     a locked start and prints one RESTART line when it changed.
#   - secondmate-liveness-skip: bin/fm-bootstrap.sh's startup liveness sweep
#     leaves a dormant second mate down, and leaves every second mate to a
#     restart recovery pass that is running.
#   - secondmate-liveness-serial: the same sweep relaunches second mates one at
#     a time.
# The Herdr lifecycle proof (a real lab restart, in-place relaunches, the
# manual-relaunch guard) lives in tests/fm-local-restart-recovery-herdr-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-restart-recovery)
RR="$ROOT/bin/fm-local-restart-recovery.sh"
DORMANT="$ROOT/bin/fm-local-dormant.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-"$(fm_test_core_path):/usr/bin:/bin:/usr/sbin:/sbin"}
fm_git_identity fmtest fmtest@example.invalid

# make_fake_herdr <dir>: a Herdr that answers `status --json` (running while
# <dir>/running exists), `session list --json` (one default session whose
# socket is <dir>/herdr.sock), and `workspace list`. With FM_TEST_HERDR_PANE_SHELL
# set to the pid of a real idle bash, it also reads every pane as present, with
# that shell alone in it and no agent, in the directory FM_TEST_HERDR_PANE_CWD.
# With FM_TEST_HERDR_HOLDER set to a claude-named bash, the first `pane get`
# also starts it as a detached stand-in in FM_TEST_HERDR_PANE_CWD and writes its
# pid to
# <dir>/holder.pid. Every other call is logged to <dir>/unexpected and fails,
# because nothing may be typed into a pane here.
make_fake_herdr() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_TEST_HERDR_DIR:?}
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
case "${args[0]:-} ${args[1]:-}" in
  "status --json")
    if [ -e "$dir/running" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  "session list")
    printf '{"sessions":[{"name":"default","default":true,"running":true,"socket_path":"%s"}]}\n' "$dir/herdr.sock"
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"w9","label":"fleet"}]}}\n'
    ;;
  "pane get")
    [ -n "${FM_TEST_HERDR_PANE_SHELL:-}" ] || { printf '%s\n' "${args[*]}" >> "$dir/unexpected"; exit 1; }
    if [ -n "${FM_TEST_HERDR_HOLDER:-}" ] && [ ! -e "$dir/holder.pid" ]; then
      mkfifo "$dir/holder.fifo"
      (cd "$FM_TEST_HERDR_PANE_CWD" && exec "$FM_TEST_HERDR_HOLDER" -c 'read -r -t 60 _ <> "$0"' "$dir/holder.fifo") >/dev/null 2>&1 < /dev/null &
      printf '%s\n' "$!" > "$dir/holder.pid"
    fi
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "${args[2]}" "$FM_TEST_HERDR_PANE_CWD"
    ;;
  "agent get")
    [ -n "${FM_TEST_HERDR_PANE_SHELL:-}" ] || { printf '%s\n' "${args[*]}" >> "$dir/unexpected"; exit 1; }
    printf '{"error":{"code":"agent_not_found"}}\n'
    ;;
  "pane process-info")
    [ -n "${FM_TEST_HERDR_PANE_SHELL:-}" ] || { printf '%s\n' "${args[*]}" >> "$dir/unexpected"; exit 1; }
    shell=$FM_TEST_HERDR_PANE_SHELL
    pgid=$(ps -o pgid= -p "$shell" | tr -d ' ')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv0":"bash","argv":["bash"]}]}}}\n' \
      "${args[3]}" "$shell" "$pgid" "$shell"
    ;;
  *)
    printf '%s\n' "${args[*]}" >> "$dir/unexpected"
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# new_world <name>: a primary home with a fake Herdr, a boot id file, and a
# Herdr socket stand-in. Echoes the world directory.
new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config" "$w/herdr"
  make_fake_herdr "$w/herdr" >/dev/null
  printf 'boot-1\n' > "$w/boot_id"
  printf 'um-1\n' > "$w/user_manager"
  : > "$w/herdr/herdr.sock"
  touch -d @1790000000 "$w/herdr/herdr.sock"
  : > "$w/herdr/running"
  printf '%s\n' "$w"
}

# rr <world> <args...>: run the recovery CLI against <world> with every
# ambient Herdr pane marker removed, so this suite never reads the terminal it
# was started from.
rr() {
  local w=$1
  shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
    PATH="$w/herdr/fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_RESTART_BOOT_ID_FILE="$w/boot_id" \
    FM_RESTART_USER_MANAGER_ID="$(cat "$w/user_manager")" \
    FM_TEST_HERDR_DIR="$w/herdr" \
    FM_RESTART_HERDR_WAIT="${FM_RESTART_HERDR_WAIT:-5}" FM_RESTART_POLL=0.2 \
    "$RR" "$@"
}

# start_stand_in <claude> <cwd> <fifo>: start a stand-in Claude process in
# <cwd> in the background; $! is its pid. It waits on <fifo> with bash builtins
# only, so killing it leaves no child process behind.
start_stand_in() {
  mkfifo "$3"
  # shellcheck disable=SC2016 # the stand-in's own bash expands $0
  (cd "$2" && exec "$1" -c 'read -r -t 60 _ <> "$0"' "$3") >/dev/null 2>&1 < /dev/null &
}

restart_wakes() {  # <world> <key-prefix>
  awk -F '\t' -v p="$2" 'index($4, p) == 1' "$1/home/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' '
}

test_fingerprint_reports_the_three_restart_signals() {
  local w out
  w=$(new_world fingerprint)
  out=$(rr "$w" fingerprint) || fail "fingerprint failed: $out"
  assert_contains "$out" "boot_id=boot-1" "the boot id was not reported"
  assert_contains "$out" "user_manager=um-1" "the user manager invocation was not reported"
  assert_contains "$out" "herdr_session=default" "the Herdr session was not reported"
  assert_contains "$out" "herdr_start=1790000000" "the Herdr server start time was not reported"
  pass "fingerprint: boot id, user manager invocation, and Herdr server start time"
}

test_record_names_each_restart_kind_once() {
  local w out
  w=$(new_world record-kinds)
  out=$(rr "$w" record) || fail "the first record failed: $out"
  assert_not_contains "$out" "RESTART" "a first record has no baseline to compare, so it must not report a restart"
  [ -f "$w/home/state/.restart-fingerprint" ] || fail "record did not store the fingerprint"
  out=$(rr "$w" record)
  [ -z "$out" ] || fail "an unchanged fingerprint must record silently: $out"

  printf 'um-2\n' > "$w/user_manager"
  out=$(rr "$w" record)
  assert_contains "$out" "RESTART: user service manager restart" "a new user manager invocation was not reported"
  out=$(rr "$w" record)
  [ -z "$out" ] || fail "the same restart must be reported once, at the first record after it: $out"

  touch -d @1790000100 "$w/herdr/herdr.sock"
  out=$(rr "$w" record)
  assert_contains "$out" "RESTART: Herdr server restart" "a new Herdr server start was not reported"

  printf 'boot-2\n' > "$w/boot_id"
  printf 'um-3\n' > "$w/user_manager"
  touch -d @1790000200 "$w/herdr/herdr.sock"
  out=$(rr "$w" record)
  assert_contains "$out" "RESTART: machine reboot" "a new boot id was not reported as a reboot"
  assert_not_contains "$out" "user service manager" "a reboot must be named once, as the widest restart"
  [ ! -e "$w/home/state/.primary-endpoint" ] || fail "a session outside a Herdr pane must not leave a primary endpoint record"
  pass "record: each restart kind is named once, reboot first"
}

test_record_in_a_secondmate_home_points_at_the_primary() {
  local w out
  w=$(new_world record-secondmate)
  printf 'sm\n' > "$w/home/.fm-secondmate-home"
  rr "$w" record >/dev/null || fail "the first record in a second mate home failed"
  printf 'boot-2\n' > "$w/boot_id"
  out=$(rr "$w" record)
  assert_contains "$out" "RESTART: machine reboot" "a second mate home did not report the reboot"
  assert_not_contains "$out" "No restart recovery pass ran" \
    "a second mate home has no recovery ledger, so it must not claim that no pass ran"
  assert_contains "$out" "The primary firstmate's home runs restart recovery" \
    "a second mate home must point at the primary home's restart recovery"
  pass "record: a second mate home points at the primary home's restart recovery"
}

test_record_captures_the_primary_endpoint_in_a_herdr_pane() {
  local w claude_bin cfg inner out sid rec
  if [ ! -r /proc/self/stat ]; then
    printf 'skip: primary endpoint capture needs /proc\n'
    return 0
  fi
  w=$(new_world endpoint)
  claude_bin=$(fm_fakebin "$w/harness")
  ln -s "$(fm_test_tool bash)" "$claude_bin/claude"
  cfg="$w/claude-config"
  mkdir -p "$cfg/sessions"
  sid=0b7c1d2e-3f40-4a5b-8c6d-7e8f9a0b1c2d
  inner="$w/inner.sh"
  cat > "$inner" <<'SH'
set -u
start=$(sed 's/^.*) //' "/proc/$$/stat" | awk '{ print $20 }')
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s"}\n' \
  "$$" "$FM_TEST_SID" "$FM_HOME" "$start" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
"$FM_TEST_RR" record
SH
  env -u HERDR_SOCKET_PATH -u HERDR_TAB_ID \
    PATH="$w/herdr/fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_RESTART_BOOT_ID_FILE="$w/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
    FM_TEST_HERDR_DIR="$w/herdr" FM_TEST_RR="$RR" FM_TEST_SID="$sid" \
    CLAUDE_CONFIG_DIR="$cfg" HERDR_ENV=1 HERDR_PANE_ID=w9:p3 HERDR_WORKSPACE_ID=w9 \
    HERDR_SESSION=default \
    "$claude_bin/claude" "$inner" --dangerously-skip-permissions --resume >/dev/null 2>&1 \
    || fail "record inside the claude-named harness failed"
  rec="$w/home/state/.primary-endpoint"
  [ -f "$rec" ] || fail "record inside a Herdr pane did not write the primary endpoint"
  out=$(cat "$rec")
  assert_contains "$out" "backend=herdr" "the endpoint backend was not recorded"
  assert_contains "$out" "herdr_session=default" "the endpoint session was not recorded"
  assert_contains "$out" "pane=w9:p3" "the endpoint pane was not recorded"
  assert_contains "$out" "workspace=w9" "the endpoint workspace was not recorded"
  assert_contains "$out" "workspace_label=fleet" "the endpoint workspace label was not recorded"
  assert_contains "$out" "cwd=$w/home" "the home the primary runs in was not recorded"
  assert_contains "$out" "harness=claude" "the primary harness was not recorded"
  assert_contains "$out" "native_session=$sid" "the primary's Claude session was not recorded"
  assert_contains "$out" "claude_config=$cfg" "the primary's Claude configuration was not recorded"
  assert_contains "$out" "boot_id=boot-1" "the endpoint was not bound to its boot"
  assert_contains "$out" "arg=--dangerously-skip-permissions" "the primary's launch flags were not recorded"
  pass "record: a primary in a Herdr pane records its pane, harness, launch flags, and native session"

  # The relaunch replays the recorded flags, drops the recorded session
  # selector, and resumes the recorded session only while its transcript exists.
  local line desc
  line=$(FM_HOME="$w/home" "$RR" launch-line 2> "$w/desc") || fail "launch-line failed: $(cat "$w/desc")"
  desc=$(cat "$w/desc")
  assert_contains "$line" "'--dangerously-skip-permissions'" "the relaunch dropped a recorded launch flag"
  assert_not_contains "$line" "'--resume'" "the relaunch replayed the recorded session picker flag"
  assert_not_contains "$line" "--resume '$sid'" "the relaunch resumed a session whose transcript does not exist"
  assert_contains "$line" "encode session-start" "the relaunch did not carry the session-start operational input"
  assert_contains "$line" "CLAUDE_CONFIG_DIR='$cfg'" "the relaunch did not keep the primary's Claude configuration"
  assert_contains "$desc" "fresh Claude session" "a missing transcript must start a fresh session"
  mkdir -p "$cfg/projects/home"
  printf '{}\n' > "$cfg/projects/home/$sid.jsonl"
  line=$(FM_HOME="$w/home" "$RR" launch-line 2> "$w/desc") || fail "launch-line failed: $(cat "$w/desc")"
  assert_contains "$line" "--resume '$sid'" "the relaunch did not resume the recorded session"
  assert_contains "$(cat "$w/desc")" "resuming Claude session $sid" "the relaunch did not say it resumes"
  pass "launch-line: recorded flags replayed, session selector dropped, recorded session resumed only when on disk"

  # A primary that restart recovery itself relaunched carries the earlier
  # session-start prompt and session selector; the next relaunch replays
  # neither, so the harness never gets two prompts.
  local prompt
  prompt=$(printf 'Run the session start now.\n' | "$ROOT/bin/fm-operational-input.sh" encode session-start) \
    || fail "could not encode the session-start fixture prompt"
  env -u HERDR_SOCKET_PATH -u HERDR_TAB_ID \
    PATH="$w/herdr/fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_RESTART_BOOT_ID_FILE="$w/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
    FM_TEST_HERDR_DIR="$w/herdr" FM_TEST_RR="$RR" FM_TEST_SID="$sid" \
    CLAUDE_CONFIG_DIR="$cfg" HERDR_ENV=1 HERDR_PANE_ID=w9:p3 HERDR_WORKSPACE_ID=w9 \
    HERDR_SESSION=default \
    "$claude_bin/claude" "$inner" --dangerously-skip-permissions --resume "$sid" "$prompt" >/dev/null 2>&1 \
    || fail "record inside the relaunched claude-named harness failed"
  line=$(FM_HOME="$w/home" "$RR" launch-line 2> "$w/desc") || fail "launch-line failed: $(cat "$w/desc")"
  assert_not_contains "$line" "FIRSTMATE_OP" "the relaunch replayed the earlier session-start prompt"
  assert_contains "$line" "'--dangerously-skip-permissions' --resume '$sid' \"\$(" \
    "the relaunch did not replay only the launch flags before its own resume and prompt"
  pass "launch-line: a primary that recovery relaunched is relaunched again without its earlier prompt"

  printf 'sm\n' > "$w/home/.fm-secondmate-home"
  rm -f "$rec"
  env PATH="$w/herdr/fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_RESTART_BOOT_ID_FILE="$w/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
    FM_TEST_HERDR_DIR="$w/herdr" FM_TEST_RR="$RR" FM_TEST_SID="$sid" \
    CLAUDE_CONFIG_DIR="$cfg" HERDR_ENV=1 HERDR_PANE_ID=w9:p3 HERDR_WORKSPACE_ID=w9 \
    "$claude_bin/claude" "$inner" >/dev/null 2>&1 || fail "record in a second mate home failed"
  [ ! -e "$rec" ] || fail "a second mate home must not write a primary endpoint record"
  rm -f "$w/home/.fm-secondmate-home"
  pass "record: a second mate home keeps no primary endpoint record"
}

test_run_acts_only_after_a_recorded_restart() {
  local w out rc
  w=$(new_world run-gate)
  out=$(rr "$w" run 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a run with no recorded baseline must exit 0: $out"
  assert_contains "$out" "no restart baseline" "a run with no baseline must say why it did nothing"
  [ "$(restart_wakes "$w" restart-recovery)" = 0 ] || fail "a run with no baseline must not wake firstmate"

  rr "$w" record >/dev/null
  out=$(rr "$w" run 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a run with no restart must exit 0: $out"
  assert_contains "$out" "no restart since the last session start" "a run without a restart must say so"
  [ "$(restart_wakes "$w" restart-recovery)" = 0 ] || fail "a run without a restart must not wake firstmate"
  [ ! -s "$w/herdr/unexpected" ] || fail "a run without a restart touched Herdr panes: $(cat "$w/herdr/unexpected")"
  pass "run: nothing happens without a recorded baseline and a detected restart"
}

test_run_waits_for_herdr_with_a_bound() {
  local w out rc
  w=$(new_world herdr-wait)
  rr "$w" record >/dev/null
  printf 'boot-2\n' > "$w/boot_id"
  rm -f "$w/herdr/running"
  out=$(FM_RESTART_HERDR_WAIT=1 rr "$w" run 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "a run whose Herdr never answers must exit 4, got $rc: $out"
  assert_contains "$out" "Herdr did not answer" "the Herdr wait timeout was not reported"
  [ "$(restart_wakes "$w" restart-recovery)" = 1 ] || fail "an unreachable Herdr must leave one durable wake"
  out=$(FM_RESTART_HERDR_WAIT=1 rr "$w" run 2>&1)
  [ "$(restart_wakes "$w" restart-recovery)" = 1 ] || fail "a Herdr that stays unreachable must not add a wake per attempt"
  pass "run: an unreachable Herdr ends the pass within its bound, with one wake"
}

test_run_is_single_flight_per_restart() {
  local w out rc bg bg_out
  w=$(new_world single-flight)
  rr "$w" record >/dev/null
  printf 'boot-2\n' > "$w/boot_id"

  # A pass that is still waiting for Herdr holds the recovery for this boot, so
  # a second invocation (the captain starting the unit by hand, or Herdr's own
  # restart pulling it in) must not start another.
  rm -f "$w/herdr/running"
  bg_out="$w/bg.out"
  FM_RESTART_HERDR_WAIT=20 rr "$w" run > "$bg_out" 2>&1 &
  bg=$!
  sleep 1
  out=$(rr "$w" run 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a concurrent run must exit 0: $out"
  assert_contains "$out" "another restart recovery pass is running" "a concurrent run was not refused as single-flight"
  : > "$w/herdr/running"
  wait "$bg" || fail "the first pass failed: $(cat "$bg_out")"
  assert_contains "$(cat "$bg_out")" "restart recovery after machine reboot" "the first pass did not finish its recovery"
  [ "$(restart_wakes "$w" restart-recovery:)" = 1 ] || fail "one finished pass must leave exactly one summary wake"

  out=$(rr "$w" run 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a run after a finished pass must exit 0: $out"
  assert_contains "$out" "already recovered" "a second run for the same restart was not recognized"
  [ "$(restart_wakes "$w" restart-recovery:)" = 1 ] || fail "a second run for the same restart must not add a wake"
  pass "run: one recovery pass per restart, and a concurrent run never starts a second"
}

test_run_rate_limits_a_restart_loop_with_one_alert() {
  local w out rc i
  w=$(new_world rate-limit)
  rr "$w" record >/dev/null
  for i in 2 3; do
    printf 'boot-%s\n' "$i" > "$w/boot_id"
    out=$(rr "$w" run 2>&1) || fail "pass $i failed: $out"
  done
  printf 'boot-4\n' > "$w/boot_id"
  out=$(rr "$w" run 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "the third pass inside the window must be refused with exit 3, got $rc: $out"
  assert_contains "$out" "rate limit" "the rate limit refusal was not reported"
  [ "$(restart_wakes "$w" restart-recovery-alert)" = 1 ] || fail "the first refused pass must raise exactly one alert"
  printf 'boot-5\n' > "$w/boot_id"
  out=$(rr "$w" run 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a later pass inside the window must still be refused, got $rc: $out"
  [ "$(restart_wakes "$w" restart-recovery-alert)" = 1 ] || fail "a restart loop must alert once per window, not per restart"
  [ "$(restart_wakes "$w" restart-recovery:)" = 2 ] || fail "only the two allowed passes may leave summary wakes"
  pass "run: a restart loop stops after the rate limit with one alert"
}

test_run_leaves_a_primary_that_already_runs_elsewhere() {
  local w claude_bin holder out
  if [ ! -d /proc/self ]; then
    printf 'skip: the running-primary guard needs /proc\n'
    return 0
  fi
  w=$(new_world primary-running)
  claude_bin=$(fm_fakebin "$w/harness")
  ln -s "$(fm_test_tool bash)" "$claude_bin/claude"
  rr "$w" record >/dev/null
  fm_write_meta "$w/home/state/.primary-endpoint" backend=herdr herdr_session=default \
    pane=w9:p3 workspace=w9 "cwd=$w/home" harness=claude harness_pid=1 boot_id=boot-1

  # The captain started firstmate by hand in a pane of their own: a live Claude
  # process runs in the home, and no session lock is taken yet.
  start_stand_in "$claude_bin/claude" "$w/home" "$w/holder.fifo"
  holder=$!
  printf 'boot-2\n' > "$w/boot_id"
  out=$(rr "$w" run 2>&1)
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_contains "$out" "primary firstmate: already running (a Claude process runs in this home, pid $holder)" \
    "a primary started by hand outside its recorded pane was not detected: $out"

  # The captain's session holds the fleet lock and runs outside the home.
  start_stand_in "$claude_bin/claude" "$w" "$w/lock-holder.fifo"
  holder=$!
  printf '%s\n' "$holder" > "$w/home/state/.lock"
  printf 'boot-3\n' > "$w/boot_id"
  out=$(rr "$w" run 2>&1)
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_contains "$out" "primary firstmate: already running (a live session holds the fleet lock, pid $holder)" \
    "a primary that holds the fleet lock was not detected: $out"
  [ ! -s "$w/herdr/unexpected" ] || fail "a pass with the primary already running touched Herdr panes: $(cat "$w/herdr/unexpected")"
  pass "run: a primary the captain started by hand, by its home or by the fleet lock, is not launched twice"
}

test_run_rechecks_for_a_primary_right_before_typing() {
  local w claude_bin shell holder out
  if [ ! -d /proc/self ]; then
    printf 'skip: the running-primary guard needs /proc\n'
    return 0
  fi
  w=$(new_world primary-late)
  claude_bin=$(fm_fakebin "$w/harness")
  ln -s "$(fm_test_tool bash)" "$claude_bin/claude"
  rr "$w" record >/dev/null
  fm_write_meta "$w/home/state/.primary-endpoint" backend=herdr herdr_session=default \
    pane=w9:p3 workspace=w9 "cwd=$w/home" harness=claude harness_pid=1 boot_id=boot-1
  # The recorded pane holds only an idle shell. The captain starts firstmate
  # by hand in a pane of their own once the pass has begun to read that pane,
  # after its first check for a running primary.
  mkfifo "$w/shell.fifo"
  bash -c 'read -r _ < "$0"' "$w/shell.fifo" >/dev/null 2>&1 &
  shell=$!
  printf 'boot-2\n' > "$w/boot_id"
  out=$(FM_TEST_HERDR_PANE_SHELL=$shell FM_TEST_HERDR_PANE_CWD="$w/home" \
    FM_TEST_HERDR_HOLDER="$claude_bin/claude" rr "$w" run 2>&1)
  holder=$(cat "$w/herdr/holder.pid" 2>/dev/null)
  [ -z "$holder" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; }
  kill "$shell" 2>/dev/null; wait "$shell" 2>/dev/null
  [ -n "$holder" ] || fail "the pass never read the recorded pane: $out"
  assert_contains "$out" "primary firstmate: already running (a Claude process runs in this home, pid $holder); nothing was typed into pane default:w9:p3" \
    "a primary started by hand while the pass read its pane was not detected before the launch: $out"
  assert_not_contains "$(cat "$w/herdr/unexpected" 2>/dev/null)" "pane run" "the pass typed a launch although a primary already ran"
  pass "run: a primary started by hand while the pass runs is seen right before the launch, and nothing is typed"
}

test_run_ignores_a_claude_process_older_than_herdr() {
  local w claude_bin holder out
  if [ ! -d /proc/self ]; then
    printf 'skip: the running-primary guard needs /proc\n'
    return 0
  fi
  w=$(new_world primary-orphan)
  claude_bin=$(fm_fakebin "$w/harness")
  ln -s "$(fm_test_tool bash)" "$claude_bin/claude"
  rr "$w" record >/dev/null
  fm_write_meta "$w/home/state/.primary-endpoint" backend=herdr herdr_session=default \
    pane=w9:p3 workspace=w9 "cwd=$w/home" harness=claude harness_pid=1 boot_id=boot-1
  # An orphan Claude process in the home that outlived a Herdr-only restart:
  # it started before the new Herdr server did.
  start_stand_in "$claude_bin/claude" "$w/home" "$w/holder.fifo"
  holder=$!
  touch -d "@$(( $(date +%s) + 5 ))" "$w/herdr/herdr.sock"
  out=$(rr "$w" run 2>&1)
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_contains "$out" "restart recovery after Herdr server restart" "the Herdr-only restart was not recovered: $out"
  assert_not_contains "$out" "already running (a Claude process" \
    "a Claude process older than the Herdr server was read as a primary started by hand: $out"
  assert_contains "$out" "primary firstmate: not relaunched: its pane default:w9:p3 reads" \
    "the pass did not go on to read the recorded pane: $out"
  pass "run: a Claude process older than the Herdr server is not read as a manual relaunch"
}

test_dormant_marker_cli() {
  local w out rc
  w=$(new_world dormant)
  cat > "$w/home/data/secondmates.md" <<EOF
- learn - learning supervisor (home: $w/learn; scope: learning; projects: ; added 2026-08-25)
- osg - one stop greek supervisor (home: $w/osg; scope: osg; projects: ; added 2026-08-25)
EOF
  out=$(FM_HOME="$w/home" "$DORMANT" set learn --reason "captain order: Learning stays down" 2>&1) \
    || fail "set failed for a registered second mate: $out"
  FM_HOME="$w/home" "$DORMANT" is learn >/dev/null || fail "a second mate marked dormant must read dormant"
  if FM_HOME="$w/home" "$DORMANT" is osg >/dev/null; then fail "an unmarked second mate must not read dormant"; fi
  out=$(FM_HOME="$w/home" "$DORMANT" list)
  assert_contains "$out" "learn" "list did not name the dormant second mate"
  assert_contains "$out" "captain order: Learning stays down" "list did not keep the reason"
  out=$(FM_HOME="$w/home" "$DORMANT" set nobody --reason "typo" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "set must refuse an id that is not a registered second mate"
  if FM_HOME="$w/home" "$DORMANT" set osg >/dev/null 2>&1; then fail "set must require a reason"; fi
  FM_HOME="$w/home" "$DORMANT" clear learn >/dev/null || fail "clear failed"
  if FM_HOME="$w/home" "$DORMANT" is learn >/dev/null; then fail "a cleared second mate must not read dormant"; fi
  pass "dormant: set, list, is, and clear a durable marker for registered second mates only"
}

# --- secondmate-liveness-skip seam: the real startup liveness sweep ---------

make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi gh
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.29
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
fi
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.4' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  # Every second mate endpoint is an agent-free shell; new-window and
  # kill-window calls are logged so a relaunch is observable. With
  # FM_TMUX_HOLD_DIR set, each such call holds for a moment and logs an
  # `overlap:` line when another one is in progress at the same time.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *pane_current_command*) printf 'zsh\n'; exit 0 ;; esac
    done
    exit 0
    ;;
  list-windows) printf '%s\n' fm-sm-awake fm-sm-dormant; exit 0 ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    if [ -n "${FM_TMUX_HOLD_DIR:-}" ]; then
      mkdir -p "$FM_TMUX_HOLD_DIR"
      : > "$FM_TMUX_HOLD_DIR/$$"
      if [ "$(ls "$FM_TMUX_HOLD_DIR" | wc -l)" -gt 1 ]; then
        printf 'overlap: %s\n' "$*" >> "$FM_TMUX_CALL_LOG"
      fi
      sleep 2
      rm -f "$FM_TMUX_HOLD_DIR/$$"
    fi
    exit 0
    ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

add_secondmate() {  # <world> <id>
  local w=$1 id=$2 home="$1/$2"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  fm_write_meta "$w/home/state/$id.meta" "window=firstmate:fm-$id" "kind=secondmate" \
    "harness=claude" "home=$home"
  printf -- '- %s - supervisor (home: %s; scope: %s; projects: ; added 2026-09-24)\n' \
    "$id" "$home" "$id" >> "$w/home/data/secondmates.md"
}

run_sweep() {  # <world> <fakebin> <call-log>
  local w=$1
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    PATH="$2:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" \
    FM_TMUX_CALL_LOG="$3" FM_BOOTSTRAP_VERBOSE_FACTS=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_liveness_sweep_obeys_the_dormant_marker() {
  # This is the secondmate-liveness-skip seam.
  local w fb log out
  w=$(new_world sweep-dormant)
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  add_secondmate "$w" sm-awake
  add_secondmate "$w" sm-dormant
  FM_HOME="$w/home" "$DORMANT" set sm-dormant --reason "captain order" >/dev/null \
    || fail "could not mark the fixture second mate dormant"
  fb=$(make_toolchain "$w/tools")
  log="$w/tmux.log"; : > "$log"
  out=$(run_sweep "$w" "$fb" "$log")
  assert_contains "$(cat "$log")" "fm-sm-awake" "the startup sweep did not relaunch the authorized second mate: $out"
  assert_not_contains "$(cat "$log")" "fm-sm-dormant" "the startup sweep relaunched a dormant second mate"
  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm-dormant left down: dormant" \
    "a verbose sweep must say why it left the dormant second mate down"
  pass "seam secondmate-liveness-skip: the startup sweep leaves a dormant second mate down"
}

test_liveness_sweep_yields_to_a_running_recovery_pass() {
  # This is the secondmate-liveness-skip seam, second half: a manual session
  # start during a restart recovery pass must not race the pass's serial relaunches.
  local w fb log out bg
  w=$(new_world sweep-yield)
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  add_secondmate "$w" sm-awake
  rr "$w" record >/dev/null
  printf 'boot-2\n' > "$w/boot_id"
  rm -f "$w/herdr/running"
  FM_RESTART_HERDR_WAIT=20 rr "$w" run > "$w/bg.out" 2>&1 &
  bg=$!
  sleep 1
  fb=$(make_toolchain "$w/tools")
  log="$w/tmux.log"; : > "$log"
  out=$(FM_RESTART_BOOT_ID_FILE="$w/boot_id" run_sweep "$w" "$fb" "$log")
  : > "$w/herdr/running"
  wait "$bg" || true
  assert_not_contains "$(cat "$log")" "fm-sm-awake" "the startup sweep raced a running restart recovery pass"
  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm-awake left to the running restart recovery pass" \
    "the sweep must say it left the second mate to the recovery pass"
  pass "seam secondmate-liveness-skip: the startup sweep yields to a running recovery pass"
}

test_liveness_sweep_relaunches_one_at_a_time() {
  # This is the secondmate-liveness-serial seam.
  local w fb log out
  w=$(new_world sweep-serial)
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  add_secondmate "$w" sm-one
  add_secondmate "$w" sm-two
  add_secondmate "$w" sm-three
  fb=$(make_toolchain "$w/tools")
  log="$w/tmux.log"; : > "$log"
  out=$(FM_TMUX_HOLD_DIR="$w/held" run_sweep "$w" "$fb" "$log")
  assert_contains "$(cat "$log")" "fm-sm-one" "the startup sweep did not relaunch sm-one (relaunches that run at the same time refuse each other): $out"
  assert_contains "$(cat "$log")" "fm-sm-two" "the startup sweep did not relaunch sm-two (relaunches that run at the same time refuse each other): $out"
  assert_contains "$(cat "$log")" "fm-sm-three" "the startup sweep did not relaunch sm-three (relaunches that run at the same time refuse each other): $out"
  assert_not_contains "$(cat "$log")" "overlap:" "the startup sweep relaunched second mates at the same time"
  pass "seam secondmate-liveness-serial: the startup sweep relaunches second mates one at a time"
}

# --- restart-record seam: the real locked session start ---------------------

make_fake_ps_claude() {  # <fakebin>: every queried pid is a live claude harness
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '/usr/local/bin/claude\n' ;;
  *"args="*) printf 'claude\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/ps"
}

test_session_start_records_the_restart_fingerprint() {
  # This is the restart-record seam.
  local w root fb out
  w=$(new_world session-start)
  root="$w/root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  fb=$(fm_fakebin "$w/ss")
  make_fake_ps_claude "$fb"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  run_ss() {
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
      PATH="$fb:$w/herdr/fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$root" \
      FM_RESTART_BOOT_ID_FILE="$w/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
      FM_TEST_HERDR_DIR="$w/herdr" FM_STARTUP_NETWORK_TIMEOUT=2 \
      "$ROOT/bin/fm-session-start.sh" 2>&1
  }
  out=$(run_ss)
  assert_contains "$out" "lock acquired" "the fixture session start did not take the lock: $out"
  [ -f "$w/home/state/.restart-fingerprint" ] || fail "a locked session start did not record the restart fingerprint"
  assert_not_contains "$out" "RESTART:" "a first session start has no restart to report"
  printf 'boot-2\n' > "$w/boot_id"
  out=$(run_ss)
  assert_contains "$out" "RESTART: machine reboot" "a locked session start after a reboot did not report it"
  pass "seam restart-record: a locked session start records the fingerprint and reports a reboot"
}

# FM_TEST_ONLY=<test function> runs one case.
for t in \
  test_fingerprint_reports_the_three_restart_signals \
  test_record_names_each_restart_kind_once \
  test_record_in_a_secondmate_home_points_at_the_primary \
  test_record_captures_the_primary_endpoint_in_a_herdr_pane \
  test_run_acts_only_after_a_recorded_restart \
  test_run_waits_for_herdr_with_a_bound \
  test_run_is_single_flight_per_restart \
  test_run_rate_limits_a_restart_loop_with_one_alert \
  test_run_leaves_a_primary_that_already_runs_elsewhere \
  test_run_rechecks_for_a_primary_right_before_typing \
  test_run_ignores_a_claude_process_older_than_herdr \
  test_dormant_marker_cli \
  test_liveness_sweep_obeys_the_dormant_marker \
  test_liveness_sweep_yields_to_a_running_recovery_pass \
  test_liveness_sweep_relaunches_one_at_a_time \
  test_session_start_records_the_restart_fingerprint; do
  [ -z "${FM_TEST_ONLY:-}" ] || [ "$t" = "$FM_TEST_ONLY" ] || continue
  "$t"
done
