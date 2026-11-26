#!/usr/bin/env bash
# fm-session-ledger.sh: the machine-level agent session ledger and its restore.
#
# The ledger must record the exact session each Herdr pane runs, survive a
# crash with every entry valid, and restore only those exact sessions - never
# a fresh one. These tests drive the public verbs against a fake /proc tree
# (FM_SESSION_LEDGER_PROC) that stands in for the agent process, a fake Claude
# config that holds its per-process session record, and a fake Herdr CLI that
# serves a snapshot and records every mutation. No harness binary, no model,
# and no real Herdr server is involved; the live crash tests are recorded in
# the pull request evidence.
#   1. hook + writer: SessionStart writes the full entry (location, layout,
#      launch arguments without the prompt, filtered environment, fleet
#      identity); busy events update the state; /clear replaces the pane's
#      entry; a deliberate exit removes it; a crash-class exit keeps it.
#   2. the hook is silent and always exits 0, even on bad input.
#   3. restore --dry-run plans same-pane, split, rebuild, running, and missing
#      transcript cases and changes nothing.
#   4. restore launches only native resumes of recorded sessions, rebuilds the
#      recorded layout, and never types a fresh launch; a resumed worker's
#      record moves to its new pane and keeps its PR region last.
#   5. can-resume gates automatic recovery.
#   6. install-hooks and uninstall-hooks are idempotent and keep other hooks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER_BIN="$ROOT/bin/fm-session-ledger.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq is required"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "skip: flock is required"; exit 0; }
command -v setsid >/dev/null 2>&1 || { echo "skip: setsid is required"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-session-ledger)
FAKE_PROC="$TMP_ROOT/proc"
CFG="$TMP_ROOT/claude"
HERDR_DIR="$TMP_ROOT/herdr"
mkdir -p "$FAKE_PROC" "$CFG/sessions" "$CFG/projects/p" "$HERDR_DIR" "$TMP_ROOT/bin"

export FM_SESSION_LEDGER_DIR="$TMP_ROOT/ledger"
export FM_SESSION_LEDGER_PROC="$FAKE_PROC"
export FM_SESSION_LEDGER_HERDR="$TMP_ROOT/bin/herdr"
export FM_SESSION_LEDGER_PRIMARY_HOME="$TMP_ROOT/primary"
export FM_SESSION_LEDGER_SETTLE=0
export CLAUDE_CONFIG_DIR="$CFG"
export FAKE_HERDR_DIR="$HERDR_DIR"
mkdir -p "$FM_SESSION_LEDGER_PRIMARY_HOME/state"

# A fake Herdr CLI: serves $FAKE_HERDR_DIR/snapshot.json, answers pane reads
# from it, and logs every call. The file "down" makes every call fail, as a
# killed server does.
cat >"$TMP_ROOT/bin/herdr" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_HERDR_DIR
printf '%s\n' "$*" >>"$d/calls.log"
[ ! -e "$d/down" ] || exit 1
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then shift 2; continue; fi
  args+=("$1"); shift
done
set -- "${args[@]}"
next_id() { n=$(cat "$d/counter" 2>/dev/null || echo 100); n=$((n + 1)); echo "$n" >"$d/counter"; echo "$n"; }
case "$1 $2" in
  "api snapshot") cat "$d/snapshot.json" ;;
  "pane get")
    if jq -e --arg p "$3" '.result.snapshot.panes[] | select(.pane_id == $p)' "$d/snapshot.json" >/dev/null; then
      jq -c --arg p "$3" '{result: {pane: (.result.snapshot.panes[] | select(.pane_id == $p))}}' "$d/snapshot.json"
    else
      echo '{"error":{"code":"pane_not_found"}}'
    fi ;;
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "pane process-info")
    if [ -f "$d/busy-$4" ]; then echo '{"result":{"process_info":{"foreground_process_group_id":2,"shell_pid":1}}}'
    else echo '{"result":{"process_info":{"foreground_process_group_id":1,"shell_pid":1}}}'; fi ;;
  "pane split") n=$(next_id); echo "{\"result\":{\"pane\":{\"pane_id\":\"wN:p$n\"}}}" ;;
  "workspace create") n=$(next_id); echo "{\"result\":{\"workspace\":{\"workspace_id\":\"wN$n\"},\"tab\":{\"tab_id\":\"wN$n:t1\"},\"root_pane\":{\"pane_id\":\"wN$n:p1\"}}}" ;;
  "tab create") n=$(next_id); echo "{\"result\":{\"tab\":{\"tab_id\":\"wT:t$n\"},\"root_pane\":{\"pane_id\":\"wT:p$n\"}}}" ;;
  "pane run")
    printf '%s\n' "$4" >>"$d/typed.log"
    # The file "start-on-run" makes the typed resume run: a fake process and
    # its Claude session record appear, as a real resume would make them.
    if [ -e "$d/start-on-run" ]; then
      sid=$(printf '%s' "$4" | sed -n 's/.*--resume \([0-9a-f-]*\).*/\1/p')
      mkdir -p "$FM_SESSION_LEDGER_PROC/7701"
      printf '7701 (claude) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 77 0 0\n' >"$FM_SESSION_LEDGER_PROC/7701/stat"
      printf '{"pid":7701,"sessionId":"%s","procStart":"77"}\n' "$sid" >"$CLAUDE_CONFIG_DIR/sessions/7701.json"
    fi
    echo '{"result":{}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/herdr"

# The live layout: workspace w1 "fleet", tab w1:t1 "crew" with three panes.
write_snapshot() {
  cat >"$HERDR_DIR/snapshot.json" <<'EOF'
{"result":{"snapshot":{
 "workspaces":[{"workspace_id":"w1","label":"fleet","number":1}],
 "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"crew","number":1}],
 "panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","cwd":"/tmp/a","label":"lead"},
          {"pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1","cwd":"/tmp/b"},
          {"pane_id":"w1:p3","tab_id":"w1:t1","workspace_id":"w1","cwd":"/tmp/c","label":"third"}],
 "layouts":[{"tab_id":"w1:t1","workspace_id":"w1",
   "splits":[{"id":"split_0_root","direction":"right","ratio":0.4},{"id":"split_1_1","direction":"down","ratio":0.3}],
   "panes":[{"pane_id":"w1:p1","rect":{"x":0,"y":0,"width":40,"height":40}},
            {"pane_id":"w1:p2","rect":{"x":40,"y":0,"width":60,"height":12}},
            {"pane_id":"w1:p3","rect":{"x":40,"y":12,"width":60,"height":28}}]}],
 "agents":[]}}}
EOF
}
write_snapshot

# fake_agent <pid> <start> <cwd> <env-lines> <arg...>: a fake /proc entry and
# the Claude per-process session record for it. FAKE_PPID sets its parent.
fake_agent() {
  local pid=$1 start=$2 cwd=$3 envs=$4 i
  shift 4
  mkdir -p "$FAKE_PROC/$pid"
  printf '%s (claude) S %s 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$pid" "${FAKE_PPID:-1}" "$start" >"$FAKE_PROC/$pid/stat"
  : >"$FAKE_PROC/$pid/cmdline"
  for i in "$@"; do printf '%s\0' "$i" >>"$FAKE_PROC/$pid/cmdline"; done
  : >"$FAKE_PROC/$pid/environ"
  while IFS= read -r i; do [ -z "$i" ] || printf '%s\0' "$i" >>"$FAKE_PROC/$pid/environ"; done <<<"$envs"
  ln -sfn "$cwd" "$FAKE_PROC/$pid/cwd"
}

session_record() {  # <pid> <start> <session-id>
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}\n' "$1" "$3" "$2" >"$CFG/sessions/$1.json"
}

# hook_event <pid> <pane> <json>: run the hook as a child of fake agent <pid>.
# The subshell's own pid is the hook's parent, so it carries the agent's
# per-process record for the duration of the call.
hook_event() {
  local pid=$1 pane=$2 json=$3
  (
    me=$BASHPID
    cp -r "$FAKE_PROC/$pid" "$FAKE_PROC/$me" 2>/dev/null
    cp "$CFG/sessions/$pid.json" "$CFG/sessions/$me.json"
    printf '%s' "$json" | HERDR_PANE_ID=$pane HERDR_TAB_ID=w1:t1 HERDR_WORKSPACE_ID=w1 \
      HERDR_SOCKET_PATH="$HERDR_DIR/herdr.sock" "$LEDGER_BIN" hook claude
    echo "rc=$?"
  )
}

entry_file() { printf '%s/entries/claude-%s.json' "$FM_SESSION_LEDGER_DIR" "$1"; }

wait_for() {  # <shell-test> <label>
  local i
  for i in $(seq 1 100); do
    if eval "$1"; then return 0; fi
    sleep 0.05
  done
  fail "timed out waiting: $2"
}

SID1=11111111-1111-4111-8111-111111111111
SID2=22222222-2222-4222-8222-222222222222
SID3=33333333-3333-4333-8333-333333333333
: >"$HERDR_DIR/herdr.sock"

test_session_start_writes_the_full_entry() {
  mkdir -p "$TMP_ROOT/wt1"
  # A fleet worker: its record lives in the primary home.
  printf 'kind=ship\nworktree=%s\nherdr_session=default\nherdr_pane_id=w1:p1\nwindow=default:w1:p1\n' "$TMP_ROOT/wt1" \
    >"$FM_SESSION_LEDGER_PRIMARY_HOME/state/task-a.meta"
  fake_agent 4101 777 "$TMP_ROOT/wt1" $'FM_TASK_ID=task-a\nCLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1\nCLAUDE_CODE_OAUTH_TOKEN=secret\nHOME=/home/x\nCOMPACT_ADVISER_DISABLE=1' \
    /usr/bin/claude --dangerously-skip-permissions --settings '{"a":1}' --model haiku --add-dir /x /y --resume old-id --name "Task A" "the long launch brief"
  session_record 4101 777 "$SID1"
  : >"$CFG/projects/p/$SID1.jsonl"
  local out
  out=$(hook_event 4101 w1:p1 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID1\",\"transcript_path\":\"$CFG/projects/p/$SID1.jsonl\",\"cwd\":\"$TMP_ROOT/wt1\"}")
  assert_equals "rc=0" "$out" "hook prints nothing and exits 0"
  wait_for "[ -f '$(entry_file "$SID1")' ]" "SessionStart entry"
  local e
  e=$(cat "$(entry_file "$SID1")")
  assert_equals "w1:p1 fleet crew lead" "$(printf '%s' "$e" | jq -r '[.herdr.pane_id, .herdr.workspace_label, .herdr.tab_label, .herdr.pane_label] | join(" ")')" "location comes from the Herdr snapshot"
  assert_equals "default" "$(printf '%s' "$e" | jq -r '.herdr.session')" "session from the socket path"
  assert_equals 3 "$(printf '%s' "$e" | jq -r '.herdr.tab_layout.panes | length')" "the tab layout is recorded"
  assert_equals '["claude","--dangerously-skip-permissions","--settings","{\"a\":1}","--model","haiku","--add-dir","/x","/y","--name","Task A"]' \
    "$(printf '%s' "$e" | jq -c '.argv')" "launch arguments keep flags and drop the prompt and the old resume"
  assert_equals "--resume $SID1" "$(printf '%s' "$e" | jq -r '.resume_argv[-2:] | join(" ")')" "resume arguments end with the exact session"
  assert_equals true "$(printf '%s' "$e" | jq -r '.initial_prompt_dropped')" "the prompt is reported dropped"
  assert_equals '{"CLAUDE_CODE_FORCE_SESSION_PERSISTENCE":"1","COMPACT_ADVISER_DISABLE":"1","FM_TASK_ID":"task-a"}' \
    "$(printf '%s' "$e" | jq -cS '.env')" "environment keeps launch variables and never a credential"
  assert_equals "worker task-a $FM_SESSION_LEDGER_PRIMARY_HOME ship" \
    "$(printf '%s' "$e" | jq -r '[.fleet.role, .fleet.task_id, .fleet.home, .fleet.kind] | join(" ")')" "fleet identity with its record home"
  assert_equals idle "$(printf '%s' "$e" | jq -r '.state')" "a new session starts idle"
  pass "SessionStart writes the full entry"
}

test_busy_events_update_the_state() {
  hook_event 4101 w1:p1 "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID1\"}" >/dev/null
  wait_for "[ \"\$(jq -r .state '$(entry_file "$SID1")')\" = working ]" "working state"
  hook_event 4101 w1:p1 "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID1\"}" >/dev/null
  wait_for "[ \"\$(jq -r .state '$(entry_file "$SID1")')\" = idle ]" "idle state"
  hook_event 4101 w1:p1 "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID1\"}" >/dev/null
  wait_for "[ \"\$(jq -r .state '$(entry_file "$SID1")')\" = working ]" "working again"
  pass "UserPromptSubmit and Stop update the busy state"
}

test_clear_replaces_the_pane_entry() {
  fake_agent 4102 778 /tmp/b "" /usr/bin/claude
  session_record 4102 778 "$SID2"
  hook_event 4102 w1:p2 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID2\",\"transcript_path\":\"$CFG/projects/p/$SID2.jsonl\",\"cwd\":\"/tmp/b\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SID2")' ]" "second entry"
  assert_equals null "$(jq -c .fleet "$(entry_file "$SID2")")" "a hand-opened session has no fleet identity"
  # /clear: the same process gets a new session id in the same pane.
  session_record 4102 778 "$SID3"
  hook_event 4102 w1:p2 "{\"hook_event_name\":\"SessionStart\",\"source\":\"clear\",\"session_id\":\"$SID3\",\"transcript_path\":\"$CFG/projects/p/$SID3.jsonl\",\"cwd\":\"/tmp/b\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SID3")' ] && [ ! -f '$(entry_file "$SID2")' ]" "clear replaces the pane's entry"
  assert_equals clear "$(jq -r .start_source "$(entry_file "$SID3")")" "the new entry records the clear"
  pass "/clear records the new session id and replaces the old entry"
}

test_session_end_keeps_a_crash_and_removes_a_deliberate_exit() {
  # A dying server: Herdr does not answer, so the end is crash-class.
  : >"$HERDR_DIR/down"
  hook_event 4102 w1:p2 "{\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\",\"session_id\":\"$SID3\"}" >/dev/null
  wait_for "[ \"\$(jq -r '.end.reason // empty' '$(entry_file "$SID3")')\" = other ]" "crash-class end marked"
  rm -f "$HERDR_DIR/down"
  assert_present "$(entry_file "$SID3")" "a crash-class end keeps the entry"
  # A deliberate /exit removes it.
  hook_event 4102 w1:p2 "{\"hook_event_name\":\"SessionEnd\",\"reason\":\"prompt_input_exit\",\"session_id\":\"$SID3\"}" >/dev/null
  wait_for "[ ! -f '$(entry_file "$SID3")' ]" "deliberate exit removes the entry"
  # A pane closed by hand while Herdr runs: Herdr answers and the pane is gone.
  fake_agent 4103 779 /tmp/c "" /usr/bin/claude
  session_record 4103 779 "$SID2"
  hook_event 4103 w1:p9 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID2\",\"transcript_path\":\"$CFG/projects/p/$SID2.jsonl\",\"cwd\":\"/tmp/c\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SID2")' ]" "entry for the hand-closed pane"
  hook_event 4103 w1:p9 "{\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\",\"session_id\":\"$SID2\"}" >/dev/null
  wait_for "[ ! -f '$(entry_file "$SID2")' ]" "a pane closed while Herdr runs removes the entry"
  pass "SessionEnd keeps a crash-class end and removes a deliberate one"
}

SID6=66666666-6666-4666-8666-666666666666

test_a_fresh_relaunch_replaces_the_fleet_entry() {
  # task-a's agent is relaunched fresh in another pane: the older entry of the
  # same fleet agent can never be restored beside it.
  fake_agent 4104 780 "$TMP_ROOT/wt1" 'FM_TASK_ID=task-a' /usr/bin/claude --model haiku
  session_record 4104 780 "$SID6"
  printf 'kind=ship\nworktree=%s\nherdr_session=default\nherdr_pane_id=w1:p3\nwindow=default:w1:p3\n' "$TMP_ROOT/wt1" \
    >"$FM_SESSION_LEDGER_PRIMARY_HOME/state/task-a.meta"
  hook_event 4104 w1:p3 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID6\",\"transcript_path\":\"$CFG/projects/p/$SID6.jsonl\",\"cwd\":\"$TMP_ROOT/wt1\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SID6")' ] && [ ! -f '$(entry_file "$SID1")' ]" "the fresh session replaces the task's older entry"
  pass "a fresh relaunch of a fleet agent replaces its older entry"
}

SID7=77777777-7777-4777-8777-777777777777
SID8=88888888-8888-4888-8888-888888888888
SID9=99999999-9999-4999-8999-999999999999
SIDA=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
SIDB=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb

# Every detached writer removes its event payload when it finishes.
writers_done() {
  wait_for "! ls '$FM_SESSION_LEDGER_DIR'/.event.* >/dev/null 2>&1" "detached writers"
}

test_a_nested_print_session_never_replaces_the_agent() {
  mkdir -p "$TMP_ROOT/wt2"
  printf 'kind=ship\nworktree=%s\nherdr_session=default\nherdr_pane_id=w1:p2\nwindow=default:w1:p2\n' "$TMP_ROOT/wt2" \
    >"$FM_SESSION_LEDGER_PRIMARY_HOME/state/task-n.meta"
  fake_agent 4501 781 "$TMP_ROOT/wt2" 'FM_TASK_ID=task-n' /usr/bin/claude --model haiku
  session_record 4501 781 "$SID7"
  hook_event 4501 w1:p2 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID7\",\"transcript_path\":\"$CFG/projects/p/$SID7.jsonl\",\"cwd\":\"$TMP_ROOT/wt2\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SID7")' ]" "the worker's entry"
  # The worker runs `claude -p` through its Bash tool: the child inherits the
  # pane and the fleet environment, and its hooks fire in the same pane.
  FAKE_PPID=4501 fake_agent 4502 782 "$TMP_ROOT/wt2" 'FM_TASK_ID=task-n' /usr/bin/claude -p "check the hook"
  session_record 4502 782 "$SID8"
  hook_event 4502 w1:p2 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID8\",\"transcript_path\":\"$CFG/projects/p/$SID8.jsonl\",\"cwd\":\"$TMP_ROOT/wt2\"}" >/dev/null
  hook_event 4502 w1:p2 "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID8\"}" >/dev/null
  # An interactive agent that another agent started is nested too.
  FAKE_PPID=4501 fake_agent 4503 783 "$TMP_ROOT/wt2" 'FM_TASK_ID=task-n' /usr/bin/claude --model haiku
  session_record 4503 783 "$SID9"
  hook_event 4503 w1:p2 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID9\",\"transcript_path\":\"$CFG/projects/p/$SID9.jsonl\",\"cwd\":\"$TMP_ROOT/wt2\"}" >/dev/null
  # A print-mode run straight from a pane shell has no resumable session.
  fake_agent 4504 784 /tmp/b '' /usr/bin/claude --print "one shot"
  session_record 4504 784 "$SIDA"
  hook_event 4504 w1:p8 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SIDA\",\"transcript_path\":\"$CFG/projects/p/$SIDA.jsonl\",\"cwd\":\"/tmp/b\"}" >/dev/null
  writers_done
  assert_present "$(entry_file "$SID7")" "the worker keeps its entry"
  assert_equals "worker task-n" "$(jq -r '[.fleet.role, .fleet.task_id] | join(" ")' "$(entry_file "$SID7")")" "the entry is still the worker's own session"
  assert_absent "$(entry_file "$SID8")" "a nested print session writes no entry"
  assert_absent "$(entry_file "$SID9")" "an agent that another agent started writes no entry"
  assert_absent "$(entry_file "$SIDA")" "a print-mode run writes no entry"
  rm -f "$CFG"/sessions/*.json
  pass "a nested or print-mode session never replaces the pane's agent"
}

test_the_primary_comes_from_its_endpoint_record() {
  local home=$FM_SESSION_LEDGER_PRIMARY_HOME
  printf 'backend=herdr\nherdr_session=default\npane=w1:p1\nharness=claude\nharness_pid=99999\n' >"$home/state/.primary-endpoint"
  fake_agent 4601 785 "$home" '' /usr/bin/claude
  session_record 4601 785 "$SID9"
  hook_event 4601 w1:p1 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID9\",\"transcript_path\":\"$CFG/projects/p/$SID9.jsonl\",\"cwd\":\"$home\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SID9")' ]" "the primary's entry"
  assert_equals primary "$(jq -r '.fleet.role' "$(entry_file "$SID9")")" "the session in the endpoint pane is the primary"
  # The captain opens another Claude session in the primary home by hand.
  fake_agent 4602 786 "$home" '' /usr/bin/claude
  session_record 4602 786 "$SIDA"
  hook_event 4602 w1:p8 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SIDA\",\"transcript_path\":\"$CFG/projects/p/$SIDA.jsonl\",\"cwd\":\"$home\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SIDA")' ]" "the hand session's entry"
  writers_done
  assert_equals null "$(jq -c .fleet "$(entry_file "$SIDA")")" "another session in the primary home is opened by hand"
  assert_present "$(entry_file "$SID9")" "a hand session never replaces the primary's entry"
  # The primary is relaunched fresh in a new pane. Its session start writes
  # the endpoint record after the ledger built the entry, so the next busy
  # event makes it the primary and replaces the older primary entry.
  fake_agent 4603 787 "$home" '' /usr/bin/claude
  session_record 4603 787 "$SIDB"
  hook_event 4603 w1:p7 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SIDB\",\"transcript_path\":\"$CFG/projects/p/$SIDB.jsonl\",\"cwd\":\"$home\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SIDB")' ]" "the relaunched primary's entry"
  printf 'backend=herdr\nherdr_session=default\npane=w1:p7\nharness=claude\nharness_pid=99998\n' >"$home/state/.primary-endpoint"
  hook_event 4603 w1:p7 "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SIDB\"}" >/dev/null
  wait_for "[ \"\$(jq -r '.fleet.role // empty' '$(entry_file "$SIDB")')\" = primary ] && [ ! -f '$(entry_file "$SID9")' ]" "the relaunched primary replaces the older one"
  assert_equals null "$(jq -c .fleet "$(entry_file "$SIDA")")" "the hand session stays opened by hand"
  # After a crash, can-resume answers for the primary from the primary's entry.
  : >"$CFG/projects/p/$SIDB.jsonl"
  rm -f "$CFG"/sessions/*.json
  "$LEDGER_BIN" can-resume --primary "$home" >/dev/null
  expect_code 0 "$?" "the stopped primary can resume"
  rm -f "$CFG/projects/p/$SIDB.jsonl"
  "$LEDGER_BIN" can-resume --primary "$home" >/dev/null
  expect_code 1 "$?" "the hand session's entry never answers for the primary"
  rm -f "$home/state/.primary-endpoint"
  pass "the primary is the session its endpoint record names"
}

SIDC=cccccccc-cccc-4ccc-8ccc-cccccccccccc
SIDD=dddddddd-dddd-4ddd-8ddd-dddddddddddd
SIDE=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
SIDF=ffffffff-ffff-4fff-8fff-ffffffffffff

# A setsid that removes the agent's /proc entry before the detached writer
# starts, as a short-lived process that exits right after its hook does.
REAL_SETSID=$(command -v setsid)
mkdir -p "$TMP_ROOT/racebin"
cat >"$TMP_ROOT/racebin/setsid" <<'EOF'
#!/usr/bin/env bash
[ "$1" != -f ] || [ "$3" != record ] || rm -rf "${RACE_PROC:?}/$6"
exec "$REAL_SETSID" "$@"
EOF
chmod +x "$TMP_ROOT/racebin/setsid"

race_hook_event() {  # <pid> <pane> <json>
  (
    export PATH="$TMP_ROOT/racebin:$PATH" RACE_PROC="$FAKE_PROC" REAL_SETSID
    hook_event "$@"
  )
}

test_an_agent_that_exits_before_the_writer_never_replaces_an_entry() {
  mkdir -p "$TMP_ROOT/wt3"
  printf 'kind=ship\nworktree=%s\nherdr_session=default\nherdr_pane_id=w1:p6\nwindow=default:w1:p6\n' "$TMP_ROOT/wt3" \
    >"$FM_SESSION_LEDGER_PRIMARY_HOME/state/task-r.meta"
  fake_agent 4701 790 "$TMP_ROOT/wt3" 'FM_TASK_ID=task-r' /usr/bin/claude --model haiku
  session_record 4701 790 "$SIDC"
  hook_event 4701 w1:p6 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SIDC\",\"transcript_path\":\"$CFG/projects/p/$SIDC.jsonl\",\"cwd\":\"$TMP_ROOT/wt3\"}" >/dev/null
  wait_for "[ -f '$(entry_file "$SIDC")' ]" "the worker's entry"
  # The worker's `claude -p` child ends its turn and exits before the writer
  # of its Stop event runs.
  FAKE_PPID=4701 fake_agent 4702 791 "$TMP_ROOT/wt3" 'FM_TASK_ID=task-r' /usr/bin/claude -p "check the hook"
  session_record 4702 791 "$SIDD"
  race_hook_event 4702 w1:p6 "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SIDD\"}" >/dev/null
  # A pane's own agent that exits before its writer runs leaves no entry
  # built from a process that is gone.
  fake_agent 4703 792 /tmp/c '' /usr/bin/claude
  session_record 4703 792 "$SIDE"
  race_hook_event 4703 w1:p5 "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SIDE\"}" >/dev/null
  writers_done
  assert_present "$(entry_file "$SIDC")" "the worker keeps its entry"
  assert_equals "worker task-r" "$(jq -r '[.fleet.role, .fleet.task_id] | join(" ")' "$(entry_file "$SIDC")")" "the entry is still the worker's own session"
  assert_absent "$(entry_file "$SIDD")" "the exited nested child writes no entry"
  assert_absent "$(entry_file "$SIDE")" "an exited agent writes no new entry"
  # An existing entry still takes the busy state of an agent that is gone.
  race_hook_event 4701 w1:p6 "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SIDC\"}" >/dev/null
  wait_for "[ \"\$(jq -r .state '$(entry_file "$SIDC")')\" = working ]" "state of an existing entry"
  rm -f "$CFG"/sessions/*.json
  pass "an agent that exits before the writer runs never replaces an entry"
}

test_a_resumed_primary_in_a_new_pane_stays_the_primary() {
  local home=$FM_SESSION_LEDGER_PRIMARY_HOME
  printf 'backend=herdr\nherdr_session=default\npane=w1:p1\nharness=claude\nharness_pid=99999\n' >"$home/state/.primary-endpoint"
  fake_agent 4801 793 "$home" '' /usr/bin/claude
  session_record 4801 793 "$SIDF"
  hook_event 4801 w1:p1 "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SIDF\",\"transcript_path\":\"$CFG/projects/p/$SIDF.jsonl\",\"cwd\":\"$home\"}" >/dev/null
  wait_for "[ \"\$(jq -r '.fleet.role // empty' '$(entry_file "$SIDF")' 2>/dev/null)\" = primary ]" "the primary's entry"
  # After a reboot the restore resumes the primary in a rebuilt pane with a
  # new id. The endpoint record still names the old pane and process.
  rm -f "$CFG"/sessions/*.json
  fake_agent 4802 794 "$home" '' /usr/bin/claude --resume "$SIDF"
  session_record 4802 794 "$SIDF"
  hook_event 4802 w1:p4 "{\"hook_event_name\":\"SessionStart\",\"source\":\"resume\",\"session_id\":\"$SIDF\",\"transcript_path\":\"$CFG/projects/p/$SIDF.jsonl\",\"cwd\":\"$home\"}" >/dev/null
  wait_for "[ \"\$(jq -r .herdr.pane_id '$(entry_file "$SIDF")')\" = w1:p4 ]" "the resumed primary's entry"
  assert_equals primary "$(jq -r '.fleet.role' "$(entry_file "$SIDF")")" "the resumed primary keeps its identity in the new pane"
  : >"$CFG/projects/p/$SIDF.jsonl"
  rm -f "$CFG"/sessions/*.json
  "$LEDGER_BIN" can-resume --primary "$home" >/dev/null
  expect_code 0 "$?" "can-resume still answers for the resumed primary"
  rm -f "$home/state/.primary-endpoint"
  pass "a resumed primary in a new pane stays the primary"
}

test_hook_is_silent_and_never_fails() {
  local out rc
  out=$(printf 'not json' | HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$HERDR_DIR/herdr.sock" "$LEDGER_BIN" hook claude 2>&1)
  rc=$?
  assert_equals "0|" "$rc|$out" "bad input: exit 0, no output"
  out=$(printf '{}' | env -u HERDR_PANE_ID "$LEDGER_BIN" hook claude 2>&1)
  rc=$?
  assert_equals "0|" "$rc|$out" "outside Herdr: exit 0, no output"
  out=$(printf '{}' | HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=x FM_SESSION_LEDGER=off "$LEDGER_BIN" hook claude 2>&1)
  rc=$?
  assert_equals "0|" "$rc|$out" "disabled: exit 0, no output"
  pass "the hook is silent and always exits 0"
}

# Plan fixtures: SID1 (task-a, working) in w1:p1; SID2 hand session in w1:p2
# (pane runs something else); SID3 in w1:p3 with a missing transcript; a
# fourth in a tab that no longer exists; a fifth already running.
SID4=44444444-4444-4444-8444-444444444444
SID5=55555555-5555-4555-8555-555555555555

make_entry() {  # <sid> <pane> <tab> <ws> <ws-label> <transcript> <state> [fleet-json]
  jq -n --arg sid "$1" --arg pane "$2" --arg tab "$3" --arg ws "$4" --arg wl "$5" --arg tr "$6" --arg st "$7" \
    --argjson fleet "${8:-null}" '{
    schema: "fm-session-ledger/v1", agent: "claude", session_id: $sid, transcript: $tr, seq: 1, state: $st,
    cwd: "/tmp", argv: ["claude", "--model", "haiku"], resume_argv: ["claude", "--model", "haiku", "--resume", $sid],
    env: {FM_TASK_ID: "x"}, fleet: $fleet,
    herdr: {session: "default", workspace_id: $ws, workspace_label: $wl, tab_id: $tab, tab_label: "crew", pane_id: $pane,
      tab_layout: {splits: [{id: "split_0_root", direction: "right", ratio: 0.4}, {id: "split_1_1", direction: "down", ratio: 0.3}],
        panes: [{pane_id: ($ws + ":p1")}, {pane_id: ($ws + ":p2")}, {pane_id: ($ws + ":p3")}]},
      tab_panes: [{pane_id: ($ws + ":p1"), cwd: "/tmp", label: "lead"}, {pane_id: $pane, cwd: "/tmp", label: null}]}}' \
    >"$(entry_file "$1")"
}

setup_plan_fixture() {
  rm -f "$FM_SESSION_LEDGER_DIR"/entries/*.json "$HERDR_DIR/typed.log" "$HERDR_DIR"/busy-*
  : >"$CFG/projects/p/$SID1.jsonl"
  : >"$CFG/projects/p/$SID2.jsonl"
  : >"$CFG/projects/p/$SID4.jsonl"
  : >"$CFG/projects/p/$SID5.jsonl"
  rm -f "$CFG/projects/p/$SID3.jsonl"
  make_entry "$SID1" w1:p1 w1:t1 w1 fleet "$CFG/projects/p/$SID1.jsonl" working \
    "{\"role\":\"worker\",\"task_id\":\"task-a\",\"home\":\"$FM_SESSION_LEDGER_PRIMARY_HOME\",\"kind\":\"ship\"}"
  make_entry "$SID2" w1:p2 w1:t1 w1 fleet "$CFG/projects/p/$SID2.jsonl" idle
  make_entry "$SID3" w1:p3 w1:t1 w1 fleet "$CFG/projects/p/$SID3.jsonl" idle
  make_entry "$SID4" w9:p2 w9:t1 w9 gone "$CFG/projects/p/$SID4.jsonl" idle
  make_entry "$SID5" w1:p3 w1:t1 w1 fleet "$CFG/projects/p/$SID5.jsonl" idle
  # An entry of a named Herdr session that was deleted since (a finished lab).
  make_entry "$SID6" w5:p1 w5:t1 w5 lab "$CFG/projects/p/$SID1.jsonl" idle
  jq '.herdr.session = "fm-lab-gone" | .herdr.socket = "/nonexistent/sessions/fm-lab-gone/herdr.sock"' "$(entry_file "$SID6")" >"$TMP_ROOT/e6" && mv "$TMP_ROOT/e6" "$(entry_file "$SID6")"
  : >"$HERDR_DIR/busy-w1:p2"
  # SID5 runs now.
  rm -f "$CFG"/sessions/*.json
  fake_agent 4200 900 /tmp "" /usr/bin/claude
  session_record 4200 900 "$SID5"
}

test_restore_dry_run_plans_and_changes_nothing() {
  setup_plan_fixture
  : >"$HERDR_DIR/calls.log"
  local out
  out=$("$LEDGER_BIN" restore --dry-run)
  assert_contains "$out" "resume in same pane   claude $SID1 [worker:task-a, working] default fleet/crew/w1:p1" "same pane"
  assert_contains "$out" "resume in new split   claude $SID2 [hand, idle]" "a pane running something else gets a new split"
  assert_contains "$out" "rebuild workspace     claude $SID4" "a gone workspace is rebuilt"
  assert_contains "$out" "running      claude $SID5: already running; left alone" "a running session is left alone"
  assert_contains "$out" "missing      claude $SID3: transcript" "a missing transcript is reported"
  assert_contains "$out" "--resume $SID1" "the planned command resumes the exact session"
  assert_contains "$out" "3 would resume, 1 already running, 1 missing transcript" "dry-run summary"
  assert_contains "$out" "deleted      claude $SID6: Herdr session fm-lab-gone no longer exists; entry would be removed" "a deleted Herdr session is reported"
  assert_present "$(entry_file "$SID6")" "dry run keeps the deleted session's entry"
  assert_no_grep "pane run" "$HERDR_DIR/calls.log" "dry run types nothing"
  assert_no_grep "create" "$HERDR_DIR/calls.log" "dry run creates nothing"
  assert_no_grep "split" "$HERDR_DIR/calls.log" "dry run splits nothing"
  pass "restore --dry-run plans every case and changes nothing"
}

test_restore_resumes_only_recorded_sessions() {
  setup_plan_fixture
  : >"$HERDR_DIR/calls.log"
  local out
  out=$("$LEDGER_BIN" restore --wait 0 --pause 0 --batch 2)
  # Nothing really starts in the fake panes, so each launch reports failed;
  # what matters is what was typed and where.
  assert_equals 3 "$(wc -l <"$HERDR_DIR/typed.log" | tr -d ' ')" "three resumes typed"
  while IFS= read -r line; do
    case "$line" in
      *"--resume $SID1"* | *"--resume $SID2"* | *"--resume $SID4"*) ;;
      *) fail "a typed launch is not a recorded resume: $line" ;;
    esac
    assert_contains "$line" "cd -- /tmp && env -u CLAUDECODE" "the resume runs in the recorded directory"
  done <"$HERDR_DIR/typed.log"
  assert_no_grep "$SID3" "$HERDR_DIR/typed.log" "a missing transcript is never launched"
  assert_no_grep "$SID5" "$HERDR_DIR/typed.log" "a running session is never launched again"
  assert_grep "workspace create --cwd /tmp --label gone --no-focus" "$HERDR_DIR/calls.log" "the gone workspace is created with its label"
  assert_grep "pane split wN102:p1 --direction right --ratio 0.4" "$HERDR_DIR/calls.log" "the root split is replayed"
  assert_grep "pane split wN:p103 --direction down --ratio 0.3" "$HERDR_DIR/calls.log" "the nested split is replayed on the new pane"
  assert_grep "pane rename wN102:p1 lead" "$HERDR_DIR/calls.log" "pane names come back"
  assert_grep "pane split w1:p2 --direction right" "$HERDR_DIR/calls.log" "the busy pane is left alone and split"
  assert_grep "pane run wN:p103 cd -- /tmp" "$HERDR_DIR/calls.log" "the rebuilt session resumes in its own rebuilt pane"
  assert_contains "$out" "restore summary: 0 resumed, 3 failed" "launches that never run are reported as failed"
  assert_absent "$(entry_file "$SID6")" "a real run removes the entry of a deleted Herdr session"
  pass "restore types only native resumes of recorded sessions and rebuilds the layout"
}

# Live repro (Herdr 0.8.2 lab): the worker classify probes the recorded Herdr
# endpoint, and that probe starts the server of a deleted named session again.
# The stub classify does the same to its recorded session directory, so a
# restore that classified before it planned would see the session as present
# and never prune it. Oracle: the restore contract - a deleted named session's
# entries are reported and removed, and a dry run changes nothing.
test_restore_never_wakes_a_deleted_session_through_classify() {
  local home="$TMP_ROOT/labhome" sockdir="$TMP_ROOT/herdr-sessions/fm-lab-gone2" out
  rm -f "$FM_SESSION_LEDGER_DIR"/entries/*.json "$HERDR_DIR/typed.log"
  rm -rf "$home" "$sockdir"
  mkdir -p "$home/bin" "$home/state"
  printf 'kind=ship\nherdr_session=fm-lab-gone2\nherdr_pane_id=w1:p1\n' >"$home/state/task-z.meta"
  cat >"$home/bin/fm-local-worker-restore.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TMP_ROOT/classify.log"
mkdir -p "$sockdir" && : >"$sockdir/herdr.sock"
printf 'task-z\tworking\tit was working when it stopped\n'
EOF
  chmod +x "$home/bin/fm-local-worker-restore.sh"
  rm -f "$TMP_ROOT/classify.log"
  : >"$CFG/projects/p/$SID1.jsonl"
  make_entry "$SID1" w1:p1 w1:t1 w1 fleet "$CFG/projects/p/$SID1.jsonl" working \
    "{\"role\":\"worker\",\"task_id\":\"task-z\",\"home\":\"$home\",\"kind\":\"ship\"}"
  jq --arg sock "$sockdir/herdr.sock" '.herdr.session = "fm-lab-gone2" | .herdr.socket = $sock' "$(entry_file "$SID1")" >"$TMP_ROOT/e1" \
    && mv "$TMP_ROOT/e1" "$(entry_file "$SID1")"

  out=$("$LEDGER_BIN" restore --dry-run)
  assert_contains "$out" "deleted      claude $SID1: Herdr session fm-lab-gone2 no longer exists; entry would be removed" "dry run reports the deleted session"
  assert_absent "$TMP_ROOT/classify.log" "a dry run never runs the worker classify"
  assert_absent "$sockdir" "a dry run leaves the deleted session deleted"

  out=$("$LEDGER_BIN" restore --wait 0 --pause 0)
  assert_contains "$out" "deleted      claude $SID1: Herdr session fm-lab-gone2 no longer exists; entry was removed" "the restore prunes the deleted session"
  assert_absent "$(entry_file "$SID1")" "the entry is gone"
  assert_absent "$TMP_ROOT/classify.log" "a worker of a deleted session is never classified"
  assert_absent "$sockdir" "the restore never brings the deleted session back"
  assert_absent "$HERDR_DIR/typed.log" "nothing was typed"
  pass "the restore never wakes a deleted Herdr session through the worker classify"
}

# An armed merge poll trusts a task record only while its PR region is the
# tail (fm_pr_metadata_identity_parse in bin/fm-pr-lib.sh). A restore moves a
# resumed worker's record to its new pane, so it must write the pane keys
# ahead of pr=, or a merge made after the restore is never seen.
test_restore_rebind_keeps_the_pr_region_last() {
  local home="$TMP_ROOT/prhome" sid=7a7a7a7a-1111-4222-8333-944444444444 meta out
  meta="$home/state/task-pr.meta"
  rm -f "$FM_SESSION_LEDGER_DIR"/entries/*.json "$HERDR_DIR/typed.log" "$HERDR_DIR"/busy-* "$CFG"/sessions/*.json
  mkdir -p "$home/state" "$home/data"
  printf 'kind=ship\nworktree=/tmp\nherdr_session=default\nherdr_pane_id=w1:p9\nwindow=default:w1:p9\npr=https://github.com/example/repo/pull/7\npr_head=%s\n' \
    "$(printf '%040d' 7)" >"$meta"
  bash -c '. "$1/bin/fm-pr-lib.sh" && fm_pr_metadata_identity_parse "$2"' _ "$ROOT" "$meta" \
    || fail "setup error: the fixture PR region must parse before the restore"
  : >"$CFG/projects/p/$sid.jsonl"
  make_entry "$sid" w1:p9 w1:t1 w1 fleet "$CFG/projects/p/$sid.jsonl" idle \
    "{\"role\":\"worker\",\"task_id\":\"task-pr\",\"home\":\"$home\",\"kind\":\"ship\"}"
  : >"$HERDR_DIR/start-on-run"
  out=$("$LEDGER_BIN" restore --wait 5 --pause 0 --batch 1 2>&1)
  rm -f "$HERDR_DIR/start-on-run" "$CFG/sessions/7701.json"
  rm -rf "$FAKE_PROC/7701"
  assert_contains "$out" "resumed      claude $sid" "the typed resume runs"
  assert_contains "$out" "record       task-pr in $home now names pane" "the record moves to the new pane"
  assert_no_grep '^herdr_pane_id=w1:p9$' "$meta" "the old pane id is gone from the record"
  bash -c '. "$1/bin/fm-pr-lib.sh" && fm_pr_metadata_identity_parse "$2" && [ "$FM_PR_META_NUMBER" = 7 ]' _ "$ROOT" "$meta" \
    || fail "the restore must keep the PR region last so an armed merge poll still validates: $(cat "$meta")"
  pass "restore moves a resumed worker's record to its new pane and keeps the PR region last"
}

test_can_resume_gates_automatic_recovery() {
  setup_plan_fixture
  local out rc
  out=$("$LEDGER_BIN" can-resume --task task-a --home "$FM_SESSION_LEDGER_PRIMARY_HOME")
  rc=$?
  expect_code 0 "$rc" "a resumable fleet task"
  assert_contains "$out" "fm-session-ledger.sh restore" "it prints the restore command"
  "$LEDGER_BIN" can-resume --task task-b --home "$FM_SESSION_LEDGER_PRIMARY_HOME" >/dev/null
  expect_code 1 "$?" "no entry"
  rm -f "$CFG/projects/p/$SID1.jsonl"
  "$LEDGER_BIN" can-resume --task task-a --home "$FM_SESSION_LEDGER_PRIMARY_HOME" >/dev/null
  expect_code 1 "$?" "a missing transcript cannot resume"
  : >"$CFG/projects/p/$SID1.jsonl"
  fake_agent 4300 901 /tmp "" /usr/bin/claude
  session_record 4300 901 "$SID1"
  "$LEDGER_BIN" can-resume --task task-a --home "$FM_SESSION_LEDGER_PRIMARY_HOME" >/dev/null
  expect_code 1 "$?" "a running session needs no resume"
  pass "can-resume answers only for a live, resumable, stopped session"
}

test_install_and_uninstall_are_idempotent() {
  local s="$TMP_ROOT/settings.json"
  printf '{"model":"x","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"gh-axi"}]}]}}\n' >"$s"
  "$LEDGER_BIN" install-hooks --settings "$s" >/dev/null || fail "install"
  "$LEDGER_BIN" install-hooks --settings "$s" >/dev/null || fail "install again"
  assert_equals 2 "$(jq '.hooks.SessionStart | length' "$s")" "one ledger hook beside the existing one"
  assert_equals 1 "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command | contains("fm-session-ledger.sh"))] | length' "$s")" "SessionEnd hooked once"
  assert_equals "UserPromptSubmit Stop StopFailure" "$(jq -r '[.hooks | keys[] | select(. == "UserPromptSubmit" or . == "Stop" or . == "StopFailure")] | sort_by(if . == "UserPromptSubmit" then 0 elif . == "Stop" then 1 else 2 end) | join(" ")' "$s")" "busy events hooked"
  "$LEDGER_BIN" uninstall-hooks --settings "$s" >/dev/null || fail "uninstall"
  "$LEDGER_BIN" uninstall-hooks --settings "$s" >/dev/null || fail "uninstall again"
  assert_equals '{"hooks":{"SessionStart":[{"hooks":[{"command":"gh-axi","type":"command"}],"matcher":""}]},"model":"x"}' "$(jq -cS . "$s")" "uninstall restores the other hooks exactly"
  pass "install-hooks and uninstall-hooks are idempotent and keep other hooks"
}

test_session_start_writes_the_full_entry
test_busy_events_update_the_state
test_clear_replaces_the_pane_entry
test_session_end_keeps_a_crash_and_removes_a_deliberate_exit
test_a_fresh_relaunch_replaces_the_fleet_entry
test_a_nested_print_session_never_replaces_the_agent
test_the_primary_comes_from_its_endpoint_record
test_an_agent_that_exits_before_the_writer_never_replaces_an_entry
test_a_resumed_primary_in_a_new_pane_stays_the_primary
test_hook_is_silent_and_never_fails
test_restore_dry_run_plans_and_changes_nothing
test_restore_resumes_only_recorded_sessions
test_restore_never_wakes_a_deleted_session_through_classify
test_restore_rebind_keeps_the_pr_region_last
test_can_resume_gates_automatic_recovery
test_install_and_uninstall_are_idempotent
