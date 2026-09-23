#!/usr/bin/env bash
# fm-native-session.sh: proving a running worker's native session identity.
#
# A park records the session a worker can later resume, so a wrong id is worse
# than none: it resumes some other conversation, or a fresh one, silently.
# These tests pin the proof per harness against REAL processes that stand in
# for each agent - their kernel-visible start time, environment, and open file
# descriptors are the evidence the capture reads - plus the session files each
# harness keeps on disk. No harness binary and no model is involved.
#   1. claude: the per-process session record Claude Code keeps, bound to the
#      exact process by its kernel start time, and the transcript it names.
#   2. codex: the rollout file and thread lock the process holds open.
#   3. pi: the session the Firstmate worker extension recorded for the current
#      incarnation, and the session file it names.
#   4. Every case the capture cannot prove refuses and records nothing.
#   5. locate: a recorded session is resumable only while its file exists.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

NS="$ROOT/bin/fm-native-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-native-session)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
STAND_IN_PIDS=()
cleanup() {
  local pid
  for pid in "${STAND_IN_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  rm -rf "$TMP_ROOT"
  fm_test_cleanup
}
trap cleanup EXIT

if [ ! -r /proc/self/stat ]; then
  echo "skip: fm-native-session capture proofs read /proc, which this host does not have"
  exit 0
fi

SID_A=0f3c2a9e-1111-4a2b-9c3d-000000000001
SID_B=0f3c2a9e-2222-4a2b-9c3d-000000000002

# stand_in <comm> <env-assignment|-> <shell-snippet>: start a real process
# whose kernel name is <comm>, optionally with one extra environment variable,
# that runs <shell-snippet> and then blocks. Echoes its pid.
stand_in() {  # <comm> <env|-> <snippet>
  local comm=$1 envset=$2 snippet=$3 bin="$TMP_ROOT/bin" fifo pid
  mkdir -p "$bin"
  [ -x "$bin/$comm" ] || cp "$(command -v bash)" "$bin/$comm"
  fifo="$TMP_ROOT/block.$RANDOM$RANDOM"
  mkfifo "$fifo"
  if [ "$envset" = - ]; then
    "$bin/$comm" -c "$snippet; read -r _ < '$fifo'" >/dev/null 2>&1 &
  else
    env "$envset" "$bin/$comm" -c "$snippet; read -r _ < '$fifo'" >/dev/null 2>&1 &
  fi
  pid=$!
  STAND_IN_PIDS+=("$pid")
  # Wait until the snippet ran and the process is parked on the fifo open.
  for _ in $(seq 1 100); do
    [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$comm" ] && break
    sleep 0.02
  done
  sleep 0.1
  printf '%s\n' "$pid"
}

proc_start() {  # <pid>: kernel start time, field 22 of /proc/<pid>/stat
  local rest
  rest=$(cat "/proc/$1/stat")
  rest=${rest##*) }
  # shellcheck disable=SC2086
  set -- $rest
  printf '%s' "${20}"
}

new_worktree() {  # <name>
  local wt="$TMP_ROOT/$1"
  mkdir -p "$wt"
  printf '%s\n' "$wt"
}

# claude_record <cfg> <pid> <session-id> <cwd> [proc-start]
claude_record() {
  local cfg=$1 pid=$2 sid=$3 cwd=$4 start=${5:-}
  [ -n "$start" ] || start=$(proc_start "$pid")
  mkdir -p "$cfg/sessions"
  jq -cn --argjson pid "$pid" --arg sid "$sid" --arg cwd "$cwd" --arg start "$start" \
    '{pid: $pid, sessionId: $sid, cwd: $cwd, procStart: $start, kind: "interactive"}' \
    > "$cfg/sessions/$pid.json"
}

claude_transcript() {  # <cfg> <session-id> -> path
  local dir="$1/projects/-some-project"
  mkdir -p "$dir"
  printf '{"type":"user","sessionId":"%s"}\n' "$2" > "$dir/$2.jsonl"
  printf '%s\n' "$dir/$2.jsonl"
}

capture() {  # <args...>: run the capture; echoes combined output, returns its code
  "$NS" capture "$@" 2>&1
}

# --- 1. claude ----------------------------------------------------------------

test_claude_capture_proves_the_running_session() {
  local wt cfg pid out rc transcript
  wt=$(new_worktree claude-ok)
  cfg="$TMP_ROOT/claude-ok-cfg"
  pid=$(stand_in claude "CLAUDE_CONFIG_DIR=$cfg" ':')
  claude_record "$cfg" "$pid" "$SID_A" "$wt"
  transcript=$(claude_transcript "$cfg" "$SID_A")
  out=$(capture --harness claude --worktree "$wt" --pid "$pid"); rc=$?
  expect_code 0 "$rc" "claude capture should prove the running session"$'\n'"$out"
  assert_contains "$out" "session=$SID_A" "claude capture should report the session id"
  assert_contains "$out" "file=$transcript" "claude capture should report the transcript"
  pass "claude capture: the per-process record plus its transcript prove the session"
}

expect_refusal() {  # <out> <rc> <reason-fragment> <label>
  expect_code 1 "$2" "$4 should refuse"$'\n'"$1"
  assert_contains "$1" "$3" "$4 should name why it refused"
  assert_not_contains "$1" "session=" "$4 must report no session"
}

test_claude_capture_refuses_what_it_cannot_prove() {
  local wt other cfg pid out rc
  wt=$(new_worktree claude-refuse)
  other=$(new_worktree claude-elsewhere)
  cfg="$TMP_ROOT/claude-refuse-cfg"
  pid=$(stand_in claude "CLAUDE_CONFIG_DIR=$cfg" ':')

  # A record written for an earlier process that had the same pid.
  claude_record "$cfg" "$pid" "$SID_A" "$wt" 1
  claude_transcript "$cfg" "$SID_A" >/dev/null
  out=$(capture --harness claude --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "does not belong to the running process" "a record from a reused pid"

  # The running session belongs to another directory.
  claude_record "$cfg" "$pid" "$SID_A" "$other"
  out=$(capture --harness claude --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "not the task worktree" "a session in another directory"

  # The session exists but was never saved, so nothing could resume it.
  claude_record "$cfg" "$pid" "$SID_B" "$wt"
  out=$(capture --harness claude --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "no single saved transcript" "an unsaved session"

  # No record at all for the running process.
  rm -f "$cfg/sessions/$pid.json"
  out=$(capture --harness claude --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "has a session record" "a process with no session record"
  pass "claude capture: a reused pid, another directory, an unsaved session, and a missing record all refuse"
}

test_claude_capture_reads_the_default_config_from_the_process_home() {
  local wt home pid out rc transcript
  wt=$(new_worktree claude-home)
  home="$TMP_ROOT/claude-home-dir"
  pid=$(stand_in claude "HOME=$home" ':')
  claude_record "$home/.claude" "$pid" "$SID_A" "$wt"
  transcript=$(claude_transcript "$home/.claude" "$SID_A")
  out=$(HOME=/nonexistent capture --harness claude --worktree "$wt" --pid "$pid"); rc=$?
  expect_code 0 "$rc" "claude capture should use the process's own HOME"$'\n'"$out"
  assert_contains "$out" "file=$transcript" "claude capture should find the transcript under the process HOME"
  pass "claude capture: the config directory comes from the agent process's own environment"
}

test_unverified_harness_refuses() {
  local wt pid out rc
  wt=$(new_worktree grok)
  pid=$(stand_in grok - ':')
  out=$(capture --harness grok --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "no verified native session capture" "an unverified harness"
  pass "capture: a harness with no verified native session contract refuses"
}

# --- 2. codex -----------------------------------------------------------------

# codex_rollout <codex-home> <session-id> <cwd> [header-id] -> path
codex_rollout() {
  local dir="$1/sessions/2026/09/22" sid=$2 cwd=$3 header=${4:-$2} path
  mkdir -p "$dir"
  path="$dir/rollout-2026-09-22T20-36-45-$sid.jsonl"
  jq -cn --arg id "$header" --arg cwd "$cwd" \
    '{type: "session_meta", payload: {id: $id, cwd: $cwd, originator: "codex-tui"}}' > "$path"
  printf '%s\n' "$path"
}

codex_lock() {  # <codex-home> <session-id> -> path
  mkdir -p "$1/thread-writer-locks"
  : > "$1/thread-writer-locks/$2.lock"
  printf '%s\n' "$1/thread-writer-locks/$2.lock"
}

test_codex_capture_proves_the_open_rollout() {
  local wt home rollout lock pid out rc
  wt=$(new_worktree codex-ok)
  home="$TMP_ROOT/codex-ok-home"
  rollout=$(codex_rollout "$home" "$SID_A" "$wt")
  lock=$(codex_lock "$home" "$SID_A")
  pid=$(stand_in codex - "exec 3>>'$rollout' 4>'$lock'")
  out=$(capture --harness codex --worktree "$wt" --pid "$pid"); rc=$?
  expect_code 0 "$rc" "codex capture should prove the open rollout"$'\n'"$out"
  assert_contains "$out" "session=$SID_A" "codex capture should report the session id"
  assert_contains "$out" "file=$rollout" "codex capture should report the rollout"
  pass "codex capture: the rollout and thread lock the process holds open prove the session"
}

test_codex_capture_refuses_what_it_cannot_prove() {
  local wt other home rollout rollout_b lock lock_b pid out rc
  wt=$(new_worktree codex-refuse)
  other=$(new_worktree codex-elsewhere)
  home="$TMP_ROOT/codex-refuse-home"

  # A session whose first turn never completed has a lock but no rollout.
  lock=$(codex_lock "$home" "$SID_A")
  pid=$(stand_in codex - "exec 4>'$lock'")
  out=$(capture --harness codex --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "no saved rollout" "a codex session with no rollout yet"

  # Two sessions open at once cannot be told apart.
  rollout=$(codex_rollout "$home" "$SID_A" "$wt")
  rollout_b=$(codex_rollout "$home" "$SID_B" "$wt")
  pid=$(stand_in codex - "exec 3>>'$rollout' 5>>'$rollout_b'")
  out=$(capture --harness codex --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "more than one" "two open codex rollouts"

  # The thread lock names another session than the rollout.
  lock_b=$(codex_lock "$home" "$SID_B")
  pid=$(stand_in codex - "exec 3>>'$rollout' 4>'$lock_b'")
  out=$(capture --harness codex --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "disagree" "a lock naming another session"

  # The rollout's own header names another session.
  rollout=$(codex_rollout "$home" "$SID_A" "$wt" "$SID_B")
  pid=$(stand_in codex - "exec 3>>'$rollout'")
  out=$(capture --harness codex --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "header" "a rollout whose header names another session"

  # The session ran in another directory.
  rollout=$(codex_rollout "$home" "$SID_A" "$other")
  pid=$(stand_in codex - "exec 3>>'$rollout'")
  out=$(capture --harness codex --worktree "$wt" --pid "$pid"); rc=$?
  expect_refusal "$out" "$rc" "not the task worktree" "a codex session in another directory"
  pass "codex capture: no rollout, two rollouts, a disagreeing lock or header, and another directory all refuse"
}

# --- 3. pi ----------------------------------------------------------------------

# pi_session_file <dir> <session-id> <cwd> [header-id] -> path
pi_session_file() {
  local dir=$1 sid=$2 cwd=$3 header=${4:-$2} path
  mkdir -p "$dir"
  path="$dir/2026-09-23T01-38-09-454Z_$sid.jsonl"
  jq -cn --arg id "$header" --arg cwd "$cwd" \
    '{type: "session", version: 3, id: $id, cwd: $cwd}' > "$path"
  printf '%s\n' "$path"
}

# pi_record <state> <task-id> <gen> <session-id> <file>: what the Firstmate
# worker extension writes on session_start.
pi_record() {
  mkdir -p "$1"
  jq -cn --arg gen "$3" --arg id "$4" --arg file "$5" \
    '{gen: $gen, id: $id, file: $file}' > "$1/$2.pi-session"
}

test_pi_capture_proves_the_extension_record() {
  local wt state file pid out rc harness
  for harness in pi pi-signed; do
    wt=$(new_worktree "$harness-ok")
    state="$TMP_ROOT/$harness-ok-state"
    file=$(pi_session_file "$TMP_ROOT/$harness-ok-sessions" "$SID_A" "$wt")
    pi_record "$state" t1 gen-7 "$SID_A" "$file"
    pid=$(stand_in pi - ':')
    out=$(capture --harness "$harness" --worktree "$wt" --pid "$pid" \
      --state "$state" --id t1 --gen gen-7); rc=$?
    expect_code 0 "$rc" "$harness capture should prove the recorded session"$'\n'"$out"
    assert_contains "$out" "session=$SID_A" "$harness capture should report the session id"
    assert_contains "$out" "file=$file" "$harness capture should report the session file"
  done
  pass "pi capture: the current incarnation's extension record plus its session file prove the session"
}

test_pi_capture_refuses_what_it_cannot_prove() {
  local wt other state file pid out rc
  wt=$(new_worktree pi-refuse)
  other=$(new_worktree pi-elsewhere)
  state="$TMP_ROOT/pi-refuse-state"
  pid=$(stand_in pi - ':')
  file=$(pi_session_file "$TMP_ROOT/pi-refuse-sessions" "$SID_A" "$wt")

  out=$(capture --harness pi --worktree "$wt" --pid "$pid" --state "$state" --id t1 --gen gen-7); rc=$?
  expect_refusal "$out" "$rc" "no session record" "a pi worker with no extension record"

  # A record left by an earlier incarnation of the task.
  pi_record "$state" t1 gen-6 "$SID_A" "$file"
  out=$(capture --harness pi --worktree "$wt" --pid "$pid" --state "$state" --id t1 --gen gen-7); rc=$?
  expect_refusal "$out" "$rc" "earlier incarnation" "a record from an earlier incarnation"

  # The recorded session was never saved.
  pi_record "$state" t1 gen-7 "$SID_A" "$TMP_ROOT/pi-refuse-sessions/missing.jsonl"
  out=$(capture --harness pi --worktree "$wt" --pid "$pid" --state "$state" --id t1 --gen gen-7); rc=$?
  expect_refusal "$out" "$rc" "not on disk" "an unsaved pi session"

  # The session file's own header names another session.
  file=$(pi_session_file "$TMP_ROOT/pi-refuse-sessions" "$SID_A" "$wt" "$SID_B")
  pi_record "$state" t1 gen-7 "$SID_A" "$file"
  out=$(capture --harness pi --worktree "$wt" --pid "$pid" --state "$state" --id t1 --gen gen-7); rc=$?
  expect_refusal "$out" "$rc" "header" "a pi session file naming another session"

  # The session ran in another directory.
  file=$(pi_session_file "$TMP_ROOT/pi-refuse-sessions" "$SID_A" "$other")
  pi_record "$state" t1 gen-7 "$SID_A" "$file"
  out=$(capture --harness pi --worktree "$wt" --pid "$pid" --state "$state" --id t1 --gen gen-7); rc=$?
  expect_refusal "$out" "$rc" "not the task worktree" "a pi session in another directory"
  pass "pi capture: no record, an earlier incarnation's record, an unsaved session, a disagreeing header, and another directory all refuse"
}

# --- 5. locate ----------------------------------------------------------------

locate() {  # <args...>
  "$NS" locate "$@" 2>&1
}

test_locate_confirms_a_resumable_session() {
  local wt cfg transcript rollout pifile out rc
  wt=$(new_worktree locate-ok)
  cfg="$TMP_ROOT/locate-ok-cfg"
  transcript=$(claude_transcript "$cfg" "$SID_A")
  out=$(locate --harness claude --session "$SID_A" --file "$transcript" \
    --worktree "$wt" --claude-config "$cfg"); rc=$?
  expect_code 0 "$rc" "a saved claude transcript should be resumable"$'\n'"$out"
  assert_contains "$out" "file=$transcript" "locate should report the claude transcript"

  rollout=$(codex_rollout "$TMP_ROOT/locate-ok-codex" "$SID_A" "$wt")
  out=$(locate --harness codex --session "$SID_A" --file "$rollout" --worktree "$wt"); rc=$?
  expect_code 0 "$rc" "a saved codex rollout should be resumable"$'\n'"$out"

  pifile=$(pi_session_file "$TMP_ROOT/locate-ok-pi" "$SID_A" "$wt")
  out=$(locate --harness pi --session "$SID_A" --file "$pifile" --worktree "$wt"); rc=$?
  expect_code 0 "$rc" "a saved pi session should be resumable"$'\n'"$out"
  pass "locate: a recorded session whose file still names it is resumable"
}

test_locate_refuses_a_session_that_is_gone() {
  local wt cfg transcript rollout pifile out rc
  wt=$(new_worktree locate-gone)
  cfg="$TMP_ROOT/locate-gone-cfg"
  transcript=$(claude_transcript "$cfg" "$SID_A")
  rm -f "$transcript"
  out=$(locate --harness claude --session "$SID_A" --file "$transcript" \
    --worktree "$wt" --claude-config "$cfg"); rc=$?
  expect_refusal "$out" "$rc" "is missing" "a deleted claude transcript"

  # A transcript in another Claude configuration is invisible to the resume.
  transcript=$(claude_transcript "$TMP_ROOT/locate-other-cfg" "$SID_A")
  out=$(locate --harness claude --session "$SID_A" --file "$transcript" \
    --worktree "$wt" --claude-config "$cfg"); rc=$?
  expect_refusal "$out" "$rc" "not under" "a transcript in another Claude configuration"

  rollout=$(codex_rollout "$TMP_ROOT/locate-gone-codex" "$SID_A" "$wt" "$SID_B")
  out=$(locate --harness codex --session "$SID_A" --file "$rollout" --worktree "$wt"); rc=$?
  expect_refusal "$out" "$rc" "header" "a codex rollout naming another session"

  pifile=$(pi_session_file "$TMP_ROOT/locate-gone-pi" "$SID_A" "$wt")
  rm -f "$pifile"
  out=$(locate --harness pi --session "$SID_A" --file "$pifile" --worktree "$wt"); rc=$?
  expect_refusal "$out" "$rc" "is missing" "a deleted pi session file"

  out=$(locate --harness claude --session not-a-uuid --file "$transcript" --worktree "$wt"); rc=$?
  expect_refusal "$out" "$rc" "not a valid session id" "a malformed recorded id"
  pass "locate: a deleted file, another Claude configuration, a disagreeing header, and a malformed id all refuse"
}

# The record comes from the REAL generated extension: spawn a pi worker with
# fake tooling, fire its session_start handler in a plain Node host with a
# session manager that names a saved session, and prove it through the capture.
# drive_pi_session_start <ext> <session-id> <session-file> [reason]
drive_pi_session_start() {
  EXT_PATH="$1" SID="$2" SFILE="$3" REASON="${4:-startup}" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
if (!handlers["session_start"]) throw new Error("no session_start handler");
const ctx = {
  isIdle: () => true,
  sessionManager: {
    getSessionId: () => process.env.SID,
    getSessionFile: () => process.env.SFILE,
  },
};
await handlers["session_start"]({ type: "session_start", reason: process.env.REASON }, ctx);
EOF
}

test_pi_worker_extension_records_its_session() {
  local case_dir home proj wt fakebin id=park-pi-1 out rc state ext gen file
  command -v node >/dev/null 2>&1 || { echo "skip: node is not installed"; return 0; }
  case_dir="$TMP_ROOT/pi-spawn"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi)
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" wt-pi-spawn
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off 2>&1); rc=$?
  expect_code 0 "$rc" "pi spawn should succeed"$'\n'"$out"
  state="$home/state"
  ext="$state/$id.pi-ext.ts"
  gen=$(sed -n 's/^busy_gen=//p' "$state/$id.meta")
  [ -n "$gen" ] || fail "pi spawn should record a busy generation"

  file=$(pi_session_file "$case_dir/sessions" "$SID_A" "$wt")
  out=$(drive_pi_session_start "$ext" "$SID_A" "$file") || fail "session_start drive failed: $out"
  out=$(capture --harness pi --worktree "$wt" --pid "$$" --state "$state" --id "$id" --gen "$gen"); rc=$?
  expect_code 0 "$rc" "the extension's record should prove the pi session"$'\n'"$out"
  assert_contains "$out" "session=$SID_A" "the pi record should name the session"

  # A /new or /resume inside Pi starts another session; the record follows it.
  file=$(pi_session_file "$case_dir/sessions" "$SID_B" "$wt")
  out=$(drive_pi_session_start "$ext" "$SID_B" "$file" new) || fail "second session_start drive failed: $out"
  out=$(capture --harness pi --worktree "$wt" --pid "$$" --state "$state" --id "$id" --gen "$gen"); rc=$?
  expect_code 0 "$rc" "the record should follow a session switch"$'\n'"$out"
  assert_contains "$out" "session=$SID_B" "the pi record should name the session Pi switched to"
  pass "pi worker extension: every session_start records the live session for the current incarnation"
}

# --- 6. resume launch -----------------------------------------------------------

# resume_launch <harness> <template> <session> <file>: run the pure transform.
resume_launch() {
  bash -c '. "$1"; fm_native_session_resume_launch "$2" "$3" "$4" "$5"' _ \
    "$ROOT/bin/fm-native-session-lib.sh" "$@" 2>&1
}

test_resume_launch_reopens_the_exact_session() {
  local brief out rc
  # shellcheck disable=SC2016 # The template is literal launch text.
  brief='"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  out=$(resume_launch claude "claude --dangerously-skip-permissions __MODELFLAG____NAMEFLAG__$brief" "$SID_A" /x/t.jsonl); rc=$?
  expect_code 0 "$rc" "claude resume launch should build"$'\n'"$out"
  [ "$out" = "claude --dangerously-skip-permissions __MODELFLAG____NAMEFLAG__--resume '$SID_A'" ] \
    || fail "claude resume must replace the brief with --resume <id>, got: $out"

  out=$(resume_launch codex "codex __MODELFLAG__--dangerously-bypass-approvals-and-sandbox -c \"notify=[1]\" $brief" "$SID_A" /x/r.jsonl); rc=$?
  expect_code 0 "$rc" "codex resume launch should build"$'\n'"$out"
  [ "$out" = "codex resume __MODELFLAG__--dangerously-bypass-approvals-and-sandbox -c \"notify=[1]\" '$SID_A'" ] \
    || fail "codex resume must use the resume subcommand with the session id, got: $out"

  out=$(resume_launch pi "__PIBIN____PITUIMODE__ __MODELFLAG__-e __PIEXT__ $brief" "$SID_A" "/x/pi sessions/s.jsonl"); rc=$?
  expect_code 0 "$rc" "pi resume launch should build"$'\n'"$out"
  [ "$out" = "__PIBIN____PITUIMODE__ __MODELFLAG__-e __PIEXT__ --session '/x/pi sessions/s.jsonl'" ] \
    || fail "pi resume must open the exact session file, got: $out"
  pass "resume launch: each harness reopens the exact recorded session with its fleet flags kept"
}

test_resume_launch_refuses_an_unknown_shape() {
  local out rc
  out=$(resume_launch claude "claude --print hello" "$SID_A" /x/t.jsonl); rc=$?
  expect_code 1 "$rc" "a template without the brief argument must refuse"$'\n'"$out"
  out=$(resume_launch grok "grok \"\$(x)\"" "$SID_A" /x/t.jsonl); rc=$?
  expect_code 1 "$rc" "an unverified harness must refuse"$'\n'"$out"
  pass "resume launch: a launch shape it does not recognize, or an unverified harness, refuses"
}

test_claude_capture_proves_the_running_session
test_claude_capture_refuses_what_it_cannot_prove
test_resume_launch_reopens_the_exact_session
test_resume_launch_refuses_an_unknown_shape
test_pi_worker_extension_records_its_session
test_locate_confirms_a_resumable_session
test_locate_refuses_a_session_that_is_gone
test_pi_capture_proves_the_extension_record
test_pi_capture_refuses_what_it_cannot_prove
test_codex_capture_proves_the_open_rollout
test_codex_capture_refuses_what_it_cannot_prove
test_claude_capture_reads_the_default_config_from_the_process_home
test_unverified_harness_refuses
