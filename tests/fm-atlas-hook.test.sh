#!/usr/bin/env bash
# Behavior tests for bin/fm-atlas-hook.sh and the four fleet actions that call
# it, so the Atlas is written by the actor already holding the evidence.
#
# Every atlas-axi here is a mock that logs its arguments. Nothing in this file
# ever reaches a real Atlas repo, and no test writes outside its own temp root.
#
# Matrix:
#   Hook contract
#     (a) no config/specs pointer      -> no call at all, silent, exit 0
#     (b) atlas-axi not on PATH        -> no call at all, silent, exit 0
#     (c) no atlas_ticket= in the meta -> no call at all, silent, exit 0
#     (c2) a path-escaping task id     -> refused before any call, exit 0
#     (d) start   -> ticket start --to fm-<id> --task <id>, stamped --by
#     (d2) start with fm-prefixed id -> holder is the id as-is, no fm-fm- doubling
#     (e) complete on a started ticket -> restage, then ticket complete
#     (f) complete on a completed one  -> no second completion
#     (g) land with no open ticket     -> complete, release, land
#     (h) land with an open ticket     -> complete and release, never land
#     (i) a failing atlas-axi          -> exit 0 and exactly one warning line
#     (j) a hanging atlas-axi          -> bounded by the timeout, exit 0
#   Callers survive a broken Atlas
#     (k) fm-merge-local still merges and exits 0
#     (l) fm-pr-merge still merges and exits 0
#     (m) fm-teardown still tears the task down and exits 0
#     (m2) fm-spawn still launches and still records the ticket
#   Callers record the fact when the Atlas works
#     (n) fm-spawn --ticket records atlas_ticket= and starts the ticket
#     (o) fm-spawn without --ticket writes no atlas_ticket= and makes no call
#     (p) fm-merge-local discharges the ticket with its own before..after range
#     (q) fm-pr-merge discharges the ticket with the PR URL
#     (r) fm-teardown completes, releases, and lands after proving the landing
#     (s) fm-teardown --force records nothing when it is discarding real work
#     (v) abort returns a dead dispatch's ticket to the queue, and demands a reason
#     (w) state reads the recorded ticket's state back, silently or not at all
#     (x) fm-teardown aborts a leg that produced nothing, forced or not
#     (y) fm-teardown never aborts a ticket a merge or crewmate already closed
#   Flag validation
#     (t) --ticket refused for --secondmate and for batch id=repo dispatch
#     (u) a malformed --ticket is refused before the spawn starts
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

HOOK="$ROOT/bin/fm-atlas-hook.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-atlas-hook)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- mock Atlas -------------------------------------------------------------
#
# One atlas-axi stand-in for every case. It appends the arguments of each call
# to $FM_FAKE_ATLAS_LOG, one call per line, and answers the two read verbs the
# hook uses from files the test writes:
#   $FM_FAKE_ATLAS_TICKET_JSON  what `ticket show <c> --json` returns
#   $FM_FAKE_ATLAS_LIST_JSON    what `ticket list <node> --json` returns
# FM_FAKE_ATLAS_FAIL makes every mutation verb fail, FM_FAKE_ATLAS_HANG makes
# every call sleep past the hook's timeout.
write_atlas_mock() {  # <fakebin>
  cat > "$1/atlas-axi" <<'SH'
#!/usr/bin/env bash
set -u
# Strip the two global flags the hook always passes so the logged line is the
# verb and its own arguments; log the actor and repo separately so both stay
# assertable.
logged=()
skip=
actor=
repo=
for a in "$@"; do
  case "$skip" in
    by) actor=$a; skip=; continue ;;
    repo) repo=$a; skip=; continue ;;
  esac
  case "$a" in
    --by) skip=by; continue ;;
    --repo) skip=repo; continue ;;
  esac
  logged+=("$a")
done
[ -z "${FM_FAKE_ATLAS_LOG:-}" ] || printf 'by=%s repo=%s %s\n' "$actor" "$repo" "${logged[*]}" >> "$FM_FAKE_ATLAS_LOG"
if [ "${FM_FAKE_ATLAS_HANG:-0}" = 1 ]; then
  sleep 30
fi
case "${logged[0]:-} ${logged[1]:-}" in
  "ticket show")
    cat "$FM_FAKE_ATLAS_TICKET_JSON"
    exit 0
    ;;
  "ticket list")
    cat "$FM_FAKE_ATLAS_LIST_JSON"
    exit 0
    ;;
esac
if [ "${FM_FAKE_ATLAS_FAIL:-0}" = 1 ]; then
  echo "atlas-axi: the store is unavailable" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$1/atlas-axi"
}

# A home wired to an Atlas, with one ticketed task recorded. Echoes the home.
make_home() {  # <name> [ticket] [ticket-state] [open-tickets-json]
  local name=$1 ticket=${2:-c7} state=${3:-started} open=${4:-'[]'}
  local home fakebin
  home="$TMP_ROOT/$name"
  fakebin="$home/fakebin"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/specs/atlas" "$fakebin"
  printf '%s\n' "$home/specs" > "$home/config/specs"
  write_atlas_mock "$fakebin"
  cat > "$home/ticket.json" <<EOF
{"change":{"id":"$ticket","state":"$state","node":"n42","nodePath":"demo/thing"}}
EOF
  printf '%s\n' "$open" > "$home/open.json"
  : > "$home/atlas.log"
  fm_write_meta "$home/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "atlas_ticket=$ticket"
  printf '%s\n' "$home"
}

run_hook() {  # <home> <hook args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_ATLAS_LOG="$home/atlas.log" \
    FM_FAKE_ATLAS_TICKET_JSON="$home/ticket.json" \
    FM_FAKE_ATLAS_LIST_JSON="$home/open.json" \
    FM_FAKE_ATLAS_FAIL="${FM_FAKE_ATLAS_FAIL:-0}" \
    FM_FAKE_ATLAS_HANG="${FM_FAKE_ATLAS_HANG:-0}" \
    PATH="$home/fakebin:$PATH" \
    "$HOOK" "$@"
}

atlas_log_has() {  # <home> <fixed string> <msg>
  grep -F -- "$2" "$1/atlas.log" >/dev/null || {
    fail "$3"$'\n'"--- atlas calls ---"$'\n'"$(cat "$1/atlas.log")"
  }
}

atlas_log_lacks() {  # <home> <fixed string> <msg>
  ! grep -F -- "$2" "$1/atlas.log" >/dev/null || {
    fail "$3"$'\n'"--- atlas calls ---"$'\n'"$(cat "$1/atlas.log")"
  }
}

atlas_log_empty() {  # <home> <msg>
  [ ! -s "$1/atlas.log" ] || {
    fail "$2"$'\n'"--- atlas calls ---"$'\n'"$(cat "$1/atlas.log")"
  }
}

# --- (a)(b)(c) the three silent skips ---------------------------------------

test_silent_skips() {
  local home rc out

  home=$(make_home no-specs)
  rm -f "$home/config/specs"
  set +e
  out=$(run_hook "$home" start task-a1 --actor fm-spawn 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "no-specs: the hook must not fail its caller"
  [ -z "$out" ] || fail "no-specs: an unwired home must stay silent, got: $out"
  atlas_log_empty "$home" "no-specs: an unwired home must make no Atlas call"

  home=$(make_home no-atlas-axi)
  rm -f "$home/fakebin/atlas-axi"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_ATLAS_LOG="$home/atlas.log" \
    PATH="$home/fakebin:$(fm_test_core_path)" \
    "$HOOK" start task-a1 --actor fm-spawn 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "no-atlas-axi: the hook must not fail its caller"
  [ -z "$out" ] || fail "no-atlas-axi: a home without the tool must stay silent, got: $out"

  home=$(make_home no-ticket)
  fm_write_meta "$home/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" "worktree=$home/wt" "kind=ship"
  set +e
  out=$(run_hook "$home" land task-a1 --evidence proof 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "no-ticket: the hook must not fail its caller"
  [ -z "$out" ] || fail "no-ticket: an unticketed task must stay silent, got: $out"
  atlas_log_empty "$home" "no-ticket: an unticketed task must make no Atlas call"

  pass "the hook is a silent no-op with no Atlas pointer, no atlas-axi, or no recorded ticket"
}

# The task id becomes a state path and an Atlas crew name, so a caller bug must
# stop at the hook rather than reach another home's records.
test_unusable_task_id_is_refused() {
  local home rc out
  home=$(make_home bad-id)
  set +e
  out=$(run_hook "$home" land '../../elsewhere/task-a1' --evidence proof 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "bad id: the hook must still exit 0"
  assert_contains "$out" 'atlas-hook: land called with an unusable task id' \
    "bad id: a path-escaping task id was not refused"
  atlas_log_empty "$home" "bad id: no Atlas call may be made for an unusable task id"
  pass "a task id that could escape this home's records is refused before any Atlas call"
}

# --- (d) start --------------------------------------------------------------

test_start_records_the_holder() {
  local home rc
  home=$(make_home start-ok)
  set +e
  run_hook "$home" start task-a1 --actor fm-spawn >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "start: the hook must exit 0"
  atlas_log_has "$home" 'ticket start c7 --to fm-task-a1 --task task-a1' \
    "start: the ticket was not started against this task's own crew"
  atlas_log_has "$home" 'by=fm-spawn' "start: the calling script was not stamped as the author"
  atlas_log_has "$home" "repo=$home/specs" "start: the Atlas repo from config/specs was not used"
  pass "start tells the Atlas the recorded ticket is being worked by this task's crew"
}

# --- (d2) start with an already-prefixed task id ----------------------------

test_start_prefixed_id_no_double_prefix() {
  local home rc
  home=$(make_home start-prefixed)
  fm_write_meta "$home/state/fm-upstream-m1.meta" \
    "window=firstmate:fm-upstream-m1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "atlas_ticket=c7"
  set +e
  run_hook "$home" start fm-upstream-m1 --actor fm-spawn >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "start-prefixed: the hook must exit 0"
  atlas_log_has "$home" 'ticket start c7 --to fm-upstream-m1 --task fm-upstream-m1' \
    "start-prefixed: a prefixed task id must not be doubled to fm-fm-upstream-m1"
  atlas_log_lacks "$home" 'fm-fm-upstream-m1' \
    "start-prefixed: the holder must not carry a doubled fm-fm- prefix"
  pass "start with an fm-prefixed task id records the holder as the id itself, no doubling"
}

# --- (e)(f) complete --------------------------------------------------------

test_complete_restages_then_completes() {
  local home rc
  home=$(make_home complete-started)
  set +e
  run_hook "$home" complete task-a1 --actor fm-pr-merge --restage merge \
    --evidence 'https://example.invalid/pull/3' --summary 'merged' >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "complete: the hook must exit 0"
  atlas_log_has "$home" 'restage n42 merge' "complete: the node was not restaged to merge"
  atlas_log_has "$home" 'ticket complete c7 --evidence https://example.invalid/pull/3 --summary merged' \
    "complete: the ticket was not completed with the merge evidence"
  pass "complete restages the node and discharges the ticket with the caller's evidence"
}

test_complete_leaves_a_completed_ticket_alone() {
  local home
  home=$(make_home complete-already completed completed)
  set +e
  run_hook "$home" complete task-a1 --actor fm-pr-merge --restage merge \
    --evidence proof --summary 'already closed' >/dev/null 2>&1
  set -e
  atlas_log_lacks "$home" 'ticket complete' \
    "already completed: the crewmate's own completion must not be overwritten"
  atlas_log_lacks "$home" 'restage' \
    "already completed: a closed ticket's node must not be restaged"
  pass "complete is a no-op on a ticket the crewmate already completed"
}

# --- (g)(h) land ------------------------------------------------------------

test_land_completes_releases_and_lands() {
  local home rc
  home=$(make_home land-clear)
  set +e
  run_hook "$home" land task-a1 --actor fm-teardown --evidence 'landed on main' \
    --summary 'torn down after landing' >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "land: the hook must exit 0"
  atlas_log_has "$home" 'ticket complete c7 --evidence landed on main' \
    "land: the ticket was not completed"
  atlas_log_has "$home" 'release n42' "land: the node was not released"
  atlas_log_has "$home" 'land n42 --evidence landed on main' "land: the node was not landed"
  pass "land completes the ticket, releases the node, and lands it when nothing else is open"
}

test_land_holds_back_while_a_ticket_is_open() {
  local home
  home=$(make_home land-blocked c7 started '[{"id":"c8","state":"queued"}]')
  set +e
  run_hook "$home" land task-a1 --actor fm-teardown --evidence 'landed on main' >/dev/null 2>&1
  set -e
  atlas_log_has "$home" 'ticket complete c7' "open ticket: this task's own ticket must still complete"
  atlas_log_has "$home" 'release n42' "open ticket: the node must still be released"
  atlas_log_lacks "$home" 'land n42' \
    "open ticket: a node with work still queued on it must not be landed"
  pass "land releases the node but leaves it unlanded while another ticket is still open"
}

# --- (v)(w) abort and state ------------------------------------------------

test_abort_returns_the_ticket_to_the_queue() {
  local home rc
  home=$(make_home abort-started)
  set +e
  run_hook "$home" abort task-a1 --actor fm-teardown \
    --reason 'the dispatch died before producing work' >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "abort: the hook must exit 0"
  atlas_log_has "$home" 'ticket abort c7 the dispatch died before producing work' \
    "abort: the ticket was not returned to the queue with the reason that killed the dispatch"
  atlas_log_lacks "$home" 'ticket complete' \
    "abort: a dispatch that produced nothing must never be recorded as completed"
  atlas_log_lacks "$home" 'land n42' \
    "abort: a dispatch that produced nothing must never land its node"
  pass "abort returns the ticket to the queue with the reason, and claims nothing about the work"
}

test_abort_demands_a_reason() {
  local home rc out
  home=$(make_home abort-no-reason)
  set +e
  out=$(run_hook "$home" abort task-a1 --actor fm-teardown 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "abort: a missing reason must not fail the caller"
  assert_contains "$out" 'atlas-hook: abort called for task-a1 with no --reason' \
    "abort: a reasonless abort was not refused"
  atlas_log_empty "$home" "abort: no Atlas call may be made without a reason"
  pass "abort refuses without the reason the act is made of"
}

test_state_reports_the_recorded_ticket_state() {
  local home out
  home=$(make_home state-started)
  out=$(run_hook "$home" state task-a1 2>/dev/null)
  [ "$out" = started ] || fail "state: expected 'started', got: $out"
  home=$(make_home state-completed c7 completed)
  out=$(run_hook "$home" state task-a1 2>/dev/null)
  [ "$out" = completed ] || fail "state: expected 'completed', got: $out"
  home=$(make_home state-unwired)
  rm -f "$home/config/specs"
  out=$(run_hook "$home" state task-a1 2>/dev/null)
  [ -z "$out" ] || fail "state: an unwired home must print nothing, got: $out"
  pass "state reads back the recorded ticket's state, and prints nothing when there is none"
}

# --- (i)(j) a broken Atlas never blocks -------------------------------------

test_failing_atlas_warns_once_and_exits_zero() {
  local home rc out lines
  home=$(make_home atlas-fails)
  set +e
  out=$(FM_FAKE_ATLAS_FAIL=1 run_hook "$home" start task-a1 --actor fm-spawn 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "failing atlas: the hook must still exit 0"
  assert_contains "$out" 'atlas-hook: ticket start failed for task-a1' \
    "failing atlas: the failure was not reported"
  assert_contains "$out" 'the map was not updated' \
    "failing atlas: the consequence was not stated"
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" = 1 ] || fail "failing atlas: expected exactly one warning line, got $lines:"$'\n'"$out"
  pass "a failing Atlas produces one warning line and never a non-zero exit"
}

test_hanging_atlas_is_bounded_by_the_timeout() {
  local home rc started elapsed
  command -v timeout >/dev/null 2>&1 || { pass "hanging atlas: skipped, no timeout(1)"; return 0; }
  home=$(make_home atlas-hangs)
  started=$(date +%s)
  set +e
  FM_FAKE_ATLAS_HANG=1 FM_ATLAS_HOOK_TIMEOUT_SECS=1 \
    run_hook "$home" start task-a1 --actor fm-spawn >/dev/null 2>&1
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "hanging atlas: the hook must still exit 0"
  [ "$elapsed" -lt 15 ] || fail "hanging atlas: the call was not bounded (took ${elapsed}s)"
  pass "a wedged Atlas is bounded by the hook timeout instead of stalling the caller"
}

# --- (k)(p) fm-merge-local --------------------------------------------------

# A local-only project with an fm/<id> branch ready to fast-forward into main.
make_merge_local_case() {  # <name> [ticket-lines...]
  local name=$1 home proj
  shift
  home=$(make_home "$name")
  proj="$home/project"
  fm_git_init_commit "$proj"
  git -C "$proj" checkout -q -b fm/task-a1
  printf 'change\n' > "$proj/change.txt"
  git -C "$proj" add change.txt
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm change
  git -C "$proj" checkout -q main 2>/dev/null || git -C "$proj" checkout -q master
  fm_write_meta "$home/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" \
    "worktree=$proj" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only" \
    "$@"
  printf '%s\n' "$home"
}

run_merge_local() {  # <home>
  local home=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_ATLAS_LOG="$home/atlas.log" \
    FM_FAKE_ATLAS_TICKET_JSON="$home/ticket.json" \
    FM_FAKE_ATLAS_LIST_JSON="$home/open.json" \
    FM_FAKE_ATLAS_FAIL="${FM_FAKE_ATLAS_FAIL:-0}" \
    PATH="$home/fakebin:$PATH" \
    "$MERGE_LOCAL" task-a1
}

test_merge_local_discharges_the_ticket() {
  local home rc out
  home=$(make_merge_local_case merge-local-ok atlas_ticket=c7)
  set +e
  out=$(run_merge_local "$home" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-local: the merge must succeed"
  assert_contains "$out" 'merged fm/task-a1 into local' "merge-local: the merge was not reported"
  atlas_log_has "$home" 'by=fm-merge-local' "merge-local: the merge script was not stamped as the author"
  atlas_log_has "$home" 'ticket complete c7 --evidence ' \
    "merge-local: the ticket was not discharged with the merge evidence"
  grep -F 'ticket complete c7' "$home/atlas.log" | grep -Eq '\.\.[0-9a-f]+ on (main|master)' \
    || fail "merge-local: the evidence did not carry the before..after range this script computed"$'\n'"$(cat "$home/atlas.log")"
  pass "fm-merge-local discharges the task's ticket with the shas it already computed"
}

test_merge_local_survives_a_broken_atlas() {
  local home rc out before after
  home=$(make_merge_local_case merge-local-broken atlas_ticket=c7)
  before=$(git -C "$home/project" rev-parse HEAD)
  set +e
  out=$(FM_FAKE_ATLAS_FAIL=1 run_merge_local "$home" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-local: a broken Atlas must not fail the merge"
  after=$(git -C "$home/project" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "merge-local: the fast-forward did not happen"
  assert_contains "$out" 'merged fm/task-a1 into local' \
    "merge-local: the merge outcome must still be reported"
  assert_contains "$out" 'atlas-hook:' "merge-local: the Atlas failure must still be reported"
  pass "fm-merge-local still merges and exits 0 when the Atlas is broken"
}

# --- (l)(q) fm-pr-merge -----------------------------------------------------

make_pr_merge_case() {  # <name> [meta-lines...]
  local home fakebin
  home=$(make_home "$1")
  shift
  fakebin="$home/fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
exit 0
SH
  # fm-pr-merge reads the live outcome back after gh-axi returns and refuses
  # any merge it cannot prove, so the fake forge has to answer that read.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  : > "$home/gh.log"
  fm_write_meta "$home/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "$@"
  printf '%s\n' "$home"
}

run_pr_merge() {  # <home>
  local home=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_ATLAS_LOG="$home/atlas.log" \
    FM_FAKE_ATLAS_TICKET_JSON="$home/ticket.json" \
    FM_FAKE_ATLAS_LIST_JSON="$home/open.json" \
    FM_FAKE_ATLAS_FAIL="${FM_FAKE_ATLAS_FAIL:-0}" \
    FM_FAKE_GH_LOG="$home/gh.log" \
    PATH="$home/fakebin:$PATH" \
    "$PR_MERGE" task-a1 https://github.com/example/repo/pull/9
}

test_pr_merge_discharges_the_ticket() {
  local home rc
  home=$(make_pr_merge_case pr-merge-ok atlas_ticket=c7)
  set +e
  run_pr_merge "$home" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "pr-merge: the merge must succeed"
  atlas_log_has "$home" 'by=fm-pr-merge' "pr-merge: the merge script was not stamped as the author"
  atlas_log_has "$home" 'ticket complete c7 --evidence https://github.com/example/repo/pull/9' \
    "pr-merge: the ticket was not discharged with the PR URL"
  pass "fm-pr-merge discharges the task's ticket with the PR URL it already holds"
}

test_pr_merge_survives_a_broken_atlas() {
  local home rc out
  home=$(make_pr_merge_case pr-merge-broken atlas_ticket=c7)
  set +e
  out=$(FM_FAKE_ATLAS_FAIL=1 run_pr_merge "$home" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "pr-merge: a broken Atlas must not fail the merge"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$home/gh.log" \
    || fail "pr-merge: the merge itself did not happen"$'\n'"$(cat "$home/gh.log")"
  assert_contains "$out" 'atlas-hook:' "pr-merge: the Atlas failure must still be reported"
  pass "fm-pr-merge still merges and exits 0 when the Atlas is broken"
}

# --- (m)(r)(s)(x)(y) fm-teardown ------------------------------------------

# A ship task whose leg PRODUCED work and pushed it, so teardown's landed-work
# proof passes on real commits rather than vacuously. That proof is exactly the
# precondition the Atlas close-out rides on.
make_teardown_case() {  # <name> [meta-lines...]
  local home wt
  home=$(make_home "$1")
  shift
  wt="$home/wt"
  fm_fake_exit0 "$home/fakebin" tmux treehouse no-mistakes gh
  fm_git_worktree "$home/project" "$wt" fm/task-a1
  printf 'the work this leg produced\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" commit -qm 'the leg produced this'
  git -C "$wt" push -q origin fm/task-a1
  fm_write_meta "$home/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" \
    "endpoint_task_id=task-a1" \
    "worktree=$wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=local-only" \
    "$@"
  printf 'done: merged into the local default branch\n' > "$home/state/task-a1.status"
  printf '%s\n' "$home"
}

run_teardown() {  # <home> [extra args]
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_ATLAS_LOG="$home/atlas.log" \
    FM_FAKE_ATLAS_TICKET_JSON="$home/ticket.json" \
    FM_FAKE_ATLAS_LIST_JSON="$home/open.json" \
    FM_FAKE_ATLAS_FAIL="${FM_FAKE_ATLAS_FAIL:-0}" \
    PATH="$home/fakebin:$PATH" \
    "$TEARDOWN" task-a1 "$@"
}

test_teardown_closes_out_the_ticket() {
  local home rc
  home=$(make_teardown_case teardown-ok atlas_ticket=c7)
  set +e
  run_teardown "$home" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown: cleanup must succeed"
  atlas_log_has "$home" 'by=fm-teardown' "teardown: cleanup was not stamped as the author"
  atlas_log_has "$home" 'ticket complete c7' "teardown: the ticket was not completed"
  atlas_log_has "$home" 'release n42' "teardown: the node was not released"
  atlas_log_has "$home" 'land n42 --evidence task task-a1 landed on the project' \
    "teardown: the node was not landed with the landing teardown had just proved"
  assert_absent "$home/state/task-a1.meta" "teardown: the task record should be gone afterwards"
  pass "fm-teardown closes out the ticket at the point it has already proved the landing"
}

test_teardown_force_records_nothing() {
  local home
  home=$(make_teardown_case teardown-force atlas_ticket=c7)
  # Unlanded work: cleanup refuses without --force, so --force here is a discard.
  printf 'scratch\n' > "$home/wt/scratch.txt"
  git -C "$home/wt" add scratch.txt
  git -C "$home/wt" -c user.name=t -c user.email=t@example.invalid commit -qm scratch
  set +e
  run_teardown "$home" --force >/dev/null 2>&1
  set -e
  atlas_log_empty "$home" \
    "forced teardown: a discard proves nothing and must not be recorded as landed"
  pass "a forced teardown records nothing, because it has proved nothing"
}

# A leg that produced NOTHING: the same shape, minus the work commit. Its
# landed-work proof passes vacuously - there is nothing to fail - which is
# exactly the case that must never be recorded as shipped ground.
make_teardown_empty_case() {  # <name> [meta-lines...]
  local home wt
  home=$(make_home "$1")
  shift
  wt="$home/wt"
  fm_fake_exit0 "$home/fakebin" tmux treehouse no-mistakes gh
  fm_git_worktree "$home/project" "$wt" fm/task-a1
  fm_write_meta "$home/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" \
    "endpoint_task_id=task-a1" \
    "worktree=$wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=local-only" \
    "$@"
  printf 'working: launched\n' > "$home/state/task-a1.status"
  printf '%s\n' "$home"
}

test_teardown_aborts_a_leg_that_produced_nothing() {
  local home rc
  home=$(make_teardown_empty_case teardown-empty atlas_ticket=c7)
  set +e
  run_teardown "$home" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "empty leg: cleanup must succeed"
  atlas_log_has "$home" 'ticket abort c7' \
    "empty leg: the ticket was not returned to the queue"
  atlas_log_has "$home" 'with no work produced' \
    "empty leg: the abort did not say what killed the dispatch"
  atlas_log_lacks "$home" 'ticket complete' \
    "empty leg: a dispatch that produced nothing must never be completed"
  atlas_log_lacks "$home" 'land n42' \
    "empty leg: a dispatch that produced nothing must never land its node"
  pass "cleanup of a leg that produced nothing aborts the ticket instead of claiming it landed"
}

test_teardown_force_aborts_a_killed_dispatch() {
  local home rc
  home=$(make_teardown_empty_case teardown-killed atlas_ticket=c7)
  set +e
  run_teardown "$home" --force >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "killed dispatch: cleanup must succeed"
  atlas_log_has "$home" 'ticket abort c7' \
    "killed dispatch: a spawn that died with no work must return its ticket to the queue"
  atlas_log_lacks "$home" 'ticket complete' \
    "killed dispatch: a killed dispatch must never be recorded as completed"
  pass "a forced cleanup of a killed dispatch that produced nothing aborts its ticket with the reason"
}

test_teardown_leaves_an_already_discharged_ticket_alone() {
  local home
  home=$(make_teardown_empty_case teardown-discharged atlas_ticket=c7)
  printf '%s\n' '{"change":{"id":"c7","state":"completed","node":"n42","nodePath":"demo/thing"}}' \
    > "$home/ticket.json"
  set +e
  run_teardown "$home" >/dev/null 2>&1
  set -e
  atlas_log_lacks "$home" 'ticket abort' \
    "discharged ticket: work a merge already closed out must never be re-queued as a dead dispatch"
  atlas_log_has "$home" 'release n42' "discharged ticket: the node was not released"
  atlas_log_has "$home" 'land n42' "discharged ticket: the node was not landed"
  pass "cleanup never aborts a ticket a crewmate or a merge already discharged"
}

test_teardown_survives_a_broken_atlas() {
  local home rc out
  home=$(make_teardown_case teardown-broken atlas_ticket=c7)
  set +e
  out=$(FM_FAKE_ATLAS_FAIL=1 run_teardown "$home" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown: a broken Atlas must not fail cleanup"
  assert_absent "$home/state/task-a1.meta" "teardown: cleanup must still remove the task record"
  assert_contains "$out" 'atlas-hook:' "teardown: the Atlas failure must still be reported"
  pass "fm-teardown still tears the task down and exits 0 when the Atlas is broken"
}

# --- (n)(o)(t)(u) fm-spawn --ticket -----------------------------------------

# A full spawn against a fake tmux and a real isolated git worktree, the same
# shape tests/fm-trace-context-spawn.test.sh uses to observe recorded metadata.
make_spawn_case() {  # <name>
  local name=$1 home proj wt fakebin
  home=$(make_home "$name")
  proj="$home/project"
  wt="$home/wt"
  fakebin="$home/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/projects" "$home/data/task-a1"
  printf 'brief for task-a1\n' > "$home/data/task-a1/brief.md"
  rm -f "$home/state/task-a1.meta"
  fm_git_worktree "$proj" "$wt" wt-spawn
  printf '%s\n' "$home"
}

run_spawn() {  # <home> <spawn args...>
  local home=$1
  shift
  env -u FM_TRACE_CONTEXT FM_BACKEND=tmux \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$home/wt" TMUX="fake,1,0" \
    FM_FAKE_ATLAS_LOG="$home/atlas.log" \
    FM_FAKE_ATLAS_TICKET_JSON="$home/ticket.json" \
    FM_FAKE_ATLAS_LIST_JSON="$home/open.json" \
    FM_FAKE_ATLAS_FAIL="${FM_FAKE_ATLAS_FAIL:-0}" \
    PATH="$home/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_survives_a_broken_atlas() {
  local home out rc
  home=$(make_spawn_case spawn-broken)
  set +e
  out=$(FM_FAKE_ATLAS_FAIL=1 run_spawn "$home" task-a1 "$home/project" \
    --scout --harness claude --ticket c7)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn: a broken Atlas must not fail the spawn"$'\n'"$out"
  assert_grep 'atlas_ticket=c7' "$home/state/task-a1.meta" \
    "spawn: the ticket must still be recorded when the Atlas is broken"
  assert_contains "$out" 'atlas-hook:' "spawn: the Atlas failure must still be reported"
  assert_contains "$out" 'spawned task-a1 ' "spawn: the spawn outcome must still be reported"
  pass "fm-spawn still launches the worker and records the ticket when the Atlas is broken"
}

test_spawn_ticket_is_recorded_and_started() {
  local home out rc
  home=$(make_spawn_case spawn-ticket)
  set +e
  out=$(run_spawn "$home" task-a1 "$home/project" --scout --harness claude --ticket c7)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn: the ticketed spawn must succeed"$'\n'"$out"
  assert_grep 'atlas_ticket=c7' "$home/state/task-a1.meta" \
    "spawn: the ticket was not recorded in the task's durable record"
  atlas_log_has "$home" 'ticket start c7 --to fm-task-a1 --task task-a1' \
    "spawn: the ticket was not started against the new crew"
  atlas_log_has "$home" 'by=fm-spawn' "spawn: the spawn was not stamped as the author"
  pass "a spawn with --ticket records the ticket and tells the Atlas its crew is working it"
}

test_spawn_without_ticket_touches_nothing() {
  local home out rc
  home=$(make_spawn_case spawn-no-ticket)
  set +e
  out=$(run_spawn "$home" task-a1 "$home/project" --scout --harness claude)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn: an unticketed spawn must still succeed"$'\n'"$out"
  assert_no_grep 'atlas_ticket=' "$home/state/task-a1.meta" \
    "spawn: an unticketed task must record no ticket"
  atlas_log_empty "$home" "spawn: an unticketed spawn must make no Atlas call"
  pass "a spawn without --ticket is unchanged: no recorded ticket and no Atlas call"
}

test_spawn_refuses_bad_ticket_uses() {
  local home out

  home=$(make_spawn_case spawn-bad-ticket)
  out=$(run_spawn "$home" task-a1 "$home/project" --scout --harness claude --ticket 'c7; rm -rf /' || true)
  assert_contains "$out" 'error: --ticket must be an Atlas ticket id' \
    "spawn: a malformed ticket id was not refused"

  out=$(run_spawn "$home" second-a2 "$home/project" --secondmate --ticket c7 || true)
  assert_contains "$out" 'error: --ticket applies to crewmate and scout spawns' \
    "spawn: --ticket on a secondmate was not refused"

  out=$(run_spawn "$home" a-z1="$home/project" b-z2="$home/project" \
    --scout --harness claude --ticket c7 || true)
  assert_contains "$out" 'error: --ticket is not supported for batch id=repo dispatch' \
    "spawn: a shared --ticket across a batch was not refused"

  pass "--ticket is refused when malformed, on a secondmate, and across a batch"
}

# `wired` is the read-only home query fm-spawn's ticket-less warning branches on,
# so it must answer the pointer alone: the repo path when the home is wired,
# nothing at all when it is not, and never a task-scoped call.
test_wired_reports_the_home_pointer() {
  local home out

  home=$(make_home wired-yes)
  out=$(run_hook "$home" wired)
  assert_contains "$out" "$home/specs" "wired did not print the resolved Atlas repo for a wired home"
  atlas_log_empty "$home" "wired must be a pure query and call the Atlas for nothing"

  # Same home with its pointer removed: the query goes quiet rather than failing.
  rm -f "$home/config/specs"
  out=$(run_hook "$home" wired)
  [ -z "$out" ] || fail "wired must print nothing for a home with no Atlas pointer; got '$out'"

  # A pointer to a directory holding no atlas/ is not wiring either.
  mkdir -p "$home/not-an-atlas"
  printf '%s\n' "$home/not-an-atlas" > "$home/config/specs"
  out=$(run_hook "$home" wired)
  [ -z "$out" ] || fail "a pointer with no atlas/ must not read as wired; got '$out'"

  pass "wired answers the home's Atlas pointer and calls nothing"
}

test_silent_skips
test_wired_reports_the_home_pointer
test_unusable_task_id_is_refused
test_start_records_the_holder
test_start_prefixed_id_no_double_prefix
test_complete_restages_then_completes
test_complete_leaves_a_completed_ticket_alone
test_land_completes_releases_and_lands
test_land_holds_back_while_a_ticket_is_open
test_abort_returns_the_ticket_to_the_queue
test_abort_demands_a_reason
test_state_reports_the_recorded_ticket_state
test_failing_atlas_warns_once_and_exits_zero
test_hanging_atlas_is_bounded_by_the_timeout
test_merge_local_discharges_the_ticket
test_merge_local_survives_a_broken_atlas
test_pr_merge_discharges_the_ticket
test_pr_merge_survives_a_broken_atlas
test_teardown_closes_out_the_ticket
test_teardown_force_records_nothing
test_teardown_aborts_a_leg_that_produced_nothing
test_teardown_force_aborts_a_killed_dispatch
test_teardown_leaves_an_already_discharged_ticket_alone
test_teardown_survives_a_broken_atlas
test_spawn_ticket_is_recorded_and_started
test_spawn_survives_a_broken_atlas
test_spawn_without_ticket_touches_nothing
test_spawn_refuses_bad_ticket_uses
