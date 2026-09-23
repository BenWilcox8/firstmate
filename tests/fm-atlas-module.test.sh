#!/usr/bin/env bash
# Behavior tests for the optional Atlas module and its hook points.
#
# The module loads only in a home whose config/specs names a local Atlas repo.
# These tests drive the public entry points a session actually meets:
#   - the session-start digest, with and without the pointer;
#   - the launch brief a spawned worker receives, ticketed or not;
#   - the secondmate charter scaffold, which never mentions the Atlas.
# They assert only on emitted output and rendered files, never on source bytes.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
# The temp root name avoids the word the no-Atlas-text checks search for.
TMP_ROOT=$(fm_test_tmproot fm-mapmod)

# A home with no harness to hold the lock runs the read-only digest, which still
# emits every instruction block and needs no network, so the case stays fast and
# hermetic.
new_session_world() {  # <name> <wired: yes|no|hollow> -> "<root>|<home>|<fakebin>"
  local name=$1 wired=$2 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin=$(fm_fakebin "$w/fake")
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_git_init_commit "$root" >/dev/null
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/ps"
  chmod +x "$fakebin/ps"
  case "$wired" in
    yes)
      mkdir -p "$w/specs/atlas"
      printf '%s\n' "$w/specs" > "$home/config/specs"
      ;;
    hollow)
      # A pointer to a directory that holds no atlas/ is not a wired home.
      mkdir -p "$w/specs"
      printf '%s\n' "$w/specs" > "$home/config/specs"
      ;;
  esac
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

run_session_start() {  # <root> <home> <fakebin>
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_HOME="$2" FM_ROOT_OVERRIDE="$1" PATH="$3:$PATH" \
    "$SESSION_START" 2>&1
}

test_unwired_session_start_has_no_atlas_text() {
  local rec root home fakebin out count
  rec=$(new_session_world unwired no)
  IFS='|' read -r root home fakebin <<< "$rec"

  out=$(run_session_start "$root" "$home" "$fakebin")
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS" "the digest did not run far enough to judge"
  count=$(printf '%s\n' "$out" | grep -c -i 'atlas')
  [ "$count" = 0 ] || fail "a home with no config/specs printed $count Atlas line(s) in its session start"
  pass "a home with no Atlas pointer gets no Atlas text in its session start"
}

test_hollow_pointer_is_not_wired() {
  local rec root home fakebin out count
  rec=$(new_session_world hollow hollow)
  IFS='|' read -r root home fakebin <<< "$rec"

  out=$(run_session_start "$root" "$home" "$fakebin")
  count=$(printf '%s\n' "$out" | grep -c -i 'atlas')
  [ "$count" = 0 ] || fail "a pointer to a directory with no atlas/ printed $count Atlas line(s)"
  pass "a pointer to a directory that holds no Atlas is not a wired home"
}

test_wired_session_start_emits_supervisor_block() {
  local rec root home fakebin out order
  rec=$(new_session_world wired yes)
  IFS='|' read -r root home fakebin <<< "$rec"

  out=$(run_session_start "$root" "$home" "$fakebin")
  assert_contains "$out" "ATLAS MODULE" "a wired home did not get the Atlas supervisor block"
  assert_contains "$out" "atlas-firstmate-bridge" "the supervisor block does not name the bridge skill"
  assert_contains "$out" "atlas-supervising" "the supervisor block does not name the supervising skill"
  # The block is operating instructions, so it sits with the supervision block
  # and ahead of the read-once contract and the bulk digests.
  order=$(printf '%s\n' "$out" | grep -n -E '^(SUPERVISION OPERATING INSTRUCTIONS|ATLAS MODULE|READ-ONCE CONTRACT)' | cut -d: -f2 | cut -c1-12 | tr '\n' ',')
  [ "$order" = "SUPERVISION ,ATLAS MODULE,READ-ONCE CO," ] \
    || fail "the Atlas block is out of place in the digest: $order"
  pass "a wired home gets the Atlas supervisor block right after the supervision block"
}

# --- spawn: the crewmate fragment in the launch brief -------------------------

# A spawn world with a real isolated worktree and a fake tmux pane. The fake
# atlas-axi records its calls, so the hook's start call never reaches a real map.
new_spawn_world() {  # <name> <wired: yes|no> <task-id> -> "<home>|<proj>|<wt>|<fakebin>"
  local name=$1 wired=$2 id=$3 w home proj wt fakebin
  w="$TMP_ROOT/$name"
  home="$w/home"
  proj="$w/project"
  wt="$w/wt"
  fakebin=$(make_spawn_fakebin "$w/fake")
  cat > "$fakebin/atlas-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_ATLAS_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/atlas-axi"
  fm_test_spawn_home "$home" claude
  if [ "$wired" = yes ]; then
    mkdir -p "$w/specs/atlas"
    printf '%s\n' "$w/specs" > "$home/config/specs"
  fi
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "Exercise fixture $id."
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

test_ticketed_worker_gets_crewmate_fragment() {
  local rec home proj wt fakebin id out status brief
  id=mapmod-ticketed-t1
  # fm-spawn gives every task a scratch directory at /tmp/fm-<task-id>.
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
  rec=$(new_spawn_world ticketed yes "$id")
  IFS='|' read -r home proj wt fakebin <<< "$rec"

  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --ticket c901)
  status=$?
  expect_code 0 "$status" "a ticketed spawn in a wired home failed: $out"
  brief="$home/data/$id/launch-brief.md"
  assert_present "$brief" "the spawn rendered no launch brief"
  assert_grep 'atlas-working' "$brief" "the ticketed worker was not pointed at the atlas-working skill"
  assert_grep 'c901' "$brief" "the crewmate fragment does not name the worker's ticket"
  assert_grep "fm-$id" "$brief" "the crewmate fragment does not name the worker's Atlas author name"
  assert_no_grep '{TICKET}\|{HOLDER}' "$brief" "the crewmate fragment kept an unfilled placeholder"
  pass "a ticketed worker in a wired home gets the crewmate fragment with its ticket and author name"
}

test_unticketed_worker_gets_no_atlas_text() {
  local rec home proj wt fakebin id out status count
  id=mapmod-unticketed-t2
  # fm-spawn gives every task a scratch directory at /tmp/fm-<task-id>.
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
  rec=$(new_spawn_world unticketed yes "$id")
  IFS='|' read -r home proj wt fakebin <<< "$rec"

  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an unticketed spawn in a wired home failed: $out"
  count=$(grep -c -i 'atlas' "$home/data/$id/launch-brief.md")
  [ "$count" = 0 ] || fail "an unticketed worker's launch brief carries $count Atlas line(s)"
  pass "an unticketed worker gets no Atlas text in its launch brief"
}

test_unwired_home_ticketed_worker_gets_no_atlas_text() {
  local rec home proj wt fakebin id out status count
  id=mapmod-unwired-t3
  # fm-spawn gives every task a scratch directory at /tmp/fm-<task-id>.
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
  rec=$(new_spawn_world unwired no "$id")
  IFS='|' read -r home proj wt fakebin <<< "$rec"

  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --ticket c902)
  status=$?
  expect_code 0 "$status" "a ticketed spawn in a home with no Atlas pointer failed: $out"
  count=$(grep -c -i 'atlas' "$home/data/$id/launch-brief.md")
  [ "$count" = 0 ] || fail "a worker in a home with no Atlas pointer got $count Atlas line(s)"
  pass "a worker in a home with no Atlas pointer gets no Atlas text, even with a ticket"
}

# A relaunch passes no --ticket, so the fragment must come from the recorded
# ticket in the task's own record.
test_crewmate_brief_reads_the_recorded_ticket() {
  local w home out
  w="$TMP_ROOT/recorded"
  home="$w/home"
  mkdir -p "$home/state" "$home/config" "$w/specs/atlas"
  printf '%s\n' "$w/specs" > "$home/config/specs"
  printf 'kind=ship\natlas_ticket=c903\n' > "$home/state/fm-relaunched-t4.meta"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-atlas-module.sh" crewmate-brief fm-relaunched-t4)
  assert_contains "$out" "atlas-working" "a recorded ticket did not produce the crewmate fragment"
  assert_contains "$out" "c903" "the fragment does not name the recorded ticket"
  assert_contains "$out" "ATLAS_AXI_BY=fm-relaunched-t4" \
    "a task id that already starts with fm- must be its own author name"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-atlas-module.sh" crewmate-brief no-record-t5)
  [ -z "$out" ] || fail "a task with no recorded ticket still got a crewmate fragment: $out"
  pass "the crewmate fragment falls back to the recorded ticket, and a task with none gets nothing"
}

# --- the secondmate charter never mentions the Atlas --------------------------

test_secondmate_charter_has_no_atlas_text() {
  local w home count status
  w="$TMP_ROOT/charter"
  home="$w/home"
  mkdir -p "$home/data" "$home/config" "$w/specs/atlas"
  printf '%s\n' "$w/specs" > "$home/config/specs"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='the captain web product' \
    FM_SECONDMATE_SCOPE='web product work' \
    "$ROOT/bin/fm-brief.sh" webmate --secondmate --no-projects >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "the secondmate charter scaffold failed"
  assert_present "$home/data/webmate/brief.md" "no charter was scaffolded"
  count=$(grep -c -i 'atlas' "$home/data/webmate/brief.md")
  [ "$count" = 0 ] || fail "the secondmate charter carries $count Atlas line(s) even in a wired home"
  pass "the secondmate charter never mentions the Atlas, even in a wired home"
}

# --- the worker environment ---------------------------------------------------

# Spawn sends each worker-env line to the pane, so the lines must be exactly the
# shell commands a worker shell runs: exports in a wired home, and a clear of
# inherited values in a home with no pointer.
test_worker_env_lines() {
  local w home out
  w="$TMP_ROOT/workerenv"
  home="$w/home"
  mkdir -p "$home/state" "$home/config" "$w/specs dir/atlas"
  printf '%s\n' "$w/specs dir" > "$home/config/specs"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-atlas-module.sh" worker-env env-t6)
  [ "$out" = "unset SPECS_REPO"$'\n'"export ATLAS_AXI_BY=fm-env-t6"$'\n'"export ATLAS_REPO='$w/specs dir'" ] \
    || fail "a wired worker-env did not print the expected shell lines: $out"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-atlas-module.sh" worker-env 'bad id')
  [ -z "$out" ] || fail "an unusable task id still produced worker-env lines: $out"

  rm "$home/config/specs"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-atlas-module.sh" worker-env env-t6)
  [ "$out" = "unset ATLAS_REPO SPECS_REPO ATLAS_AXI_BY" ] \
    || fail "an unwired worker-env did not clear the inherited values: $out"
  pass "worker-env prints exports in a wired home and clears inherited values in an unwired one"
}

test_unwired_session_start_has_no_atlas_text
test_hollow_pointer_is_not_wired
test_wired_session_start_emits_supervisor_block
test_ticketed_worker_gets_crewmate_fragment
test_unticketed_worker_gets_no_atlas_text
test_unwired_home_ticketed_worker_gets_no_atlas_text
test_crewmate_brief_reads_the_recorded_ticket
test_secondmate_charter_has_no_atlas_text
test_worker_env_lines
