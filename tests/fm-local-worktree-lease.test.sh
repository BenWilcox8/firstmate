#!/usr/bin/env bash
# Behavior coverage for the worktree lease check.
#
# bin/fm-local-worktree-lease.sh owns the check that refuses to launch a worker
# into a worktree that is now leased to other work. This suite drives its CLI
# against a stubbed tmux, real Git worktrees, records, and Treehouse pool
# records. It also drives the upstream seam through the real script that
# carries its hook line:
#   - worktree-lease: bin/fm-spawn.sh --relaunch (the launch owner of
#     bin/fm-control.sh relaunch and resume) refuses to launch a worker into a
#     worktree that is now leased to other work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-worktree-lease)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
WL="$ROOT/bin/fm-local-worktree-lease.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
fm_git_identity fmtest fmtest@example.invalid
OWNER_PIDS=()

worktree_lease_cleanup() {
  local pid
  for pid in "${OWNER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  rm -rf "$TMP_ROOT"
}
trap worktree_lease_cleanup EXIT

# new_world <name>: a home with a tmux stub and a fake no-mistakes. Every
# endpoint reads missing unless its window is listed in <world>/fake/windows.
# Echoes the world directory.
new_world() {
  local w="$TMP_ROOT/$1" fb
  mkdir -p "$w/home/state" "$w/home/data" "$w/fake"
  fb=$(fm_fakebin "$w")
  : > "$w/fake/windows"
  printf 'zsh' > "$w/fake/command"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
case "${1:-}" in
  list-windows) cat "$D/windows"; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd" 2>/dev/null; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  send-keys) shift; printf '%s\n' "$*" >> "$D/keys"; exit 0 ;;
  capture-pane) printf '$ \n'; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/herdr"
  chmod +x "$fb/herdr"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/tmux" "$fb/no-mistakes"
  printf '%s\n' "$w"
}

# add_worker <world> <id> <status-line|-> [key=value]...: a ship record whose
# worktree is <world>/pool/<id>/proj and whose endpoint is fmses:fm-<id>.
add_worker() {
  local w=$1 id=$2 status=$3 wt
  shift 3
  wt="$w/pool/$id/proj"
  mkdir -p "$w/pool/$id"
  fm_git_worktree "$w/repo-$id" "$wt" "fm/$id" >/dev/null 2>&1
  mkdir -p "$w/home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nKeep working.\n\n## Firstmate spec\nKeep working.\n' > "$w/home/data/$id/brief.md"
  fm_write_meta "$w/home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$w/repo-$id" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "yolo=off" "backend=tmux" "spawn_gen=s1790000000.1.1" "$@"
  [ "$status" = - ] || printf '%s\n' "$status" > "$w/home/state/$id.status"
}

wl() {  # <world> <task-id>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u TMUX -u TMUX_PANE \
    PATH="$1/fakebin:$PATH" FM_HOME="$1/home" FM_FAKE_DIR="$1/fake" \
    "$WL" check "$2"
}

# start_owner <fifo>: a live stand-in Treehouse lease owner; $! is its pid.
start_owner() {
  mkfifo "$1"
  # shellcheck disable=SC2016 # the stand-in's own bash expands $0
  bash -c 'read -r -t 60 _ <> "$0"' "$1" >/dev/null 2>&1 < /dev/null &
}

# lease_slot <world> <id> <pid>: record <pid> as the Treehouse owner of <id>'s
# slot, with its kernel start time in epoch milliseconds, as Treehouse does.
lease_slot() {
  local w=$1 id=$2 pid=$3 ticks btime hz
  ticks=$(awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$pid/stat")
  btime=$(awk '$1 == "btime" { print $2 }' /proc/stat)
  hz=$(getconf CLK_TCK)
  jq -n --arg path "$w/pool/$id/proj" --argjson pid "$pid" \
    --argjson started "$((btime * 1000 + ticks * 1000 / hz))" \
    '{worktrees: [{name: "1", path: $path, owner_pid: $pid, owner_started_at: $started}]}' \
    > "$w/pool/treehouse-state.json"
}

test_lease_check_counts_a_live_agent_whose_location_cannot_be_read() {
  local w out
  w=$(new_world unlocated)
  add_worker "$w" w-b 'working: b'
  add_worker "$w" w-old 'done: PR https://example.invalid/pull/4 checks green' \
    "worktree=$w/pool/w-b/proj" spawn_gen=s1789990000.1.1
  printf 'fm-w-old\n' > "$w/fake/windows"
  printf 'claude' > "$w/fake/command"
  out=$(wl "$w" w-b 2>&1) && fail "a live agent whose pane location cannot be read must count as occupying the worktree: $out"
  assert_contains "$out" "w-old" "the reason must name the other task"
  pass "lease-check counts a live agent whose pane location cannot be read"
}

# After a Herdr restart, pane ids start low again, so a recorded id can name a
# pane that now belongs to other work. Only a pane in the record's own worktree
# is its endpoint.
test_a_recorded_pane_that_sits_elsewhere_does_not_lease_the_worktree() {
  local w
  w=$(new_world recycled)
  add_worker "$w" w-b 'working: b'
  add_worker "$w" w-old 'done: PR https://example.invalid/pull/3 checks green' \
    "worktree=$w/pool/w-b/proj" spawn_gen=s1789990000.1.1
  mkdir -p "$w/elsewhere"
  printf 'fm-w-old\n' > "$w/fake/windows"
  printf 'claude' > "$w/fake/command"
  printf '%s' "$w/elsewhere" > "$w/fake/cwd"
  wl "$w" w-b >/dev/null 2>&1 || fail "an older record's recycled pane that now runs other work must not lease the worktree"
  printf '%s' "$w/pool/w-b/proj" > "$w/fake/cwd"
  wl "$w" w-b >/dev/null 2>&1 && fail "an older record with a live agent in the worktree must lease it"
  pass "a recorded pane that now runs other work is not a lease on the worktree"
}

test_lease_check_reports_a_live_treehouse_owner() {
  local w out
  w=$(new_world lease)
  add_worker "$w" w-a 'working: a'
  wl "$w" w-a >/dev/null 2>&1 || fail "a slot with no live owner and no newer record is not reused"
  start_owner "$w/owner.fifo"
  OWNER_PIDS+=("$!")
  lease_slot "$w" w-a "$!"
  out=$(wl "$w" w-a 2>&1) && fail "a live Treehouse owner that is not this worker's must read as reused: $out"
  assert_contains "$out" "Treehouse leases it to live process $!" "the reason must name the live owner"
  pass "lease-check reports a worktree Treehouse leased to another live process"
}

test_lease_check_sees_records_in_sibling_homes() {
  local w sib out
  w=$(new_world sibling)
  add_worker "$w" w-a 'working: a'
  sib="$w/sibling-home"
  mkdir -p "$sib/state"
  fm_write_secondmate_meta "$w/home/state/sm-one.meta" "$sib"
  fm_write_meta "$sib/state/other.meta" "worktree=$w/pool/w-a/proj" "kind=ship" \
    "spawn_gen=s1790000900.1.1" "window=fmses:fm-other"
  out=$(wl "$w" w-a 2>&1) && fail "a newer record in a second mate's home must read as reused: $out"
  assert_contains "$out" "other" "the reason must name the other task"
  pass "lease-check finds a newer record for the worktree in a second mate's home"
}

# The worktree-lease seam: fm-spawn --relaunch, which bin/fm-control.sh
# relaunch and resume both delegate to, refuses a reused slot before it types
# anything into the endpoint.
test_spawn_relaunch_refuses_a_reused_worktree() {
  local w out
  w=$(new_world seam)
  add_worker "$w" w-a 'working: a'
  printf 'fm-w-a\n' > "$w/fake/windows"
  printf 'zsh' > "$w/fake/command"
  printf '%s' "$w/pool/w-a/proj" > "$w/fake/cwd"
  start_owner "$w/seam.fifo"
  OWNER_PIDS+=("$!")
  lease_slot "$w" w-a "$!"
  : > "$w/fake/keys"
  mkdir -p "$w/user-home"
  out=$(env PATH="$w/fakebin:$PATH" FM_HOME="$w/home" FM_FAKE_DIR="$w/fake" \
    HOME="$w/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" w-a --relaunch 2>&1) && fail "relaunch into a reused worktree must refuse: $out"
  assert_contains "$out" "worktree-lease" "the refusal must come from the worktree-lease seam"
  assert_contains "$out" "Treehouse leases it to live process" "the refusal must say why"
  [ ! -s "$w/fake/keys" ] || fail "a refused relaunch must type nothing: $(cat "$w/fake/keys")"
  pass "fm-spawn --relaunch refuses a worktree leased to other work (worktree-lease seam)"
}

test_a_recorded_pane_that_sits_elsewhere_does_not_lease_the_worktree
test_lease_check_counts_a_live_agent_whose_location_cannot_be_read
test_lease_check_reports_a_live_treehouse_owner
test_lease_check_sees_records_in_sibling_homes
test_spawn_relaunch_refuses_a_reused_worktree
