#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --ultracode.
#
# Claude Code's ultracode session mode has no CLI flag. It is read from a
# top-level "ultracode": true key in the .claude/settings.local.json of the
# directory claude launches in, so fm-spawn merges that key into the task
# worktree before the launch and records ultracode=on in the task meta.
#
# The same settings file carries this task's busy-state and turn-end hooks, so
# the assertion that matters most is composition: the key arrives AND the hooks
# the claude branch wrote are still there and still parse. These tests therefore
# read the produced file with node's JSON parser rather than grepping it, and the
# last test EXECUTES the captured launch command against a fake claude that
# reports what it read out of the worktree, which is what proves the composed
# spawn really delivers the mode.
#
# A spawn always hands the merge fm-spawn's own freshly written hook file, so a
# test that seeds operator content into the worktree first proves nothing: the
# hook write clobbers it before the merge runs. The reachable hazard is instead
# the hook COMMANDS, which embed this task's real paths and id inside JSON string
# values, so one test drives a path carrying JSON punctuation through a spawn.
#
# Like the persistence suite, everything runs against a fake tmux pane and a real
# isolated git worktree, so no harness is ever started.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-ultracode)

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
  display-message)
    case "$*" in
      *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-firstmate}"; exit 0 ;;
    esac
    printf 'firstmate\n'; exit 0
    ;;
  list-windows)
    [ -z "${FM_FAKE_TMUX_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
    exit 0
    ;;
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

# Echoes "case_dir|home|proj|wt|fakebin|launchlog".
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

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

SETTINGS_REL='.claude/settings.local.json'

# The settings file is read through a real JSON parser, never grepped: a merge
# that produced the right substring inside a file claude cannot parse would be a
# silent failure of exactly the thing this flag exists to do.
read_settings_field() {
  local file=$1 expr=$2
  node -e '
    const fs = require("fs");
    const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const out = eval(process.argv[2]);
    process.stdout.write(String(out));
  ' "$file" "$expr"
}

assert_ultracode_settings() {
  local wt=$1 what=$2 file value
  file="$wt/$SETTINGS_REL"
  [ -f "$file" ] || fail "$what wrote no $SETTINGS_REL into the worktree"
  value=$(read_settings_field "$file" 'doc.ultracode') \
    || fail "$what left a $SETTINGS_REL that is not parseable JSON: $(cat "$file")"
  [ "$value" = "true" ] \
    || fail "$what did not set ultracode true in $SETTINGS_REL (got '$value')"
}

meta_line() {
  grep -E "^$2=" "$1/state/$3.meta" 2>/dev/null || true
}

# A claude ship spawn is the ordinary case: the mode key lands in the worktree
# before launch, and the meta records it so a later reader knows the worker is in
# ultracode without re-reading the worktree.
test_claude_ship_spawn_gets_the_mode_and_records_it() {
  local rec id out status
  id=ultra-ship-u1
  rec=$(make_spawn_case ultra-ship claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ultracode)
  status=$?
  expect_code 0 "$status" "a claude --ultracode spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_ultracode_settings "$WT_DIR" "the claude ultracode ship spawn"
  [ "$(meta_line "$HOME_DIR" ultracode "$id")" = "ultracode=on" ] \
    || fail "meta did not record ultracode=on for $id"
  pass "a claude ultracode spawn carries ultracode:true into the worktree and ultracode=on into meta"
}

# The merge is the load-bearing half. fm-spawn writes this same file to install
# the claude busy-state and turn-end hooks, and an ultracode write that clobbered
# it would silently break the watcher's view of the worker.
test_the_mode_key_merges_with_the_claude_hooks() {
  local rec id status file hooks stop
  id=ultra-merge-u2
  rec=$(make_spawn_case ultra-merge claude "$id")
  read_case_record "$rec"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ultracode >/dev/null
  status=$?
  expect_code 0 "$status" "a claude --ultracode spawn should succeed"
  file="$WT_DIR/$SETTINGS_REL"
  assert_ultracode_settings "$WT_DIR" "the merged claude ultracode spawn"

  # Every hook key the claude branch installs must survive, and the Stop hook
  # must still carry the turn-end touch the watcher depends on.
  hooks=$(read_settings_field "$file" 'Object.keys(doc.hooks || {}).sort().join(",")')
  assert_contains "$hooks" "SessionEnd" "the ultracode merge dropped the SessionEnd hook"
  assert_contains "$hooks" "Stop" "the ultracode merge dropped the Stop hook"
  assert_contains "$hooks" "StopFailure" "the ultracode merge dropped the StopFailure hook"
  assert_contains "$hooks" "UserPromptSubmit" "the ultracode merge dropped the UserPromptSubmit hook"
  stop=$(read_settings_field "$file" 'doc.hooks.Stop[0].hooks[0].command')
  assert_contains "$stop" "$id.turn-ended" "the ultracode merge broke the Stop turn-end touch"
  pass "the ultracode key merges into the claude hook settings without dropping a hook"
}

# The flag is claude-only and the refusal must land before anything exists, so a
# rejected spawn leaves no endpoint, no worktree hooks, and no task metadata for
# a supervisor to reconcile later.
test_non_claude_ultracode_spawn_refuses_before_anything_exists() {
  local harness rec id out status n=0
  for harness in codex opencode pi grok; do
    n=$((n + 1))
    id="ultra-refuse-u3$n"
    rec=$(make_spawn_case "ultra-refuse-$harness" "$harness" "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ultracode)
    status=$?
    expect_code 1 "$status" "a $harness --ultracode spawn should be refused"
    assert_contains "$out" "--ultracode applies only to claude-harness spawns" \
      "the $harness refusal did not name the claude-only rule"
    assert_contains "$out" "resolved harness '$harness'" \
      "the $harness refusal did not name the harness it resolved"
    assert_not_contains "$out" "spawned $id" "the refused $harness spawn still reported a spawn"
    [ ! -e "$HOME_DIR/state/$id.meta" ] \
      || fail "the refused $harness spawn left task metadata behind"
    [ ! -e "$WT_DIR/$SETTINGS_REL" ] \
      || fail "the refused $harness spawn still wrote worktree settings"
    [ ! -s "$LAUNCH_LOG" ] \
      || fail "the refused $harness spawn still composed a launch"
  done
  pass "codex, opencode, pi, and grok refuse --ultracode before an endpoint, worktree, or meta exists"
}

# Without the flag nothing changes: the settings file must carry hooks only, and
# meta must stay byte-identical to an ordinary spawn's.
test_a_spawn_without_the_flag_is_untouched() {
  local rec id status file has
  id=ultra-off-u4
  rec=$(make_spawn_case ultra-off claude "$id")
  read_case_record "$rec"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null
  status=$?
  expect_code 0 "$status" "an ordinary claude spawn should succeed"
  file="$WT_DIR/$SETTINGS_REL"
  [ -f "$file" ] || fail "the ordinary claude spawn wrote no $SETTINGS_REL"
  has=$(read_settings_field "$file" '"ultracode" in doc')
  [ "$has" = "false" ] \
    || fail "a spawn without --ultracode still wrote an ultracode key: $(cat "$file")"
  [ -z "$(meta_line "$HOME_DIR" ultracode "$id")" ] \
    || fail "a spawn without --ultracode still wrote ultracode= to meta"
  pass "a claude spawn without --ultracode carries no ultracode key and no ultracode meta line"
}


# The assertions above pin the produced file. This one runs the spawn's own
# launch command against a fake claude that reads the settings out of the
# directory it starts in, exactly as the real CLI does. Without the merge the
# fake reports no mode, which is precisely the failure the flag exists to
# prevent.
test_the_composed_launch_reaches_claude_with_the_mode_on() {
  local rec id status launch fakeclaude out
  id=ultra-exec-u6
  rec=$(make_spawn_case ultra-exec claude "$id")
  read_case_record "$rec"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ultracode >/dev/null
  status=$?
  expect_code 0 "$status" "a claude --ultracode spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  [ -n "$launch" ] || fail "the ultracode spawn composed no launch command"

  # A fake claude that resolves its session mode the way the CLI does: from the
  # settings.local.json of the directory it was started in.
  fakeclaude="$CASE_DIR/claudebin"
  mkdir -p "$fakeclaude"
  cat > "$fakeclaude/claude" <<'SH'
#!/usr/bin/env bash
set -u
f=".claude/settings.local.json"
if [ -f "$f" ] && node -e '
  const d = JSON.parse(require("fs").readFileSync(".claude/settings.local.json","utf8"));
  process.exit(d.ultracode === true ? 0 : 1);
'; then
  printf 'ultracode - xhigh effort + dynamic workflows\n'
else
  printf 'no ultracode banner\n'
fi
SH
  chmod +x "$fakeclaude/claude"

  out=$(cd "$WT_DIR" && PATH="$fakeclaude:$PATH" bash -c "$launch" 2>&1)
  status=$?
  expect_code 0 "$status" "the composed ultracode launch should run"
  assert_contains "$out" "ultracode - xhigh effort + dynamic workflows" \
    "the composed launch did not reach claude with the ultracode session mode on"
  pass "running the composed launch reaches claude with the ultracode session mode on"
}


make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

# The flag is scoped by harness and by kind, so the one other kind it accepts
# must get the mode too.
test_a_scout_spawn_gets_the_mode() {
  local rec id status
  id=ultra-scout-u7
  rec=$(make_spawn_case ultra-scout claude "$id")
  read_case_record "$rec"
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --ultracode >/dev/null
  status=$?
  expect_code 0 "$status" "a claude scout --ultracode spawn should succeed"
  assert_ultracode_settings "$WT_DIR" "the claude ultracode scout spawn"
  [ "$(meta_line "$HOME_DIR" ultracode "$id")" = "ultracode=on" ] \
    || fail "meta did not record ultracode=on for the scout"
  pass "a claude scout spawn carries the ultracode mode"
}



# The merge only ever meets one file in practice: the hook settings the claude
# branch wrote moments earlier. That file is not inert JSON - every hook command
# is a string holding this task's real worktree path, state path, and id. A path
# carrying JSON punctuation therefore puts that punctuation INSIDE a string
# value, which is precisely what a text-level merge cannot tell apart from
# structure. This drives that case end to end rather than reasoning about it.
test_the_merge_does_not_rewrite_paths_inside_hook_commands() {
  local rec id status file stop punct_home
  id=ultra-punct-u9
  rec=$(make_spawn_case ultra-punct claude "$id")
  read_case_record "$rec"
  # The home PATH carries the sequences a text-level merge collapses. fm-spawn
  # embeds that path in every hook command, so this puts the punctuation inside
  # a JSON string value, where it must survive untouched.
  punct_home="$CASE_DIR/home{,}a, }b"
  cp -r "$HOME_DIR" "$punct_home"

  run_ship_spawn "$punct_home" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ultracode >/dev/null
  status=$?
  expect_code 0 "$status" "a spawn whose hook paths carry JSON punctuation should succeed"
  file="$WT_DIR/$SETTINGS_REL"
  assert_ultracode_settings "$WT_DIR" "the spawn whose hook paths carry JSON punctuation"
  stop=$(read_settings_field "$file" 'doc.hooks.Stop[0].hooks[0].command')
  assert_contains "$stop" '{,}' "the merge collapsed a brace-comma sequence inside a hook command"
  assert_contains "$stop" ', }' "the merge collapsed a comma-brace sequence inside a hook command"
  assert_contains "$stop" "$id.turn-ended" "the merge broke the Stop turn-end touch"
  pass "the merge leaves JSON punctuation inside hook command strings untouched"
}

# The two refusals that keep the flag honest rather than harness-scoped: a
# secondmate home outlives the spawn, and an explicit effort would pin the very
# level the mode exists to raise.
test_secondmate_and_effort_refuse_the_flag() {
  local rec id sm out status
  id=ultra-smrefuse-u12
  rec=$(make_spawn_case ultra-smrefuse claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate --ultracode)
  status=$?
  expect_code 1 "$status" "a secondmate --ultracode spawn should be refused"
  assert_contains "$out" "--ultracode applies only to task worktrees" \
    "the secondmate refusal did not name the task-worktree rule"
  [ ! -e "$sm/$SETTINGS_REL" ] \
    || fail "the refused secondmate spawn still wrote settings into the persistent home"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "the refused secondmate spawn left task metadata behind"

  id=ultra-effrefuse-u13
  rec=$(make_spawn_case ultra-effrefuse claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ultracode --effort low)
  status=$?
  expect_code 1 "$status" "an --ultracode --effort spawn should be refused"
  assert_contains "$out" "--ultracode selects xhigh effort itself" \
    "the effort refusal did not explain the conflict"
  [ ! -e "$WT_DIR/$SETTINGS_REL" ] \
    || fail "the refused effort spawn still wrote worktree settings"
  pass "a secondmate spawn and an explicit effort each refuse --ultracode before anything exists"
}

# A switch that silently becomes a positional is a spawn that quietly runs
# without the mode the caller asked for.
test_ultracode_with_a_value_is_rejected() {
  local rec id out status
  id=ultra-value-u14
  rec=$(make_spawn_case ultra-value claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ultracode=true)
  status=$?
  expect_code 1 "$status" "--ultracode=true should be rejected"
  assert_contains "$out" "--ultracode is a switch and takes no value" \
    "the rejection did not explain that --ultracode takes no value"
  pass "--ultracode with a value is rejected instead of being read as a positional"
}

# A relaunch replaces the agent in place, and fm-control passes no --ultracode.
# The relaunch path also retires this task's claude wiring and rewrites the
# settings file the mode key lives in, so the replacement worker genuinely starts
# without the mode. The record must follow: an ultracode= line preserved from the
# retired incarnation would assert a mode the running worker does not have, which
# is the exact half-application this flag was built to make impossible.
test_a_relaunch_drops_the_mode_from_the_worktree_and_the_record() {
  local rec id status file value relaunch_out window
  id=ultra-relaunch-u10
  rec=$(make_spawn_case ultra-relaunch claude "$id")
  read_case_record "$rec"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ultracode >/dev/null
  status=$?
  expect_code 0 "$status" "the seeding claude --ultracode spawn should succeed"
  assert_ultracode_settings "$WT_DIR" "the seeding ultracode spawn"
  [ "$(meta_line "$HOME_DIR" ultracode "$id")" = "ultracode=on" ] \
    || fail "the seeding spawn did not record ultracode=on for $id"

  # The relaunch path reads the recorded endpoint, so the fake pane must be
  # visible and agent-free for it: exactly the state fm-control leaves behind
  # after it stops the old agent.
  window=$(meta_line "$HOME_DIR" window "$id"); window=${window#window=}
  export FM_FAKE_TMUX_WINDOWS="${window#*:}" FM_FAKE_TMUX_CURRENT_COMMAND=zsh

  relaunch_out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" --relaunch --harness claude)
  status=$?
  expect_code 0 "$status" "the relaunch should succeed: $relaunch_out"

  file="$WT_DIR/$SETTINGS_REL"
  [ -f "$file" ] || fail "the relaunch left no $SETTINGS_REL to check"
  value=$(read_settings_field "$file" 'doc.ultracode === undefined ? "absent" : String(doc.ultracode)') \
    || fail "the relaunch left a $SETTINGS_REL that is not parseable JSON: $(cat "$file")"
  [ "$value" = absent ] \
    || fail "the relaunch kept an ultracode key in $SETTINGS_REL (got '$value')"
  [ -z "$(meta_line "$HOME_DIR" ultracode "$id")" ] \
    || fail "the relaunch preserved '$(meta_line "$HOME_DIR" ultracode "$id")' while the worktree lost the mode"
  unset FM_FAKE_TMUX_WINDOWS FM_FAKE_TMUX_CURRENT_COMMAND
  pass "a relaunch drops the mode from the worktree and stops the record claiming it"
}
test_claude_ship_spawn_gets_the_mode_and_records_it
test_the_mode_key_merges_with_the_claude_hooks
test_non_claude_ultracode_spawn_refuses_before_anything_exists
test_a_spawn_without_the_flag_is_untouched
test_a_scout_spawn_gets_the_mode
test_the_merge_does_not_rewrite_paths_inside_hook_commands
test_secondmate_and_effort_refuse_the_flag
test_ultracode_with_a_value_is_rejected
test_a_relaunch_drops_the_mode_from_the_worktree_and_the_record
test_the_composed_launch_reaches_claude_with_the_mode_on

printf '# all fm-spawn-ultracode tests passed\n'
