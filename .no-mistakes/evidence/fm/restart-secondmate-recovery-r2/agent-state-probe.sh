#!/usr/bin/env bash
# Probe: does a raw-started claude stand-in's Herdr agent status flip during the
# first seconds, and does the liveness-skip hook change the sweep's next read?
set -u
WT=/home/ben/.no-mistakes/worktrees/3665d600861c/01M4H3P65QYCK28T80Y6NXATBK
. "$WT/tests/lib.sh"
LAB_HELPER=$WT/bin/fm-herdr-lab.sh
SESSION=$("$LAB_HELPER" name probe) || exit 1
TMP_ROOT=$(fm_test_tmproot fm-nm-probe)
ORIGINAL_PATH=$PATH
CORE_PATH=$(fm_test_core_path)
STUB="$TMP_ROOT/stub"; FAKEBIN="$STUB/bin"; mkdir -p "$FAKEBIN" "$STUB/sleep"
ln -s "$(fm_test_tool perl)" "$STUB/sleep/claude"
cat > "$FAKEBIN/claude" <<SH
#!$(fm_test_tool bash)
exec -a claude '$STUB/sleep/claude' -e 'sleep 86400'
SH
cat > "$FAKEBIN/herdr" <<SH
#!$(fm_test_tool bash)
set -u
args=("\$@"); last=\$((\${#args[@]} - 1)); flag=\$((last - 1))
if [ "\${#args[@]}" -ge 2 ] && [ "\${args[\$flag]}" = --session ] && [ "\${args[\$last]}" = '$SESSION' ]; then unset "args[\$last]" "args[\$flag]"; fi
set -- "\${args[@]}"
for arg in "\$@"; do case "\$arg" in --session|--session=*) exit 9 ;; esac; done
exec env PATH='$ORIGINAL_PATH' '$LAB_HELPER' run '$SESSION' "\$@"
SH
cat > "$STUB/lab-shell" <<SH
#!$(fm_test_tool bash)
exec env PATH='$FAKEBIN:$CORE_PATH' '$(fm_test_tool bash)' --noprofile --norc -i
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/herdr" "$STUB/lab-shell"
trap '"$LAB_HELPER" teardown "$SESSION" && echo "teardown ok: $SESSION"; fm_test_cleanup' EXIT
env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV \
  SHELL="$STUB/lab-shell" "$LAB_HELPER" provision "$SESSION" || exit 1
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }
H="$TMP_ROOT/home"; SM="$TMP_ROOT/sm-live"; mkdir -p "$H/state" "$H/data" "$SM/state"
printf 'live\n' > "$SM/.fm-secondmate-home"
row=$(lab workspace create --cwd "$SM" --label 2ndmate-live --no-focus | jq -er '.result.root_pane | [.workspace_id, .tab_id, .pane_id] | @tsv')
IFS=$'\t' read -r WS TAB PANE <<<"$row"
sleep 2
fm_write_meta "$H/state/live.meta" "window=$SESSION:$PANE" "kind=secondmate" "harness=claude" "home=$SM" \
  "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WS" "herdr_pane_id=$PANE"
lab pane run "$PANE" "claude --x" >/dev/null
T0=$(date +%s)
state() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION PATH="$FAKEBIN:$CORE_PATH" FM_HOME="$H" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state herdr "$1"' "$WT" "$SESSION:$PANE" 2>/dev/null
}
skip() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION PATH="$FAKEBIN:$CORE_PATH" FM_HOME="$H" \
    "$WT/bin/fm-local-restart-recovery.sh" liveness-skip live >/dev/null 2>&1; echo $?
}
for i in $(seq 1 14); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // .error.code')
  if [ $((i % 2)) -eq 0 ]; then
    rc=$(skip); s=$(state); echo "t+$(( $(date +%s) - T0 ))s registry=$st  liveness-skip rc=$rc  then sweep-read=$s"
  else
    s=$(state); echo "t+$(( $(date +%s) - T0 ))s registry=$st  (no hook)          sweep-read=$s"
  fi
done
