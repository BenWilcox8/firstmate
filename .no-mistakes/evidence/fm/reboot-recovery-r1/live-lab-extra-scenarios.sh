#!/usr/bin/env bash
# Supplemental live driver for the restart recovery pass, run against a guarded
# Herdr lab session through bin/fm-herdr-lab.sh. Setup mirrors
# tests/fm-local-restart-recovery-herdr-e2e.test.sh; the scenarios are the ones
# that test covers only with a fake Herdr.
set -u
WT=${WT:?}
. "$WT/tests/lib.sh"
fm_live_gate default-on FM_RESTART_RECOVERY_LIVE_E2E herdr jq
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
SESSION=$("$LAB_HELPER" name rr-extra) || fail "lab name"
TMP_ROOT=$(fm_test_tmproot fm-rr-extra)
RR="$ROOT/bin/fm-local-restart-recovery.sh"
DORMANT="$ROOT/bin/fm-local-dormant.sh"
ORIGINAL_PATH=$PATH
CORE_PATH=$(fm_test_core_path)
TEARDOWN_PENDING=0
BG_PIDS=()
cleanup_all() {
  local status=$1 p
  trap - EXIT INT TERM
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  if [ "$TEARDOWN_PENDING" -eq 1 ]; then
    "$LAB_HELPER" teardown "$SESSION" || { printf 'not ok - teardown/tripwire failed\n' >&2; status=1; }
  fi
  fm_test_cleanup
  exit "$status"
}
trap 'cleanup_all $?' EXIT
trap 'cleanup_all 130' INT
trap 'cleanup_all 143' TERM

STUB="$TMP_ROOT/stub"; FAKEBIN="$STUB/bin"; LAUNCH_LOG="$TMP_ROOT/launches"
mkdir -p "$FAKEBIN" "$STUB/sleep" "$STUB/primary"; : > "$LAUNCH_LOG"
ln -s "$(fm_test_tool perl)" "$STUB/sleep/claude"
ln -s "$(fm_test_tool bash)" "$STUB/primary/claude"
cat > "$FAKEBIN/claude" <<SH
#!$(fm_test_tool bash)
{ printf '%s' "\$PWD"; printf '\t%s' "\$@"; printf '\n'; } >> '$LAUNCH_LOG'
exec -a claude '$STUB/sleep/claude' -e 'sleep 86400'
SH
# Herdr goes through the lab helper. When $TMP_ROOT/inject-captain exists, the
# first `tab create` (the pass opening a new tab for the primary) is followed,
# before it returns, by the captain typing `claude --by-hand` into their own
# lab pane in the primary home: a manual relaunch after the pass's early check
# and before its final read.
cat > "$FAKEBIN/herdr" <<SH
#!$(fm_test_tool bash)
set -u
args=("\$@")
last=\$((\${#args[@]} - 1)); flag=\$((last - 1))
if [ "\${#args[@]}" -ge 2 ] && [ "\${args[\$flag]}" = --session ] && [ "\${args[\$last]}" = '$SESSION' ]; then
  unset "args[\$last]" "args[\$flag]"
fi
set -- "\${args[@]}"
for arg in "\$@"; do case "\$arg" in --session|--session=*) exit 9 ;; esac; done
if [ "\${1:-}" = tab ] && [ "\${2:-}" = create ] && [ -f '$TMP_ROOT/inject-captain' ]; then
  rm -f '$TMP_ROOT/inject-captain'
  out=\$(env PATH='$ORIGINAL_PATH' '$LAB_HELPER' run '$SESSION' "\$@"); rc=\$?
  cp=\$(cat '$TMP_ROOT/captain-pane')
  env PATH='$ORIGINAL_PATH' '$LAB_HELPER' run '$SESSION' pane run "\$cp" "claude --by-hand" >/dev/null 2>&1
  for _ in \$(seq 1 60); do
    grep -q -- '--by-hand' '$LAUNCH_LOG' && break; sleep 0.2
  done
  sleep 0.5
  printf 'injected captain relaunch in %s\n' "\$cp" >> '$TMP_ROOT/inject.log'
  printf '%s\n' "\$out"; exit \$rc
fi
exec env PATH='$ORIGINAL_PATH' '$LAB_HELPER' run '$SESSION' "\$@"
SH
PANE_PATH="$FAKEBIN:$CORE_PATH"
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
provision || fail "provision"
launches_in() { awk -F '\t' -v d="$1" '$1 == d { n++ } END { print n + 0 }' "$LAUNCH_LOG"; }
wait_launches() { for _ in $(seq 1 60); do [ "$(launches_in "$1")" -ge "$2" ] && return 0; sleep 0.5; done; return 1; }
pane_runs_claude() { lab pane process-info --pane "$1" 2>/dev/null | jq -e '[.result.process_info.foreground_processes[].name] | index("claude") != null' >/dev/null; }
wait_claude() { for _ in $(seq 1 60); do pane_runs_claude "$1" && return 0; sleep 0.5; done; return 1; }
wait_shell() { for _ in $(seq 1 60); do lab pane process-info --pane "$1" 2>/dev/null | jq -e '[.result.process_info.foreground_processes[].name] == ["bash"]' >/dev/null && return 0; sleep 0.5; done; return 1; }

H="$TMP_ROOT/home"
mkdir -p "$H/state" "$H/data" "$H/config"
printf 'claude\n' > "$H/config/secondmate-harness"
printf 'boot-1\n' > "$TMP_ROOT/boot_id"
: > "$H/data/secondmates.md"
fm_git_identity fmtest fmtest@example.invalid
new_workspace() { lab workspace create --cwd "$1" --label "$2" --no-focus | jq -er '.result.root_pane | [.workspace_id, .tab_id, .pane_id] | @tsv'; }
SM_PANES=()
add_secondmate() {
  local id=$1 home="$TMP_ROOT/sm-$1" row ws tab pane
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"; printf '# Firstmate\n' > "$home/AGENTS.md"
  git -C "$home" init -q -b main && git -C "$home" add -A && git -C "$home" commit -q -m init || fail "git $id"
  mkdir -p "$H/data/$id"; printf 'Second mate %s charter.\n' "$id" > "$H/data/$id/brief.md"
  printf -- '- %s - %s supervisor (home: %s; scope: %s; projects: ; added 2026-09-24)\n' "$id" "$id" "$home" "$id" >> "$H/data/secondmates.md"
  row=$(new_workspace "$home" "$id") || fail "ws $id"
  IFS=$'\t' read -r ws tab pane <<EOF
$row
EOF
  wait_shell "$pane" || fail "shell $id"
  lab pane run "$pane" "claude --dangerously-skip-permissions" >/dev/null || fail "start $id"
  wait_launches "$home" 1 || fail "$id never started"
  fm_write_meta "$H/state/$id.meta" "window=$SESSION:$pane" "endpoint_task_id=$id" \
    "worktree=$home" "project=$home" "harness=claude" "kind=secondmate" "mode=secondmate" \
    "yolo=off" "model=claude-opus-5-5" "effort=high" "backend=herdr" "herdr_session=$SESSION" \
    "herdr_workspace_id=$ws" "herdr_tab_id=$tab" "herdr_pane_id=$pane" "home=$home" "projects="
  SM_PANES+=("$pane")
}
add_secondmate osg
add_secondmate learning
FM_HOME="$H" "$DORMANT" set learning --reason "captain order: Learning stays down" >/dev/null || fail "dormant"
OSG_HOME="$TMP_ROOT/sm-osg"; LEARN_HOME="$TMP_ROOT/sm-learning"
OSG_PANE=${SM_PANES[0]}; LEARN_PANE=${SM_PANES[1]}

CFG="$TMP_ROOT/claude-config"; SID=5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b
mkdir -p "$CFG/sessions" "$CFG/projects/home"; printf '{"type":"summary"}\n' > "$CFG/projects/home/$SID.jsonl"
cat > "$TMP_ROOT/primary.sh" <<SH
start=\$(sed 's/^.*) //' "/proc/\$\$/stat" | awk '{ print \$20 }')
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s"}\n' "\$\$" '$SID' '$H' "\$start" > '$CFG/sessions/'"\$\$.json"
FM_HOME='$H' FM_RESTART_BOOT_ID_FILE='$TMP_ROOT/boot_id' FM_RESTART_USER_MANAGER_ID=um-1 '$RR' record > '$TMP_ROOT/record.out' 2>&1
printf 'recorded\n' >> '$TMP_ROOT/record.out'
exec -a claude '$STUB/sleep/claude' -e 'sleep 86400'
SH
row=$(new_workspace "$H" fleet) || fail "primary ws"
IFS=$'\t' read -r PRIMARY_WS _ PRIMARY_PANE <<EOF
$row
EOF
wait_shell "$PRIMARY_PANE" || fail "primary shell"
# The captain's own tab in the primary workspace: a shell in the primary home.
CAPTAIN_PANE=$(lab tab create --workspace "$PRIMARY_WS" --cwd "$H" --label captain --no-focus | jq -er '.result.root_pane.pane_id') || fail "captain tab"
printf '%s\n' "$CAPTAIN_PANE" > "$TMP_ROOT/captain-pane"
lab pane run "$PRIMARY_PANE" "CLAUDE_CONFIG_DIR='$CFG' '$STUB/primary/claude' --noprofile < '$TMP_ROOT/primary.sh'" >/dev/null || fail "primary start"
for _ in $(seq 1 60); do grep -q '^recorded$' "$TMP_ROOT/record.out" 2>/dev/null && break; sleep 0.5; done
grep -q '^recorded$' "$TMP_ROOT/record.out" || fail "primary never recorded"
wait_claude "$PRIMARY_PANE" || fail "primary not running"
echo "== setup: primary pane $PRIMARY_PANE (workspace $PRIMARY_WS), captain pane $CAPTAIN_PANE, osg $OSG_PANE, learning(dormant) $LEARN_PANE"
echo "== stored baseline:"; cat "$H/state/.restart-fingerprint"

UM=um-1
recover() {
  OUT=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
    -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT PATH="$FAKEBIN:$CORE_PATH" FM_HOME="$H" \
    FM_RESTART_BOOT_ID_FILE="$TMP_ROOT/boot_id" FM_RESTART_USER_MANAGER_ID="$UM" \
    FM_RESTART_POLL=0.5 FM_RESTART_LAUNCH_WAIT=30 FM_RESTART_HERDR_WAIT="${WAIT:-60}" FM_RESTART_MAX_PASSES=20 \
    "$RR" run 2>&1); RC=$?
  printf -- '--- run (rc=%s):\n%s\n' "$RC" "$OUT"
}
restart_lab() {
  "$LAB_HELPER" stop "$SESSION" >/dev/null || fail "stop"
  provision || fail "reprovision"
  local p; for p in "$PRIMARY_PANE" "$CAPTAIN_PANE" "${SM_PANES[@]}"; do wait_shell "$p" || fail "pane $p not a shell"; done
}

echo; echo "=== S1: user service manager restart (logout with lingering off), state/.afk present"
touch "$H/state/.afk"
restart_lab; UM=um-2
recover
[ "$RC" -eq 0 ] || fail "S1 rc"
assert_contains "$OUT" "restart recovery after user service manager restart" "S1 class"
assert_contains "$OUT" "away mode: state/.afk survived the restart" "S1 afk"
[ "$(launches_in "$OSG_HOME")" -eq 2 ] || fail "S1 osg"
[ "$(launches_in "$LEARN_HOME")" -eq 1 ] || fail "S1 dormant relaunched"
[ "$(launches_in "$H")" -eq 1 ] && pane_runs_claude "$PRIMARY_PANE" || fail "S1 primary"
pass "S1 user-manager restart classified; osg + primary back, dormant stays down, .afk reported"

echo; echo "=== S2: Herdr-only restart (same boot id, same user manager)"
rm -f "$H/state/.afk"
# No session start recorded since S1 (stand-ins do not record), so the stored
# baseline still reads um-1: keep the user manager at um-1 for a Herdr-only restart.
UM=um-1
restart_lab
recover
[ "$RC" -eq 0 ] || fail "S2 rc"
assert_contains "$OUT" "restart recovery after Herdr server restart" "S2 class"
case "$OUT" in *"away mode"*) fail "S2 afk note without .afk" ;; esac
[ "$(launches_in "$OSG_HOME")" -eq 3 ] && [ "$(launches_in "$LEARN_HOME")" -eq 1 ] && [ "$(launches_in "$H")" -eq 2 ] || fail "S2 launches"
pass "S2 Herdr-only restart classified and recovered; no away-mode note without .afk"

echo; echo "=== S3: Herdr absent at boot: bounded wait, no spawns, one alert"
"$LAB_HELPER" stop "$SESSION" >/dev/null || fail "stop"
printf 'boot-2\n' > "$TMP_ROOT/boot_id"
t0=$(date +%s); WAIT=4 recover; t1=$(date +%s)
[ "$RC" -eq 4 ] || fail "S3 rc"; assert_contains "$OUT" "Herdr did not answer" "S3 message"
[ $((t1 - t0)) -le 30 ] || fail "S3 wait unbounded ($((t1-t0))s)"
WAIT=4 recover; [ "$RC" -eq 4 ] || fail "S3 rc2"; assert_contains "$OUT" "alert already raised in this window" "S3 once"
[ "$(grep -c 'restart-recovery-alert:herdr-unavailable' "$H/state/.wake-queue")" -eq 1 ] || fail "S3 alert count"
[ "$(launches_in "$OSG_HOME")" -eq 3 ] && [ "$(launches_in "$H")" -eq 2 ] || fail "S3 launched"
echo "(first run took $((t1 - t0))s with FM_RESTART_HERDR_WAIT=4)"
pass "S3 Herdr absent: exit 4 within the bound, one alert across two attempts, nothing launched"

echo; echo "=== S4: a session start records a new fingerprint while the pass waits for Herdr (reboot, boot-2); reused-PID lock"
# The recorded primary pid is now reused by an unrelated claude-named process
# outside the home, and the fleet lock names it (lock from the earlier boot).
( cd "$TMP_ROOT" && exec "$STUB/sleep/claude" -e 'sleep 600' ) >/dev/null 2>&1 &
REUSED=$!; BG_PIDS+=("$REUSED"); sleep 0.3
sed -i "s/^harness_pid=.*/harness_pid=$REUSED/" "$H/state/.primary-endpoint"
printf '%s\n' "$REUSED" > "$H/state/.lock"
cp "$H/state/.primary-endpoint" "$TMP_ROOT/endpoint.bak"
( WAIT=90 recover > "$TMP_ROOT/s4.out" 2>&1 ) &
S4=$!; sleep 3
# A locked session start's restart-record hook runs now (outside a pane, so it
# drops the endpoint record; the captain's in-pane start would re-write it).
env -u HERDR_PANE_ID -u HERDR_ENV HERDR_SESSION="$SESSION" PATH="$FAKEBIN:$CORE_PATH" FM_HOME="$H" \
  FM_RESTART_BOOT_ID_FILE="$TMP_ROOT/boot_id" FM_RESTART_USER_MANAGER_ID="$UM" "$RR" record
echo "baseline after the mid-wait record:"; cat "$H/state/.restart-fingerprint"
cp "$TMP_ROOT/endpoint.bak" "$H/state/.primary-endpoint"
provision || fail "reprovision"
wait "$S4"; cat "$TMP_ROOT/s4.out"; OUT=$(cat "$TMP_ROOT/s4.out")
assert_contains "$OUT" "restart recovery after machine reboot" "S4 restart hidden by mid-wait record"
assert_contains "$OUT" "cleared a session lock whose pid belonged to the primary of an earlier boot" "S4 reused pid lock"
[ "$(launches_in "$OSG_HOME")" -eq 4 ] || fail "S4 osg"
[ "$(launches_in "$H")" -eq 3 ] && pane_runs_claude "$PRIMARY_PANE" || fail "S4 primary"
kill "$REUSED" 2>/dev/null; wait "$REUSED" 2>/dev/null
pass "S4 a mid-wait session start does not hide the reboot; a reused-PID lock is cleared and the primary is relaunched"

echo; echo "=== S5: two concurrent passes (boot-3) + captain relaunches the primary by hand after the early check"
restart_lab; printf 'boot-3\n' > "$TMP_ROOT/boot_id"
lab pane close "$PRIMARY_PANE" >/dev/null || fail "close primary pane"
touch "$TMP_ROOT/inject-captain"
( recover > "$TMP_ROOT/s5a.out" 2>&1 ) & A=$!
( sleep 0.3; recover > "$TMP_ROOT/s5b.out" 2>&1 ) & B=$!
wait "$A"; wait "$B"
cat "$TMP_ROOT/s5a.out" "$TMP_ROOT/s5b.out"
ALL=$(cat "$TMP_ROOT/s5a.out" "$TMP_ROOT/s5b.out")
[ "$(printf '%s\n' "$ALL" | grep -c 'another restart recovery pass is running')" -eq 1 ] || fail "S5 single flight"
[ "$(printf '%s\n' "$ALL" | grep -c 'restart recovery after machine reboot (')" -eq 1 ] || fail "S5 two passes"
[ "$(launches_in "$OSG_HOME")" -eq 5 ] || fail "S5 osg launched $(launches_in "$OSG_HOME") (want 5)"
cat "$TMP_ROOT/inject.log" || fail "S5 injection never fired"
assert_contains "$ALL" "primary firstmate: already running (a Claude process runs in this home, pid" "S5 final recheck"
assert_contains "$ALL" "nothing was typed into a new tab" "S5 nothing typed"
[ "$(launches_in "$H")" -eq 4 ] || fail "S5 primary launches $(launches_in "$H") (want 4: only the captain's)"
pane_runs_claude "$CAPTAIN_PANE" || fail "S5 captain primary not running"
NEWPANE=$(printf '%s\n' "$ALL" | sed -n 's/.*nothing was typed into a new tab [^ ]* in the recorded workspace [^,]*, pane [^:]*:\([^ )]*\).*/\1/p' | head -n1)
echo "new tab pane: $NEWPANE"
if [ -n "$NEWPANE" ] && pane_runs_claude "$NEWPANE"; then fail "S5 a second primary runs in the new tab"; fi
echo "record:"; cat "$(ls -1t "$H/state/restart-recovery/"*.txt | head -n1)"
pass "S5 one pass per boot under concurrency; a captain relaunch during the pass is seen at the final read and nothing is typed"
echo; echo "=== status subcommand"; FM_HOME="$H" "$RR" status
