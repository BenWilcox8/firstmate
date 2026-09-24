#!/usr/bin/env bash
# Regression seam: cleanup-slot-return-gates and explicit stale-record retirement.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity slot-test slot-test@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-local-cleanup-slot)
unset ATLAS_REPO SPECS_REPO
export ATLAS_AXI_DASH=http://127.0.0.1:1

make_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/home/config" "$CASE/fakebin" "$CASE/pool/1"
  git init -q -b main "$CASE/project"
  git -C "$CASE/project" commit -qm baseline --allow-empty
  WT="$CASE/pool/1/project"
  git -C "$CASE/project" worktree add -qb fm/old "$WT"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"old","lease_id":"lease-old"}]}\n' "$WT" > "$CASE/pool/treehouse-state.json"
  fm_write_meta "$CASE/home/state/old.meta" "window=fixture:fm-old" "endpoint_task_id=old" \
    "worktree=$WT" "project=$CASE/project" "kind=ship" "mode=local-only" "spawn_gen=old-generation"
  printf 'done: finished\n' > "$CASE/home/state/old.status"
  cat > "$CASE/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'returned\n' >> "$CASE/runtime.log"
jq '.worktrees[0].leased=false' "$CASE/pool/treehouse-state.json" > "$CASE/pool/new.json"
mv "$CASE/pool/new.json" "$CASE/pool/treehouse-state.json"
SH
  cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  kill-*) printf 'killed\n' >> "$CASE/runtime.log" ;;
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

test_parent_gate_preserves_slot() {
  make_case parent
  mkdir -p "$CASE/parent/state/mate.status" "$CASE/parent/data"
  printf 'mate\n' > "$CASE/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$CASE/parent" > "$CASE/home/.fm-secondmate-parent"
  fm_write_meta "$CASE/parent/state/mate.meta" "kind=secondmate" "home=$CASE/home"
  printf -- '- mate - fixture (home: %s; scope: fixture; projects: fixture; added 2026-09-24)\n' "$CASE/home" > "$CASE/parent/data/secondmates.md"
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
  [ "$(jq -r '.worktrees[0].leased' "$CASE/pool/treehouse-state.json")" = false ] || fail 'retry retained the slot'
  pass 'parent refusal retains the slot and endpoint; a repaired channel permits cleanup'
}

make_collision() {
  make_case "$1"
  git -C "$WT" checkout -qb fm/live
  jq '.worktrees[0] += {lease_holder:"live",lease_id:"lease-live"}' "$CASE/pool/treehouse-state.json" > "$CASE/pool/new.json"
  mv "$CASE/pool/new.json" "$CASE/pool/treehouse-state.json"
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
printf '123 123 123 claude\n'
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
  (cd "$WT" && sleep 120) &
  local worker=$! rc=0
  run_retire > "$CASE/out" 2> "$CASE/err" || rc=$?
  if ! kill -0 "$worker" 2>/dev/null; then fail 'retirement killed the live process'; fi
  kill "$worker"
  wait "$worker" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "retirement failed: $(cat "$CASE/err")"
  assert_absent "$CASE/home/state/old.meta" 'finished record still active'
  cmp -s "$CASE/old.before" "$CASE/home/data/old/retired-reassigned/old.meta" || fail 'old record was not archived intact'
  cmp -s "$CASE/live.before" "$CASE/home/state/live.meta" || fail 'live record changed'
  cmp -s "$CASE/pool.before" "$CASE/pool/treehouse-state.json" || fail 'live lease changed'
  [ "$(cat "$WT/sentinel")" = 'live edits' ] || fail 'live edits changed'
  [ "$(git -C "$WT" branch --show-current)" = fm/live ] || fail 'live branch changed'
  assert_absent "$CASE/runtime.log" 'retirement called process or pool cleanup'
  pass 'finished scout retirement preserves the live slot, record, branch, dirty work, and process'
}

test_busy_generation_refusal_preserves_slot() {
  make_case busy-refusal
  printf 'busy_gen=stale-generation\n' >> "$CASE/home/state/old.meta"
  printf 'new-generation\n' > "$CASE/home/state/old.busy-gen"
  cp "$CASE/pool/treehouse-state.json" "$CASE/pool.before"
  if run_teardown > "$CASE/out" 2> "$CASE/err"; then fail 'stale busy generation must refuse'; fi
  assert_contains "$(cat "$CASE/err")" 'stale busy-state gen' 'must reach the busy retirement gate'
  cmp -s "$CASE/pool.before" "$CASE/pool/treehouse-state.json" || fail 'busy refusal returned the leased slot'
  assert_present "$CASE/home/state/old.meta" 'busy refusal removed the record'
  pass 'busy generation refusal retains the leased slot'
}

test_retirement_refusals_preserve_records() {
  local scenario
  for scenario in unfinished missing-report open-decision wrong-lease old-alive dirty-ship unlanded-ship unreadable-ship busy-drift; do
    make_collision "$scenario"
    case "$scenario" in
      unfinished) printf 'working: still working\n' > "$CASE/home/state/old.status" ;;
      missing-report) rm "$CASE/home/data/old/report.md" ;;
      open-decision) printf 'blocked [key=choice]: unresolved\ndone: finished\n' > "$CASE/home/state/old.status" ;;
      wrong-lease) perl -pi -e 's/"lease_holder": "live"/"lease_holder": "stranger"/' "$CASE/pool/treehouse-state.json" ;;
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
  pass 'unfinished, ambiguous, decision-held, and unlanded records refuse retirement'
}

test_retirement_closes_only_its_ticket_and_backlog() {
  make_collision atlas-close
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
case "$1 $2 $3" in
  'ticket show c1') printf '{"change":{"id":"c1","task":"old","state":"%s","node":"n1"}}\n' "$(cat "$CASE/ticket-state")" ;;
  'ticket complete c1')
    [ ! -e "$CASE/refuse-atlas" ] || { echo 'captain approval required' >&2; exit 1; }
    [ ! -e "$CASE/atlas-noop" ] || exit 0
    printf 'completed\n' > "$CASE/ticket-state" ;;
  *) echo 'unexpected Atlas mutation' >&2; exit 13 ;;
esac
SH
  chmod +x "$CASE/fakebin/atlas-axi"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$CASE/home/data/backlog.md"
  tasks-axi add old 'Finished scout' --kind scout --file "$CASE/home/data/backlog.md" >/dev/null
  tasks-axi start old --file "$CASE/home/data/backlog.md" >/dev/null
  : > "$CASE/refuse-atlas"
  if run_retire > "$CASE/out" 2> "$CASE/err"; then fail 'Atlas refusal must retain the active record'; fi
  assert_present "$CASE/home/state/old.meta" 'Atlas refusal removed the record'
  assert_contains "$(cat "$CASE/err")" 'Atlas completion refused' 'expected the Atlas gate'
  rm "$CASE/refuse-atlas"
  : > "$CASE/atlas-noop"
  if run_retire > "$CASE/out" 2> "$CASE/err"; then fail 'unconfirmed Atlas completion must retain the record'; fi
  assert_present "$CASE/home/state/old.meta" 'unconfirmed Atlas completion removed the record'
  rm "$CASE/atlas-noop"
  run_retire > "$CASE/out" 2> "$CASE/err" || fail "Atlas retry failed: $(cat "$CASE/err")"
  [ "$(cat "$CASE/ticket-state")" = completed ] || fail 'old Atlas leg remains started'
  assert_absent "$CASE/home/state/old.meta" 'old record remains active'
  assert_absent "$CASE/home/state/old.backlog-close" 'backlog close did not finish'
  assert_contains "$(tasks-axi show old --file "$CASE/home/data/backlog.md")" 'state: done' 'backlog item remains open'
  if grep -Eq 'release|land|c2' "$CASE/atlas-calls"; then fail 'retirement touched another Atlas leg or node'; fi
  pass 'Atlas refusal retains the record; retry closes only the old ticket and backlog'
}

test_retirement_preserves_landed_ship_ref_and_task_artifacts() {
  make_collision landed-ship
  perl -pi -e 's/kind=scout/kind=ship/' "$CASE/home/state/old.meta"
  rm "$WT/sentinel"
  printf 'old poll\n' > "$CASE/home/state/old.check.sh"
  printf 'live poll\n' > "$CASE/home/state/live.check.sh"
  local old_head
  old_head=$(git -C "$CASE/project" rev-parse fm/old)
  run_retire > "$CASE/out" 2> "$CASE/err" || fail "landed ship retirement failed: $(cat "$CASE/err")"
  [ "$(git -C "$CASE/project" rev-parse fm/old)" = "$old_head" ] || fail 'retirement deleted the old branch'
  assert_absent "$CASE/home/state/old.check.sh" 'retired check remains active'
  [ "$(cat "$CASE/home/data/old/retired-reassigned/old.check.sh")" = 'old poll' ] || fail 'retired check was not archived'
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

test_parent_gate_preserves_slot
test_retire_finished_scout_preserves_live_task
test_busy_generation_refusal_preserves_slot
test_retirement_refusals_preserve_records
test_retirement_closes_only_its_ticket_and_backlog
test_retirement_preserves_landed_ship_ref_and_task_artifacts
test_retirement_serializes_with_live_task_lifecycle
