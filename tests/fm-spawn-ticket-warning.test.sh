#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's ticket-less dispatch warning (AGENTS.md
# section 8, Atlas doctrine).
#
# An Atlas-wired home carries work on tickets, so a ship or scout spawn that
# names no ticket is a doctrine miss the supervisor should see AT DISPATCH
# rather than in the next audit. The warning never blocks: the spawn still
# succeeds, and a home with no Atlas pointer behaves exactly as before.
#
# These drive fm-spawn with a fake tmux pane and a real isolated git worktree,
# the same shape as the session-name suite, and assert only on fm-spawn's own
# output and exit status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-ticket-warning)

# The one string every assertion here pins: the warning must name the doctrine,
# so a reader who has forgotten why --ticket matters is told where to look.
WARN_MARK='Atlas doctrine'

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
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# <name> <wired: yes|no> <task-id>...
make_spawn_case() {
  local name=$1 wired=$2 case_dir home proj wt fakebin atlas id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  atlas="$case_dir/specs"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  if [ "$wired" = yes ]; then
    mkdir -p "$atlas/atlas"
    printf '%s\n' "$atlas" > "$home/config/specs"
  fi
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<< "$1"
}

test_wired_ship_without_ticket_warns_and_still_spawns() {
  local rec id out status count
  id=ticket-warn-ship-w1
  rec=$(make_spawn_case wired-ship yes "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a ticket-less ship spawn must still succeed; the warning never blocks"
  assert_contains "$out" "$WARN_MARK" "ticket-less ship spawn on an Atlas-wired home did not warn"
  assert_contains "$out" "spawned $id" "the warned spawn did not report a launch"
  count=$(printf '%s\n' "$out" | grep -c -- "$WARN_MARK")
  [ "$count" = 1 ] || fail "the doctrine warning must be exactly one line; saw $count"
  pass "a ticket-less ship spawn on an Atlas-wired home warns once and still spawns"
}

test_wired_scout_without_ticket_warns() {
  local rec id out status count
  id=ticket-warn-scout-w2
  rec=$(make_spawn_case wired-scout yes "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "a ticket-less scout spawn must still succeed"
  assert_contains "$out" "$WARN_MARK" "ticket-less scout spawn on an Atlas-wired home did not warn"
  pass "a ticket-less scout spawn on an Atlas-wired home warns"
}

test_wired_ship_with_ticket_is_silent() {
  local rec id out status count
  id=ticket-warn-ticketed-w3
  rec=$(make_spawn_case wired-ticketed yes "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --ticket c337)
  status=$?
  expect_code 0 "$status" "a ticketed ship spawn should succeed"
  assert_not_contains "$out" "$WARN_MARK" "a spawn that named its ticket must not be warned about"
  pass "a ticketed spawn on an Atlas-wired home is silent"
}

test_unwired_home_is_silent() {
  local rec id out status count
  id=ticket-warn-unwired-w4
  rec=$(make_spawn_case unwired no "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a ticket-less spawn on a home with no Atlas pointer should succeed"
  assert_not_contains "$out" "$WARN_MARK" "a home with no Atlas pointer must behave exactly as before"
  pass "a home with no Atlas pointer never warns"
}

test_secondmate_spawn_is_silent() {
  local rec id sm out status
  id=ticket-warn-secondmate-w5
  rec=$(make_spawn_case wired-secondmate yes "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "a secondmate spawn should succeed"
  assert_not_contains "$out" "$WARN_MARK" \
    "a secondmate is a persistent home, not a ticket's work, so it must never be warned about"
  pass "a secondmate spawn is never warned about"
}

test_wired_ship_without_ticket_warns_and_still_spawns
test_wired_scout_without_ticket_warns
test_wired_ship_with_ticket_is_silent
test_unwired_home_is_silent
test_secondmate_spawn_is_silent
