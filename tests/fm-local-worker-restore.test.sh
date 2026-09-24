#!/usr/bin/env bash
# Behavior coverage for worker restore after a restart.
#
# bin/fm-local-worker-restore.sh owns classifying a home's worker records after
# a restart and relaunching only the ones that were working. This suite drives
# its CLI against a stubbed tmux (every endpoint is gone, as after a restart),
# a stand-in control plane that logs each relaunch, and real Git worktrees,
# records, and Treehouse pool records. It also drives the upstream seams
# through the real scripts that carry their hook lines:
#   - worktree-lease: bin/fm-spawn.sh --relaunch (the launch owner of
#     bin/fm-control.sh relaunch and resume) refuses to launch a worker into a
#     worktree that is now leased to other work.
#   - restart-record: bin/fm-local-restart-recovery.sh record starts worker
#     restore once for a detected restart.
# The Herdr lifecycle proof (a real lab restart and fresh-pane relaunches)
# lives in tests/fm-local-worker-restore-herdr-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-worker-restore)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
WR="$ROOT/bin/fm-local-worker-restore.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
fm_git_identity fmtest fmtest@example.invalid
OWNER_PIDS=()

worker_restore_cleanup() {
  local pid
  for pid in "${OWNER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  rm -rf "$TMP_ROOT"
}
trap worker_restore_cleanup EXIT

# new_world <name>: a home with a tmux stub, a fake no-mistakes, and a
# stand-in control plane. Every endpoint reads missing unless its window is
# listed in <world>/fake/windows. Echoes the world directory.
new_world() {
  local w="$TMP_ROOT/$1" fb
  mkdir -p "$w/home/state" "$w/home/data" "$w/fake" "$w/crew-state"
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
  # The stand-in control plane logs each call and fails for ids listed in
  # <world>/fake/fail.
  cat > "$fb/control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/control.log"
if grep -qx "$1" "$FM_FAKE_DIR/fail" 2>/dev/null; then
  echo "error: the replacement agent for $1 could not be launched on claude" >&2
  exit 1
fi
echo "relaunched $1"
SH
  # A crew-state stand-in: a canned line for ids with a file under
  # <world>/crew-state, else the real reader.
  cat > "$fb/crew-state" <<SH
#!/usr/bin/env bash
if [ -f "$w/crew-state/\$1" ]; then cat "$w/crew-state/\$1"; exit 0; fi
exec "$ROOT/bin/fm-crew-state.sh" "\$@"
SH
  chmod +x "$fb/tmux" "$fb/no-mistakes" "$fb/control" "$fb/crew-state"
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

wr() {  # <world> <args...>
  local w=$1
  shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u TMUX -u TMUX_PANE \
    PATH="$w/fakebin:$PATH" FM_HOME="$w/home" FM_FAKE_DIR="$w/fake" \
    FM_WORKER_RESTORE_CONTROL="$w/fakebin/control" \
    FM_WORKER_RESTORE_CREW_STATE="$w/fakebin/crew-state" \
    "$WR" "$@"
}

class_of() {  # <classify-output> <id>
  printf '%s\n' "$1" | awk -F '\t' -v id="$2" '$1 == id { print $2 }'
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

# populate <world>: one worker in each class the classifier names.
populate() {
  local w=$1
  add_worker "$w" w-working 'working: building the parser'
  add_worker "$w" w-fresh -
  add_worker "$w" w-parked 'working: waiting' \
    parked=2026-09-24T01:00:00Z parked_reason='captain call on scope' \
    native_session=0b5e4a1c-2d3f-4a5b-8c7d-9e0f1a2b3c4d native_session_harness=claude
  add_worker "$w" w-finished 'done: PR https://example.invalid/pull/1 checks green'
  add_worker "$w" w-waiting 'needs-decision [key=scope]: pick A or B'
  add_worker "$w" w-held 'captain-held: waiting for the captain to test'
  add_worker "$w" w-validating 'done: implementation committed'
  printf 'state: working · source: run-step · running (review)\n' > "$w/crew-state/w-validating"
  add_worker "$w" w-gate 'done: implementation committed'
  printf 'state: parked · source: run-step · awaiting_approval (review)\n' > "$w/crew-state/w-gate"
  add_worker "$w" w-passed 'working: validating'
  printf 'state: done · source: run-step · passed\n' > "$w/crew-state/w-passed"
  add_worker "$w" w-old-done 'done: PR https://example.invalid/pull/0 checks green' \
    "worktree=$w/pool/w-working/proj" spawn_gen=s1789990000.1.1
  add_worker "$w" w-reused 'working: building'
  add_worker "$w" w-newer 'working: took the slot after the restart' \
    "worktree=$w/pool/w-reused/proj" spawn_gen=s1790000500.1.1
  printf 'fm-w-newer\n' > "$w/fake/windows"
  printf 'claude' > "$w/fake/command"
}

test_classify_names_each_worker_class() {
  local w out
  w=$(new_world classify)
  populate "$w"
  out=$(wr "$w" classify 2>&1)
  [ "$(class_of "$out" w-working)" = working ] || fail "a worker that reported working must classify working, even beside an older finished record for its slot: $out"
  [ "$(class_of "$out" w-old-done)" = finished ] || fail "an older finished record for the same slot must classify finished: $out"
  [ "$(class_of "$out" w-fresh)" = working ] || fail "a worker with no status line yet must classify working: $out"
  [ "$(class_of "$out" w-parked)" = parked ] || fail "a parked worker must classify parked: $out"
  [ "$(class_of "$out" w-finished)" = finished ] || fail "a done worker must classify finished: $out"
  [ "$(class_of "$out" w-waiting)" = captain-waiting ] || fail "an open decision must classify captain-waiting: $out"
  [ "$(class_of "$out" w-held)" = captain-waiting ] || fail "a captain-held line must classify captain-waiting: $out"
  [ "$(class_of "$out" w-validating)" = working ] || fail "an active validation run must classify working even after a done line: $out"
  [ "$(class_of "$out" w-gate)" = working ] || fail "a validation run at a gate with no open decision must classify working: $out"
  [ "$(class_of "$out" w-passed)" = finished ] || fail "a passed validation run must classify finished: $out"
  [ "$(class_of "$out" w-reused)" = slot-reused ] || fail "a worker whose worktree a newer record holds must classify slot-reused: $out"
  assert_contains "$out" "w-newer" "the classifier must list the newer record"
  pass "classify names working, parked, finished, captain-waiting, and slot-reused workers"
}

test_classify_orders_finished_first_and_an_active_run_over_a_decision() {
  local w out
  w=$(new_world order)
  add_worker "$w" w-decided 'needs-decision [key=scope]: pick A or B'
  printf 'done: PR https://example.invalid/pull/2 checks green\n' >> "$w/home/state/w-decided.status"
  add_worker "$w" w-driving 'needs-decision [key=scope]: pick A or B'
  printf 'state: working · source: run-step · running (review)\n' > "$w/crew-state/w-driving"
  add_worker "$w" w-gate-held 'needs-decision [key=gate]: approve the fix?'
  printf 'captain-held [key=gate]: the captain holds this gate\n' >> "$w/home/state/w-gate-held.status"
  printf 'state: parked · source: run-step · awaiting_approval (review)\n' > "$w/crew-state/w-gate-held"
  add_worker "$w" w-run-held 'captain-held: the captain wants to test first'
  printf 'state: working · source: run-step · running (review)\n' > "$w/crew-state/w-run-held"
  add_worker "$w" w-unknown 'needs-decision [key=scope]: pick A or B'
  printf 'state: unknown · source: run-step · the daemon is down\n' > "$w/crew-state/w-unknown"
  out=$(wr "$w" classify 2>&1)
  [ "$(class_of "$out" w-decided)" = finished ] || fail "with no run, a done line must classify finished before an older open decision: $out"
  [ "$(class_of "$out" w-driving)" = working ] || fail "an active validation run must override an older open decision: $out"
  [ "$(class_of "$out" w-gate-held)" = captain-waiting ] || fail "a run parked at a gate with a newest captain-held line must classify captain-waiting: $out"
  [ "$(class_of "$out" w-run-held)" = captain-waiting ] || fail "a newest captain-held line must win over an active run: $out"
  [ "$(class_of "$out" w-unknown)" = captain-waiting ] || fail "a run in an unknown state is not active, so an open decision must classify captain-waiting: $out"
  out=$(wr "$w" run --key order-1 --restart 'a Herdr restart' 2>&1) || fail "run failed: $out"
  [ "$(awk '{ print $1 }' "$w/fake/control.log" | sort | tr '\n' ' ')" = "w-driving " ] \
    || fail "only the worker with an active run may come back: $(cat "$w/fake/control.log")"
  pass "classify checks captain-held first, finished before captain-waiting, and only an active run overrides an open decision"
}

# A live agent at another record's endpoint counts as occupying the worktree
# unless its pane is proven to sit elsewhere.
test_lease_check_counts_a_live_agent_whose_location_cannot_be_read() {
  local w out
  w=$(new_world unlocated)
  add_worker "$w" w-b 'working: b'
  add_worker "$w" w-old 'done: PR https://example.invalid/pull/4 checks green' \
    "worktree=$w/pool/w-b/proj" spawn_gen=s1789990000.1.1
  printf 'fm-w-old\n' > "$w/fake/windows"
  printf 'claude' > "$w/fake/command"
  out=$(wr "$w" lease-check w-b 2>&1) && fail "a live agent whose pane location cannot be read must count as occupying the worktree: $out"
  assert_contains "$out" "w-old" "the reason must name the other task"
  out=$(wr "$w" classify 2>&1)
  [ "$(class_of "$out" w-b)" = slot-reused ] || fail "the worker must stay down as slot-reused: $out"
  pass "lease-check counts a live agent whose pane location cannot be read"
}

# After a Herdr restart, pane ids start low again, so a recorded id can name a
# pane that now belongs to other work. Only a pane in the record's own worktree
# is its endpoint.
test_a_recorded_pane_that_sits_elsewhere_is_not_the_workers_own() {
  local w out
  w=$(new_world recycled)
  add_worker "$w" w-a 'working: a'
  add_worker "$w" w-b 'working: b'
  add_worker "$w" w-old 'done: PR https://example.invalid/pull/3 checks green' \
    "worktree=$w/pool/w-b/proj" spawn_gen=s1789990000.1.1
  mkdir -p "$w/elsewhere"
  printf 'fm-w-a\nfm-w-old\n' > "$w/fake/windows"
  printf 'claude' > "$w/fake/command"
  printf '%s' "$w/elsewhere" > "$w/fake/cwd"
  out=$(wr "$w" classify 2>&1)
  [ "$(class_of "$out" w-a)" = working ] || fail "a live recorded pane outside the worker's worktree must not read as its running agent: $out"
  [ "$(class_of "$out" w-b)" = working ] || fail "an older record whose recorded pane now runs other work must not make the slot read as reused: $out"
  wr "$w" lease-check w-b >/dev/null 2>&1 || fail "lease-check must not count an older record's recycled pane as a live agent in the worktree"
  out=$(wr "$w" run --key herdr-2 --restart 'a Herdr restart' 2>&1) || fail "run failed: $out"
  assert_contains "$out" "restored 2 (w-a, w-b)" "workers whose recorded panes now run other work must be relaunched"
  printf '%s' "$w/pool/w-a/proj" > "$w/fake/cwd"
  out=$(wr "$w" classify 2>&1)
  [ "$(class_of "$out" w-a)" = running ] || fail "a live pane in the worker's own worktree must read as running: $out"
  rm -f "$w/fake/cwd"
  out=$(wr "$w" classify 2>&1)
  [ "$(class_of "$out" w-a)" = unreadable ] || fail "a live recorded pane whose location cannot be read must stay down as unreadable: $out"
  pass "a recorded pane that now runs other work is not the worker's endpoint"
}

test_run_relaunches_only_working_workers_once_per_restart() {
  local w out log
  w=$(new_world run)
  populate "$w"
  out=$(wr "$w" run --key boot-2 --restart 'a machine reboot' 2>&1) || fail "run failed: $out"
  log=$(sort "$w/fake/control.log")
  [ "$(printf '%s\n' "$log" | awk '{ print $1 }' | tr '\n' ' ')" = "w-fresh w-gate w-validating w-working " ] \
    || fail "only the working workers may be relaunched, got: $log"
  printf '%s\n' "$log" | grep -q '^w-working relaunch --note ' || fail "a relaunch must go through the control plane with a note: $log"
  assert_contains "$out" "restored 4 (w-fresh, w-gate, w-validating, w-working)" "the summary must name the restored workers"
  assert_contains "$out" "slot-reused 1 (w-reused:" "the summary must report the reused slot"
  assert_contains "$out" "failed 0" "the summary must count failures"
  [ "$(printf '%s\n' "$out" | grep -c 'worker restore after a machine reboot')" = 1 ] || fail "run must print exactly one summary line: $out"
  grep -q 'check: worker restore after a machine reboot: restored 4' "$w/home/state/.wake-queue" \
    || fail "run must queue one check wake with the summary"
  out=$(wr "$w" run --key boot-2 --restart 'a machine reboot' 2>&1) || fail "second run failed: $out"
  [ "$(wc -l < "$w/fake/control.log")" = 4 ] || fail "a restart must be restored once, not twice"
  pass "run relaunches only working workers, one summary, once per restart"
}

test_run_reports_a_failed_relaunch_with_its_reason() {
  local w out
  w=$(new_world fail)
  add_worker "$w" w-a 'working: a'
  add_worker "$w" w-b 'working: b'
  printf 'w-a\n' > "$w/fake/fail"
  out=$(wr "$w" run --key k1 --restart 'a Herdr restart' 2>&1)
  assert_contains "$out" "restored 1 (w-b)" "the other worker must still be restored"
  assert_contains "$out" "failed 1 (w-a: error: the replacement agent for w-a could not be launched on claude)" \
    "a failed relaunch must be reported with its reason"
  pass "run reports a failed relaunch with its reason and continues"
}

test_lease_check_reports_a_live_treehouse_owner() {
  local w out
  w=$(new_world lease)
  add_worker "$w" w-a 'working: a'
  wr "$w" lease-check w-a >/dev/null 2>&1 || fail "a slot with no live owner and no newer record is not reused"
  start_owner "$w/owner.fifo"
  OWNER_PIDS+=("$!")
  lease_slot "$w" w-a "$!"
  out=$(wr "$w" lease-check w-a 2>&1) && fail "a live Treehouse owner that is not this worker's must read as reused: $out"
  assert_contains "$out" "Treehouse leases it to live process $!" "the reason must name the live owner"
  out=$(wr "$w" classify 2>&1)
  [ "$(class_of "$out" w-a)" = slot-reused ] || fail "a live foreign lease must classify slot-reused: $out"
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
  out=$(wr "$w" lease-check w-a 2>&1) && fail "a newer record in a second mate's home must read as reused: $out"
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

test_record_starts_worker_restore_once_for_a_restart() {
  local w out _
  w=$(new_world record)
  add_worker "$w" w-a 'working: a'
  printf 'boot-1\n' > "$w/boot_id"
  rrec() {
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u TMUX -u TMUX_PANE \
      PATH="$w/fakebin:$PATH" FM_HOME="$w/home" FM_FAKE_DIR="$w/fake" \
      FM_WORKER_RESTORE_CONTROL="$w/fakebin/control" \
      FM_WORKER_RESTORE_CREW_STATE="$w/fakebin/crew-state" \
      FM_RESTART_BOOT_ID_FILE="$w/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
      "$ROOT/bin/fm-local-restart-recovery.sh" record
  }
  out=$(rrec 2>&1)
  assert_not_contains "$out" "worker restore" "a first record has no restart and must not restore workers"
  printf 'boot-2\n' > "$w/boot_id"
  out=$(rrec 2>&1)
  assert_contains "$out" "Worker restore is relaunching" "a restart must start worker restore and say so"
  for _ in $(seq 1 100); do
    grep -q 'check: worker restore' "$w/home/state/.wake-queue" 2>/dev/null && break
    sleep 0.1
  done
  grep -q 'check: worker restore after machine reboot: restored 1 (w-a)' "$w/home/state/.wake-queue" \
    || fail "the detached worker restore must relaunch the working worker and queue its summary: $(cat "$w/home/state/.wake-queue" "$w/home/state/.worker-restore.log" 2>&1)"
  pass "record starts worker restore once for a detected restart (restart-record seam)"
}

test_classify_names_each_worker_class
test_classify_orders_finished_first_and_an_active_run_over_a_decision
test_a_recorded_pane_that_sits_elsewhere_is_not_the_workers_own
test_lease_check_counts_a_live_agent_whose_location_cannot_be_read
test_run_relaunches_only_working_workers_once_per_restart
test_run_reports_a_failed_relaunch_with_its_reason
test_lease_check_reports_a_live_treehouse_owner
test_lease_check_sees_records_in_sibling_homes
test_spawn_relaunch_refuses_a_reused_worktree
test_record_starts_worker_restore_once_for_a_restart
