#!/usr/bin/env bash
# fm-control.sh park and resume: worker gone, work preserved.
#
# These tests pin the two verbs through the executable interface firstmate
# calls, hermetically: a lifecycle-modelling tmux stub, a `ps` stub that names
# the pane's foreground process, a REAL stand-in process whose kernel start
# time, environment, and open files are the session evidence, a fake Atlas,
# and the real bin/fm-spawn.sh for the resume launch.
#   1. park proves the running session, records it with the reason, records
#      the park on the Atlas ticket, exits the agent, and closes only its
#      endpoint; the worktree, brief, and status log stay.
#   2. A session park cannot prove, a session the resume would not find, an
#      Atlas that does not record the park, an unverified harness, and a
#      secondmate all refuse with nothing changed.
#   3. resume unparks the ticket first, reopens the exact recorded session in a
#      new endpoint in the same worktree, clears the park record, and delivers
#      the note as a durable steer.
#   4. The resume always opens a new endpoint: it closes the task's own
#      leftover pane from an unfinished close, leaves a pane that merely reuses
#      the recorded id alone, and refuses while an agent runs in the worktree.
#   5. Parking a parked task again only refreshes its reason, blocker, and
#      Atlas park, never closes a pane, and keeps the prior record when the
#      Atlas does not record the update.
#   6. A missing session file refuses before anything changes, and a launch
#      that does not come up re-records the Atlas park.
#   7. relaunch of a parked task resumes its session instead of starting fresh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-park)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FM_TEST_REAL_PS=$(command -v ps)
export FM_TEST_REAL_PS
STAND_IN_PIDS=()
TASK_TMPS=()
park_cleanup() {
  local pid d
  for pid in "${STAND_IN_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
  fm_test_cleanup
}
trap park_cleanup EXIT

if [ ! -r /proc/self/stat ]; then
  echo "skip: park proves sessions through /proc, which this host does not have"
  exit 0
fi

SID=0f3c2a9e-3333-4a2b-9c3d-000000000003

# --- stubs --------------------------------------------------------------------
#
# tmux: the relaunch suite's lifecycle model, plus what park and resume touch.
# An exit command stops the agent, and a launch that reopens a session (or
# carries a brief) starts the harness named in `becomes`. The window inventory
# is `session:name` lines, so kill-window and new-window change what each
# session lists: a closed endpoint reads missing and a resume's new one is
# found. FM_FAKE_KILL_FAILS leaves a killed window in place.
make_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          [ -n "${FM_FAKE_NEVER_DIES:-}" ] || printf 'zsh' > "$D/command"
          ;;
        *'encode launch-brief'*|*' --resume '*|*'codex resume '*|*' --session '*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *pane_tty*) printf '/dev/pts/fmpark\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows)
    ses=''
    while [ $# -gt 0 ]; do
      case "$1" in -t) ses=$2; shift 2 ;; *) shift ;; esac
    done
    [ -f "$D/windows" ] && sed -n "s/^$ses://p" "$D/windows"
    exit 0 ;;
  has-session|new-session|set-window-option) exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_KILL_FAILS:-}" ] || exit 0
    target=''
    while [ $# -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    target=$(printf '%s' "$target" | tr -d '=')
    grep -vxF "$target" "$D/windows" > "$D/windows.next" || true
    mv "$D/windows.next" "$D/windows"
    exit 0 ;;
  new-window)
    shift
    name='' dir='' ses=''
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=$2; shift 2 ;;
        -c) dir=$2; shift 2 ;;
        -t) ses=${2%:}; shift 2 ;;
        -F) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s:%s\n' "$ses" "$name" >> "$D/windows"
    printf 'zsh' > "$D/command"
    printf '%s' "$dir" > "$D/cwd"
    printf '%s\n' "$name" >> "$D/new-windows"
    printf '@7\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # ps: the pane's foreground process group is the stand-in agent while the
  # agent runs and an unreadable shell pid once it has exited; everything else
  # is the real ps.
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
case " $* " in
  *" -t "*)
    cmd=$(cat "$D/command")
    if [ "$cmd" = zsh ]; then pid=999999; else pid=$(cat "$D/fgpid"); fi
    printf '%s %s %s %s\n' "$pid" "$pid" "$pid" "$cmd"
    exit 0 ;;
esac
exec "$FM_TEST_REAL_PS" "$@"
SH
  chmod +x "$fb/ps"
  # atlas-axi: records every call and models one ticket's state and the park in
  # force. A park identical to the one in force appends nothing, so its `at`
  # stays; a blocker of c99 names nothing on the map and is refused.
  cat > "$fb/atlas-axi" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--by) shift 2 ;;
    *) break ;;
  esac
done
printf '%s\n' "$*" >> "$D/atlas"
case "$1 $2" in
  'ticket show')
    parked=null
    [ "$(cat "$D/ticket-state")" != parked ] \
      || parked=$(jq -c --arg at "$(cat "$D/park-at")" '. + {at: $at}' "$D/park-body")
    printf '{"change":{"node":"proj/node","state":"%s","parked":%s}}\n' "$(cat "$D/ticket-state")" "$parked"
    ;;
  'ticket park')
    [ "${FM_FAKE_ATLAS_FAIL:-}" != park ] || { echo "gate refused the park" >&2; exit 1; }
    why=$4 on='' sid=''
    shift 4
    while [ $# -gt 0 ]; do
      case "$1" in
        --on) on=$2; shift 2 ;;
        --session) sid=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    [ "$on" != c99 ] || { echo "nothing on the map answers to --on c99" >&2; exit 1; }
    body=$(jq -cn --arg why "$why" --arg on "$on" --arg id "$sid" \
      '{why: $why, on: (if $on == "" then null else $on end), session: {id: $id}}')
    if [ "$(cat "$D/ticket-state")" != parked ] || [ "$body" != "$(cat "$D/park-body" 2>/dev/null)" ]; then
      printf '%s' "$body" > "$D/park-body"
      printf 'at-%s' "$(wc -l < "$D/atlas")" > "$D/park-at"
      printf 'parked' > "$D/ticket-state"
    fi
    ;;
  'ticket unpark')
    [ "${FM_FAKE_ATLAS_FAIL:-}" != unpark ] || { echo "gate 5 refused the unpark" >&2; exit 1; }
    printf 'started' > "$D/ticket-state"
    ;;
esac
exit 0
SH
  chmod +x "$fb/atlas-axi"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# stand_in <comm> <env-assignment> <snippet>: a real process named <comm> that
# runs <snippet> and blocks. Echoes its pid.
stand_in() {
  local comm=$1 envset=$2 snippet=$3 bin="$TMP_ROOT/bin" fifo pid
  mkdir -p "$bin"
  [ -x "$bin/$comm" ] || cp "$(command -v bash)" "$bin/$comm"
  fifo="$TMP_ROOT/block.$RANDOM$RANDOM"
  mkfifo "$fifo"
  env "$envset" "$bin/$comm" -c "$snippet; read -r _ < '$fifo'" >/dev/null 2>&1 &
  pid=$!
  STAND_IN_PIDS+=("$pid")
  for _ in $(seq 1 100); do
    [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$comm" ] && break
    sleep 0.02
  done
  sleep 0.1
  printf '%s\n' "$pid"
}

proc_start() {
  local rest
  rest=$(cat "/proc/$1/stat")
  rest=${rest##*) }
  # shellcheck disable=SC2086
  set -- $rest
  printf '%s' "${20}"
}

# new_case <name> [harness] [kind] -> echoes a case dir with one live task t1,
# a wired Atlas whose ticket c7 is started, and a stand-in agent whose native
# session is provable.
new_case() {
  local name=$1 harness=${2:-claude} kind=${3:-ship} dir home proj wt cfg pid
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"; proj="$dir/proj"; wt="$dir/wt"
  mkdir -p "$home/state" "$home/data/t1" "$home/config" "$dir/fake" "$dir/atlas/atlas" "$dir/user-home"
  make_stubs "$dir"
  fm_git_worktree "$proj" "$wt" task-t1
  cat > "$home/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise park and resume.

## Firstmate spec
Keep the work while the worker is gone.
EOF
  {
    echo "window=fmses:fm-t1"
    echo "endpoint_task_id=t1"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=$kind"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-t1"
    echo "model=default"
    echo "effort=default"
    echo "atlas_ticket=c7"
  } > "$home/state/t1.meta"
  TASK_TMPS+=("/tmp/fm-t1")
  printf 'working: started\n' > "$home/state/t1.status"
  printf '%s\n' "$dir/atlas" > "$home/config/specs"
  printf 'started' > "$dir/fake/ticket-state"
  : > "$dir/fake/literal"; : > "$dir/fake/keys"; : > "$dir/fake/atlas"
  printf 'fmses:fm-t1\n' > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf '%s' "$harness" > "$dir/fake/command"
  printf '%s' "$harness" > "$dir/fake/becomes"
  case "$harness" in
    claude)
      cfg="$dir/user-home/.claude"
      pid=$(stand_in claude "CLAUDE_CONFIG_DIR=$cfg" ':')
      mkdir -p "$cfg/sessions" "$cfg/projects/-wt"
      jq -cn --argjson pid "$pid" --arg sid "$SID" --arg cwd "$wt" --arg start "$(proc_start "$pid")" \
        '{pid: $pid, sessionId: $sid, cwd: $cwd, procStart: $start}' > "$cfg/sessions/$pid.json"
      printf '{"type":"user"}\n' > "$cfg/projects/-wt/$SID.jsonl"
      ;;
    codex)
      mkdir -p "$dir/codex/sessions/2026/09/22"
      jq -cn --arg id "$SID" --arg cwd "$wt" '{type: "session_meta", payload: {id: $id, cwd: $cwd}}' \
        > "$dir/codex/sessions/2026/09/22/rollout-2026-09-22T20-36-45-$SID.jsonl"
      pid=$(stand_in codex "CODEX_HOME=$dir/codex" \
        "exec 3>>'$dir/codex/sessions/2026/09/22/rollout-2026-09-22T20-36-45-$SID.jsonl'")
      ;;
    *) pid=$(stand_in "$harness" "X=1" ':') ;;
  esac
  printf '%s' "$pid" > "$dir/fake/fgpid"
  printf '%s\n' "$dir"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u TMUX PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.2 FM_CONTROL_STATE_SETTLE=0.1 FM_CONTROL_READY_WAIT=0.1 \
    FM_FAKE_ATLAS_FAIL="${FM_FAKE_ATLAS_FAIL:-}" FM_FAKE_NEVER_DIES="${FM_FAKE_NEVER_DIES:-}" \
    FM_FAKE_KILL_FAILS="${FM_FAKE_KILL_FAILS:-}" \
    FM_TEST_REAL_PS="$FM_TEST_REAL_PS" \
    "$CONTROL" "$@" 2>&1
}

meta_field() {  # <case-dir> <key>
  grep "^$2=" "$1/home/state/t1.meta" | tail -1 | cut -d= -f2-
}

# --- 1. park ------------------------------------------------------------------

test_park_records_the_session_and_closes_only_the_endpoint() {
  local dir out rc wt
  dir=$(new_case park-ok)
  wt=$(meta_field "$dir" worktree)
  out=$(run_control "$dir" t1 park --reason "waits on the captain's merge word" --on c12); rc=$?
  expect_code 0 "$rc" "park should succeed"$'\n'"$out"
  assert_contains "$out" "parked t1 harness=claude session=$SID" "park should report the recorded session"
  grep -qx '/exit' "$dir/fake/literal" || fail "park should exit the agent through its verified exit command"
  [ ! -s "$dir/fake/windows" ] || fail "park should close the task's endpoint, got windows: $(cat "$dir/fake/windows")"
  [ -n "$(meta_field "$dir" parked)" ] || fail "park should record when the task was parked"
  [ "$(meta_field "$dir" parked_reason)" = "waits on the captain's merge word" ] || fail "park should record the reason"
  [ "$(meta_field "$dir" parked_on)" = c12 ] || fail "park should record the blocker"
  [ "$(meta_field "$dir" native_session)" = "$SID" ] || fail "park should record the native session"
  [ "$(meta_field "$dir" native_session_harness)" = claude ] || fail "park should record the session's harness"
  [ "$(meta_field "$dir" native_session_file)" = "$dir/user-home/.claude/projects/-wt/$SID.jsonl" ] \
    || fail "park should record the transcript that proves the session"
  [ -d "$wt" ] || fail "park must keep the worktree"
  [ -f "$dir/home/data/t1/brief.md" ] || fail "park must keep the instructions"
  [ "$(cat "$dir/home/state/t1.status")" = "working: started" ] || fail "park must keep the status log unchanged"
  grep -qxF "ticket park c7 waits on the captain's merge word --home main --harness claude --session $SID --task t1 --on c12" "$dir/fake/atlas" \
    || fail "park should record the park on the Atlas ticket, got: $(cat "$dir/fake/atlas")"
  pass "park: the proven session and reason are recorded, the Atlas ticket is parked, and only the endpoint closes"
}

test_park_codex_records_the_open_rollout() {
  local dir out rc
  dir=$(new_case park-codex codex)
  out=$(run_control "$dir" t1 park --reason "waits on review"); rc=$?
  expect_code 0 "$rc" "codex park should succeed"$'\n'"$out"
  grep -qx '/quit' "$dir/fake/literal" || fail "codex park should exit through /quit"
  [ "$(meta_field "$dir" native_session)" = "$SID" ] || fail "codex park should record the rollout's session"
  pass "park: a codex worker's open rollout is the recorded session"
}

# --- 2. park refusals ---------------------------------------------------------

assert_nothing_changed() {  # <case-dir> <meta-before> <label>
  cmp -s "$2" "$1/home/state/t1.meta" || fail "$3 must leave the task record unchanged"
  ! grep -qx '/exit' "$1/fake/literal" || fail "$3 must not exit the agent"
  grep -qx 'fmses:fm-t1' "$1/fake/windows" || fail "$3 must not close the endpoint"
}

test_park_refuses_an_unproven_session() {
  local dir out rc before
  dir=$(new_case park-unproven)
  rm -f "$dir/user-home/.claude/sessions/"*.json
  before="$dir/meta.before"; cp "$dir/home/state/t1.meta" "$before"
  out=$(run_control "$dir" t1 park --reason "waits"); rc=$?
  expect_code 1 "$rc" "park without a provable session should refuse"$'\n'"$out"
  assert_contains "$out" "cannot be parked" "the refusal should say the task cannot be parked"
  assert_nothing_changed "$dir" "$before" "an unproven park"
  ! grep -q 'ticket park' "$dir/fake/atlas" || fail "an unproven park must not touch the Atlas"
  pass "park: a session that cannot be proven refuses with nothing changed"
}

test_park_refuses_when_the_atlas_does_not_record_it() {
  local dir out rc before
  dir=$(new_case park-atlas-fail)
  before="$dir/meta.before"; cp "$dir/home/state/t1.meta" "$before"
  out=$(FM_FAKE_ATLAS_FAIL=park run_control "$dir" t1 park --reason "waits"); rc=$?
  expect_code 1 "$rc" "park should refuse when the Atlas does not record it"$'\n'"$out"
  assert_contains "$out" "Atlas ticket could not record the park" "the refusal should name the Atlas"
  assert_nothing_changed "$dir" "$before" "an unrecorded Atlas park"
  pass "park: an Atlas that does not record the park refuses with the worker still running"
}

# A worker that never stops leaves nothing parked: the stop is retried while
# the agent still reads alive, then the ticket is unparked and the record is
# withdrawn, and the refusal is reported rather than lost.
test_park_withdraws_when_the_worker_does_not_stop() {
  local dir out rc
  dir=$(new_case park-stuck)
  out=$(FM_FAKE_NEVER_DIES=1 run_control "$dir" t1 park --reason "waits"); rc=$?
  expect_code 1 "$rc" "park of a worker that does not stop should fail"$'\n'"$out"
  assert_contains "$out" "its worker did not stop" "the failure should say the worker did not stop"
  assert_contains "$out" "exit=unconfirmed" "the failure should carry the stop refusal"
  [ "$(grep -cx '/exit' "$dir/fake/literal")" = 3 ] || fail "park should retry the stop three times, got: $(cat "$dir/fake/literal")"
  [ -z "$(meta_field "$dir" parked)" ] || fail "a failed park must withdraw its record"
  [ -z "$(meta_field "$dir" native_session)" ] || fail "a failed park must withdraw the recorded session"
  [ "$(cat "$dir/fake/ticket-state")" = started ] || fail "a failed park must return the ticket to started"
  grep -qx 'fmses:fm-t1' "$dir/fake/windows" || fail "a failed park must not close the endpoint"
  pass "park: a worker that does not stop leaves the task and its ticket as they were"
}

# A Claude worker started on another account profile keeps its session under
# that profile, where the resume launch never looks, so the park refuses it.
test_park_refuses_a_session_its_resume_would_not_find() {
  local dir out rc before profile pid
  dir=$(new_case park-account)
  profile="$dir/account-profile"
  pid=$(stand_in claude "CLAUDE_CONFIG_DIR=$profile" ':')
  mkdir -p "$profile/sessions" "$profile/projects/-wt"
  jq -cn --argjson pid "$pid" --arg sid "$SID" --arg cwd "$(meta_field "$dir" worktree)" --arg start "$(proc_start "$pid")" \
    '{pid: $pid, sessionId: $sid, cwd: $cwd, procStart: $start}' > "$profile/sessions/$pid.json"
  printf '{"type":"user"}\n' > "$profile/projects/-wt/$SID.jsonl"
  printf '%s' "$pid" > "$dir/fake/fgpid"
  before="$dir/meta.before"; cp "$dir/home/state/t1.meta" "$before"
  out=$(run_control "$dir" t1 park --reason "waits"); rc=$?
  expect_code 1 "$rc" "park of a session the resume would not find should refuse"$'\n'"$out"
  assert_contains "$out" "its resume would not find the session" "the refusal should say the resume would not find the session"
  assert_nothing_changed "$dir" "$before" "a park its resume would not find"
  ! grep -q 'ticket park' "$dir/fake/atlas" || fail "a park its resume would not find must not touch the Atlas"
  pass "park: a session outside the configuration the resume launches with refuses with nothing changed"
}

# A park whose stop failed and whose unpark rollback also failed leaves the
# local record withdrawn while the ticket still holds that exact park. A retry
# meets an Atlas that drops the identical park as a no-op, and still parks.
test_park_retry_accepts_the_identical_park_already_in_force() {
  local dir out rc
  dir=$(new_case park-retry)
  printf 'parked' > "$dir/fake/ticket-state"
  jq -cn --arg why "waits" --arg on "" --arg id "$SID" \
    '{why: $why, on: (if $on == "" then null else $on end), session: {id: $id}}' | tr -d '\n' > "$dir/fake/park-body"
  printf 'at-0' > "$dir/fake/park-at"
  out=$(run_control "$dir" t1 park --reason "waits"); rc=$?
  expect_code 0 "$rc" "a retried park the Atlas already holds should succeed"$'\n'"$out"
  [ "$(cat "$dir/fake/park-at")" = at-0 ] || fail "the setup needs the Atlas to drop the identical park as a no-op"
  [ "$(meta_field "$dir" native_session)" = "$SID" ] || fail "the retried park should record the session"
  [ ! -s "$dir/fake/windows" ] || fail "the retried park should close the endpoint"
  pass "park: a retry whose ticket already holds the identical park is accepted"
}

test_park_refuses_unverified_harnesses_and_secondmates() {
  local dir out rc
  dir=$(new_case park-grok grok)
  out=$(run_control "$dir" t1 park --reason "waits"); rc=$?
  expect_code 1 "$rc" "park on grok should refuse"$'\n'"$out"
  assert_contains "$out" "no verified native session" "the grok refusal should name the missing contract"
  dir=$(new_case park-sm claude secondmate)
  out=$(run_control "$dir" t1 park --reason "waits"); rc=$?
  expect_code 1 "$rc" "park on a secondmate should refuse"$'\n'"$out"
  out=$(run_control "$dir" t1 park); rc=$?
  expect_code 1 "$rc" "park without a reason should refuse"$'\n'"$out"
  pass "park: an unverified harness, a secondmate, and a missing reason all refuse"
}

# --- 3. resume ------------------------------------------------------------------

park_case() {  # <name> [harness]: a case whose task is already parked
  local dir out
  dir=$(new_case "$1" "${2:-claude}")
  out=$(run_control "$dir" t1 park --reason "waits on the captain" --on c12) \
    || fail "setup park failed: $out"
  : > "$dir/fake/literal"
  printf '%s\n' "$dir"
}

test_resume_reopens_the_exact_session_in_a_new_endpoint() {
  local dir out rc launch unpark_line spawn_line
  dir=$(park_case resume-ok)
  out=$(run_control "$dir" t1 resume --note "the captain approved the merge"); rc=$?
  expect_code 0 "$rc" "resume should succeed"$'\n'"$out"
  assert_contains "$out" "resumed t1 harness=claude session=$SID" "resume should report the reopened session"
  launch=$(grep -F -- "--resume '$SID'" "$dir/fake/literal" || true)
  [ -n "$launch" ] || fail "resume should launch claude --resume with the recorded session, got: $(cat "$dir/fake/literal")"
  assert_not_contains "$launch" "encode launch-brief" "resume must not launch the brief as a fresh session"
  grep -qx 'fm-t1' "$dir/fake/new-windows" || fail "resume should open a new endpoint for the parked task"
  grep -qx 'firstmate:fm-t1' "$dir/fake/windows" || fail "resume should record its new endpoint in the inventory"
  [ "$(cat "$dir/fake/cwd")" = "$(meta_field "$dir" worktree)" ] || fail "resume should open the endpoint in the task worktree"
  [ -z "$(meta_field "$dir" parked)" ] || fail "resume should clear the park record"
  [ -z "$(meta_field "$dir" native_session)" ] || fail "resume should clear the recorded session with the park"
  [ "$(meta_field "$dir" harness)" = claude ] || fail "resume should keep the recorded harness"
  unpark_line=$(grep -n 'ticket unpark c7 the captain approved the merge' "$dir/fake/atlas" | cut -d: -f1)
  [ -n "$unpark_line" ] || fail "resume should unpark the Atlas ticket, got: $(cat "$dir/fake/atlas")"
  spawn_line=$(grep -n '^ticket start c7' "$dir/fake/atlas" | tail -1 | cut -d: -f1)
  [ -z "$spawn_line" ] || [ "$unpark_line" -lt "$spawn_line" ] || fail "resume must unpark before the launch starts the ticket"
  grep -rqF "the captain approved the merge" "$dir/home/state/t1.inbox" \
    || fail "resume should deliver the note as a durable steer"
  grep -rqs 'event=resume' "$dir/home/state/" || fail "the resumed incarnation should be armed idle, not busy"
  pass "resume: the ticket is unparked first, the exact session reopens in a new endpoint in the worktree, and the note is steered"
}

test_resume_codex_uses_its_resume_subcommand() {
  local dir out rc
  dir=$(park_case resume-codex codex)
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 0 "$rc" "codex resume should succeed"$'\n'"$out"
  grep -qF "codex resume " "$dir/fake/literal" || fail "codex resume should use codex resume, got: $(cat "$dir/fake/literal")"
  grep -qF "'$SID'" "$dir/fake/literal" || fail "codex resume should name the recorded session"
  pass "resume: a codex worker reopens through codex resume <session>"
}

# A park whose close never finished leaves the task's own agent-free pane in its
# worktree; the resume closes that pane before it opens the new one.
test_resume_closes_its_own_leftover_pane_first() {
  local dir out rc
  dir=$(new_case resume-leftover)
  out=$(FM_FAKE_KILL_FAILS=1 run_control "$dir" t1 park --reason "waits"); rc=$?
  expect_code 1 "$rc" "a park whose close cannot be proven should report it"$'\n'"$out"
  assert_contains "$out" "is parked with its session recorded" "the unfinished close should still leave the task parked"
  grep -qx 'fmses:fm-t1' "$dir/fake/windows" || fail "the setup needs the leftover pane to remain"
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 0 "$rc" "resume should close its own leftover pane and continue"$'\n'"$out"
  ! grep -qx 'fmses:fm-t1' "$dir/fake/windows" || fail "resume should close the task's own leftover pane"
  grep -qx 'firstmate:fm-t1' "$dir/fake/windows" || fail "resume should open its new endpoint"
  pass "resume: the task's own leftover pane from an unfinished close is closed before the new endpoint opens"
}

# After a server restart the recorded endpoint id can name another pane. That
# pane sits elsewhere, so the resume leaves it alone and opens its own.
test_resume_leaves_a_reused_endpoint_alone() {
  local dir out rc
  dir=$(park_case resume-reused)
  printf 'fmses:fm-t1\n' >> "$dir/fake/windows"
  printf 'claude' > "$dir/fake/command"
  printf '%s' "$TMP_ROOT" > "$dir/fake/cwd"
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 0 "$rc" "resume should not be blocked by another pane reusing the recorded id"$'\n'"$out"
  grep -qx 'fmses:fm-t1' "$dir/fake/windows" || fail "resume must leave another pane that reuses the recorded id alone"
  grep -qx 'firstmate:fm-t1' "$dir/fake/windows" || fail "resume should open its own new endpoint"
  pass "resume: a recorded endpoint id that now names another pane is left alone"
}

test_resume_refuses_an_agent_running_in_the_worktree() {
  local dir out rc
  dir=$(park_case resume-running)
  printf 'fmses:fm-t1\n' >> "$dir/fake/windows"
  printf 'claude' > "$dir/fake/command"
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 1 "$rc" "resume should refuse when an agent runs in the task worktree"$'\n'"$out"
  assert_contains "$out" "already runs in task t1's worktree" "the refusal should name the running agent"
  [ -n "$(meta_field "$dir" parked)" ] || fail "a refused resume keeps the task parked"
  ! grep -q 'ticket unpark' "$dir/fake/atlas" || fail "a refused resume must not unpark the ticket"
  pass "resume: an agent already running in the task worktree refuses the resume"
}

# --- 4. park again ---------------------------------------------------------------

# After a server restart the recorded endpoint id can name another agent-free
# pane. Parking again only refreshes the record and the Atlas park, and leaves
# that pane alone.
test_repark_leaves_a_reused_endpoint_alone() {
  local dir out rc stamp
  dir=$(park_case repark-reused)
  stamp=$(meta_field "$dir" parked)
  printf 'fmses:fm-t1\n' >> "$dir/fake/windows"
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$TMP_ROOT" > "$dir/fake/cwd"
  out=$(run_control "$dir" t1 park --reason "waits on the new review" --on c13); rc=$?
  expect_code 0 "$rc" "parking a parked task again should succeed"$'\n'"$out"
  grep -qx 'fmses:fm-t1' "$dir/fake/windows" || fail "parking again must leave another pane that reuses the recorded id alone"
  [ "$(meta_field "$dir" parked_reason)" = "waits on the new review" ] || fail "parking again should refresh the reason"
  [ "$(meta_field "$dir" parked_on)" = c13 ] || fail "parking again should refresh the blocker"
  [ "$(meta_field "$dir" parked)" = "$stamp" ] || fail "parking again should keep the original park time"
  [ "$(meta_field "$dir" native_session)" = "$SID" ] || fail "parking again should keep the recorded session"
  grep -qxF "ticket park c7 waits on the new review --home main --harness claude --session $SID --task t1 --on c13" "$dir/fake/atlas" \
    || fail "parking again should re-record the Atlas park, got: $(cat "$dir/fake/atlas")"
  [ ! -s "$dir/fake/literal" ] || fail "parking again must send nothing to the pane, got: $(cat "$dir/fake/literal")"
  out=$(run_control "$dir" t1 park --reason "waits on the new review" --on c13); rc=$?
  expect_code 0 "$rc" "parking again with the park already recorded should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" parked_reason)" = "waits on the new review" ] || fail "an identical park must keep the reason"
  pass "park again: only the reason, blocker, and Atlas park are refreshed, and a reused endpoint id is left alone"
}

# The Atlas refuses a park update whose blocker names nothing, and the ticket
# stays parked under its prior park, so the state alone cannot tell the refusal
# apart from an update.
test_repark_keeps_the_prior_record_when_the_atlas_does_not_record_it() {
  local dir out rc before
  dir=$(park_case repark-atlas-fail)
  before="$dir/meta.before"; cp "$dir/home/state/t1.meta" "$before"
  out=$(run_control "$dir" t1 park --reason "waits on the new review" --on c99); rc=$?
  expect_code 1 "$rc" "parking again should fail when the Atlas does not record it"$'\n'"$out"
  assert_contains "$out" "park was not updated" "the failure should say the park was not updated"
  assert_contains "$out" "prior park record was kept" "the failure should say the prior record stays"
  assert_not_contains "$out" "worker is still running" "the failure must not claim a worker still runs"
  cmp -s "$before" "$dir/home/state/t1.meta" || fail "a failed park update must restore the prior park record"
  [ "$(cat "$dir/fake/ticket-state")" = parked ] || fail "the refused update must leave the ticket parked"
  out=$(run_control "$dir" t1 park --reason "waits on the captain" --on c99); rc=$?
  expect_code 1 "$rc" "a refused blocker-only update should fail too"$'\n'"$out"
  assert_contains "$out" "park was not updated" "the blocker-only failure should say the park was not updated"
  cmp -s "$before" "$dir/home/state/t1.meta" || fail "a failed blocker-only update must restore the prior park record"
  pass "park again: an Atlas that refuses the update while the ticket stays parked keeps the prior park record"
}

# --- 5. resume refusals and rollback --------------------------------------------

test_resume_refuses_a_missing_session_file() {
  local dir out rc before
  dir=$(park_case resume-missing)
  rm -f "$(meta_field "$dir" native_session_file)"
  before="$dir/meta.before"; cp "$dir/home/state/t1.meta" "$before"
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 1 "$rc" "resume without its session file should refuse"$'\n'"$out"
  assert_contains "$out" "is missing" "the refusal should say the session file is missing"
  assert_contains "$out" "never restarted as a fresh session" "the refusal should rule out a fresh session"
  cmp -s "$before" "$dir/home/state/t1.meta" || fail "a refused resume must leave the task parked and unchanged"
  ! grep -q 'ticket unpark' "$dir/fake/atlas" || fail "a refused resume must not unpark the ticket"
  [ ! -s "$dir/fake/literal" ] || fail "a refused resume must launch nothing"
  pass "resume: a missing session file refuses before anything changes"
}

test_resume_that_does_not_come_up_parks_the_ticket_again() {
  local dir out rc
  dir=$(park_case resume-dead)
  printf 'zsh' > "$dir/fake/becomes"
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 1 "$rc" "a resume whose agent never runs should fail"$'\n'"$out"
  assert_contains "$out" "stays parked" "the failure should say the task stays parked"
  [ -n "$(meta_field "$dir" parked)" ] || fail "a failed resume must keep the park record"
  [ "$(cat "$dir/fake/ticket-state")" = parked ] || fail "a failed resume must park the Atlas ticket again"
  pass "resume: a launch that does not come up keeps the park and re-records it on the Atlas"
}

test_resume_refuses_when_the_atlas_does_not_unpark() {
  local dir out rc
  dir=$(park_case resume-gate)
  out=$(FM_FAKE_ATLAS_FAIL=unpark run_control "$dir" t1 resume); rc=$?
  expect_code 1 "$rc" "resume should refuse when the ticket cannot be unparked"$'\n'"$out"
  assert_contains "$out" "could not be returned to started" "the refusal should name the ticket"
  [ ! -s "$dir/fake/literal" ] || fail "a refused unpark must launch nothing"
  pass "resume: a ticket the Atlas will not unpark refuses before any launch"
}

test_resume_refuses_a_task_that_is_not_parked() {
  local dir out rc
  dir=$(new_case resume-unparked)
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 1 "$rc" "resume of a running task should refuse"$'\n'"$out"
  assert_contains "$out" "is not parked" "the refusal should say the task is not parked"
  pass "resume: a task that is not parked refuses"
}

# --- 6. relaunch of a parked task --------------------------------------------

test_relaunch_of_a_parked_task_resumes_its_session() {
  local dir out rc
  dir=$(park_case relaunch-parked)
  out=$(run_control "$dir" t1 relaunch --harness codex --note "switch"); rc=$?
  expect_code 1 "$rc" "relaunch of a parked task onto another harness should refuse"$'\n'"$out"
  assert_contains "$out" "is parked" "the refusal should say the task is parked"
  out=$(run_control "$dir" t1 relaunch --note "continue from the park"); rc=$?
  expect_code 0 "$rc" "relaunch of a parked task should resume it"$'\n'"$out"
  grep -qF -- "--resume '$SID'" "$dir/fake/literal" || fail "relaunch of a parked task should reopen its session"
  ! grep -qF 'encode launch-brief' "$dir/fake/literal" || fail "relaunch of a parked task must not start fresh"
  pass "relaunch: a parked task resumes its recorded session instead of starting fresh"
}

test_park_records_the_session_and_closes_only_the_endpoint
test_park_codex_records_the_open_rollout
test_park_refuses_an_unproven_session
test_park_refuses_when_the_atlas_does_not_record_it
test_park_refuses_unverified_harnesses_and_secondmates
test_park_withdraws_when_the_worker_does_not_stop
test_park_refuses_a_session_its_resume_would_not_find
test_park_retry_accepts_the_identical_park_already_in_force
test_resume_reopens_the_exact_session_in_a_new_endpoint
test_resume_codex_uses_its_resume_subcommand
test_resume_closes_its_own_leftover_pane_first
test_resume_leaves_a_reused_endpoint_alone
test_resume_refuses_an_agent_running_in_the_worktree
test_resume_refuses_a_missing_session_file
test_resume_that_does_not_come_up_parks_the_ticket_again
test_resume_refuses_when_the_atlas_does_not_unpark
test_resume_refuses_a_task_that_is_not_parked
test_repark_leaves_a_reused_endpoint_alone
test_repark_keeps_the_prior_record_when_the_atlas_does_not_record_it
test_relaunch_of_a_parked_task_resumes_its_session
