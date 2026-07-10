#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --session-name and the per-kind default session
# display name (AGENTS.md task lifecycle / spawn).
#
# Like the dispatch-profile suite, these drive fm-spawn through meta writing and
# launch construction with a fake tmux pane and a real isolated git worktree. The
# fake tmux captures the literal launch command sent with `tmux send-keys -l`, so
# assertions pin the command firstmate would run without starting any real
# harness. Coverage: flag parsing, per-kind defaults (crewmate/scout task id,
# secondmate "Secondmate, <id>"), harness gating (claude threads --name; a
# no-support harness like codex does not and launches byte-identically), meta
# recording of session_name= only when a flag was passed, quoting safety for a
# name with spaces and single quotes, batch refusal, and empty-value rejection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-session-name)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

test_claude_explicit_session_name_threads_name_flag() {
  local rec id out status launch name
  id=session-explicit-z1
  name="herdr pane-split layout"
  rec=$(make_spawn_case session-explicit claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name "$name")
  status=$?
  expect_code 0 "$status" "claude spawn with an explicit session name should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --name 'herdr pane-split layout' \"\$(cat " \
    "claude launch did not thread the explicit --name flag"
  assert_grep "session_name=$name" "$HOME_DIR/state/$id.meta" "meta missing explicit session_name"
  pass "claude threads an explicit --session-name and records session_name= in meta"
}

test_crewmate_default_name_is_task_id() {
  local rec id out status launch
  id=session-crew-default-z2
  rec=$(make_spawn_case session-crew-default claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude crewmate spawn without a session name should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --name '$id' \"\$(cat " \
    "claude crewmate launch did not default --name to the task id"
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
  assert_contains "$launch" "claude --dangerously-skip-permissions --name '$id' \"\$(cat " \
    "claude scout launch did not default --name to the task id"
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
  assert_contains "$launch" "claude --dangerously-skip-permissions --name 'Secondmate, $id' \"\$(cat " \
    "claude secondmate launch did not default --name to 'Secondmate, <id>'"
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
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn without a session name should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--name" "codex launch must not pass an unverified session-name flag"
  assert_no_grep "session_name=" "$HOME_DIR/state/$id.meta" "codex meta must not record session_name when no flag was passed"

  # Explicit --session-name on codex: still no --name, still no session_name=, and
  # the launch is byte-identical to the no-flag codex launch above.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name "ignored name")
  status=$?
  expect_code 0 "$status" "codex spawn with an ignored session name should still succeed"
  launch_named=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch_named" "--name" "codex launch must ignore --session-name for an unsupported harness"
  assert_not_contains "$launch_named" "ignored name" "codex launch must not embed the ignored session name"
  assert_no_grep "session_name=" "$HOME_DIR/state/$id.meta" "codex meta must not record session_name even when a flag was passed"
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name "$name")
  status=$?
  expect_code 0 "$status" "claude spawn with a quote-laden session name should succeed"
  launch=$(cat "$LAUNCH_LOG")
  # POSIX single-quote escaping: a literal ' becomes '\'' inside the quoted run.
  assert_contains "$launch" "--name 'a '\\''b'\\'' c' \"\$(cat " \
    "claude launch did not safely single-quote a name containing spaces and single quotes"
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name "$name")
  status=$?
  expect_code 0 "$status" "claude spawn with an ampersand session name should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--name 'fix build & tests' \"\$(cat " \
    "claude launch did not preserve a literal ampersand in the session name"
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 'claude --raw-launch "$(cat __BRIEF__)"')
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --session-name=)
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
