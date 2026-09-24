#!/usr/bin/env bash
# tests/fm-spawn-agent-limit.test.sh - bin/fm-spawn.sh enforces the concurrent
# agent limit from the live Herdr count, with the --over-limit flag and
# config/agent-limit off as overrides, and bin/fm-control.sh resume checks it
# before its Atlas unpark.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/agent-limit-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/agent-limit-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-agent-limit)

# A home with two crewmate agents already open in Herdr, and a queued ship task.
build_case() {  # <name> -> sets DIR HOME_DIR PROJ FAKEBIN
  DIR="$TMP_ROOT/$1"
  HOME_DIR="$DIR/home"
  PROJ="$DIR/proj"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  fm_git_init_commit "$PROJ" >/dev/null 2>&1 || { mkdir -p "$PROJ"; git -C "$PROJ" init -q; }
  mkdir -p "$HOME_DIR/data/new-task"
  cat > "$HOME_DIR/data/new-task/brief.md" <<'MD'
# Task
## Captain's intent
Exercise the agent limit.

## Firstmate spec
Nothing to build.

Delivery contract: mode=direct-PR
MD
  FAKEBIN=$(make_fake_herdr "$DIR")
  fm_fake_exit0 "$FAKEBIN" treehouse
  add_pane "$DIR" default w1:p1 w1 "$DIR/wt-a" claude claude
  add_pane "$DIR" default w1:p2 w1 "$DIR/wt-b" pi pi
  agent_limit_task_meta "$HOME_DIR" task-a ship claude default:w1:p1
  agent_limit_task_meta "$HOME_DIR" task-b scout pi default:w1:p2
}

run_spawn() {  # [fm-spawn args...]
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    FM_ROOT_OVERRIDE= FM_HOME="$HOME_DIR" HOME="$DIR" CLAUDE_CONFIG_DIR= \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN= HERDR_SESSION=default \
    FM_FAKE_HERDR_DIR="$DIR/herdr" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

spawn_new_task() {  # [extra args...]
  run_spawn new-task "$PROJ" --mode direct-PR --yolo off --harness claude "$@"
}

# The fake answers only the count's reads, so a spawn that passed the limit
# shows its first endpoint call in the log and then stops there.
assert_passed_limit() {  # <out> <label>
  assert_not_contains "$1" "agent limit" "$2: the spawn was refused by the agent limit"
  grep -v -e '^pane list' -e '^pane process-info' -e '^status' "$DIR/herdr/calls" | grep -q . \
    || fail "$2: the spawn never went on to create its endpoint"$'\n'"$1"
}

test_under_the_limit_spawns() {
  local out
  build_case under
  printf '3\n' > "$HOME_DIR/config/agent-limit"
  out=$(spawn_new_task)
  assert_passed_limit "$out" "under the limit"
  pass "fm-spawn: a spawn under the agent limit goes ahead"
}

test_at_the_limit_refuses() {
  local out rc
  build_case at
  printf '2\n' > "$HOME_DIR/config/agent-limit"
  out=$(spawn_new_task); rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn at the agent limit succeeded: $out"
  assert_contains "$out" "agent limit reached: 2 agents are open in Herdr and the limit is 2" \
    "the refusal should name the count and the limit"
  assert_contains "$out" "--over-limit" "the refusal should name the per-spawn override"
  assert_contains "$out" "config/agent-limit" "the refusal should name the config override"
  if grep -v -e '^pane list' -e '^pane process-info' -e '^status' "$DIR/herdr/calls" | grep -q .; then
    fail "a refused spawn still made an endpoint call: $(cat "$DIR/herdr/calls")"
  fi
  assert_absent "$HOME_DIR/state/new-task.meta" "a refused spawn wrote a task record"
  pass "fm-spawn: a spawn at the agent limit is refused before any endpoint exists, naming the count, the limit, and the overrides"
}

test_over_limit_flag_passes() {
  local out
  build_case flag
  printf '2\n' > "$HOME_DIR/config/agent-limit"
  out=$(spawn_new_task --over-limit)
  assert_passed_limit "$out" "--over-limit"
  pass "fm-spawn: --over-limit lets one spawn past the agent limit"
}

test_config_off_passes() {
  local out
  build_case off
  printf 'off\n' > "$HOME_DIR/config/agent-limit"
  touch "$DIR/herdr/default/broken"
  out=$(spawn_new_task)
  assert_passed_limit "$out" "config off"
  assert_no_grep "pane list" "$DIR/herdr/calls" "config off still read the Herdr agent count"
  pass "fm-spawn: config/agent-limit off disables the limit without reading Herdr"
}

test_unreadable_count_refuses() {
  local out rc
  build_case unreadable
  touch "$DIR/herdr/default/broken"
  out=$(spawn_new_task); rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn with an unreadable agent count succeeded: $out"
  assert_contains "$out" "the agent count could not be read" "the refusal should say the count was unreadable"
  assert_contains "$out" "--over-limit" "the refusal should name the per-spawn override"
  pass "fm-spawn: an unreadable Herdr count refuses rather than guessing, and names the override"
}

# A ship task recorded on Herdr <pane>, whose worktree exists, for --relaunch.
relaunch_task_meta() {  # <pane>
  mkdir -p "$DIR/wt-old"
  fm_write_meta "$HOME_DIR/state/old-task.meta" "window=default:$1" "kind=ship" "harness=claude" \
    "backend=herdr" "worktree=$DIR/wt-old" "project=$PROJ" "mode=direct-PR" "yolo=off" \
    "endpoint_task_id=old-task" "herdr_session=default" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=$1"
  mkdir -p "$HOME_DIR/data/old-task"
  cp "$HOME_DIR/data/new-task/brief.md" "$HOME_DIR/data/old-task/brief.md"
}

test_relaunch_in_its_own_pane_ignores_the_limit() {
  local out
  build_case relaunch-in-place
  make_fake_ps "$FAKEBIN"
  printf '2\n' > "$HOME_DIR/config/agent-limit"
  add_pane "$DIR" default w1:p3 w1 "$DIR/wt-old" bash /bin/bash
  relaunch_task_meta w1:p3
  out=$(FM_HERDR_PS_BIN="$FAKEBIN/ps" run_spawn old-task --relaunch)
  assert_not_contains "$out" "agent limit" "a relaunch into the task's own open pane was held to the agent limit"
  assert_not_contains "$out" "endpoint reads" "the fixture pane did not read as agent-free, so the case proves nothing"
  assert_not_contains "$out" "REFUSED" "the fixture task record was refused, so the case proves nothing"
  pass "fm-spawn: a relaunch into the task's own open pane replaces an agent and ignores the limit"
}

# The old task, parked on Atlas ticket c7 with its Claude session recorded. The
# park closed its pane, so <pane> is no longer in the Herdr pane list.
parked_task_meta() {  # <pane>
  local sid=0f3c2a9e-3333-4a2b-9c3d-000000000003 file
  relaunch_task_meta "$1"
  file="$DIR/.claude/projects/-wt-old/$sid.jsonl"
  mkdir -p "${file%/*}" "$DIR/atlas/atlas"
  printf '{"type":"user"}\n' > "$file"
  printf '%s\n' "atlas_ticket=c7" "parked=2026-09-23T00:00:00Z" "parked_reason=waits on the captain" \
    "native_session=$sid" "native_session_harness=claude" "native_session_file=$file" \
    >> "$HOME_DIR/state/old-task.meta"
  printf '%s\n' "$DIR/atlas" > "$HOME_DIR/config/specs"
  : > "$DIR/atlas-calls"
  cat > "$FAKEBIN/atlas-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$DIR/atlas-calls'
exit 1
SH
  chmod +x "$FAKEBIN/atlas-axi"
}

run_control() {  # [fm-control args...]
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    FM_ROOT_OVERRIDE= FM_HOME="$HOME_DIR" HOME="$DIR" CLAUDE_CONFIG_DIR= \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND_HERDR_AXI_BIN= HERDR_SESSION=default \
    FM_CONTROL_POLL=0.01 FM_CONTROL_STATE_SETTLE=0.05 FM_CONTROL_LAUNCH_WAIT=0.2 \
    FM_FAKE_HERDR_DIR="$DIR/herdr" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# A resume also reads its recorded pane's state, so proof that it went on to
# create its endpoint must look past those reads as well as the count's.
endpoint_calls() {
  grep -v -e '^pane list' -e '^pane process-info' -e '^pane get' -e '^agent get' -e '^status' \
    "$DIR/herdr/calls" || true
}

assert_resume_reached_its_endpoint() {  # <out> <label>
  assert_not_contains "$1" "agent limit" "$2: the resume was refused by the agent limit"
  [ -n "$(endpoint_calls)" ] || fail "$2: the resume never went on to create its endpoint"$'\n'"$1"
}

test_resume_into_a_new_pane_is_held_to_the_limit() {
  local out rc
  build_case resume-spawn
  printf '2\n' > "$HOME_DIR/config/agent-limit"
  parked_task_meta w1:p9
  out=$(run_spawn old-task --relaunch --resume-session); rc=$?
  [ "$rc" -ne 0 ] || fail "a resume at the agent limit succeeded: $out"
  assert_contains "$out" "agent limit reached: 2 agents are open in Herdr and the limit is 2" \
    "a resume into a new pane should be held to the agent limit"
  assert_contains "$out" "--over-limit" "the refusal should name the per-spawn override"
  [ -z "$(endpoint_calls)" ] || fail "a refused resume still made an endpoint call: $(endpoint_calls)"
  out=$(run_spawn old-task --relaunch --resume-session --over-limit)
  assert_resume_reached_its_endpoint "$out" "spawn --resume-session --over-limit"
  pass "fm-spawn: a resume opens a new pane, so it is held to the agent limit unless --over-limit is passed"
}

test_control_resume_at_the_limit_keeps_the_ticket_parked() {
  local out rc meta
  build_case resume-control
  printf '2\n' > "$HOME_DIR/config/agent-limit"
  parked_task_meta w1:p9
  out=$(run_control old-task resume --note "the captain approved"); rc=$?
  [ "$rc" -ne 0 ] || fail "a resume at the agent limit succeeded: $out"
  assert_contains "$out" "agent limit reached" "resume should refuse at the agent limit"
  assert_contains "$out" "--over-limit" "the refusal should name the override"
  assert_no_grep "unpark" "$DIR/atlas-calls" "a resume refused by the limit must not unpark the Atlas ticket"
  assert_grep "parked=2026-09-23T00:00:00Z" "$HOME_DIR/state/old-task.meta" "a resume refused by the limit must leave the task parked"
  [ -z "$(endpoint_calls)" ] || fail "a resume refused by the limit still made an endpoint call: $(endpoint_calls)"
  # Without a ticket, the resume goes straight on to the launch, which shows
  # that --over-limit reached bin/fm-spawn.sh as well.
  meta="$HOME_DIR/state/old-task.meta"
  grep -v '^atlas_ticket=' "$meta" > "$meta.next" && mv "$meta.next" "$meta"
  out=$(run_control old-task resume --over-limit)
  assert_resume_reached_its_endpoint "$out" "resume --over-limit"
  pass "fm-control: resume at the agent limit refuses before the Atlas unpark, and --over-limit carries through to the launch"
}

test_control_relaunch_refuses_over_limit_for_a_task_that_is_not_parked() {
  local out rc
  build_case relaunch-over-limit
  relaunch_task_meta w1:p9
  out=$(run_control old-task relaunch --note "go on" --over-limit); rc=$?
  [ "$rc" -ne 0 ] || fail "relaunch of a task that is not parked accepted --over-limit: $out"
  assert_contains "$out" "--over-limit applies only when" \
    "relaunch of a task that is not parked should refuse --over-limit, which it never needs"
  pass "fm-control: a relaunch into the task's own pane refuses --over-limit, because the limit never holds it"
}

test_under_the_limit_spawns
test_at_the_limit_refuses
test_over_limit_flag_passes
test_config_off_passes
test_unreadable_count_refuses
test_relaunch_in_its_own_pane_ignores_the_limit
test_resume_into_a_new_pane_is_held_to_the_limit
test_control_resume_at_the_limit_keeps_the_ticket_parked
test_control_relaunch_refuses_over_limit_for_a_task_that_is_not_parked
