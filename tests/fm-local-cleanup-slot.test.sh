#!/usr/bin/env bash
# Regression seams: cleanup-slot-return-gates, cleanup-late-outcome-retry, and explicit
# stale-record retirement.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity slot-test slot-test@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-local-cleanup-slot)
unset ATLAS_REPO SPECS_REPO
export ATLAS_AXI_DASH=http://127.0.0.1:1
FIXTURE_PIDS=()
stop_fixture_processes() {
  [ "${#FIXTURE_PIDS[@]}" -eq 0 ] || kill "${FIXTURE_PIDS[@]}" 2>/dev/null || true
  fm_test_cleanup
}
trap stop_fixture_processes EXIT

# Treehouse v2.3.0 records a slot owner as its pid and start time in epoch ms.
started_ms() {  # <pid>
  local ticks btime hz
  ticks=$(awk '{sub(/.*\) /, ""); print $20}' "/proc/$1/stat")
  btime=$(awk '$1 == "btime" {print $2}' /proc/stat)
  hz=$(getconf CLK_TCK)
  printf '%s\n' "$((btime * 1000 + ticks * 1000 / hz))"
}

set_slot_owner() {  # <pid> [started-ms]
  local started=${2:-$(started_ms "$1")}
  jq --argjson pid "$1" --argjson started "$started" \
    '.worktrees[0] += {owner_pid: $pid, owner_started_at: $started}' \
    "$CASE/pool/treehouse-state.json" > "$CASE/pool/new.json"
  mv "$CASE/pool/new.json" "$CASE/pool/treehouse-state.json"
}

make_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/home/config" "$CASE/fakebin" "$CASE/pool/1"
  git init -q -b main "$CASE/project"
  git -C "$CASE/project" commit -qm baseline --allow-empty
  WT="$CASE/pool/1/project"
  git -C "$CASE/project" worktree add -qb fm/old "$WT"
  printf '{"worktrees":[{"name":"1","path":"%s","created_at":"2026-09-24T00:00:00Z"}]}\n' "$WT" > "$CASE/pool/treehouse-state.json"
  set_slot_owner "$$"
  fm_write_meta "$CASE/home/state/old.meta" "window=fixture:fm-old" "endpoint_task_id=old" \
    "worktree=$WT" "project=$CASE/project" "kind=ship" "mode=local-only" "spawn_gen=old-generation"
  printf 'done: finished\n' > "$CASE/home/state/old.status"
  cat > "$CASE/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ ! -e "$CASE/refuse-return" ] || { echo 'error: return refused by fixture' >&2; exit 1; }
printf 'returned\n' >> "$CASE/runtime.log"
jq '.worktrees[0] |= del(.owner_pid, .owner_started_at)' "$CASE/pool/treehouse-state.json" > "$CASE/pool/new.json"
mv "$CASE/pool/new.json" "$CASE/pool/treehouse-state.json"
SH
  cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  kill-*)
    printf 'killed\n' >> "$CASE/runtime.log"
    [ ! -e "$CASE/late-outcome" ] || printf 'failed: late outcome before the endpoint stopped\n' >> "$CASE/home/state/old.status"
    [ ! -e "$CASE/subshell.pid" ] || kill "$(cat "$CASE/subshell.pid")"
    [ ! -e "$CASE/break-parent" ] || mv "$CASE/home/.fm-secondmate-parent" "$CASE/parent-binding.off"
    ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE/fakebin/no-mistakes"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE/fakebin/lsof"
  chmod +x "$CASE/fakebin/"*
  export CASE
}

run_teardown() {
  env FM_HOME="$CASE/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$CASE/home/state" \
    FM_DATA_OVERRIDE="$CASE/home/data" FM_CONFIG_OVERRIDE="$CASE/home/config" \
    FM_TEARDOWN_GUARD_DONE=1 PATH="$CASE/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" old
}

run_scan() {
  env FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" FM_DATA_OVERRIDE="$CASE/home/data" \
    "$ROOT/bin/fm-inactive-reconcile.sh" scan > "$CASE/scan.out" 2>&1 || fail "reconcile scan failed: $(cat "$CASE/scan.out")"
}

make_parent() {
  mkdir -p "$CASE/parent/state" "$CASE/parent/data"
  printf 'mate\n' > "$CASE/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$CASE/parent" > "$CASE/home/.fm-secondmate-parent"
  fm_write_meta "$CASE/parent/state/mate.meta" "kind=secondmate" "home=$CASE/home"
  printf -- '- mate - fixture (home: %s; scope: fixture; projects: fixture; added 2026-09-24)\n' "$CASE/home" > "$CASE/parent/data/secondmates.md"
}

test_parent_gate_preserves_slot() {
  make_case parent
  make_parent
  mkdir "$CASE/parent/state/mate.status"
  cp "$CASE/home/state/old.meta" "$CASE/before.meta"
  cp "$CASE/pool/treehouse-state.json" "$CASE/before.pool"
  if run_teardown > "$CASE/out" 2> "$CASE/err"; then
    fail 'parent delivery failure must refuse cleanup'
  fi
  assert_contains "$(cat "$CASE/err")" 'has not reached the parent channel' 'must reach the parent gate'
  cmp -s "$CASE/before.pool" "$CASE/pool/treehouse-state.json" || fail 'parent refusal returned the leased slot'
  cmp -s "$CASE/before.meta" "$CASE/home/state/old.meta" || fail 'parent refusal changed the record'
  [ "$(git -C "$WT" branch --show-current)" = fm/old ] || fail 'parent refusal detached the worktree'
  assert_absent "$CASE/runtime.log" 'parent refusal touched the endpoint or pool'
  rmdir "$CASE/parent/state/mate.status"
  run_teardown > "$CASE/out" 2> "$CASE/err" || fail "retry failed: $(cat "$CASE/err")"
  assert_absent "$CASE/home/state/old.meta" 'retry did not retire the task'
  [ "$(jq -r '.worktrees[0].owner_pid' "$CASE/pool/treehouse-state.json")" = null ] || fail 'retry retained the slot'
  pass 'parent refusal retains the slot and endpoint; a repaired channel permits cleanup'
}

test_late_outcome_reaches_parent_before_record_retires() {
  make_case late-outcome
  make_parent
  : > "$CASE/late-outcome"
  run_teardown > "$CASE/out" 2> "$CASE/err" || fail "teardown failed: $(cat "$CASE/err")"
  assert_contains "$(cat "$CASE/runtime.log")" 'killed' 'the endpoint was not stopped'
  assert_contains "$(cat "$CASE/parent/state/mate.status")" 'child old done' 'the first outcome did not reach the parent'
  assert_contains "$(cat "$CASE/parent/state/mate.status")" 'child old failed' 'the late outcome was discarded'
  pass 'an outcome written before the endpoint stopped reaches the parent before the record retires'
}

test_undelivered_late_outcome_completes_after_owner_exits() {
  make_case late-undelivered
  make_parent
  : > "$CASE/late-outcome"
  : > "$CASE/break-parent"
  # An interactive `treehouse get` owns the slot and exits once its worktree subshell is reaped.
  bash -c 'sleep 1000 & printf "%s\n" "$!" > "$CASE/subshell.pid.tmp"; mv "$CASE/subshell.pid.tmp" "$CASE/subshell.pid"; wait; exit 0' &
  local owner=$! i
  FIXTURE_PIDS+=("$owner")
  for ((i=0; i<100; i++)); do [ ! -e "$CASE/subshell.pid" ] || break; sleep 0.1; done
  assert_present "$CASE/subshell.pid" 'slot owner fixture did not start its subshell'
  set_slot_owner "$owner"
  run_teardown > "$CASE/out" 2> "$CASE/err" || fail "an undelivered late outcome refused after the endpoint stopped: $(cat "$CASE/err")"
  wait "$owner" || true
  ! kill -0 "$owner" 2>/dev/null || fail 'the slot owner outlived its reaped subshell'
  assert_contains "$(cat "$CASE/err")" 'LATE OUTCOME UNDELIVERED' 'the undelivered late outcome was not reported loudly'
  assert_absent "$CASE/home/state/old.meta" 'teardown did not complete after the endpoint stopped'
  [ "$(jq -r '.worktrees[0].owner_pid' "$CASE/pool/treehouse-state.json")" = null ] || fail 'teardown did not return the slot'
  assert_contains "$(cat "$CASE/parent/state/mate.status")" 'child old done' 'the first outcome did not reach the parent'
  assert_contains "$(cat "$CASE/home/state/terminal-outcomes/"*.pending)" 'child old failed' 'the late outcome was not recorded for retry'
  mv "$CASE/parent-binding.off" "$CASE/home/.fm-secondmate-parent"
  run_scan
  assert_contains "$(cat "$CASE/parent/state/mate.status")" 'child old failed' 'the watcher did not retry the late outcome'
  if compgen -G "$CASE/home/state/terminal-outcomes/*.pending" > /dev/null; then fail 'the delivered late outcome is still pending'; fi
  pass 'cleanup-late-outcome-retry: an undelivered late outcome completes teardown after the slot owner exits and the watcher delivers it'
}

test_superseded_outcome_never_follows_newer_outcome() {
  make_case superseded
  make_parent
  printf 'failed: older outcome\n' > "$CASE/home/state/old.status"
  mv "$CASE/home/.fm-secondmate-parent" "$CASE/parent-binding.off"
  run_scan
  assert_contains "$(cat "$CASE/home/state/terminal-outcomes/"*.pending)" 'child old failed' 'the older outcome was not left owed'
  mv "$CASE/parent-binding.off" "$CASE/home/.fm-secondmate-parent"
  printf 'done: newer outcome\n' >> "$CASE/home/state/old.status"
  run_teardown > "$CASE/out" 2> "$CASE/err" || fail "teardown failed: $(cat "$CASE/err")"
  run_scan
  assert_contains "$(cat "$CASE/parent/state/mate.status")" 'child old done' 'the newer outcome did not reach the parent'
  case "$(cat "$CASE/parent/state/mate.status")" in
    *'child old failed'*) fail 'the superseded older outcome reached the parent after the newer outcome' ;;
  esac
  pass 'cleanup-late-outcome-retry: an older failed outcome never follows a newer done outcome of the same task'
}

test_reused_task_id_keeps_older_incarnation_outcome() {
  make_case reused-id
  make_parent
  : > "$CASE/late-outcome"
  : > "$CASE/break-parent"
  run_teardown > "$CASE/out" 2> "$CASE/err" || fail "teardown failed: $(cat "$CASE/err")"
  assert_contains "$(cat "$CASE/home/state/terminal-outcomes/"*.pending)" 'child old failed' 'the late outcome was not left owed'
  mv "$CASE/parent-binding.off" "$CASE/home/.fm-secondmate-parent"
  fm_write_meta "$CASE/home/state/old.meta" "window=fixture:fm-old" "endpoint_task_id=old" \
    "worktree=$WT" "project=$CASE/project" "kind=ship" "mode=local-only" "spawn_gen=new-generation"
  printf 'done: replacement finished\n' > "$CASE/home/state/old.status"
  run_scan
  assert_contains "$(cat "$CASE/parent/state/mate.status")" 'child old done: replacement finished' 'the replacement outcome did not reach the parent'
  assert_contains "$(cat "$CASE/parent/state/mate.status")" 'child old failed' 'the replacement erased the older incarnation outcome'
  if compgen -G "$CASE/home/state/terminal-outcomes/*.pending" > /dev/null; then fail 'an owed outcome is still pending'; fi
  run_scan
  [ "$(grep -c 'child old failed' "$CASE/parent/state/mate.status")" = 1 ] || fail 'the older incarnation outcome was delivered more than once'
  pass 'cleanup-late-outcome-retry: a reused task id keeps and delivers the older incarnation outcome once'
}

test_return_refusal_keeps_task_records() {
  make_case return-refusal
  printf 'busy_gen=old-busy\n' >> "$CASE/home/state/old.meta"
  printf 'old-busy\n' > "$CASE/home/state/old.busy-gen"
  : > "$CASE/refuse-return"
  cp "$CASE/home/state/old.status" "$CASE/status.before"
  if run_teardown > "$CASE/out" 2> "$CASE/err"; then fail 'a refused Treehouse return must refuse cleanup'; fi
  assert_contains "$(cat "$CASE/err")" 'treehouse return failed' 'must reach the Treehouse return'
  ! grep -qx killed "$CASE/runtime.log" 2>/dev/null || fail 'return refusal stopped the endpoint before the rerun'
  assert_present "$CASE/home/state/old.meta" 'return refusal removed the record'
  cmp -s "$CASE/status.before" "$CASE/home/state/old.status" || fail 'return refusal retired the status log'
  [ "$(cat "$CASE/home/state/old.busy-gen")" = old-busy ] || fail 'return refusal retired the busy state'
  [ "$(jq -r '.worktrees[0].owner_pid' "$CASE/pool/treehouse-state.json")" = "$$" ] || fail 'return refusal released the slot'
  rm "$CASE/refuse-return"
  run_teardown > "$CASE/out" 2> "$CASE/err" || fail "retry failed: $(cat "$CASE/err")"
  assert_absent "$CASE/home/state/old.meta" 'retry did not retire the task'
  assert_absent "$CASE/home/state/old.busy-gen" 'retry did not retire the busy state'
  pass 'a refused Treehouse return keeps the status log, busy state, and record for a rerun'
}

test_busy_generation_refusal_preserves_slot() {
  make_case busy-refusal
  printf 'busy_gen=stale-generation\n' >> "$CASE/home/state/old.meta"
  printf 'new-generation\n' > "$CASE/home/state/old.busy-gen"
  cp "$CASE/pool/treehouse-state.json" "$CASE/pool.before"
  if run_teardown > "$CASE/out" 2> "$CASE/err"; then fail 'stale busy generation must refuse'; fi
  assert_contains "$(cat "$CASE/err")" 'busy-state gen for old does not match its record' 'must reach the busy retirement gate'
  cmp -s "$CASE/pool.before" "$CASE/pool/treehouse-state.json" || fail 'busy refusal returned the leased slot'
  assert_present "$CASE/home/state/old.meta" 'busy refusal removed the record'
  assert_absent "$CASE/runtime.log" 'busy refusal touched the endpoint or pool'
  pass 'busy generation refusal retains the leased slot and endpoint'
}

test_unsafe_merge_marker_refusal_preserves_slot() {
  make_case unsafe-merge-marker
  ln -s "$CASE/home/state/old.status" "$CASE/home/state/old.pr-poll-merge-notified"
  cp "$CASE/pool/treehouse-state.json" "$CASE/pool.before"
  if run_teardown > "$CASE/out" 2> "$CASE/err"; then fail 'an unsafe merge marker must refuse'; fi
  cmp -s "$CASE/pool.before" "$CASE/pool/treehouse-state.json" || fail 'merge marker refusal returned the leased slot'
  assert_present "$CASE/home/state/old.meta" 'merge marker refusal removed the record'
  assert_absent "$CASE/runtime.log" 'merge marker refusal touched the endpoint or pool'
  assert_contains "$(cat "$CASE/err")" 'unsafe task PR-check artifact' 'must reach the PR cleanup preflight'
  pass 'unsafe PR merge markers refuse before endpoint or pool changes'
}

# The live task holds the slot the way an interactive `treehouse get` does: an
# owner process with the live agent as its descendant, and no lease holder.
make_collision() {
  make_case "$1"
  git -C "$WT" checkout -qb fm/live
  bash -c 'cd "$2" || exit 1; sleep 300 & printf "%s\n" "$!" > "$1.tmp"; mv "$1.tmp" "$1"; wait' _ "$CASE/agent-pid" "$WT" &
  OWNER_PID=$!
  FIXTURE_PIDS+=("$OWNER_PID")
  local i
  for ((i=0; i<100; i++)); do [ ! -e "$CASE/agent-pid" ] || break; sleep 0.05; done
  AGENT_PID=$(cat "$CASE/agent-pid")
  FIXTURE_PIDS+=("$AGENT_PID")
  set_slot_owner "$OWNER_PID"
  fm_write_meta "$CASE/home/state/live.meta" "window=fixture:fm-live" "endpoint_task_id=live" \
    "worktree=$WT" "project=$CASE/project" "kind=ship" "spawn_gen=live-generation"
  perl -pi -e 's/kind=ship/kind=scout/' "$CASE/home/state/old.meta"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$CASE/home/state/old.meta"
  mkdir -p "$CASE/home/data/old"
  printf 'Finished scout report.\n' > "$CASE/home/data/old/report.md"
  printf 'live edits\n' > "$WT/sentinel"
  printf 'working: live task\n' > "$CASE/home/state/live.status"
  cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-live\n' ;;
  display-message) printf '/dev/pts/fixture\n' ;;
  *) printf 'unexpected tmux mutation: %s\n' "$*" >> "$CASE/runtime.log"; exit 1 ;;
esac
SH
  cat > "$CASE/fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=$(cat "$CASE/agent-pid")
printf '%s %s %s claude\n' "$pid" "$pid" "$pid"
SH
  chmod +x "$CASE/fakebin/ps"
}

run_retire() {
  env FM_HOME="$CASE/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$CASE/home/state" \
    FM_DATA_OVERRIDE="$CASE/home/data" FM_CONFIG_OVERRIDE="$CASE/home/config" \
    PATH="$CASE/fakebin:$PATH" "$ROOT/bin/fm-local-retire-reassigned.sh" old --live-task live
}

test_retire_finished_scout_preserves_live_task() {
  make_collision retire
  cp "$CASE/home/state/live.meta" "$CASE/live.before"
  cp "$CASE/pool/treehouse-state.json" "$CASE/pool.before"
  cp "$CASE/home/state/old.meta" "$CASE/old.before"
  local rc=0
  run_retire > "$CASE/out" 2> "$CASE/err" || rc=$?
  kill -0 "$OWNER_PID" 2>/dev/null || fail 'retirement killed the slot owner'
  kill -0 "$AGENT_PID" 2>/dev/null || fail 'retirement killed the live agent'
  [ "$rc" -eq 0 ] || fail "retirement failed: $(cat "$CASE/err")"
  assert_absent "$CASE/home/state/old.meta" 'finished record still active'
  cmp -s "$CASE/old.before" "$CASE/home/data/old/retired-reassigned/old.meta" || fail 'old record was not archived intact'
  cmp -s "$CASE/live.before" "$CASE/home/state/live.meta" || fail 'live record changed'
  cmp -s "$CASE/pool.before" "$CASE/pool/treehouse-state.json" || fail 'live slot owner changed'
  [ "$(cat "$WT/sentinel")" = 'live edits' ] || fail 'live edits changed'
  [ "$(git -C "$WT" branch --show-current)" = fm/live ] || fail 'live branch changed'
  assert_absent "$CASE/runtime.log" 'retirement called process or pool cleanup'
  pass 'finished scout retirement preserves the live slot, record, branch, dirty work, and process'
}

test_retirement_refusals_preserve_records() {
  local scenario stranger
  for scenario in unfinished missing-report open-decision unowned-slot stranger-owner stale-owner old-alive dirty-ship unlanded-ship unreadable-ship busy-drift; do
    make_collision "$scenario"
    case "$scenario" in
      unfinished) printf 'working: still working\n' > "$CASE/home/state/old.status" ;;
      missing-report) rm "$CASE/home/data/old/report.md" ;;
      open-decision) printf 'blocked [key=choice]: unresolved\ndone: finished\n' > "$CASE/home/state/old.status" ;;
      unowned-slot)
        jq '.worktrees[0] |= del(.owner_pid, .owner_started_at)' "$CASE/pool/treehouse-state.json" > "$CASE/pool/new.json"
        mv "$CASE/pool/new.json" "$CASE/pool/treehouse-state.json"
        ;;
      stranger-owner)
        sleep 300 &
        stranger=$!
        FIXTURE_PIDS+=("$stranger")
        set_slot_owner "$stranger"
        ;;
      stale-owner) set_slot_owner "$OWNER_PID" "$(($(started_ms "$OWNER_PID") + 10))" ;;
      old-alive) perl -pi -e 's/fm-live\\n/fm-old\\nfm-live\\n/' "$CASE/fakebin/tmux" ;;
      dirty-ship) perl -pi -e 's/kind=scout/kind=ship/' "$CASE/home/state/old.meta" ;;
      unlanded-ship)
        perl -pi -e 's/kind=scout/kind=ship/' "$CASE/home/state/old.meta"
        rm "$WT/sentinel"
        git -C "$WT" checkout -q fm/old
        git -C "$WT" commit -qm unlanded --allow-empty
        git -C "$WT" checkout -q fm/live
        ;;
      unreadable-ship)
        perl -pi -e 's/kind=scout/kind=ship/' "$CASE/home/state/old.meta"
        rm "$WT/sentinel"
        printf 'corrupt index\n' > "$(git -C "$WT" rev-parse --git-path index)"
        ;;
      busy-drift)
        printf 'busy_gen=old-busy\n' >> "$CASE/home/state/old.meta"
        printf 'new-busy\n' > "$CASE/home/state/old.busy-gen"
        ;;
    esac
    cp "$CASE/home/state/old.meta" "$CASE/old.before"
    cp "$CASE/pool/treehouse-state.json" "$CASE/pool.before"
    if run_retire > "$CASE/out" 2> "$CASE/err"; then fail "$scenario unexpectedly allowed retirement"; fi
    cmp -s "$CASE/old.before" "$CASE/home/state/old.meta" || fail "$scenario changed the old record"
    cmp -s "$CASE/pool.before" "$CASE/pool/treehouse-state.json" || fail "$scenario changed the lease"
    assert_absent "$CASE/runtime.log" "$scenario touched an endpoint or slot"
  done
  pass 'unfinished, unowned, ambiguous, decision-held, and unlanded records refuse retirement'
}

make_atlas() {
  mkdir -p "$CASE/atlas-repo/atlas"
  printf '%s\n' "$CASE/atlas-repo" > "$CASE/home/config/specs"
  printf 'atlas_ticket=c1\n' >> "$CASE/home/state/old.meta"
  printf 'atlas_ticket=c2\n' >> "$CASE/home/state/live.meta"
  printf 'started\n' > "$CASE/ticket-state"
  cat > "$CASE/fakebin/atlas-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = --repo ] && [ "$2" = "$CASE/atlas-repo" ] || exit 11
shift 2
[ "$1" = --by ] && [ "$2" = fm-local-retire-reassigned ] || exit 12
shift 2
printf '%s\n' "$*" >> "$CASE/atlas-calls"
case "$*" in
  'ticket show c1 --json') printf '{"change":{"id":"c1","task":"%s","state":"%s","node":"n1"}}\n' "$(cat "$CASE/ticket-task" 2>/dev/null || echo old)" "$(cat "$CASE/ticket-state")" ;;
  'ticket complete c1 '*)
    [ ! -e "$CASE/refuse-atlas" ] || { echo 'ticket c1 must be reviewed by the captain' >&2; exit 1; }
    [ ! -e "$CASE/atlas-noop" ] || exit 0
    printf 'completed\n' > "$CASE/ticket-state" ;;
  'release n1') ;;
  'ticket list n1 --json')
    if [ -e "$CASE/live-ticket-open" ]; then printf '[{"id":"c2","state":"started"}]\n'; else printf '[]\n'; fi ;;
  'land n1 '*) ;;
  *) echo "unexpected Atlas call: $*" >&2; exit 13 ;;
esac
SH
  chmod +x "$CASE/fakebin/atlas-axi"
}

test_retirement_checks_atlas_task_identity() {
  make_collision atlas-identity
  make_atlas
  printf 'live\n' > "$CASE/ticket-task"
  if run_retire > "$CASE/out" 2> "$CASE/err"; then fail 'retirement accepted another task on the old ticket'; fi
  assert_contains "$(cat "$CASE/err")" 'Atlas ticket does not name this finished leg' 'expected the Atlas identity guard'
  assert_present "$CASE/home/state/old.meta" 'identity refusal removed the old record'
  if grep -Eq '^(ticket complete|release|land) ' "$CASE/atlas-calls"; then fail 'identity refusal changed the Atlas'; fi
  [ "$(cat "$CASE/ticket-state")" = started ] || fail 'identity refusal completed another task'
  assert_absent "$CASE/runtime.log" 'identity refusal touched the live endpoint or slot'
  pass 'retirement proves the Atlas task identity before any ticket or node mutation'
}

test_retirement_closes_only_its_ticket_and_backlog() {
  make_collision atlas-close
  make_atlas
  : > "$CASE/live-ticket-open"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$CASE/home/data/backlog.md"
  tasks-axi add old 'Finished scout' --kind scout --file "$CASE/home/data/backlog.md" >/dev/null
  tasks-axi start old --file "$CASE/home/data/backlog.md" >/dev/null
  : > "$CASE/refuse-atlas"
  if run_retire > "$CASE/out" 2> "$CASE/err"; then fail 'Atlas refusal must retain the active record'; fi
  assert_present "$CASE/home/state/old.meta" 'Atlas refusal removed the record'
  assert_contains "$(cat "$CASE/err")" 'Atlas completion refused' 'expected the Atlas gate'
  assert_contains "$(tail -n 1 "$CASE/home/state/old.status")" 'blocked [key=atlas-gate-c1]' 'refusal left no keyed blocker'
  assert_contains "$(cat "$CASE/atlas-calls")" 'release n1' 'refused completion kept the node held'
  assert_absent "$CASE/home/data/old/retired-reassigned/old.status" 'refusal archived a status log that later changes'
  rm "$CASE/refuse-atlas"
  printf 'resolved [key=atlas-gate-c1]: captain approval recorded\ndone: finished\n' >> "$CASE/home/state/old.status"
  : > "$CASE/atlas-noop"
  if run_retire > "$CASE/out" 2> "$CASE/err"; then fail 'unconfirmed Atlas completion must retain the record'; fi
  assert_present "$CASE/home/state/old.meta" 'unconfirmed Atlas completion removed the record'
  rm "$CASE/atlas-noop"
  : > "$CASE/atlas-calls"
  run_retire > "$CASE/out" 2> "$CASE/err" || fail "Atlas retry failed: $(cat "$CASE/err")"
  [ "$(cat "$CASE/ticket-state")" = completed ] || fail 'old Atlas leg remains started'
  assert_contains "$(cat "$CASE/atlas-calls")" 'release n1' 'completed leg kept the node held'
  if grep -q '^land ' "$CASE/atlas-calls"; then fail 'retirement landed a node another open ticket holds'; fi
  if grep -q 'c2' "$CASE/atlas-calls"; then fail 'retirement touched the live Atlas ticket'; fi
  assert_absent "$CASE/home/state/old.meta" 'old record remains active'
  assert_absent "$CASE/home/state/old.backlog-close" 'backlog close did not finish'
  assert_contains "$(tasks-axi show old --file "$CASE/home/data/backlog.md")" 'state: done' 'backlog item remains open'
  pass 'Atlas refusal keeps a keyed blocker and the record; retry closes only the old ticket and backlog'
}

test_retirement_lands_a_node_no_open_ticket_holds() {
  make_collision atlas-land
  make_atlas
  run_retire > "$CASE/out" 2> "$CASE/err" || fail "retirement failed: $(cat "$CASE/err")"
  [ "$(cat "$CASE/ticket-state")" = completed ] || fail 'old Atlas leg remains started'
  assert_contains "$(cat "$CASE/atlas-calls")" 'release n1' 'completed leg kept the node held'
  assert_contains "$(cat "$CASE/atlas-calls")" 'land n1 --evidence' 'a node with no open ticket stayed underway'
  assert_absent "$CASE/home/state/old.meta" 'old record remains active'
  pass 'retirement releases and lands a node that no other open ticket holds'
}

test_retirement_preserves_landed_ship_ref_and_task_artifacts() {
  make_collision landed-ship
  perl -pi -e 's/kind=scout/kind=ship/' "$CASE/home/state/old.meta"
  rm "$WT/sentinel"
  printf 'old poll\n' > "$CASE/home/state/old.check.sh"
  printf 'live poll\n' > "$CASE/home/state/live.check.sh"
  printf 'old index\n' > "$CASE/home/state/.old.branch-outcome-index"
  printf 'old journal\n' > "$CASE/home/state/old.herdr-presentation"
  local old_head
  old_head=$(git -C "$CASE/project" rev-parse fm/old)
  run_retire > "$CASE/out" 2> "$CASE/err" || fail "landed ship retirement failed: $(cat "$CASE/err")"
  [ "$(git -C "$CASE/project" rev-parse fm/old)" = "$old_head" ] || fail 'retirement deleted the old branch'
  assert_absent "$CASE/home/state/old.check.sh" 'retired check remains active'
  assert_absent "$CASE/home/state/.old.branch-outcome-index" 'retired branch-outcome index remains active'
  assert_absent "$CASE/home/state/old.herdr-presentation" 'retired presentation journal remains active'
  [ "$(cat "$CASE/home/data/old/retired-reassigned/old.check.sh")" = 'old poll' ] || fail 'retired check was not archived'
  [ "$(cat "$CASE/home/data/old/retired-reassigned/.old.branch-outcome-index")" = 'old index' ] || fail 'branch-outcome index was not archived'
  [ "$(cat "$CASE/home/data/old/retired-reassigned/old.herdr-presentation")" = 'old journal' ] || fail 'presentation journal was not archived'
  [ "$(cat "$CASE/home/state/live.check.sh")" = 'live poll' ] || fail 'live check changed'
  pass 'landed ship retirement keeps Git refs and archives only its own task artifacts'
}

test_retirement_serializes_with_live_task_lifecycle() {
  make_collision live-lock
  local held="$CASE/home/state/.control-live.lock" lock_pid i
  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$held" || exit 1
    trap 'fm_lock_release "$held"' EXIT
    : > "$CASE/lock-ready"
    for ((i=0; i<300; i++)); do
      [ ! -e "$CASE/release-lock" ] || exit 0
      sleep 0.1
    done
  ) &
  # shellcheck disable=SC2031 # $! is read in this shell; only the sourced library's jobs run inside the subshell.
  lock_pid=$!
  for ((i=0; i<100; i++)); do [ ! -e "$CASE/lock-ready" ] || break; sleep 0.1; done
  assert_present "$CASE/lock-ready" 'live lifecycle fixture could not acquire its lock'
  local rc=0
  run_retire > "$CASE/out" 2> "$CASE/err" || rc=$?
  : > "$CASE/release-lock"
  wait "$lock_pid"
  [ "$rc" -ne 0 ] || fail 'retirement ignored the live lifecycle lock'
  assert_present "$CASE/home/state/old.meta" 'contended retirement removed the old record'
  assert_contains "$(cat "$CASE/err")" 'another lifecycle action holds' 'expected lifecycle contention'
  assert_absent "$CASE/runtime.log" 'contended retirement touched an endpoint'
  pass 'retirement refuses while another lifecycle action owns the live task'
}

test_unsafe_merge_marker_refusal_preserves_slot
test_retirement_checks_atlas_task_identity
test_parent_gate_preserves_slot
test_late_outcome_reaches_parent_before_record_retires
test_undelivered_late_outcome_completes_after_owner_exits
test_superseded_outcome_never_follows_newer_outcome
test_reused_task_id_keeps_older_incarnation_outcome
test_return_refusal_keeps_task_records
test_busy_generation_refusal_preserves_slot
test_retire_finished_scout_preserves_live_task
test_retirement_refusals_preserve_records
test_retirement_closes_only_its_ticket_and_backlog
test_retirement_lands_a_node_no_open_ticket_holds
test_retirement_preserves_landed_ship_ref_and_task_artifacts
test_retirement_serializes_with_live_task_lifecycle
