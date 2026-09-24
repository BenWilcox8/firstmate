#!/usr/bin/env bash
# Behavior tests for the Atlas captain gate as the fleet meets it: a refused
# close-out still releases the node and leaves one keyed status line that wakes
# the supervisor, the captain's exact words become the Atlas approval, and every
# worker is launched able to reach the Atlas under its own author name.
#
# Every scenario runs against a temporary Atlas store that enforces the captain
# gate. Two stores are used when they are available:
#   mock  a small stateful stand-in, always present, that refuses the way the
#         real store does, so the portable lanes cover every scenario;
#   real  the installed atlas-axi against a fresh git repo under this test's
#         own temp root, when atlas-axi is on PATH and can open such a repo.
# Neither ever touches a real Atlas: every call names its temp repo, the
# ambient Atlas environment is cleared below, and HOME points into the temp root.
#
# Matrix (each hook and caller row runs once per available store):
#   Hook
#     (a) complete refused for the captain's approval -> node released, one
#         keyed status line naming the ticket and the gate, ticket left open
#     (b) complete refused for a testing brief        -> the line names that gate
#     (c) complete with --captain-word                -> approval carries the
#         exact words and the actor, the ticket completes, no status line
#     (d) land refused                                -> released, never landed,
#         one status line
#     (e) land with --defer-status                    -> the line is printed for
#         the caller and the status log is left alone
#   Callers, end to end
#     (f) fm-pr-merge refused    -> merge still lands and exits 0, status line
#     (g) fm-pr-merge with --captain-word -> ticket approved and completed
#     (h) fm-merge-local with --captain-word -> ticket approved and completed
#     (i) fm-teardown refused    -> cleanup succeeds, node released, and the
#         status line outlives the task's retired records
#     (j) fm-teardown with --captain-word -> ticket completed, node landed
#     (k) an empty --captain-word is refused before anything happens
#   Worker environment
#     (l) a wired spawn replaces ambient Atlas values with this home's values
#     (m) an unwired spawn clears every ambient Atlas value
#     (n) a relaunch exports wired Atlas values again
#     (o) a relaunch keeps the recorded ticket in its launch brief, and a
#         relaunch refuses a new --ticket
#     (p) a fresh ticket-less spawn over an older ticketed record gets no
#         ticket: no crewmate fragment, the dispatch warning, no recorded ticket
#     (q) with the filtered launch environment, a secondmate still receives the
#         Atlas values its pane shell holds
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# No ambient Atlas may leak into a fixture or a caller.
unset ATLAS_REPO SPECS_REPO ATLAS_AXI_BY SPEC_AXI_ACTOR ATLAS_AXI_DASH

HOOK="$ROOT/bin/fm-atlas-hook.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-atlas-gate)
TASK_TMPS=()

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

gate_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_cleanup
}
trap gate_cleanup EXIT

# --- the two stores ---------------------------------------------------------

MOCK_BIN="$TMP_ROOT/store-mock"
REAL_BIN="$TMP_ROOT/store-real"
mkdir -p "$MOCK_BIN" "$REAL_BIN"

# A stateful Atlas stand-in. It keeps one JSON file per ticket and per node
# under <repo>/atlas/mock/ and answers the verbs the fleet uses in the shapes
# the real store prints. It refuses exactly where the real store refuses:
#   - a ticket reviewed by the captain (review human or adversarial-then-human)
#     cannot move to merge, be completed, or be landed until it is approved;
#   - a ticket with captain-review on its path and a captain surface other than
#     `none` cannot be completed without a testing brief.
cat > "$MOCK_BIN/atlas-axi" <<'SH'
#!/usr/bin/env bash
set -u
repo=${ATLAS_REPO:-}
by=${ATLAS_AXI_BY:-cli}
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --by) by=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
die() { printf 'atlas-axi: %s\n' "$*" >&2; exit 1; }
[ -n "$repo" ] || die "no atlas repo configured"
db="$repo/atlas/mock"
[ -d "$db" ] || die "no Atlas store at $repo"
set -- "${args[@]}"
printf '%s %s\n' "$by" "$*" >> "$db/log"

opt() {  # <flag> <args...> -> the flag's value
  local want=$1 prev=
  shift
  for a in "$@"; do
    [ "$prev" = "$want" ] && { printf '%s' "$a"; return 0; }
    prev=$a
  done
  return 1
}
upd() {  # <file> <jq args...>
  local f=$1
  shift
  [ -f "$f" ] || exit 1
  jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
ticket_file() {
  [ -f "$db/$1.json" ] || die "no ticket $1"
  printf '%s' "$db/$1.json"
}
node_file() {
  local f
  for f in "$db"/n*.json; do
    jq -e --arg r "$1" '.id == $r or .path_ == $r' "$f" >/dev/null && { printf '%s' "$f"; return 0; }
  done
  die "no node $1"
}
awaits_captain() {
  jq -e '(.review == "human" or .review == "adversarial-then-human")
    and ((.captain.verdict // "") != "approved")' "$1" >/dev/null
}
captain_refusal() {  # <ticket-file> <act>
  die "$(jq -r .id "$1") is reviewed by the captain (review: $(jq -r .review "$1")) and the captain has not looked yet - it cannot $2 until that word is given."
}
started_on() {  # <node-id>
  local f
  for f in "$db"/c*.json; do
    jq -e --arg n "$1" '.node == $n and .state == "started"' "$f" >/dev/null && printf '%s\n' "$f"
  done
}

case "${1:-}" in
  ticket)
    case "${2:-}" in
      show) jq '{change: .}' "$(ticket_file "$3")" ;;
      list)
        nid=$(jq -r .id "$(node_file "$3")")
        jq -s --arg n "$nid" '[.[] | select(.node == $n)]' "$db"/c*.json
        ;;
      start)
        f=$(ticket_file "$3"); to=$(opt --to "$@")
        upd "$f" --arg t "$to" '.state = "started" | .agent = $t'
        upd "$(node_file "$(jq -r .node "$f")")" --arg t "$to" '.holder = $t | .cond = "underway"'
        ;;
      approve)
        [ "${FM_MOCK_APPROVE_FAIL:-}" = 1 ] && die "captain approval service is unavailable"
        f=$(ticket_file "$3"); word=$(opt --word "$@" || true)
        case "$(jq -r .state "$f")" in
          completed|abandoned) die "$3 is $(jq -r .state "$f") - the captain's word belongs on work that has not closed yet" ;;
        esac
        upd "$f" --arg w "$word" --arg b "$by" '.captain = {verdict: "approved", word: $w, by: $b}'
        ;;
      testing)
        f=$(ticket_file "$3")
        upd "$f" --arg l "$(opt --link "$@")" '.testing = {link: $l}'
        ;;
      complete)
        f=$(ticket_file "$3")
        opt --evidence "$@" >/dev/null || die "change complete needs --evidence"
        opt --summary "$@" >/dev/null || die "ticket complete needs --summary"
        case "$(jq -r .state "$f")" in
          completed) exit 0 ;;
          abandoned) die "$3 was abandoned - re-queue it rather than completing it" ;;
        esac
        awaits_captain "$f" && captain_refusal "$f" "be completed"
        if jq -e '.testing == null and .captainSurface != "none"
            and (.path | index("captain-review") != null)' "$f" >/dev/null; then
          die "$3 has captain-review on its path and a captain surface ($(jq -r .captainSurface "$f")), but no testing brief - the captain was never told how to look at this."
        fi
        upd "$f" --arg b "$by" '.state = "completed" | .completedBy = $b'
        ;;
      *) die "unsupported ticket verb: ${2:-}" ;;
    esac
    ;;
  restage)
    nf=$(node_file "$2")
    if [ "$3" = merge ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        awaits_captain "$f" && captain_refusal "$f" "move to merge"
      done <<EOF
$(started_on "$(jq -r .id "$nf")")
EOF
    fi
    upd "$nf" --arg s "$3" '.stage = $s'
    ;;
  release) upd "$(node_file "$2")" '.holder = null' ;;
  land)
    nf=$(node_file "$2")
    opt --evidence "$@" >/dev/null || die "land needs --evidence"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      awaits_captain "$f" && captain_refusal "$f" "be landed"
    done <<EOF
$(started_on "$(jq -r .id "$nf")")
EOF
    upd "$nf" '.cond = "landed" | .holder = null'
    ;;
  show) cat "$(node_file "$2")" ;;
  *) die "unsupported verb: ${1:-}" ;;
esac
SH
chmod +x "$MOCK_BIN/atlas-axi"

STORES=mock
REAL_ATLAS=$(command -v atlas-axi 2>/dev/null || true)
if [ -n "$REAL_ATLAS" ] && [ "${FM_ATLAS_GATE_REAL:-1}" != 0 ]; then
  probe="$TMP_ROOT/real-probe"
  fm_git_init_commit "$probe" >/dev/null 2>&1
  if HOME="$TMP_ROOT" "$REAL_ATLAS" --repo "$probe" create "Probe project" --name probe \
      --desc "A throwaway region that proves this atlas-axi can open a temp store." >/dev/null 2>&1; then
    ln -s "$REAL_ATLAS" "$REAL_BIN/atlas-axi"
    STORES="mock real"
  else
    echo "note: installed atlas-axi cannot open a temp store; the real-store rows are skipped"
  fi
else
  echo "note: atlas-axi is not installed; the real-store rows are skipped"
fi

store_bin() {  # <store>
  case "$1" in
    mock) printf '%s\n' "$MOCK_BIN" ;;
    real) printf '%s\n' "$REAL_BIN" ;;
  esac
}

# Run atlas-axi from <store> against <repo>, with no ambient Atlas environment.
atlas_in() {  # <store> <repo> <args...>
  local store=$1 repo=$2
  shift 2
  HOME="$TMP_ROOT" PATH="$(store_bin "$store"):$PATH" atlas-axi --repo "$repo" "$@"
}

# Seed one ticket on demo/thing and start it for task-a1, the way fm-spawn does.
# Echoes "<ticket> <node-id>".
seed_store() {  # <store> <repo> <review> <captain-surface>
  local store=$1 repo=$2 review=$3 surface=$4 json
  case "$store" in
    mock)
      mkdir -p "$repo/atlas/mock"
      printf '%s\n' '{"id":"n1","path_":"demo/thing","holder":null,"cond":"charted","stage":null}' \
        > "$repo/atlas/mock/n1.json"
      jq -n --arg r "$review" --arg s "$surface" '{id: "c1", node: "n1", nodePath: "demo/thing",
        state: "queued", review: $r, captainSurface: $s, testing: null, captain: null,
        path: ["building", "review", "captain-review", "merge"]}' > "$repo/atlas/mock/c1.json"
      ;;
    real)
      fm_git_init_commit "$repo" >/dev/null
      atlas_in real "$repo" create "Demo project" --name demo \
        --desc "The region every gate scenario in this test works under." >/dev/null 2>&1
      atlas_in real "$repo" create "Gated thing" --under demo --name thing \
        --desc "The one node whose ticket each scenario closes out." >/dev/null 2>&1
      atlas_in real "$repo" ticket queue demo/thing "Close out the gated thing" \
        --story "as a captain I want gated work closed honestly so that the map stays true" \
        --captain-surface "$surface" --review "$review" >/dev/null 2>&1
      ;;
  esac
  json=$(atlas_in "$store" "$repo" ticket list demo/thing --json) || return 1
  set -- "$(printf '%s' "$json" | jq -r '.[0].id')" "$(printf '%s' "$json" | jq -r '.[0].node')"
  atlas_in "$store" "$repo" --by fm-spawn ticket start "$1" --to fm-task-a1 --task task-a1 >/dev/null 2>&1 \
    || return 1
  printf '%s %s\n' "$1" "$2"
}

ticket_field() {  # <store> <repo> <ticket> <jq-path under .change>
  atlas_in "$1" "$2" ticket show "$3" --json | jq -r ".change$4 // empty"
}

node_field() {  # <store> <repo> <jq-path>
  atlas_in "$1" "$2" show demo/thing --json | jq -r "$3 // empty"
}

# A home wired to a freshly seeded store, with one ticketed task. Sets HOME_DIR,
# REPO and TICKET.
make_home() {  # <store> <name> <review> <captain-surface> [meta-lines...]
  local store=$1 name=$2 review=$3 surface=$4 seeded
  shift 4
  HOME_DIR="$TMP_ROOT/$store-$name"
  REPO="$HOME_DIR/specs"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/fakebin" "$REPO"
  seeded=$(seed_store "$store" "$REPO" "$review" "$surface") \
    || fail "$store store: could not seed the ticket"
  TICKET=${seeded% *}
  printf '%s\n' "$REPO" > "$HOME_DIR/config/specs"
  fm_write_meta "$HOME_DIR/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" \
    "worktree=$HOME_DIR/wt" \
    "project=$HOME_DIR/project" \
    "kind=ship" \
    "mode=${MODE:-no-mistakes}" \
    "atlas_ticket=$TICKET" \
    "$@"
}

in_home() {  # <store> <command...>: run a fleet script inside HOME_DIR's wiring
  local store=$1
  shift
  HOME="$TMP_ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$HOME_DIR/fakebin:$(store_bin "$store"):$PATH" \
    "$@"
}

gate_lines() {  # <status-file>: the keyed Atlas gate lines it holds
  grep -F "[key=atlas-gate-$TICKET]" "$1" 2>/dev/null || true
}

assert_one_gate_line() {  # <store> <status-file> <gate phrase> <what>
  local lines count
  lines=$(gate_lines "$2")
  count=$(printf '%s' "$lines" | grep -c . || true)
  [ "$count" = 1 ] || fail "$1: $4: expected exactly one gate line in $2, got $count:"$'\n'"$(cat "$2" 2>/dev/null)"
  case "$lines" in
    "blocked [key=atlas-gate-$TICKET]: "*) ;;
    *) fail "$1: $4: the gate line is not a keyed blocked line: $lines" ;;
  esac
  assert_contains "$lines" "$TICKET" "$1: $4: the gate line does not name the ticket"
  assert_contains "$lines" "$3" "$1: $4: the gate line does not name the missing gate"
}

# --- (a)-(e) the hook -------------------------------------------------------

test_complete_refused_for_approval() {
  local store=$1 out rc
  make_home "$store" complete-approval human none
  set +e
  out=$(in_home "$store" "$HOOK" complete task-a1 --actor fm-pr-merge --restage merge \
    --evidence https://example.invalid/pr/1 --summary "merged" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: a refused complete must still exit 0"
  assert_one_gate_line "$store" "$HOME_DIR/state/task-a1.status" "captain's approval" "refused complete"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .state)" = started ] \
    || fail "$store: a refused complete must leave the ticket open"
  [ -z "$(node_field "$store" "$REPO" .holder)" ] \
    || fail "$store: a refused complete must still release the node"
  assert_contains "$out" "refused" "$store: the refusal must be reported, never passed off as success"
  assert_not_contains "$out" "completed" "$store: a refused complete was reported as completed"
  pass "$store: a complete the captain gate refuses releases the node and leaves one keyed status line"
}

test_complete_refused_for_testing_brief() {
  local store=$1
  make_home "$store" complete-brief adversarial "the demo page"
  in_home "$store" "$HOOK" complete task-a1 --actor fm-pr-merge \
    --evidence https://example.invalid/pr/2 --summary "merged" >/dev/null 2>&1
  assert_one_gate_line "$store" "$HOME_DIR/state/task-a1.status" "testing brief" "missing brief"
  [ -z "$(node_field "$store" "$REPO" .holder)" ] \
    || fail "$store: a complete refused for its testing brief must still release the node"
  pass "$store: a complete refused for a missing testing brief names that gate"
}

test_complete_with_captain_word() {
  local store=$1
  make_home "$store" complete-word human none
  in_home "$store" "$HOOK" complete task-a1 --actor fm-pr-merge --restage merge \
    --captain-word "yes, merge it" \
    --evidence https://example.invalid/pr/3 --summary "merged" >/dev/null 2>&1
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.verdict)" = approved ] \
    || fail "$store: the captain's words were not recorded as the approval"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.word)" = "yes, merge it" ] \
    || fail "$store: the approval does not carry the captain's exact words"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.by)" = fm-pr-merge ] \
    || fail "$store: the approval was not stamped with the acting script"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .state)" = completed ] \
    || fail "$store: an approved ticket was not completed"
  [ -z "$(gate_lines "$HOME_DIR/state/task-a1.status")" ] \
    || fail "$store: an approved close-out must not raise a gate line"
  pass "$store: --captain-word records the captain's exact words as the approval, then completes"
}

test_complete_coalesces_failed_approval_warning() {
  local store=$1 out rc
  [ "$store" = mock ] || return 0
  make_home "$store" approval-failed human none
  set +e
  out=$(FM_MOCK_APPROVE_FAIL=1 in_home "$store" "$HOOK" complete task-a1 \
    --actor fm-pr-merge --captain-word "merge it" \
    --evidence https://example.invalid/pr/approval --summary "merged" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "mock: a failed approval must preserve the hook's best-effort exit"
  [ "$(printf '%s\n' "$out" | grep -c '^atlas-hook:')" = 1 ] \
    || fail "mock: a failed approval and refused close-out must warn once: $out"
  assert_contains "$out" "captain approval failed" \
    "mock: the refusal warning did not retain the failed approval reason"
  assert_one_gate_line "$store" "$HOME_DIR/state/task-a1.status" "captain's approval" "failed approval"
  [ -z "$(node_field "$store" "$REPO" .holder)" ] \
    || fail "mock: a failed approval left the refused node held"
  pass "mock: a failed approval is coalesced into one close-out warning"
}

test_land_refused() {
  local store=$1
  make_home "$store" land-refused human none
  in_home "$store" "$HOOK" land task-a1 --actor fm-teardown \
    --evidence "task task-a1 landed" --summary "landed" >/dev/null 2>&1
  assert_one_gate_line "$store" "$HOME_DIR/state/task-a1.status" "captain's approval" "refused land"
  [ -z "$(node_field "$store" "$REPO" .holder)" ] || fail "$store: a refused land must still release the node"
  [ "$(node_field "$store" "$REPO" .cond)" != landed ] || fail "$store: a refused ticket's node was landed"
  pass "$store: a refused land releases the node, never lands it, and leaves one keyed status line"
}

test_complete_rejects_defer_status() {
  local store=$1 out rc log_before log_after
  make_home "$store" complete-defer human none
  case "$store" in
    mock) log_before=$(wc -l < "$REPO/atlas/mock/log") ;;
  esac
  set +e
  out=$(in_home "$store" "$HOOK" complete task-a1 --actor fm-pr-merge --defer-status \
    --evidence https://example.invalid/pr/defer --summary "merged" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: an unsupported --defer-status must preserve the best-effort exit"
  [ "$(printf '%s\n' "$out" | grep -c '^atlas-hook:')" = 1 ] \
    || fail "$store: an unsupported --defer-status must warn once: $out"
  assert_absent "$HOME_DIR/state/task-a1.status" \
    "$store: an unsupported --defer-status wrote a status line"
  case "$store" in
    mock)
      log_after=$(wc -l < "$REPO/atlas/mock/log")
      [ "$log_before" = "$log_after" ] \
        || fail "mock: an unsupported --defer-status called Atlas"
      ;;
  esac
  [ "$(node_field "$store" "$REPO" .holder)" = fm-task-a1 ] \
    || fail "$store: an unsupported --defer-status changed the node"
  pass "$store: complete rejects --defer-status before any Atlas call"
}

test_land_defer_status() {
  local store=$1 out
  make_home "$store" land-defer human none
  out=$(in_home "$store" "$HOOK" land task-a1 --actor fm-teardown --defer-status \
    --evidence "task task-a1 landed" --summary "landed" 2>/dev/null)
  assert_absent "$HOME_DIR/state/task-a1.status" \
    "$store: --defer-status must leave the status log to the caller"
  case "$out" in
    "blocked [key=atlas-gate-$TICKET]: "*) ;;
    *) fail "$store: --defer-status did not print the gate line for the caller: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "$store: --defer-status printed more than the one line: $out"
  pass "$store: --defer-status hands the gate line to the caller instead of writing it"
}

# --- (f)-(k) callers end to end ---------------------------------------------

make_fake_forge() {  # writes gh-axi and gh into HOME_DIR/fakebin
  cat > "$HOME_DIR/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
exit 0
SH
  cat > "$HOME_DIR/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql") printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main' ;;
esac
exit 0
SH
  chmod +x "$HOME_DIR/fakebin/gh-axi" "$HOME_DIR/fakebin/gh"
  : > "$HOME_DIR/gh.log"
}

run_pr_merge() {  # <store> [merge args...]
  local store=$1
  shift
  FM_FAKE_GH_LOG="$HOME_DIR/gh.log" in_home "$store" \
    "$PR_MERGE" task-a1 https://github.com/example/repo/pull/9 "$@"
}

test_pr_merge_refused() {
  local store=$1 rc
  make_home "$store" pr-refused human none yolo=on
  make_fake_forge
  set +e
  run_pr_merge "$store" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: a refused Atlas close-out must not fail the merge"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$HOME_DIR/gh.log" \
    || fail "$store: the merge itself did not happen"
  assert_one_gate_line "$store" "$HOME_DIR/state/task-a1.status" "captain's approval" "fm-pr-merge"
  [ -z "$(node_field "$store" "$REPO" .holder)" ] || fail "$store: fm-pr-merge left the refused node held"
  pass "$store: fm-pr-merge still merges when the gate refuses, releases the node, and wakes the supervisor"
}

test_pr_merge_with_captain_word() {
  local store=$1 rc
  make_home "$store" pr-word human none yolo=off
  make_fake_forge
  set +e
  run_pr_merge "$store" --captain-authorized --captain-word "merge it" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: fm-pr-merge with the captain's words must succeed"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$HOME_DIR/gh.log" \
    || fail "$store: --captain-word leaked into the forge call or the merge did not happen:"$'\n'"$(cat "$HOME_DIR/gh.log")"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.word)" = "merge it" ] \
    || fail "$store: fm-pr-merge did not record the captain's words"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .state)" = completed ] \
    || fail "$store: fm-pr-merge did not complete the approved ticket"
  [ -z "$(gate_lines "$HOME_DIR/state/task-a1.status")" ] || fail "$store: an approved merge raised a gate line"
  pass "$store: fm-pr-merge --captain-word approves and completes the ticket with no manual Atlas step"
}

test_pr_merge_rejects_forwarded_captain_word() {
  local store=$1 rc out form
  make_home "$store" pr-forwarded-word human none yolo=on
  make_fake_forge
  for form in equals positional; do
    set +e
    case "$form" in
      equals) out=$(run_pr_merge "$store" -- --captain-word=words 2>&1) ;;
      positional) out=$(run_pr_merge "$store" -- --captain-word words 2>&1) ;;
    esac
    rc=$?
    set -e
    expect_code 2 "$rc" "$store: fm-pr-merge accepted a forwarded --captain-word=$form"
    assert_contains "$out" "never forwarded to the forge CLI" \
      "$store: fm-pr-merge did not explain the forwarded captain-word rule"
    [ ! -s "$HOME_DIR/gh.log" ] \
      || fail "$store: fm-pr-merge called the forge with a forwarded --captain-word"
  done
  pass "$store: fm-pr-merge refuses captain words after the forge boundary"
}

test_merge_local_with_captain_word() {
  local store=$1 proj rc
  MODE=local-only make_home "$store" local-word human none yolo=on
  proj="$HOME_DIR/project"
  fm_git_init_commit "$proj"
  git -C "$proj" checkout -q -b fm/task-a1
  printf 'change\n' > "$proj/change.txt"
  git -C "$proj" add change.txt
  git -C "$proj" commit -qm change
  git -C "$proj" checkout -q main 2>/dev/null || git -C "$proj" checkout -q master
  set +e
  in_home "$store" "$MERGE_LOCAL" task-a1 --captain-word "land it" >"$HOME_DIR/merge.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: fm-merge-local with the captain's words must succeed"$'\n'"$(grep -v "^●" "$HOME_DIR/merge.out")"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.word)" = "land it" ] \
    || fail "$store: fm-merge-local did not record the captain's words"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .state)" = completed ] \
    || fail "$store: fm-merge-local did not complete the approved ticket"
  pass "$store: fm-merge-local --captain-word approves and completes the ticket"
}

# A ship task whose leg produced work and pushed it, so cleanup's landed-work
# proof passes on real commits and cleanup reaches the Atlas close-out.
make_teardown_case() {  # <store> <name>
  local wt
  make_home "$1" "$2" human none
  wt="$HOME_DIR/wt"
  fm_fake_exit0 "$HOME_DIR/fakebin" tmux treehouse no-mistakes gh
  fm_git_worktree "$HOME_DIR/project" "$wt" fm/task-a1
  printf 'the work this leg produced\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" commit -qm 'the leg produced this'
  git -C "$wt" push -q origin fm/task-a1
  fm_write_meta "$HOME_DIR/state/task-a1.meta" \
    "window=firstmate:fm-task-a1" \
    "endpoint_task_id=task-a1" \
    "worktree=$wt" \
    "project=$HOME_DIR/project" \
    "kind=ship" \
    "mode=local-only" \
    "atlas_ticket=$TICKET"
  printf 'done: merged into the local default branch\n' > "$HOME_DIR/state/task-a1.status"
}

test_teardown_refused() {
  local store=$1 rc
  make_teardown_case "$store" teardown-refused
  set +e
  in_home "$store" "$TEARDOWN" task-a1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: a refused Atlas close-out must not fail cleanup"
  assert_absent "$HOME_DIR/state/task-a1.meta" "$store: cleanup must still remove the task record"
  assert_one_gate_line "$store" "$HOME_DIR/state/task-a1.status" "captain's approval" "fm-teardown"
  assert_no_grep 'done: merged' "$HOME_DIR/state/task-a1.status" \
    "$store: the retired status history came back with the gate line"
  [ -z "$(node_field "$store" "$REPO" .holder)" ] || fail "$store: cleanup left the refused node held"
  [ "$(node_field "$store" "$REPO" .cond)" != landed ] || fail "$store: cleanup landed a refused ticket's node"
  pass "$store: fm-teardown releases a refused node and its gate line outlives the retired records"
}

test_teardown_with_captain_word() {
  local store=$1 rc
  make_teardown_case "$store" teardown-word
  set +e
  in_home "$store" "$TEARDOWN" task-a1 --captain-word "ship it" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: cleanup with the captain's words must succeed"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.word)" = "ship it" ] \
    || fail "$store: cleanup did not record the captain's words"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .state)" = completed ] \
    || fail "$store: cleanup did not complete the approved ticket"
  [ "$(node_field "$store" "$REPO" .cond)" = landed ] || fail "$store: cleanup did not land the approved node"
  [ -z "$(gate_lines "$HOME_DIR/state/task-a1.status")" ] || fail "$store: an approved cleanup raised a gate line"
  pass "$store: fm-teardown --captain-word approves, completes, and lands the ticket"
}

test_empty_captain_word_is_refused() {
  local store=$1 rc out form log_before log_after
  make_home "$store" empty-word human none yolo=on
  for form in positional equals option missing; do
    case "$store" in
      mock) log_before=$(wc -l < "$REPO/atlas/mock/log") ;;
    esac
    set +e
    case "$form" in
      positional)
        out=$(in_home "$store" "$HOOK" complete task-a1 --captain-word "" \
          --evidence https://example.invalid/pr/empty --summary "merged" 2>&1)
        ;;
      equals)
        out=$(in_home "$store" "$HOOK" complete task-a1 --captain-word= \
          --evidence https://example.invalid/pr/empty --summary "merged" 2>&1)
        ;;
      option)
        out=$(in_home "$store" "$HOOK" complete task-a1 --captain-word --actor \
          --evidence https://example.invalid/pr/empty --summary "merged" 2>&1)
        ;;
      missing)
        out=$(in_home "$store" "$HOOK" complete task-a1 --evidence https://example.invalid/pr/empty \
          --summary "merged" --captain-word 2>&1)
        ;;
    esac
    rc=$?
    set -e
    expect_code 0 "$rc" "$store: the best-effort hook must exit 0 for an empty --captain-word"
    [ "$(printf '%s\n' "$out" | grep -c '^atlas-hook:')" = 1 ] \
      || fail "$store: an empty --captain-word must warn once: $out"
    case "$store" in
      mock)
        log_after=$(wc -l < "$REPO/atlas/mock/log")
        [ "$log_before" = "$log_after" ] \
          || fail "mock: an empty --captain-word called Atlas"
        ;;
    esac
    [ "$(ticket_field "$store" "$REPO" "$TICKET" .state)" = started ] \
      || fail "$store: an empty --captain-word changed the ticket"
    [ "$(node_field "$store" "$REPO" .holder)" = fm-task-a1 ] \
      || fail "$store: an empty --captain-word changed the node"
  done
  make_fake_forge
  for form in positional equals option missing; do
    set +e
    case "$form" in
      positional) run_pr_merge "$store" --captain-word "" >/dev/null 2>&1 ;;
      equals) run_pr_merge "$store" --captain-word= >/dev/null 2>&1 ;;
      option) run_pr_merge "$store" --captain-word --captain-authorized >/dev/null 2>&1 ;;
      missing) run_pr_merge "$store" --captain-word >/dev/null 2>&1 ;;
    esac
    rc=$?
    set -e
    expect_code 2 "$rc" "$store: fm-pr-merge accepted an empty --captain-word=$form"
    [ ! -s "$HOME_DIR/gh.log" ] || fail "$store: fm-pr-merge forwarded an empty --captain-word"
    set +e
    case "$form" in
      positional) in_home "$store" "$TEARDOWN" task-a1 --captain-word "" >/dev/null 2>&1 ;;
      equals) in_home "$store" "$TEARDOWN" task-a1 --captain-word= >/dev/null 2>&1 ;;
      option) in_home "$store" "$TEARDOWN" task-a1 --captain-word --force >/dev/null 2>&1 ;;
      missing) in_home "$store" "$TEARDOWN" task-a1 --captain-word >/dev/null 2>&1 ;;
    esac
    rc=$?
    set -e
    expect_code 2 "$rc" "$store: fm-teardown accepted an empty --captain-word=$form"
    assert_present "$HOME_DIR/state/task-a1.meta" "$store: fm-teardown acted on an empty --captain-word"
    set +e
    case "$form" in
      positional) in_home "$store" "$MERGE_LOCAL" task-a1 --captain-word "" >/dev/null 2>&1 ;;
      equals) in_home "$store" "$MERGE_LOCAL" task-a1 --captain-word= >/dev/null 2>&1 ;;
      option) in_home "$store" "$MERGE_LOCAL" task-a1 --captain-word --captain-authorized >/dev/null 2>&1 ;;
      missing) in_home "$store" "$MERGE_LOCAL" task-a1 --captain-word >/dev/null 2>&1 ;;
    esac
    rc=$?
    set -e
    expect_code 2 "$rc" "$store: fm-merge-local accepted an empty --captain-word=$form"
  done
  pass "$store: an empty or missing --captain-word is refused before anything happens"
}

test_captain_word_equals_forms() {
  local store=$1 proj rc
  make_home "$store" complete-word-equals human none
  in_home "$store" "$HOOK" complete task-a1 --actor fm-pr-merge --restage merge \
    --captain-word="-yes, merge it" --evidence https://example.invalid/pr/equals --summary "merged" >/dev/null 2>&1
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.word)" = "-yes, merge it" ] \
    || fail "$store: fm-atlas-hook did not accept --captain-word=<words>"
  make_home "$store" pr-word-equals human none yolo=off
  make_fake_forge
  set +e
  run_pr_merge "$store" --captain-authorized --captain-word="-merge it" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: fm-pr-merge did not accept --captain-word=<words>"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.word)" = "-merge it" ] \
    || fail "$store: fm-pr-merge did not record --captain-word=<words>"
  MODE=local-only make_home "$store" local-word-equals human none yolo=on
  proj="$HOME_DIR/project"
  fm_git_init_commit "$proj"
  git -C "$proj" checkout -q -b fm/task-a1
  printf 'change\n' > "$proj/change.txt"
  git -C "$proj" add change.txt
  git -C "$proj" commit -qm change
  git -C "$proj" checkout -q main 2>/dev/null || git -C "$proj" checkout -q master
  in_home "$store" "$MERGE_LOCAL" task-a1 --captain-word="-land it" >/dev/null 2>&1 \
    || fail "$store: fm-merge-local did not accept --captain-word=<words>"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.word)" = "-land it" ] \
    || fail "$store: fm-merge-local did not record --captain-word=<words>"
  make_teardown_case "$store" teardown-word-equals
  set +e
  in_home "$store" "$TEARDOWN" task-a1 --captain-word="-ship it" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "$store: fm-teardown did not accept --captain-word=<words>"
  [ "$(ticket_field "$store" "$REPO" "$TICKET" .captain.word)" = "-ship it" ] \
    || fail "$store: fm-teardown did not record --captain-word=<words>"
  pass "$store: every Atlas entry point accepts a non-empty --captain-word=<words>"
}

# --- (l)-(n) the worker environment ------------------------------------------

# A logging tmux stand-in: every call is appended to $FM_FAKE_TMUX_DIR/calls.
write_fake_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_TMUX_DIR
printf '%s\n' "$*" >> "$D/calls"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf 'zsh\n'; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
  *"#{pane_id}"*) printf 'fakepane\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) cat "$D/windows" 2>/dev/null ;;
  new-window) printf '@1\n' ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

make_spawn_home() {  # <name> <wired:yes|no> <id>
  local name=$1 wired=$2 id=$3
  HOME_DIR="$TMP_ROOT/spawn-$name"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/$id" "$HOME_DIR/projects" \
    "$HOME_DIR/fakebin" "$HOME_DIR/tmux" "$HOME_DIR/user-home"
  REPO="$HOME_DIR/specs dir"
  if [ "$wired" = yes ]; then
    mkdir -p "$REPO/atlas/mock"
    printf '%s\n' "$REPO" > "$HOME_DIR/config/specs"
  fi
  write_fake_tmux "$HOME_DIR/fakebin"
  fm_fake_exit0 "$HOME_DIR/fakebin" treehouse
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf '# Task\n## Captain\047s intent\nExercise the worker environment.\n\n## Firstmate spec\nNothing to build.\n' \
    > "$HOME_DIR/data/$id/brief.md"
  fm_git_worktree "$HOME_DIR/project" "$HOME_DIR/wt" "wt-$name"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_spawn() {  # <spawn args...>
  env -u FM_TRACE_CONTEXT -u CLAUDE_CONFIG_DIR FM_BACKEND=tmux \
    HOME="$HOME_DIR/user-home" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$HOME_DIR/wt" TMUX="fake,1,0" \
    FM_FAKE_TMUX_DIR="$HOME_DIR/tmux" \
    PATH="$HOME_DIR/fakebin:$MOCK_BIN:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The value a pane was given for <name>, by sourcing the export line it received.
pane_export() {  # <name>
  local line
  line=$(grep -E "^send-keys -t [^ ]+ export $1=" "$HOME_DIR/tmux/calls" | tail -n 1) || return 1
  line=${line#send-keys -t * export }
  line=${line% Enter}
  (eval "export $line" && printenv "$1")
}

pane_unsets() {  # <name>
  awk -v name="$1" '
    $1 == "send-keys" && $2 == "-t" {
      for (i = 1; i <= NF; i++) {
        if ($i == "unset") {
          for (j = i + 1; j < NF; j++) if ($j == name) found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$HOME_DIR/tmux/calls"
}

test_spawn_exports_atlas_environment() {
  local id=gate-env-a1 out rc
  make_spawn_home env-wired yes "$id"
  set +e
  out=$(ATLAS_REPO=/other/specs SPECS_REPO=/other/specs ATLAS_AXI_BY=other-worker \
    run_spawn "$id" "$HOME_DIR/project" --harness claude --mode no-mistakes --yolo off)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn: the launch must succeed"$'\n'"$out"
  [ "$(pane_export ATLAS_REPO)" = "$REPO" ] \
    || fail "spawn: the worker was not given the home's Atlas repo:"$'\n'"$(cat "$HOME_DIR/tmux/calls")"
  [ "$(pane_export ATLAS_AXI_BY)" = "fm-$id" ] \
    || fail "spawn: the worker was not given its Atlas author name:"$'\n'"$(cat "$HOME_DIR/tmux/calls")"
  pane_unsets SPECS_REPO || fail "spawn: the worker retained an ambient SPECS_REPO"
  pass "spawn: a wired worker replaces ambient Atlas values with this home's values"
}

test_spawn_unwired_home_exports_no_repo() {
  local id=fm-gate-env-b1 out rc
  make_spawn_home env-unwired no "$id"
  set +e
  printf '%s\n' ATLAS_REPO SPECS_REPO ATLAS_AXI_BY > "$HOME_DIR/config/launch-env-allowlist"
  out=$(ATLAS_REPO=/other/specs SPECS_REPO=/other/specs ATLAS_AXI_BY=other-worker \
    run_spawn "$id" "$HOME_DIR/project" --scout --harness claude)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn: the unwired launch must succeed"$'\n'"$out"
  pane_export ATLAS_REPO >/dev/null && fail "spawn: an unwired home exported an ATLAS_REPO"
  pane_export SPECS_REPO >/dev/null && fail "spawn: an unwired home exported a SPECS_REPO"
  pane_export ATLAS_AXI_BY >/dev/null && fail "spawn: an unwired home exported an Atlas author"
  if ! pane_unsets ATLAS_REPO || ! pane_unsets SPECS_REPO || ! pane_unsets ATLAS_AXI_BY; then
    fail "spawn: an unwired worker did not clear the ambient Atlas values"
  fi
  pass "spawn: an unwired worker clears ambient Atlas values, including with env -i"
}

test_relaunch_exports_atlas_environment() {
  local id=gate-env-c1 out
  make_spawn_home env-relaunch yes "$id"
  printf 'fm-%s\n' "$id" > "$HOME_DIR/tmux/windows"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$HOME_DIR/wt" \
    "project=$HOME_DIR/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-$id" \
    "model=default" \
    "effort=default"
  out=$(ATLAS_REPO=/other/specs SPECS_REPO=/other/specs ATLAS_AXI_BY=other-worker \
    run_spawn "$id" --relaunch) || fail "relaunch: the relaunch failed: $out"
  [ "$(pane_export ATLAS_REPO)" = "$REPO" ] \
    || fail "relaunch: the worker was not given the home's Atlas repo:"$'\n'"$(cat "$HOME_DIR/tmux/calls")"
  [ "$(pane_export ATLAS_AXI_BY)" = "fm-$id" ] \
    || fail "relaunch: the worker was not given its Atlas author name"
  pane_unsets SPECS_REPO || fail "relaunch: the worker retained an ambient SPECS_REPO"
  pass "relaunch: a wired worker replaces ambient Atlas values again"
}

test_relaunch_unwired_clears_atlas_environment() {
  local id=fm-gate-env-d1 out
  make_spawn_home env-relaunch-unwired no "$id"
  printf 'fm-%s\n' "$id" > "$HOME_DIR/tmux/windows"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$HOME_DIR/wt" \
    "project=$HOME_DIR/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-$id" \
    "model=default" \
    "effort=default"
  printf '%s\n' ATLAS_REPO SPECS_REPO ATLAS_AXI_BY > "$HOME_DIR/config/launch-env-allowlist"
  out=$(ATLAS_REPO=/other/specs SPECS_REPO=/other/specs ATLAS_AXI_BY=other-worker \
    run_spawn "$id" --relaunch) || fail "relaunch: the unwired relaunch failed: $out"
  if ! pane_unsets ATLAS_REPO || ! pane_unsets SPECS_REPO || ! pane_unsets ATLAS_AXI_BY; then
    fail "relaunch: an unwired worker did not clear the ambient Atlas values"
  fi
  pass "relaunch: an unwired worker clears ambient Atlas values"
}

# A dead task record that already names a ticket.
write_ticketed_record() {  # <id> <ticket>
  printf 'fm-%s\n' "$1" > "$HOME_DIR/tmux/windows"
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=firstmate:fm-$1" \
    "endpoint_task_id=$1" \
    "worktree=$HOME_DIR/wt" \
    "project=$HOME_DIR/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-$1" \
    "model=default" \
    "effort=default" \
    "atlas_ticket=$2"
}

test_relaunch_keeps_the_recorded_ticket() {
  local id=gate-ticket-e1 out rc brief
  make_spawn_home ticket-relaunch yes "$id"
  write_ticketed_record "$id" c5
  set +e
  out=$(run_spawn "$id" --relaunch --ticket c6)
  rc=$?
  set -e
  expect_code 1 "$rc" "relaunch: a new --ticket on a relaunch was not refused"$'\n'"$out"
  assert_contains "$out" 'error: --ticket applies to a fresh spawn' \
    "relaunch: the --ticket refusal does not say why"
  out=$(run_spawn "$id" --relaunch) || fail "relaunch: the relaunch failed: $out"
  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_grep 'This task works Atlas ticket c5.' "$brief" \
    "relaunch: the launch brief lost the recorded ticket"
  [ "$(grep -c '^atlas_ticket=' "$HOME_DIR/state/$id.meta")" = 1 ] \
    || fail "relaunch: the task record does not hold exactly one ticket:"$'\n'"$(cat "$HOME_DIR/state/$id.meta")"
  pass "relaunch: the launch brief keeps the recorded ticket, and a new --ticket is refused"
}

test_fresh_spawn_ignores_an_older_ticketed_record() {
  local id=gate-ticket-f1 out rc brief
  make_spawn_home ticket-fresh yes "$id"
  write_ticketed_record "$id" c5
  # The old window is gone, so the fresh spawn replaces the record.
  : > "$HOME_DIR/tmux/windows"
  set +e
  out=$(run_spawn "$id" "$HOME_DIR/project" --harness claude --mode no-mistakes --yolo off)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn: a fresh spawn over a dead record failed"$'\n'"$out"
  assert_contains "$out" "warning: $id is being dispatched without --ticket" \
    "spawn: a ticket-less fresh spawn did not get the dispatch warning"
  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_present "$brief" "spawn: no launch brief was rendered"
  assert_no_grep 'c5' "$brief" "spawn: a fresh spawn took the ticket of an older record"
  assert_no_grep 'atlas-working' "$brief" "spawn: a ticket-less fresh spawn got the crewmate fragment"
  assert_no_grep 'atlas_ticket=' "$HOME_DIR/state/$id.meta" \
    "spawn: a ticket-less fresh spawn recorded a ticket"
  pass "spawn: a fresh ticket-less spawn over an older ticketed record gets no ticket"
}

# The filtered launch environment passes the Atlas names for every pane kind.
# The secondmate's emitted launch command runs in a synthetic pane shell whose
# claude stand-in records the two values it received.
test_secondmate_launch_env_passes_atlas_values() {
  local id=gate-sm-g1 sm out rc launch probe_out
  make_spawn_home sm-env no "$id"
  sm="$TMP_ROOT/secondmate-home-$id"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  : > "$HOME_DIR/config/launch-env-allowlist"
  set +e
  out=$(run_spawn "$id" "$sm" --secondmate --harness claude)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn: the secondmate launch failed"$'\n'"$out"
  launch=$(grep -E '^send-keys -t [^ ]+ -l ' "$HOME_DIR/tmux/calls" | tail -n 1)
  launch=${launch#send-keys -t * -l }
  [ -n "$launch" ] || fail "spawn: no launch command was sent:"$'\n'"$(cat "$HOME_DIR/tmux/calls")"
  mkdir -p "$HOME_DIR/pane-bin"
  probe_out="$HOME_DIR/pane-probe"
  cat > "$HOME_DIR/pane-bin/claude" <<SH
#!/bin/sh
printf '%s|%s\n' "\${ATLAS_REPO-unset}" "\${ATLAS_AXI_BY-unset}" > '$probe_out'
SH
  chmod +x "$HOME_DIR/pane-bin/claude"
  (cd "$sm" && env -i HOME="$HOME_DIR/user-home" PATH="$HOME_DIR/pane-bin:/usr/bin:/bin:$PATH" TERM=xterm \
    ATLAS_REPO=/pane/specs ATLAS_AXI_BY=fm-pane FM_TEST_UNLISTED=dropped \
    /bin/sh -c "$launch" >/dev/null 2>&1) || true
  [ "$(cat "$probe_out" 2>/dev/null)" = "/pane/specs|fm-pane" ] \
    || fail "spawn: the secondmate launch dropped the pane's Atlas values: $(cat "$probe_out" 2>/dev/null)"$'\n'"$launch"
  pass "spawn: with the filtered launch environment, a secondmate still gets the pane's Atlas values"
}

for store in $STORES; do
  test_complete_refused_for_approval "$store"
  test_complete_refused_for_testing_brief "$store"
  test_complete_with_captain_word "$store"
  test_complete_coalesces_failed_approval_warning "$store"
  test_land_refused "$store"
  test_complete_rejects_defer_status "$store"
  test_land_defer_status "$store"
  test_pr_merge_refused "$store"
  test_pr_merge_with_captain_word "$store"
  test_pr_merge_rejects_forwarded_captain_word "$store"
  test_merge_local_with_captain_word "$store"
  test_teardown_refused "$store"
  test_teardown_with_captain_word "$store"
  test_empty_captain_word_is_refused "$store"
  test_captain_word_equals_forms "$store"
done
test_spawn_exports_atlas_environment
test_spawn_unwired_home_exports_no_repo
test_relaunch_exports_atlas_environment
test_relaunch_unwired_clears_atlas_environment
test_relaunch_keeps_the_recorded_ticket
test_fresh_spawn_ignores_an_older_ticketed_record
test_secondmate_launch_env_passes_atlas_values
