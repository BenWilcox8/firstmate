#!/usr/bin/env bash
# Behavior tests for the claude session-persistence launch prefix in fm-spawn.sh.
#
# Claude Code exports CLAUDE_CODE_CHILD_SESSION=1 into the shells it spawns. A
# pane daemon started from inside a claude session hands that marker to every
# pane it later creates, and a claude CLI launched there turns transcript saving
# off, so the captain can no longer resume that agent with `claude --resume`.
# fm-spawn therefore strips the inherited marker and sets the vendor's
# CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 remedy on every claude launch.
#
# Like the dispatch-profile suite, these tests drive fm-spawn through launch
# construction with a fake tmux pane and a real isolated git worktree, so the
# captured command is the one firstmate would run without starting any harness.
# The last test then EXECUTES the captured command against a fake claude in a
# deliberately contaminated environment, which is what proves the prefix does
# the job rather than merely being present as text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-persistence)

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
  # Stub pi so resolve_pi_executable finds it; the test only checks absence of
  # the claude persistence prefix, not pi's own behaviour.
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
printf 'Pi 0.84.0\nOptions: --help --tui-mode <mode>\n'
exit 0
SH
  chmod +x "$fakebin/pi"
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
  # The spawning shell is contaminated exactly the way a pane daemon started
  # from inside a claude session contaminates its children. CLAUDE_CONFIG_DIR is
  # pinned empty so these assertions never depend on the invoking shell; a test
  # opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); this
# suite is about launch composition, so it passes a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# The two halves are asserted separately on purpose: stripping the inherited
# marker removes the trigger, and the force flag is the vendor's own advertised
# remedy kept as the second line of defense. Losing either one silently is the
# regression this suite exists to catch.
assert_persistence_prefix() {
  local launch=$1 what=$2
  assert_contains "$launch" "env -u CLAUDE_CODE_CHILD_SESSION " \
    "$what did not strip the inherited CLAUDE_CODE_CHILD_SESSION marker"
  assert_contains "$launch" "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 " \
    "$what did not force claude session persistence"
}

test_claude_crewmate_launch_keeps_its_transcript() {
  local rec id out status launch
  id=persist-crew-p1
  rec=$(make_spawn_case persist-crew claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a claude crewmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  launch=$(cat "$LAUNCH_LOG")
  assert_persistence_prefix "$launch" "the claude crewmate launch"
  # The prefix must lead, so it governs the claude process no matter which other
  # launch prefixes (config dir, secondmate env, trace context) are added later.
  case "$launch" in
    "env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 "*) ;;
    *) fail "the persistence prefix did not lead the claude launch: $launch" ;;
  esac
  pass "a claude crewmate launches with session persistence forced and the inherited marker stripped"
}

test_claude_scout_launch_keeps_its_transcript() {
  local rec id out status launch
  id=persist-scout-p2
  rec=$(make_spawn_case persist-scout claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "a claude scout spawn should succeed"
  assert_contains "$out" "kind=scout" "scout spawn did not report kind=scout"
  launch=$(cat "$LAUNCH_LOG")
  assert_persistence_prefix "$launch" "the claude scout launch"
  pass "a claude scout launches with session persistence forced"
}

test_claude_secondmate_launch_keeps_its_transcript() {
  local rec id sm out status launch
  id=persist-secondmate-p3
  rec=$(make_spawn_case persist-secondmate claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "a claude secondmate spawn should succeed"
  assert_contains "$out" "kind=secondmate" "secondmate spawn did not report kind=secondmate"
  launch=$(cat "$LAUNCH_LOG")
  assert_persistence_prefix "$launch" "the claude secondmate launch"
  pass "a claude secondmate launches with session persistence forced"
}

test_claude_persistence_survives_the_config_dir_prefix() {
  local rec id status launch
  id=persist-cfgdir-p4
  rec=$(make_spawn_case persist-cfgdir claude "$id")
  read_case_record "$rec"

  # The account/config-dir prefix is the one other claude-scoped launch prefix;
  # the two must compose rather than one displacing the other.
  FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null
  status=$?
  expect_code 0 "$status" "a claude spawn with a config dir should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_persistence_prefix "$launch" "the claude launch with a config dir"
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "the persistence prefix displaced the claude config-dir prefix"
  pass "the persistence prefix composes with the claude config-dir prefix"
}

# Several non-claude adapters are checked, not just one: the fix is claude-scoped
# and a stray prefix on another harness would be a real launch-composition bug.
# kimi is deliberately absent, as it is from every other spawn suite: its launch
# path resolves a real `kimi` binary and installs a GLOBAL turn-end hook, so a
# portable test cannot exercise it without a side effect outside its tmpdir. The
# claude-only guard in fm-spawn is a single `[ "$HARNESS" = claude ]` branch, so
# the harnesses below are a faithful sample of the untouched case.
test_non_claude_harnesses_are_untouched() {
  local harness rec id out status launch n=0
  for harness in codex opencode pi grok; do
    n=$((n + 1))
    id="persist-other-p5$n"
    rec=$(make_spawn_case "persist-other-$harness" "$harness" "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "a $harness spawn should succeed"
    assert_contains "$out" "spawned $id harness=$harness" "spawn did not report $harness"
    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" "CLAUDE_CODE_CHILD_SESSION" \
      "the $harness launch received the claude-scoped marker strip"
    assert_not_contains "$launch" "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE" \
      "the $harness launch received the claude-scoped persistence flag"
  done
  pass "codex, opencode, pi, and grok launches carry no claude persistence prefix"
}

# The assertions above pin the composed text. This one runs it: the captured
# launch command is executed against a fake `claude` from a shell carrying the
# inherited marker, and the fake reports the environment claude would really
# start with. Without the prefix the marker survives and the flag is absent,
# which is exactly the state that turns transcript saving off.
test_composed_launch_really_clears_the_inherited_marker() {
  local rec id status launch env_out fakeclaude
  id=persist-exec-p6
  rec=$(make_spawn_case persist-exec claude "$id")
  read_case_record "$rec"

  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null
  status=$?
  expect_code 0 "$status" "a claude spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")

  # A fake claude that reports only the two variables under test, so the check
  # never depends on a real CLI, credential, or network.
  fakeclaude="$CASE_DIR/claudebin"
  mkdir -p "$fakeclaude"
  cat > "$fakeclaude/claude" <<'SH'
#!/usr/bin/env bash
set -u
printf 'child=%s\n' "${CLAUDE_CODE_CHILD_SESSION-<unset>}"
printf 'force=%s\n' "${CLAUDE_CODE_FORCE_SESSION_PERSISTENCE-<unset>}"
SH
  chmod +x "$fakeclaude/claude"

  # CLAUDE_CODE_CHILD_SESSION=1 reproduces the contaminated pane shell.
  env_out=$(CLAUDE_CODE_CHILD_SESSION=1 PATH="$fakeclaude:$PATH" bash -c "$launch" 2>&1)
  status=$?
  expect_code 0 "$status" "the composed claude launch should run"
  assert_contains "$env_out" "child=<unset>" \
    "the composed launch left the inherited CLAUDE_CODE_CHILD_SESSION marker in claude's environment"
  assert_contains "$env_out" "force=1" \
    "the composed launch did not reach claude with session persistence forced"
  pass "running the composed claude launch clears the inherited marker and forces persistence"
}

test_claude_crewmate_launch_keeps_its_transcript
test_claude_scout_launch_keeps_its_transcript
test_claude_secondmate_launch_keeps_its_transcript
test_claude_persistence_survives_the_config_dir_prefix
test_non_claude_harnesses_are_untouched
test_composed_launch_really_clears_the_inherited_marker

printf '# all fm-spawn-claude-persistence tests passed\n'
