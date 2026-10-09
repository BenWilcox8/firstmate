#!/usr/bin/env bash
# Live lab driver for the restart-recovery change (no-mistakes Test phase).
#
# Usage: restart-sweep-live.sh <code-root> <tag> <evidence-dir>
#   <code-root>  a firstmate tree whose bin/ runs (this change, or the base commit)
#   <tag>        label for the lab session and the transcript files
#
# Phase 1 (startup liveness sweep): the real bin/fm-bootstrap.sh network phase
#   with a fleet of local Herdr second mates in a named lab:
#     live    - running in its own open 2ndmate-live space (control)
#     away    - its space 2ndmate-away is open, but its recorded pane id names
#               an agent-free shell in the captain's own workspace "captain-notes"
#     closed  - its space 2ndmate-closed was closed by the captain
# Phase 2 (restart pass, change only): a reboot, then `fm-local-restart-recovery.sh
#   run`: live's agent is gone (relaunched in place + notice), away stays down
#   without its foreign pane being typed into, closed stays down.
# Phase 3 (agent-axi error text): fm-spawn of a second mate whose slot ledger is
#   bound to a former, missing workspace, with the installed (unfixed) agent-axi.
set -u
CODE_ROOT=$1
TAG=$2
EVID=$3
WT=/home/ben/.no-mistakes/worktrees/3665d600861c/01M4H3P65QYCK28T80Y6NXATBK
# shellcheck source=/dev/null
. "$CODE_ROOT/tests/lib.sh"
[ "$ROOT" = "$CODE_ROOT" ] || { echo "ROOT mismatch: $ROOT"; exit 2; }

LAB_HELPER=$WT/bin/fm-herdr-lab.sh
SESSION=$("$LAB_HELPER" name "sweep-$TAG") || fail "lab name"
TMP_ROOT=$(fm_test_tmproot "fm-nm-live-$TAG")
RR="$ROOT/bin/fm-local-restart-recovery.sh"
ORIGINAL_PATH=$PATH
CORE_PATH=$(fm_test_core_path)
UNFIXED_AGENT_AXI=$(command -v agent-axi)
TRANSCRIPT="$EVID/live-$TAG-transcript.txt"
: > "$TRANSCRIPT"
TEARDOWN_PENDING=0

log() { printf '%s\n' "$*" | tee -a "$TRANSCRIPT"; }
section() { log ""; log "===== $* ====="; }

cleanup_all() {
  local status=$1
  trap - EXIT INT TERM
  if [ "$TEARDOWN_PENDING" -eq 1 ]; then
    if "$LAB_HELPER" teardown "$SESSION"; then
      log "lab teardown: $SESSION removed, default-session tripwire unchanged"
    else
      log "lab teardown FAILED for $SESSION"
      status=1
    fi
  fi
  fm_test_cleanup
  exit "$status"
}
trap 'cleanup_all $?' EXIT
trap 'cleanup_all 130' INT
trap 'cleanup_all 143' TERM

# --- stand-ins (copied from tests/fm-local-restart-recovery-herdr-e2e.test.sh) ---
STUB="$TMP_ROOT/stub"
FAKEBIN="$STUB/bin"
TOOLS="$STUB/tools"
LAUNCH_LOG="$TMP_ROOT/launches"
mkdir -p "$FAKEBIN" "$TOOLS" "$STUB/sleep" "$STUB/primary"
: > "$LAUNCH_LOG"
ln -s "$(fm_test_tool perl)" "$STUB/sleep/claude"
ln -s "$(fm_test_tool bash)" "$STUB/primary/claude"
cat > "$FAKEBIN/claude" <<SH
#!$(fm_test_tool bash)
{ printf '%s' "\$PWD"; printf '\t%s' "\$@"; printf '\n'; } >> '$LAUNCH_LOG'
exec -a claude '$STUB/sleep/claude' -e 'sleep 86400'
SH
ln -s "$(fm_test_tool node)" "$FAKEBIN/node"
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
printf '%s\n' "\$*" >> '$TMP_ROOT/herdr-calls'
exec env PATH='$ORIGINAL_PATH' '$LAB_HELPER' run '$SESSION' "\$@"
SH
PANE_PATH="$FAKEBIN:$CORE_PATH"
cat > "$STUB/lab-shell" <<SH
#!$(fm_test_tool bash)
exec env PATH='$PANE_PATH' '$(fm_test_tool bash)' --noprofile --norc -i
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/herdr" "$STUB/lab-shell"
# Bootstrap's other tools, as in tests/fm-local-restart-recovery.test.sh make_toolchain.
fm_fake_exit0 "$TOOLS" chrome-devtools-axi gh tmux
fm_fake_version_tool "$TOOLS" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
fm_fake_version_tool "$TOOLS" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
fm_fake_version_tool "$TOOLS" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.29
printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLS/treehouse"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "no-mistakes version v1.46.0 (fake)"\nexit 0\n' > "$TOOLS/no-mistakes"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.2.4\nexit 0\n' > "$TOOLS/tasks-axi"
chmod +x "$TOOLS"/*

provision() {
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u HERDR_PANE_ID -u HERDR_TAB_ID \
    -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV \
    SHELL="$STUB/lab-shell" "$LAB_HELPER" provision "$SESSION"
}
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }
TEARDOWN_PENDING=1
provision || fail "lab provision"
log "lab session: $SESSION (code root: $CODE_ROOT)"

launches_in() { awk -F '\t' -v d="$1" '$1 == d { n++ } END { print n + 0 }' "$LAUNCH_LOG"; }
wait_launches() { for _ in $(seq 1 60); do [ "$(launches_in "$1")" -ge "$2" ] && return 0; sleep 0.5; done; return 1; }
fg_names() { lab pane process-info --pane "$1" 2>/dev/null | jq -c '[.result.process_info.foreground_processes[].name]'; }
pane_runs_claude() { fg_names "$1" | jq -e 'index("claude") != null' >/dev/null; }
wait_claude() { for _ in $(seq 1 60); do pane_runs_claude "$1" && return 0; sleep 0.5; done; return 1; }
wait_shell() {
  for _ in $(seq 1 60); do [ "$(fg_names "$1")" = '["bash"]' ] && return 0; sleep 0.5; done; return 1
}
pane_ws() { lab pane get "$1" 2>/dev/null | jq -r '.result.pane.workspace_id // "GONE"'; }
spaces() { lab workspace list | jq -c '[.result.workspaces[] | {id: .workspace_id, label}]'; }
new_workspace() {
  lab workspace create --cwd "$1" --label "$2" --no-focus | jq -er '.result.root_pane | [.workspace_id, .tab_id, .pane_id] | @tsv'
}

H="$TMP_ROOT/home"
mkdir -p "$H/state" "$H/data" "$H/config"
printf 'claude\n' > "$H/config/secondmate-harness"
printf 'codex\n' > "$H/config/crew-harness"
touch "$H/state/.last-watcher-beat"
printf 'boot-1\n' > "$TMP_ROOT/boot_id"
: > "$H/data/secondmates.md"
fm_git_identity fmtest fmtest@example.invalid
CFG="$TMP_ROOT/claude-config"
mkdir -p "$CFG/sessions" "$CFG/projects/home"

# add_secondmate <id> <start-agent:0|1>: registered home, its own 2ndmate-<id>
# space, and a meta recording its pane (the e2e's fixture).
declare -A SM_PANE SM_WS SM_HOME
add_secondmate() {
  local id=$1 start=$2 home="$TMP_ROOT/sm-$1" row ws tab pane
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  { git -C "$home" init -q -b main && git -C "$home" add -A && git -C "$home" commit -q -m init; } || fail "git $id"
  mkdir -p "$H/data/$id"
  printf 'Second mate %s charter.\n' "$id" > "$H/data/$id/brief.md"
  printf -- '- %s - %s supervisor (home: %s; scope: %s; projects: ; added 2026-10-09)\n' \
    "$id" "$id" "$home" "$id" >> "$H/data/secondmates.md"
  row=$(new_workspace "$home" "2ndmate-$id") || fail "workspace $id"
  IFS=$'\t' read -r ws tab pane <<<"$row"
  wait_shell "$pane" || fail "shell $id"
  if [ "$start" = 1 ]; then
    lab pane run "$pane" "claude --dangerously-skip-permissions" >/dev/null || fail "start $id"
    wait_launches "$home" 1 || fail "$id never started"
  fi
  fm_write_meta "$H/state/$id.meta" "window=$SESSION:$pane" "endpoint_task_id=$id" \
    "worktree=$home" "project=$home" "harness=claude" "kind=secondmate" "mode=secondmate" \
    "yolo=off" "model=claude-opus-5-5" "effort=high" "backend=herdr" "herdr_session=$SESSION" \
    "herdr_workspace_id=$ws" "herdr_tab_id=$tab" "herdr_pane_id=$pane" "home=$home" "projects="
  printf '{"version":1,"workspace":{"label":"2ndmate-%s","id":"%s"},"supervisorPaneId":null,"planOverrides":{},"slots":[]}\n' \
    "$id" "$ws" > "$home/state/.agent-axi-slots.json"
  SM_PANE[$id]=$pane SM_WS[$id]=$ws SM_HOME[$id]=$home
}

# --- the fleet ---------------------------------------------------------------
add_secondmate live 1
add_secondmate away 0
add_secondmate closed 1
# The captain's own workspace, with an agent-free shell: the pane a restart gave
# away's recorded pane id to.
row=$(new_workspace "$TMP_ROOT" captain-notes) || fail "captain workspace"
IFS=$'\t' read -r CAPT_WS _ CAPT_PANE <<<"$row"
wait_shell "$CAPT_PANE" || fail "captain shell"
lab pane send-text "$CAPT_PANE" "echo captain-notes-marker" >/dev/null 2>&1 || true
sed -i "s/^window=.*/window=$SESSION:$CAPT_PANE/; s/^herdr_pane_id=.*/herdr_pane_id=$CAPT_PANE/" "$H/state/away.meta"
# The captain closes the closed second mate's space.
lab workspace close "${SM_WS[closed]}" >/dev/null || fail "close closed space"

# The primary records its endpoint from its own pane, as in the e2e.
SID=5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b
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
row=$(new_workspace "$H" fleet) || fail "primary ws"
IFS=$'\t' read -r PRIMARY_WS _ PRIMARY_PANE <<<"$row"
wait_shell "$PRIMARY_PANE" || fail "primary shell"
lab pane run "$PRIMARY_PANE" "CLAUDE_CONFIG_DIR='$CFG' '$STUB/primary/claude' --noprofile < '$TMP_ROOT/primary.sh'" >/dev/null || fail "primary"
for _ in $(seq 1 60); do grep -q '^recorded$' "$TMP_ROOT/record.out" 2>/dev/null && break; sleep 0.5; done
grep -q '^recorded$' "$TMP_ROOT/record.out" || fail "primary never recorded: $(cat "$TMP_ROOT/record.out")"

# Herdr reports a raw-started stand-in's agent status as unknown for a few
# seconds; wait until it settles so the sweep's two-sample read is stable.
for _ in $(seq 1 60); do
  [ "$(lab agent get "${SM_PANE[live]}" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" = idle ] && break
  sleep 0.5
done
section "fleet before the startup sweep"
log "open spaces: $(spaces)"
log "live   recorded pane ${SM_PANE[live]} in workspace $(pane_ws "${SM_PANE[live]}") runs $(fg_names "${SM_PANE[live]}")"
log "away   space 2ndmate-away=${SM_WS[away]} open; recorded pane $CAPT_PANE is in workspace $(pane_ws "$CAPT_PANE") (captain-notes=$CAPT_WS) and runs $(fg_names "$CAPT_PANE")"
log "closed space 2ndmate-closed=${SM_WS[closed]} closed by the captain"

# --- phase 1: the startup liveness sweep ---------------------------------------
sweep() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    PATH="$FAKEBIN:$TOOLS:$CORE_PATH" TMUX='' FM_HOME="$H" FM_BACKEND=herdr HERDR_SESSION="$SESSION" \
    CLAUDE_CONFIG_DIR="$CFG" FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BACKEND_HERDR_AXI_BIN='' FM_RESTART_BOOT_ID_FILE="$TMP_ROOT/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
}
section "phase 1: bin/fm-bootstrap.sh (FM_BOOTSTRAP_NETWORK=only) startup liveness sweep"
SWEEP_OUT=$(sweep)
printf '%s\n' "$SWEEP_OUT" | grep -E 'secondmate (live|away|closed)|SECONDMATE_LIVENESS' | tee -a "$TRANSCRIPT"
sleep 3
section "fleet after the startup sweep"
log "open spaces: $(spaces)"
log "captain-notes pane $CAPT_PANE: workspace $(pane_ws "$CAPT_PANE"), runs $(fg_names "$CAPT_PANE" || echo GONE)"
log "pane-close calls: $(grep -c 'pane close' "$TMP_ROOT/herdr-calls" 2>/dev/null)"
grep 'pane close' "$TMP_ROOT/herdr-calls" 2>/dev/null | sed 's/^/  herdr /' | tee -a "$TRANSCRIPT"
log "agent launches: live=$(launches_in "${SM_HOME[live]}") away=$(launches_in "${SM_HOME[away]}") closed=$(launches_in "${SM_HOME[closed]}")"

if [ "$TAG" = base ]; then
  log "product Herdr calls that named the captain-notes pane $CAPT_PANE (sweep):"
  grep -F "$CAPT_PANE" "$TMP_ROOT/herdr-calls" | sort | uniq -c | sed 's/^/  /' | tee -a "$TRANSCRIPT"
  log "away's recorded endpoint after the sweep: $(grep -E '^(window|herdr_workspace_id)=' "$H/state/away.meta" | tr '\n' ' ')"
  section "base: phase 3 only"
else
  # --- phase 2: the restart pass ------------------------------------------------
  section "phase 2: a reboot, then the boot unit's fm-local-restart-recovery.sh run"
  # live's agent died in the restart; its pane in its own space is a bare shell.
  pid=$(lab pane process-info --pane "${SM_PANE[live]}" | jq -r '.result.process_info.foreground_processes[] | select(.name == "claude") | .pid')
  kill "$pid" 2>/dev/null
  wait_shell "${SM_PANE[live]}" || fail "live did not drop to a shell"
  # Baseline for the second mate home: its own locked session start before the reboot.
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
    PATH="$FAKEBIN:$CORE_PATH" FM_HOME="${SM_HOME[live]}" FM_RESTART_BOOT_ID_FILE="$TMP_ROOT/boot_id" \
    FM_RESTART_USER_MANAGER_ID=um-1 "$RR" record >/dev/null 2>&1
  printf 'boot-2\n' > "$TMP_ROOT/boot_id"
  PASS_OUT=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    -u HERDR_SESSION -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    PATH="$FAKEBIN:$CORE_PATH" FM_HOME="$H" CLAUDE_CONFIG_DIR="$CFG" \
    FM_RESTART_BOOT_ID_FILE="$TMP_ROOT/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
    FM_RESTART_POLL=0.5 FM_RESTART_LAUNCH_WAIT=30 FM_RESTART_HERDR_WAIT=60 \
    FM_BACKEND_HERDR_AXI_BIN='' "$RR" run 2>&1); PASS_RC=$?
  printf '%s\n' "$PASS_OUT" | tee -a "$TRANSCRIPT"
  log "pass exit status: $PASS_RC"
  wait_claude "${SM_PANE[live]}" && log "live pane ${SM_PANE[live]} runs $(fg_names "${SM_PANE[live]}") again"
  log "captain-notes pane $CAPT_PANE after the pass: workspace $(pane_ws "$CAPT_PANE"), runs $(fg_names "$CAPT_PANE")"
  log "captain-notes pane screen (last lines):"
  lab pane read "$CAPT_PANE" --source recent --lines 6 --format text 2>&1 | sed 's/^/  | /' | tee -a "$TRANSCRIPT"
  log "agent launches: live=$(launches_in "${SM_HOME[live]}") away=$(launches_in "${SM_HOME[away]}") closed=$(launches_in "${SM_HOME[closed]}")"
  log "product Herdr calls that named the captain-notes pane $CAPT_PANE (sweep + pass):"
  grep -F "$CAPT_PANE" "$TMP_ROOT/herdr-calls" | sort | uniq -c | sed 's/^/  /' | tee -a "$TRANSCRIPT"
  section "pass record"
  cat "$H/state/restart-recovery/"*.txt 2>/dev/null | tee -a "$TRANSCRIPT"
  section "check wake queued for the primary"
  grep 'restart-recovery:' "$H/state/.wake-queue" | tee -a "$TRANSCRIPT"
  section "live's steering inbox (the restart notice)"
  for f in "$H/state/live.inbox/"*.msg; do log "--- $f"; tee -a "$TRANSCRIPT" < "$f"; log ""; done
  log "inbox dirs for left-down second mates: away=$([ -e "$H/state/away.inbox" ] && echo present || echo none) closed=$([ -e "$H/state/closed.inbox" ] && echo present || echo none)"
  section "live's status boundary"
  tee -a "$TRANSCRIPT" < "$H/state/live.status"
  section "the second mate home's own locked session start (RESTART line)"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
    PATH="$FAKEBIN:$CORE_PATH" FM_HOME="${SM_HOME[live]}" FM_RESTART_BOOT_ID_FILE="$TMP_ROOT/boot_id" \
    FM_RESTART_USER_MANAGER_ID=um-1 "$RR" record 2>&1 | tee -a "$TRANSCRIPT"
  section "phase 2b: the primary's next session start runs the startup sweep again"
  SWEEP2=$(sweep)
  printf '%s\n' "$SWEEP2" | grep -E 'secondmate (live|away|closed)|SECONDMATE_LIVENESS' | tee -a "$TRANSCRIPT"
  sleep 2
  log "captain-notes pane $CAPT_PANE: workspace $(pane_ws "$CAPT_PANE"), runs $(fg_names "$CAPT_PANE")"
  log "agent launches: live=$(launches_in "${SM_HOME[live]}") away=$(launches_in "${SM_HOME[away]}") closed=$(launches_in "${SM_HOME[closed]}")"
  log "open spaces: $(spaces)"
fi

# --- phase 3: agent-axi's own refusal reaches the operator -------------------
section "phase 3: bin/fm-spawn.sh fresh --secondmate, slot ledger bound to a missing former workspace, installed agent-axi ($UNFIXED_AGENT_AXI, main $(git -C /home/ben/firstmate/projects/agent-axi rev-parse --short HEAD))"
add_secondmate fresh 0
OLD_WS=${SM_WS[fresh]}
lab workspace close "$OLD_WS" >/dev/null || fail "close fresh"
row=$(new_workspace "$TMP_ROOT" 2ndmate-fresh) || fail "new fresh space"
NEW_WS=${row%%$'\t'*}
log "fresh: former workspace $OLD_WS is gone; its space 2ndmate-fresh came back as $NEW_WS; ledger: $(cat "${SM_HOME[fresh]}/state/.agent-axi-slots.json")"
SPAWN_OUT=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
  -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  PATH="$FAKEBIN:$CORE_PATH" FM_HOME="$H" CLAUDE_CONFIG_DIR="$CFG" HERDR_SESSION="$SESSION" \
  FM_SPAWN_NO_GUARD=1 FM_BACKEND_HERDR_AXI_BIN="$UNFIXED_AGENT_AXI" FM_BACKEND_HERDR_AXI_LAUNCH="$STUB/lab-shell" \
  "$ROOT/bin/fm-spawn.sh" fresh --secondmate --backend herdr 2>&1); SPAWN_RC=$?
log "\$ bin/fm-spawn.sh fresh --secondmate --backend herdr   (exit $SPAWN_RC)"
printf '%s\n' "$SPAWN_OUT" | tee -a "$TRANSCRIPT"
log "fresh launches: $(launches_in "${SM_HOME[fresh]}")"
exit 0
