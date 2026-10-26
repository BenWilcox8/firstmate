#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --session-name and the per-kind default session
# display name (AGENTS.md task lifecycle / spawn).
#
# Like the dispatch-profile suite, these drive fm-spawn through meta writing and
# launch construction with the shared spawn-world fake tmux (tests/fixtures.sh)
# and a real isolated git worktree. The fake tmux captures the staged launch
# command, so assertions pin the command firstmate would run without starting any
# real harness. Coverage: flag parsing, per-kind defaults (crewmate/scout task id,
# secondmate "Secondmate, <id>"), harness gating (claude threads --name; a
# no-support harness like codex does not and launches byte-identically), meta
# recording of session_name= only when a flag was passed, quoting safety for a
# name with spaces and single quotes, batch refusal, and empty-value rejection.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-session-name)

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf '# Task\n## Captain\047s intent\nExercise fixture %s.\n\n## Firstmate spec\nValidate session naming.\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
  # A seeded home is a git repository; the spawn installs its strip hooks there.
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
}

# The shared runner also gives the spawn a throwaway HOME and an empty
# CLAUDE_CONFIG_DIR, so the Claude trust registration never writes the
# developer's own Claude store.
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); this
# suite is about session naming, so its ship cases pass a fixed valid one.
# Scout and secondmate spawns resolve their own contract and must not receive it.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# assert_name_flag <launch> <name> <what>
# Pins the --name flag and its position immediately before the brief argument,
# the last argument of the claude command. The text check pins the POSIX single
# quoting of the name. The parsed check runs the shell word rules on the command,
# so the name must come back as exactly <name>. It checks only that the brief
# argument is a launch-brief doorbell, because fm-spawn's launch template and
# bin/fm-operational-input.sh own the brief format, and this file does not.
assert_name_flag() {
  local launch=$1 name=$2 what=$3 quoted command
  quoted="'$(printf '%s' "$name" | sed "s/'/'\\\\''/g")'"
  assert_contains "$launch" "--name $quoted '" "$what did not thread --name $quoted before the brief"
  command=$(fm_test_launch_command "$launch")
  (
    eval "set -- $command"
    while [ "$#" -gt 0 ] && [ "$1" != --name ]; do shift; done
    [ "$#" -eq 3 ] || fail "$what: --name was not followed by exactly the name and the brief: $command"
    [ "$2" = "$name" ] || fail "$what: --name parsed as '$2', not '$name'"
    [ "$(printf '%s' "$3" | "$ROOT/bin/fm-operational-input.sh" doorbell-kind)" = launch-brief ] \
      || fail "$what: the argument after --name is not a launch-brief doorbell: $3"
  ) || exit 1
}

test_claude_explicit_session_name_threads_name_flag() {
  local rec id out status launch name
  id=session-explicit-z1
  name="herdr pane-split layout"
  rec=$(make_spawn_case session-explicit claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name "$name")
  status=$?
  expect_code 0 "$status" "claude spawn with an explicit session name should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions " \
    "claude launch omitted its configured permission flag"
  assert_contains "$launch" " --settings " "claude launch omitted its configured settings"
  assert_name_flag "$launch" "$name" "claude launch with an explicit session name"
  assert_grep "session_name=$name" "$HOME_DIR/state/$id.meta" "meta missing explicit session_name"
  pass "claude threads an explicit --session-name and records session_name= in meta"
}

test_crewmate_default_name_is_task_id() {
  local rec id out status launch
  id=session-crew-default-z2
  rec=$(make_spawn_case session-crew-default claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude crewmate spawn without a session name should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_name_flag "$launch" "$id" "claude crewmate launch (default --name is the task id)"
  assert_grep "session_name=$id" "$HOME_DIR/state/$id.meta" "meta missing default crewmate session_name=<id>"
  pass "a crewmate defaults its session name to the task id"
}

test_scout_default_name_is_task_id() {
  local rec id out status launch
  id=session-scout-default-z3
  rec=$(make_spawn_case session-scout-default claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "claude scout spawn without a session name should succeed"
  assert_contains "$out" "kind=scout" "scout spawn did not report kind=scout"
  launch=$(cat "$LAUNCH_LOG")
  assert_name_flag "$launch" "$id" "claude scout launch (default --name is the task id)"
  assert_grep "session_name=$id" "$HOME_DIR/state/$id.meta" "meta missing default scout session_name=<id>"
  pass "a scout defaults its session name to the task id"
}

test_secondmate_default_name_is_secondmate_id() {
  local rec id sm out status launch
  id=session-secondmate-z4
  rec=$(make_spawn_case session-secondmate claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "claude secondmate spawn without a session name should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=secondmate" "secondmate launch did not use claude"
  launch=$(cat "$LAUNCH_LOG")
  assert_name_flag "$launch" "Secondmate, $id" "claude secondmate launch (default --name is 'Secondmate, <id>')"
  assert_grep "session_name=Secondmate, $id" "$HOME_DIR/state/$id.meta" \
    "meta missing default secondmate session_name=Secondmate, <id>"
  pass "a secondmate defaults its session name to 'Secondmate, <id>'"
}

test_unsupported_harness_omits_name_flag_and_meta() {
  local rec id out status launch launch_named
  id=session-codex-z5
  rec=$(make_spawn_case session-codex codex "$id")
  read_case_record "$rec"

  # Default (no flag): codex has no verified session-name flag, so no --name is
  # passed and no session_name= is recorded.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn without a session name should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--name" "codex launch must not pass an unverified session-name flag"
  assert_no_grep "session_name=" "$HOME_DIR/state/$id.meta" "codex meta must not record session_name when no flag was passed"

  # Explicit --session-name on codex: still no --name, still no session_name=, and
  # the launch is byte-identical to the no-flag codex launch above, apart from
  # the per-spawn nonce in its private Git configuration file name. The first
  # worker's window closes first, so the second spawn may replace it.
  PATH="$FAKEBIN_DIR:$PATH" tmux kill-window -t "firstmate:fm-$id"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name "ignored name")
  status=$?
  expect_code 0 "$status" "codex spawn with an ignored session name should still succeed"
  launch_named=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch_named" "--name" "codex launch must ignore --session-name for an unsupported harness"
  assert_not_contains "$launch_named" "ignored name" "codex launch must not embed the ignored session name"
  assert_no_grep "session_name=" "$HOME_DIR/state/$id.meta" "codex meta must not record session_name even when a flag was passed"
  launch=$(printf '%s' "$launch" | sed -E 's/git-config\.[A-Za-z0-9.]+\.sh/git-config.NONCE.sh/g')
  launch_named=$(printf '%s' "$launch_named" | sed -E 's/git-config\.[A-Za-z0-9.]+\.sh/git-config.NONCE.sh/g')
  [ "$launch" = "$launch_named" ] || fail "codex launch changed when an unsupported --session-name was passed"$'\n'"without: $launch"$'\n'"with:    $launch_named"
  pass "an unsupported harness (codex) launches byte-identically and records no session_name"
}

test_quoting_safety_spaces_and_single_quotes() {
  local rec id out status launch name
  id=session-quote-z6
  # A name with spaces AND single quotes: shell_quote must wrap it so it cannot
  # break out of the launch command line.
  name="a 'b' c"
  rec=$(make_spawn_case session-quote claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name "$name")
  status=$?
  expect_code 0 "$status" "claude spawn with a quote-laden session name should succeed"
  launch=$(cat "$LAUNCH_LOG")
  # POSIX single-quote escaping: a literal ' becomes '\'' inside the quoted run.
  assert_contains "$launch" "--name 'a '\\''b'\\'' c' " \
    "claude launch did not safely single-quote a name containing spaces and single quotes"
  assert_name_flag "$launch" "$name" "claude launch with a quote-laden session name"
  assert_grep "session_name=$name" "$HOME_DIR/state/$id.meta" "meta did not record the raw quoted session name"
  pass "a session name with spaces and single quotes is safely quoted and recorded verbatim"
}

test_quoting_safety_ampersand() {
  local rec id out status launch name
  id=session-amp-z11
  # A name with '&': bash 5.2+ patsub_replacement would expand an unquoted '&'
  # in the substitution back into the matched __NAMEFLAG__ pattern.
  name="fix build & tests"
  rec=$(make_spawn_case session-amp claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name "$name")
  status=$?
  expect_code 0 "$status" "claude spawn with an ampersand session name should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_name_flag "$launch" "$name" "claude launch with an ampersand session name"
  assert_not_contains "$launch" "__NAMEFLAG__" \
    "claude launch leaked the __NAMEFLAG__ placeholder into the ampersand name"
  assert_grep "session_name=$name" "$HOME_DIR/state/$id.meta" "meta did not record the ampersand session name"
  pass "a session name containing an ampersand is substituted literally"
}

test_batch_refuses_session_name() {
  local rec id1 id2 out status
  id1=session-batch-a-z7
  id2=session-batch-b-z8
  rec=$(make_spawn_case session-batch claude "$id1" "$id2")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --session-name "shared name")
  status=$?
  expect_code 1 "$status" "batch dispatch with --session-name should be refused"
  assert_contains "$out" "--session-name is not supported for batch id=repo dispatch" \
    "batch refusal did not explain why --session-name is rejected"
  assert_absent "$HOME_DIR/state/$id1.meta" "batch refusal should happen before any meta is written"
  assert_absent "$HOME_DIR/state/$id2.meta" "batch refusal should happen before any meta is written"
  pass "batch id=repo dispatch refuses --session-name"
}

test_raw_launch_command_omits_name_flag_and_meta() {
  local rec id out status launch
  id=session-raw-z10
  rec=$(make_spawn_case session-raw claude "$id")
  read_case_record "$rec"

  # A raw launch command whose first word is 'claude' derives HARNESS=claude, but
  # the command has no __NAMEFLAG__ placeholder, so no --name may be injected and
  # no session_name= may be recorded.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 'claude --raw-launch __BRIEF__')
  status=$?
  expect_code 0 "$status" "raw launch command spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--name" "raw launch command must not receive a --name flag"
  assert_no_grep "session_name=" "$HOME_DIR/state/$id.meta" \
    "raw launch command meta must not record session_name"
  pass "a raw launch command gets no --name flag and records no session_name"
}

test_empty_session_name_rejected() {
  local rec id out status
  id=session-empty-z9
  rec=$(make_spawn_case session-empty claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name=)
  status=$?
  expect_code 1 "$status" "an empty --session-name value should be rejected"
  assert_contains "$out" "--session-name requires a non-empty value" "empty session name was not rejected with the expected error"
  assert_absent "$HOME_DIR/state/$id.meta" "empty session name should be rejected before meta is written"
  pass "an empty --session-name value is rejected"
}

test_claude_explicit_session_name_threads_name_flag
test_crewmate_default_name_is_task_id
test_scout_default_name_is_task_id
test_secondmate_default_name_is_secondmate_id
test_unsupported_harness_omits_name_flag_and_meta
test_quoting_safety_spaces_and_single_quotes
test_quoting_safety_ampersand
test_batch_refuses_session_name
test_raw_launch_command_omits_name_flag_and_meta
test_empty_session_name_rejected

echo "# all fm-spawn-session-name tests passed"
