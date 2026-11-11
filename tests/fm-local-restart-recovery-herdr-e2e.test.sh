#!/usr/bin/env bash
# tests/fm-local-restart-recovery-herdr-e2e.test.sh - live guard for the
# restart recovery pass (bin/fm-local-restart-recovery.sh run).
#
# It builds a fleet in an isolated Herdr lab session: a primary firstmate pane
# that records its endpoint through the real `record` subcommand, authorized
# second mates in their own 2ndmate-<id> spaces, one dormant second mate, one
# whose space the captain closed (not active), and ordinary workers in the
# primary's space and in a second mate's space. It then restarts the lab server
# (every agent dies and Herdr restores the open spaces with bare shells in the
# same panes), moves the boot id, and runs the boot unit's entry point. It
# checks that the active second mates and the primary come back in their own
# panes, the primary resuming its recorded session, and that each second mate
# gets one restart notice; that the dormant and the inactive second mates stay
# down; that no ordinary worker is relaunched, also after each home's session
# start records the restart; that a second mate the captain relaunched by hand
# during a restart is not launched twice; that a primary whose pane is gone comes back in a new tab
# of its recorded workspace, or in a new workspace once that is gone, and the
# pass names what it created; that a finished restart is never recovered again;
# and that a restart loop stops at the rate limit with one alert.
# With agent-axi available (FM_RESTART_E2E_AGENT_AXI names its executable;
# default: agent-axi on PATH), it also proves the agent-axi ledger rule: a
# second mate whose space came back under a new workspace id is relaunched
# there although its home's slot ledger is still bound to the former, missing
# workspace, while a ledger bound to a workspace that still exists keeps
# refusing, and the pass reports agent-axi's own reason.
# Every agent is a stand-in that records its launch and sleeps as a process
# named claude, so the guard spends no model tokens and runs by default wherever
# Herdr, jq, and node exist. A second mate relaunch pre-registers Claude
# workspace trust with node (bin/fm-claude-trust.sh), so the pass gets node and
# an isolated Claude config directory, never the operator's own trust store.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_RESTART_RECOVERY_LIVE_E2E herdr jq node

LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || fail "the guarded Herdr lab helper is not executable"
SESSION=$("$LAB_HELPER" name restart-recov) || fail "the guarded Herdr lab name could not be created"
TMP_ROOT=$(fm_test_tmproot fm-restart-recovery-live)
RR="$ROOT/bin/fm-local-restart-recovery.sh"
DORMANT="$ROOT/bin/fm-local-dormant.sh"
ORIGINAL_PATH=$PATH
CORE_PATH=$(fm_test_core_path)
AGENT_AXI=${FM_RESTART_E2E_AGENT_AXI:-$(command -v agent-axi 2>/dev/null || true)}
TEARDOWN_PENDING=0

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

# --- stand-ins ---------------------------------------------------------------

STUB="$TMP_ROOT/stub"
FAKEBIN="$STUB/bin"
LAUNCH_LOG="$TMP_ROOT/launches"
mkdir -p "$FAKEBIN" "$STUB/sleep" "$STUB/primary"
: > "$LAUNCH_LOG"
# A process whose kernel name is claude, so the recovery classifier reads it as
# an agent: perl sleeping, executed through a link named claude. Not coreutils
# sleep, which is a multi-call binary on some hosts and refuses a foreign name.
ln -s "$(fm_test_tool perl)" "$STUB/sleep/claude"
# The primary's recording harness: bash under the name claude.
ln -s "$(fm_test_tool bash)" "$STUB/primary/claude"
cat > "$FAKEBIN/claude" <<SH
#!$(fm_test_tool bash)
{ printf '%s' "\$PWD"; printf '\t%s' "\$@"; printf '\n'; } >> '$LAUNCH_LOG'
exec -a claude '$STUB/sleep/claude' -e 'sleep 86400'
SH
ln -s "$(fm_test_tool node)" "$FAKEBIN/node"
# Every Herdr call goes through the lab helper, which adds the lab session
# itself; a call that names any other session is refused.
cat > "$FAKEBIN/herdr" <<SH
#!$(fm_test_tool bash)
set -u
args=("\$@")
last=\$((\${#args[@]} - 1))
flag=\$((last - 1))
if [ "\${#args[@]}" -ge 2 ] && [ "\${args[\$flag]}" = --session ] && [ "\${args[\$last]}" = '$SESSION' ]; then
  unset "args[\$last]" "args[\$flag]"
fi
set -- "\${args[@]}"
for arg in "\$@"; do
  case "\$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH='$ORIGINAL_PATH' '$LAB_HELPER' run '$SESSION' "\$@"
SH
PANE_PATH="$FAKEBIN:$CORE_PATH"
# Lab panes run a bare bash on the stand-in PATH, so no rc file can put a real
# claude ahead of the stand-in.
cat > "$STUB/lab-shell" <<SH
#!$(fm_test_tool bash)
exec env PATH='$PANE_PATH' '$(fm_test_tool bash)' --noprofile --norc -i
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/herdr" "$STUB/lab-shell"

provision() {
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u HERDR_PANE_ID -u HERDR_TAB_ID \
    -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV \
    SHELL="$STUB/lab-shell" "$LAB_HELPER" provision "$SESSION"
}

lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

TEARDOWN_PENDING=1
provision || fail "the isolated Herdr lab session could not be provisioned"

# launches_in <dir>: how many stand-in agents started in <dir>.
launches_in() {
  awk -F '\t' -v d="$1" '$1 == d { n++ } END { print n + 0 }' "$LAUNCH_LOG"
}

wait_launches() {  # <dir> <count>
  for _ in $(seq 1 60); do
    [ "$(launches_in "$1")" -ge "$2" ] && return 0
    sleep 0.5
  done
  return 1
}

pane_runs_claude() {  # <pane>
  lab pane process-info --pane "$1" 2>/dev/null \
    | jq -e '[.result.process_info.foreground_processes[].name] | index("claude") != null' >/dev/null
}

wait_claude() {  # <pane>
  for _ in $(seq 1 60); do
    pane_runs_claude "$1" && return 0
    sleep 0.5
  done
  return 1
}

wait_shell() {  # <pane>: a restored pane whose shell is ready
  for _ in $(seq 1 60); do
    lab pane process-info --pane "$1" 2>/dev/null \
      | jq -e '[.result.process_info.foreground_processes[].name] == ["bash"]' >/dev/null && return 0
    sleep 0.5
  done
  return 1
}

# --- the fleet -----------------------------------------------------------------

H="$TMP_ROOT/home"
mkdir -p "$H/state" "$H/data" "$H/config"
printf 'claude\n' > "$H/config/secondmate-harness"
printf 'boot-1\n' > "$TMP_ROOT/boot_id"
: > "$H/data/secondmates.md"
fm_git_identity fmtest fmtest@example.invalid

new_workspace() {  # <cwd> <label> -> "<workspace>\t<tab>\t<pane>"
  lab workspace create --cwd "$1" --label "$2" --no-focus \
    | jq -er '.result.root_pane | [.workspace_id, .tab_id, .pane_id] | @tsv'
}

SM_PANES=()
add_secondmate() {  # <id>
  local id=$1 home="$TMP_ROOT/sm-$1" row ws tab pane
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  if ! { git -C "$home" init -q -b main && git -C "$home" add -A && git -C "$home" commit -q -m init; }; then
    fail "the $id home could not be made a git checkout"
  fi
  mkdir -p "$H/data/$id"
  printf 'Second mate %s charter.\n' "$id" > "$H/data/$id/brief.md"
  printf -- '- %s - %s supervisor (home: %s; scope: %s; projects: ; added 2026-09-24)\n' \
    "$id" "$id" "$home" "$id" >> "$H/data/secondmates.md"
  row=$(new_workspace "$home" "2ndmate-$id") || fail "the lab workspace for $id could not be created"
  IFS=$'\t' read -r ws tab pane <<EOF
$row
EOF
  wait_shell "$pane" || fail "the $id pane never showed a shell"
  lab pane run "$pane" "claude --dangerously-skip-permissions" >/dev/null || fail "$id could not be started"
  wait_launches "$home" 1 || fail "$id never started"
  fm_write_meta "$H/state/$id.meta" "window=$SESSION:$pane" "endpoint_task_id=$id" \
    "worktree=$home" "project=$home" "harness=claude" "kind=secondmate" "mode=secondmate" \
    "yolo=off" "model=claude-opus-5-5" "effort=high" "backend=herdr" "herdr_session=$SESSION" \
    "herdr_workspace_id=$ws" "herdr_tab_id=$tab" "herdr_pane_id=$pane" "home=$home" "projects="
  SM_PANES+=("$pane")
  SM_WS+=("$ws")
  # The slot ledger agent-axi keeps for the home, bound to its space.
  printf '{"version":1,"workspace":{"label":"2ndmate-%s","id":"%s"},"supervisorPaneId":null,"planOverrides":{},"slots":[]}\n' \
    "$id" "$ws" > "$home/state/.agent-axi-slots.json"
}
SM_WS=()

# spare_tab <workspace>: a second tab, so the space stays open when the second
# mate's own pane is closed.
spare_tab() {
  lab tab create --workspace "$1" --cwd "$TMP_ROOT" --label spare --no-focus >/dev/null \
    || fail "a spare tab in $1 could not be created"
}

WORKER_PANES=()
# add_worker <home> <id> <workspace>: an ordinary worker record in <home>,
# running a stand-in agent in a lab tab of <workspace> from its own worktree.
add_worker() {
  local home=$1 id=$2 ws=$3 wt="$TMP_ROOT/wt-$2" out tab pane
  mkdir -p "$wt"
  out=$(lab tab create --workspace "$ws" --cwd "$wt" --label "fm-$id" --no-focus) \
    || fail "the lab tab for worker $id could not be created"
  tab=$(printf '%s' "$out" | jq -er '.result.tab.tab_id') || fail "no tab id for worker $id: $out"
  pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id') || fail "no pane id for worker $id: $out"
  wait_shell "$pane" || fail "the $id pane never showed a shell"
  lab pane run "$pane" "claude --dangerously-skip-permissions" >/dev/null || fail "worker $id could not be started"
  wait_launches "$wt" 1 || fail "worker $id never started"
  fm_write_meta "$home/state/$id.meta" "window=$SESSION:$pane" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "yolo=off" "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$ws" \
    "herdr_tab_id=$tab" "herdr_pane_id=$pane" "spawn_gen=s1790000000.1.1"
  printf 'working: building\n' > "$home/state/$id.status"
  WORKER_PANES+=("$pane")
}

add_secondmate osg
add_secondmate research
add_secondmate learning
add_secondmate archive
FM_HOME="$H" "$DORMANT" set learning --reason "captain order: Learning stays down" >/dev/null \
  || fail "the learning second mate could not be marked dormant"
OSG_HOME="$TMP_ROOT/sm-osg"
RES_HOME="$TMP_ROOT/sm-research"
LEARN_HOME="$TMP_ROOT/sm-learning"
ARCH_HOME="$TMP_ROOT/sm-archive"
OSG_PANE=${SM_PANES[0]}
RES_PANE=${SM_PANES[1]}
LEARN_PANE=${SM_PANES[2]}
OSG_WS=${SM_WS[0]}
ARCH_WS=${SM_WS[3]}
add_worker "$OSG_HOME" osg-crew "$OSG_WS"
# The panes that Herdr restores at every lab restart.
RESTORED_PANES=("$OSG_PANE" "$RES_PANE" "$LEARN_PANE" "${WORKER_PANES[@]}")
if [ -n "$AGENT_AXI" ]; then
  add_secondmate fresh
  add_secondmate stuck
  FRESH_HOME="$TMP_ROOT/sm-fresh"
  STUCK_HOME="$TMP_ROOT/sm-stuck"
  FRESH_WS=${SM_WS[4]}
  STUCK_PANE=${SM_PANES[5]}
  STUCK_WS=${SM_WS[5]}
  spare_tab "$STUCK_WS"
fi

# The primary records its endpoint through the real restart-record path from
# inside its own pane, as its locked session start does, then keeps running.
CFG="$TMP_ROOT/claude-config"
SID=5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b
mkdir -p "$CFG/sessions" "$CFG/projects/home"
printf '{"type":"summary"}\n' > "$CFG/projects/home/$SID.jsonl"
cat > "$TMP_ROOT/primary.sh" <<SH
start=\$(sed 's/^.*) //' "/proc/\$\$/stat" | awk '{ print \$20 }')
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s"}\n' \
  "\$\$" '$SID' '$H' "\$start" > '$CFG/sessions/'"\$\$.json"
FM_HOME='$H' FM_RESTART_BOOT_ID_FILE='$TMP_ROOT/boot_id' FM_RESTART_USER_MANAGER_ID=um-1 \
  '$RR' record > '$TMP_ROOT/record.out' 2>&1
printf 'recorded\n' >> '$TMP_ROOT/record.out'
exec -a claude '$STUB/sleep/claude' -e 'sleep 86400'
SH
row=$(new_workspace "$H" fleet) || fail "the primary lab workspace could not be created"
IFS=$'\t' read -r PRIMARY_WS _ PRIMARY_PANE <<EOF
$row
EOF
wait_shell "$PRIMARY_PANE" || fail "the primary pane never showed a shell"
lab pane run "$PRIMARY_PANE" "CLAUDE_CONFIG_DIR='$CFG' '$STUB/primary/claude' --noprofile < '$TMP_ROOT/primary.sh'" >/dev/null \
  || fail "the primary could not be started"
for _ in $(seq 1 60); do
  grep -q '^recorded$' "$TMP_ROOT/record.out" 2>/dev/null && break
  sleep 0.5
done
grep -q '^recorded$' "$TMP_ROOT/record.out" || fail "the primary never recorded its endpoint"
ENDPOINT=$(cat "$H/state/.primary-endpoint" 2>/dev/null) || fail "the primary endpoint record is missing: $(cat "$TMP_ROOT/record.out")"
assert_contains "$ENDPOINT" "pane=$PRIMARY_PANE" "the primary endpoint did not record its pane"
assert_contains "$ENDPOINT" "herdr_session=$SESSION" "the primary endpoint did not record the lab session"
assert_contains "$ENDPOINT" "native_session=$SID" "the primary endpoint did not record its session"
wait_claude "$PRIMARY_PANE" || fail "the primary stand-in is not running: $(lab pane process-info --pane "$PRIMARY_PANE") $(cat "$TMP_ROOT/record.out")"
pass "live: a primary in a lab pane records its endpoint through the real restart-record path"

add_worker "$H" crew-p "$PRIMARY_WS"
RESTORED_PANES+=("${WORKER_PANES[@]: -1}")

# home_record <home>: the restart-record step of <home>'s own locked session
# start, outside any Herdr pane. Sets REC to its output.
home_record() {
  REC=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH -u HERDR_SESSION PATH="$FAKEBIN:$CORE_PATH" FM_HOME="$1" \
    FM_RESTART_BOOT_ID_FILE="$TMP_ROOT/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
    "$RR" record 2>&1)
}
home_record "$OSG_HOME"

recover() {  # sets OUT to the pass output and RC to its exit status
  OUT=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH -u HERDR_SESSION -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    PATH="$FAKEBIN:$CORE_PATH" FM_HOME="$H" CLAUDE_CONFIG_DIR="$CFG" \
    FM_RESTART_BOOT_ID_FILE="$TMP_ROOT/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
    FM_RESTART_POLL=0.5 FM_RESTART_LAUNCH_WAIT=30 FM_RESTART_HERDR_WAIT=60 \
    FM_BACKEND_HERDR_AXI_BIN="$AGENT_AXI" FM_BACKEND_HERDR_AXI_LAUNCH="$STUB/lab-shell" \
    "$RR" run 2>&1)
  RC=$?
}

recover; [ "$RC" -eq 0 ] || fail "a run with the fleet running failed: $OUT"
assert_contains "$OUT" "no restart since the last session start" "a run without a restart must do nothing"
[ "$(launches_in "$H")" -eq 0 ] || fail "a run without a restart launched a primary"
pass "live: with no restart, the boot unit relaunches nothing"

restart_lab() {  # <boot-id>
  "$LAB_HELPER" stop "$SESSION" >/dev/null || fail "the lab session could not be stopped"
  provision || fail "the lab session could not be restarted"
  printf '%s\n' "$1" > "$TMP_ROOT/boot_id"
  local pane
  for pane in "$PRIMARY_PANE" "${RESTORED_PANES[@]}"; do
    wait_shell "$pane" || fail "pane $pane did not come back as a shell after the restart"
  done
}

# --- restart 1: a reboot brings the supervisors back ---------------------------

# The captain closes the archive second mate's space: it is no longer active.
lab workspace close "$ARCH_WS" >/dev/null || fail "the archive space could not be closed"
restart_lab boot-2
if [ -n "$AGENT_AXI" ]; then
  # The fresh second mate's space comes back under a new workspace id, while
  # its home's slot ledger still names the former one, which no longer exists.
  lab workspace close "$FRESH_WS" >/dev/null || fail "the fresh space could not be closed"
  row=$(new_workspace "$TMP_ROOT" 2ndmate-fresh) || fail "the new fresh space could not be created"
  FRESH_WS2=${row%%$'\t'*}
  [ -n "$FRESH_WS2" ] && [ "$FRESH_WS2" != "$FRESH_WS" ] || fail "the re-created space did not get a new id: '$FRESH_WS2'"
  # The stuck second mate's pane is gone, and its ledger names a workspace that
  # still exists: a live conflict that agent-axi must keep refusing.
  lab pane close "$STUCK_PANE" >/dev/null || fail "the stuck pane could not be closed"
  printf '{"version":1,"workspace":{"label":"2ndmate-stuck","id":"%s"},"supervisorPaneId":null,"planOverrides":{},"slots":[]}\n' \
    "$PRIMARY_WS" > "$STUCK_HOME/state/.agent-axi-slots.json"
  STUCK_LEDGER=$(cat "$STUCK_HOME/state/.agent-axi-slots.json")
fi
recover; [ "$RC" -eq 0 ] || fail "the recovery pass failed ($RC): $OUT"
assert_contains "$OUT" "restart recovery after machine reboot" "the pass did not name the reboot"
[ "$(launches_in "$OSG_HOME")" -eq 2 ] || fail "osg was not relaunched exactly once: $OUT"
[ "$(launches_in "$RES_HOME")" -eq 2 ] || fail "research was not relaunched exactly once: $OUT"
[ "$(launches_in "$LEARN_HOME")" -eq 1 ] || fail "the dormant second mate was relaunched: $OUT"
pane_runs_claude "$OSG_PANE" || fail "osg is not running in its own pane after recovery"
pane_runs_claude "$RES_PANE" || fail "research is not running in its own pane after recovery"
if pane_runs_claude "$LEARN_PANE"; then fail "the dormant second mate is running after recovery"; fi
pass "live: after a reboot the authorized second mates run again in their own panes, and the dormant one stays down"

[ "$(launches_in "$H")" -eq 1 ] || fail "the primary was not relaunched exactly once: $OUT"
pane_runs_claude "$PRIMARY_PANE" || fail "the primary is not running in its recorded pane after recovery"
PRIMARY_LAUNCH=$(awk -F '\t' -v d="$H" '$1 == d' "$LAUNCH_LOG")
assert_contains "$PRIMARY_LAUNCH" "--noprofile" "the primary relaunch dropped its recorded launch flag"
assert_contains "$PRIMARY_LAUNCH" "--resume	$SID" "the primary relaunch did not resume its recorded session"
assert_contains "$PRIMARY_LAUNCH" "FIRSTMATE_OP: v1 session-start: Run" "the primary's first prompt was not the session-start operational input"
assert_contains "$OUT" "primary firstmate: relaunched in pane $SESSION:$PRIMARY_PANE, resuming Claude session $SID" \
  "the pass did not report the primary relaunch"
pass "live: the primary comes back last, in its recorded pane, resuming its recorded session"

grep -q 'restart-recovery:' "$H/state/.wake-queue" || fail "the pass did not leave a wake for firstmate"
assert_contains "$(cat "$H/state/osg.status")" "working: relaunched after a machine reboot" \
  "the relaunched second mate got no status boundary"
pass "live: the pass leaves one wake and a status boundary for each relaunched second mate"

[ "$(launches_in "$ARCH_HOME")" -eq 1 ] || fail "a second mate whose space was closed was relaunched: $OUT"
assert_contains "$OUT" "second mate archive: left down: not active (its Herdr space 2ndmate-archive is closed)" \
  "the pass did not say why it left the inactive second mate down"
pass "live: a second mate whose Herdr space did not survive the restart is not active and stays down"

for id in osg research; do
  assert_contains "$OUT" "second mate $id: restart notice sent" "the pass did not send $id its restart notice"
  notice=$(cat "$H/state/$id.inbox/"*.msg 2>/dev/null)
  assert_contains "$notice" "Restart notice: a machine reboot" "$id's steering inbox holds no restart notice"
  assert_contains "$notice" "Reconcile your own home now" "the restart notice does not ask $id to reconcile its home"
  [ "$(grep -c 'Restart notice' "$H/state/$id.inbox/"*.msg)" -eq 1 ] || fail "$id did not get exactly one restart notice"
done
for id in learning archive; do
  [ ! -e "$H/state/$id.inbox" ] || fail "the second mate $id was left down but got a restart notice"
done
pass "live: each relaunched second mate gets exactly one restart notice in its steering inbox, and no other does"

home_record "$OSG_HOME"
assert_contains "$REC" "RESTART: machine reboot" "the second mate home's session start did not see the restart"
assert_contains "$REC" "Workers are not relaunched automatically" "the second mate home was not told to reconcile its own workers"
sleep 3
for wt in "$TMP_ROOT/wt-osg-crew" "$TMP_ROOT/wt-crew-p"; do
  [ "$(launches_in "$wt")" -eq 1 ] || fail "an ordinary worker in $wt was relaunched after the restart: $OUT"
done
pass "live: no ordinary worker is relaunched by the pass or by a home's session start after the restart"

if [ -n "$AGENT_AXI" ]; then
  assert_contains "$OUT" "second mate fresh: relaunched in a new pane (its pane was gone)" \
    "a second mate whose space has a new workspace id was not relaunched: $OUT"
  [ "$(launches_in "$FRESH_HOME")" -eq 2 ] || fail "the fresh second mate was not relaunched exactly once: $OUT"
  FRESH_PANE=$(sed -n 's/^herdr_pane_id=//p' "$H/state/fresh.meta" | tail -n 1)
  [ "$(lab pane get "$FRESH_PANE" | jq -r '.result.pane.workspace_id')" = "$FRESH_WS2" ] \
    || fail "the fresh second mate was not relaunched in its new space $FRESH_WS2: pane $FRESH_PANE"
  wait_claude "$FRESH_PANE" || fail "the fresh second mate is not running in its new space"
  [ "$(jq -r '.workspace.id' "$FRESH_HOME/state/.agent-axi-slots.json")" = "$FRESH_WS2" ] \
    || fail "the fresh home's slot ledger was not moved to its new space: $(cat "$FRESH_HOME/state/.agent-axi-slots.json")"
  assert_contains "$OUT" "second mate fresh: restart notice sent" "the fresh second mate got no restart notice"
  pass "live: a second mate whose space came back under a new workspace id is relaunched there, and its ledger follows"

  assert_contains "$OUT" "second mate stuck: relaunch failed: error: agent-axi spawn failed for fm-stuck (session $SESSION): the home ledger is bound to workspace 2ndmate-stuck ($PRIMARY_WS), but the exact target is 2ndmate-stuck ($STUCK_WS)" \
    "a live ledger conflict did not report agent-axi's own reason: $OUT"
  [ "$(launches_in "$STUCK_HOME")" -eq 1 ] || fail "a second mate with a live ledger conflict was launched: $OUT"
  [ "$(cat "$STUCK_HOME/state/.agent-axi-slots.json")" = "$STUCK_LEDGER" ] || fail "a refused spawn changed the ledger"
  pass "live: a ledger bound to a workspace that still exists keeps refusing, and the pass reports agent-axi's reason"
else
  printf 'skip: agent-axi is not available, so the ledger cases did not run (set FM_RESTART_E2E_AGENT_AXI)\n'
fi

# created_pane <what>: the pane the pass names after "relaunched in <what>", a
# sed pattern for the tab or workspace it says it created.
created_pane() {
  printf '%s\n' "$OUT" \
    | sed -n "s/^fm-restart-recovery: primary firstmate: relaunched in $1, pane $SESSION:\([^,]*\), .*\$/\1/p" \
    | head -n 1
}

# --- restart 2: a relaunch by hand during recovery is not duplicated -------------

restart_lab boot-3
lab pane run "$RES_PANE" "claude --by-hand" >/dev/null || fail "the manual relaunch could not be typed"
wait_launches "$RES_HOME" 3 || fail "the manual relaunch never started"
# The primary's recorded pane is gone after this restart, while its workspace
# stays, so the primary comes back in a new tab of that workspace.
lab tab create --workspace "$PRIMARY_WS" --cwd "$H" --label spare --no-focus >/dev/null \
  || fail "the spare tab that keeps the primary workspace open could not be created"
lab pane close "$PRIMARY_PANE" >/dev/null || fail "the primary pane could not be closed"
recover; [ "$RC" -eq 0 ] || fail "the second recovery pass failed ($RC): $OUT"
assert_contains "$OUT" "second mate research: already running" "the pass did not notice the manual relaunch"
[ "$(launches_in "$RES_HOME")" -eq 3 ] || fail "a second mate relaunched by hand was launched again: $OUT"
[ "$(launches_in "$OSG_HOME")" -eq 3 ] || fail "osg was not relaunched after the second restart: $OUT"
[ "$(launches_in "$H")" -eq 2 ] || fail "the primary was not relaunched after the second restart: $OUT"
pass "live: a second mate relaunched by hand during a restart is detected and not launched twice"

TAB_PANE=$(created_pane "a new tab [^ ]* in the recorded workspace $PRIMARY_WS")
[ -n "$TAB_PANE" ] || fail "the pass did not name the new tab in the recorded workspace and its pane: $OUT"
pane_runs_claude "$TAB_PANE" || fail "the primary is not running in the new tab pane $TAB_PANE"
assert_contains "$(cat "$H/state/restart-recovery/"*.txt)" \
  "- primary firstmate: relaunched in a new tab " "the pass record did not name the new tab"
PRIMARY_PANE=$TAB_PANE
pass "live: a primary whose pane is gone comes back in a new tab of its recorded workspace, named in the pass record"

recover; [ "$RC" -eq 0 ] || fail "a repeat run failed ($RC): $OUT"
assert_contains "$OUT" "already recovered" "a repeat run for the same restart was not recognized"
[ "$(launches_in "$OSG_HOME")" -eq 3 ] && [ "$(launches_in "$H")" -eq 2 ] \
  || fail "a repeat run for the same restart launched agents: $OUT"
pass "live: a finished restart is never recovered twice"

# --- restart 3: a restart loop stops at the rate limit ---------------------------

restart_lab boot-4
recover; [ "$RC" -eq 3 ] || fail "a third restart inside the window must be rate limited, got $RC: $OUT"
assert_contains "$OUT" "rate limit" "the rate limit was not reported"
[ "$(launches_in "$OSG_HOME")" -eq 3 ] && [ "$(launches_in "$H")" -eq 2 ] \
  || fail "a rate-limited run launched agents: $OUT"
[ "$(grep -c 'restart-recovery-alert:rate-limit' "$H/state/.wake-queue")" -eq 1 ] \
  || fail "the rate limit did not raise exactly one alert"
pass "live: a restart loop stops at the rate limit with one alert and no launches"

# --- a retry after the loop: the recorded workspace is gone ----------------------

# The captain closes the primary's workspace and retries the refused restart
# with a higher limit, so the primary comes back in a new workspace.
lab workspace close "$PRIMARY_WS" >/dev/null || fail "the primary workspace could not be closed"
FM_RESTART_MAX_PASSES=3 recover; [ "$RC" -eq 0 ] || fail "the retried recovery pass failed ($RC): $OUT"
WS_PANE=$(created_pane "a new workspace [^ ]* labeled 'fleet' (the recorded workspace $PRIMARY_WS is gone)")
[ -n "$WS_PANE" ] || fail "the pass did not name the new workspace, its label, and its pane: $OUT"
pane_runs_claude "$WS_PANE" || fail "the primary is not running in the new workspace pane $WS_PANE"
[ "$(launches_in "$H")" -eq 3 ] || fail "the primary was not relaunched exactly once more: $OUT"
pass "live: a primary whose workspace is gone comes back in a new workspace with its label, named in the pass output"
