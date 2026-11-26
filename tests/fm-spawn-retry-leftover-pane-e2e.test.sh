#!/usr/bin/env bash
# tests/fm-spawn-retry-leftover-pane-e2e.test.sh - isolated real-Herdr,
# real-Treehouse regression test for a spawn retried in the pane an earlier
# attempt left behind.
#
# The guarantee under test: the copy fm-spawn records as worktree=, the copy its
# per-task wiring names, and the copy the worker actually runs in are the same,
# including on a retry in the pane an earlier attempt left behind.
#
# On Herdr, fm-spawn leases the task copy with `treehouse get --lease` outside
# the pane, types a cd to that copy into the pane, and launches only when the
# pane reports that copy. Three sequences leave a pane behind, and agent-axi
# hands it back to the retry in each. In the first, the earlier attempt leases
# its copy, moves its pane there, and then refuses before launch, so the pane
# stays inside a slot the retry cannot lease. In the second, an interactive
# `treehouse get` still fetches a slow origin in that pane, as in a pane an
# older fm-spawn left behind, so the retry's cd waits behind it. In the third, a
# second interactive get also waits in the pane's input behind the first. Each
# way the pane reports a slot the retry did not lease before it enters the copy
# the retry leased.
#
# This drives the REAL bin/fm-spawn.sh, treehouse, and agent-axi, because the
# guarantee spans the whole handoff and no adapter primitive holds it alone.
#
# Safety (tests/herdr-test-safety.sh): every Herdr call goes through
# bin/fm-herdr-lab.sh, which scopes it to this test's own named session and
# verifies the default fleet session is unchanged after teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }
AXI_BIN=${FM_BACKEND_HERDR_AXI_BIN:-agent-axi}
command -v "$AXI_BIN" >/dev/null 2>&1 || { echo "skip: agent-axi not found (it hands the leftover pane back)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-spawn-retry-leftover.XXXXXX")
FIXTURE_NODE=$(command -v node) || { rm -rf "$TMP_ROOT"; echo "skip: node not found (the agent fixture)"; exit 0; }
FIXTURE_AGENT="$TMP_ROOT/cursor-agent"
FIXTURE_SCRIPT="$TMP_ROOT/agent-fixture.js"
cp "$FIXTURE_NODE" "$FIXTURE_AGENT"
cat > "$FIXTURE_SCRIPT" <<'JS'
setTimeout(() => process.exit(0), Number(process.argv[2]) * 1000)
require('readline').createInterface({ input: process.stdin })
  .on('line', (line) => { if (line.trim() === '/exit') process.exit(0) })
JS

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-spawn-retry) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
POOL="$TMP_ROOT/pool"
# fm-spawn keeps each task's temp root at the fixed path /tmp/fm-<id>, so the
# task ids carry this run's pid, and cleanup removes the roots of these ids.
TASK_IDS=

CLEANED=0
cleanup_all() {
  local wt id status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  pkill -f "$FIXTURE_AGENT $FIXTURE_SCRIPT" 2>/dev/null || true
  for wt in "$POOL"/.treehouse/*/*/proj; do
    [ -d "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  for id in $TASK_IDS; do
    rm -rf "/tmp/fm-$id" "/tmp/fm-$id+"*
  done
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# --- scratch world ----------------------------------------------------------

PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
# The pool lives under this test's own root, never under the user's home.
printf 'root = "%s"\n' "$POOL" > "$PROJ/treehouse.toml"
git -C "$PROJ" add README.md treehouse.toml
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$TMP_ROOT/origin.git"
git -C "$PROJ" remote add origin "file://$TMP_ROOT/origin.git"
git -C "$PROJ" fetch -q origin
git -C "$PROJ" remote set-head origin --auto >/dev/null
# A slow origin for exactly one fetch, like a slow network fetch: the first
# fetch after the test writes a delay to slow-fetch takes that many seconds
# more. Only the interactive gets the test types into the pane are slowed, so
# fm-spawn's own lease and refresh fetches stay fast.
cat > "$TMP_ROOT/upload-pack" <<EOF
#!/bin/sh
if mv "$TMP_ROOT/slow-fetch" "$TMP_ROOT/slow-fetch.taken" 2>/dev/null; then
  : > "$TMP_ROOT/slow-fetch.started"
  sleep "\$(cat "$TMP_ROOT/slow-fetch.taken")"
fi
exec git-upload-pack "\$@"
EOF
chmod +x "$TMP_ROOT/upload-pack"
git -C "$PROJ" config remote.origin.uploadpack "$TMP_ROOT/upload-pack"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

write_brief() {  # <id>
  mkdir -p "$HOME_DIR/data/$1"
  cat > "$HOME_DIR/data/$1/brief.md" <<EOF
# Task
## Captain's intent
Exercise a spawn retry for $1.

## Firstmate spec
Verify the recorded copy is the copy the worker runs in.
EOF
}

spawn_attempt() {  # <n>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_BACKEND_HERDR_AXI_BIN="$AXI_BIN" CURSOR_PROJECTS_ROOT_OVERRIDE="$TMP_ROOT/cursor-projects" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" "$FIXTURE_AGENT $FIXTURE_SCRIPT 300" \
    --mode no-mistakes --yolo off --backend herdr \
    > "$TMP_ROOT/spawn$1.out" 2> "$TMP_ROOT/spawn$1.err"
}

task_pane() {
  lab pane list 2>/dev/null | jq -r --arg l "fm-$ID" '.result.panes[]? | select(.label == $l) | .pane_id' 2>/dev/null
}

pane_cwd() {  # <pane-id>
  lab pane get "$1" 2>/dev/null | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

real() { (cd "$1" 2>/dev/null && pwd -P); }

proc_cwd() {  # <pid>
  readlink "/proc/$1/cwd" 2>/dev/null || lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
}

# The `treehouse get` Herdr reports in the foreground of <pane-id>, a pane of
# this test's own lab session, so no process outside this test is selected.
pane_treehouse_get() {  # <pane-id>
  lab pane process-info --pane "$1" 2>/dev/null | jq -r '
    .result.process_info.foreground_processes[]? | select(.argv == ["treehouse", "get"]) | .pid
  ' 2>/dev/null | head -1
}

# The slot Treehouse records as held by the interactive get <pid>, or by the
# subshell that get opened. The pool state sits two levels above each slot.
slot_held_by() {  # <pid>
  local state pid slot
  state="$(dirname "$(dirname "$LEFTOVER_COPY")")/treehouse-state.json"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    slot=$(jq -r --argjson pid "$pid" '.worktrees[]? | select(.owner_pid == $pid) | .path' "$state" 2>/dev/null | head -1)
    [ -z "$slot" ] || { printf '%s\n' "$slot"; return 0; }
  done <<EOF
$1
$(pgrep -P "$1")
EOF
  return 1
}

# assert_one_copy <label> <slot>...: the retry for $ID launched, and the copy
# it recorded, the copy its wiring names, and the copy its new worker runs in
# are one copy, which is none of <slot>..., slots the retry did not lease.
WORKERS=
assert_one_copy() {
  local meta="$HOME_DIR/state/$ID.meta" recorded pane agent_pid worker wired slot
  recorded=$(grep '^worktree=' "$meta" | cut -d= -f2-)
  pane=$(grep '^herdr_pane_id=' "$meta" | cut -d= -f2-)
  [ "$pane" = "$LEFTOVER_PANE" ] \
    || fail "$1: repro setup is wrong: the retry was not handed the leftover pane back ($pane, not $LEFTOVER_PANE)"
  agent_pid=
  for _ in $(seq 1 20); do
    agent_pid=$(pgrep -f "$FIXTURE_AGENT $FIXTURE_SCRIPT" | grep -vxF -e "${WORKERS:-none}" | head -1)
    [ -z "$agent_pid" ] || break
    sleep 0.5
  done
  [ -n "$agent_pid" ] || fail "$1: the retry's worker never started"
  WORKERS="$WORKERS${WORKERS:+$'\n'}$agent_pid"
  worker=$(proc_cwd "$agent_pid")
  wired=$(grep '^workspace_root=' "$HOME_DIR/state/$ID.cursor-session" | cut -d= -f2-)
  [ "$(real "$recorded")" = "$(real "$worker")" ] \
    || fail "$1: the retry recorded '$recorded' but the worker runs in '$worker'"
  [ "$(real "$wired")" = "$(real "$worker")" ] \
    || fail "$1: the retry wired the worker to '$wired' but the worker runs in '$worker'"
  for slot in "${@:2}"; do
    [ "$(real "$recorded")" != "$(real "$slot")" ] \
      || fail "$1: the retry recorded '$slot', a slot it did not lease"
  done
}

# leave_pane_in_its_slot <n>: attempt <n> for $ID leases its copy, moves its
# pane there, and then refuses before launch, because its task temp root is not
# a private directory. Its pane stays inside that copy, and the copy stays
# leased to $ID, so the retry cannot lease it. Sets LEFTOVER_PANE and
# LEFTOVER_COPY.
leave_pane_in_its_slot() {  # <n>
  local temp_root="/tmp/fm-$ID"
  TASK_IDS="$TASK_IDS $ID"
  write_brief "$ID"
  mkdir -p "$TMP_ROOT/not-private"
  ln -s "$TMP_ROOT/not-private" "$temp_root" \
    || fail "repro setup is wrong: could not plant a non-private task temp root at $temp_root"
  spawn_attempt "$1" && fail "the earlier attempt launched despite its non-private temp root"$'\n'"$(cat "$TMP_ROOT/spawn$1.err")"
  rm -f "$temp_root"
  grep -q "is not a private directory" "$TMP_ROOT/spawn$1.err" \
    || fail "repro setup is wrong: the earlier attempt did not refuse on its temp root"$'\n'"$(cat "$TMP_ROOT/spawn$1.err")"
  [ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "the refused attempt published a task record"
  LEFTOVER_PANE=$(task_pane)
  [ -n "$LEFTOVER_PANE" ] || fail "repro setup is wrong: the refused attempt left no pane behind"
  LEFTOVER_COPY=$(pane_cwd "$LEFTOVER_PANE")
  case "$LEFTOVER_COPY" in
    "$POOL"/.treehouse/*) ;;
    *) fail "repro setup is wrong: the leftover pane is not inside a Treehouse slot ('$LEFTOVER_COPY')" ;;
  esac
}

# start_earlier_get <seconds>: type an interactive `treehouse get` into the
# leftover pane, as an older fm-spawn did, and wait until it fetches an origin
# that answers <seconds> late, still inside the leftover copy. Sets EARLIER_GET.
start_earlier_get() {  # <seconds>
  rm -f "$TMP_ROOT/slow-fetch.started" "$TMP_ROOT/slow-fetch.taken"
  printf '%s\n' "$1" > "$TMP_ROOT/slow-fetch"
  lab pane run "$LEFTOVER_PANE" 'treehouse get' >/dev/null \
    || fail "repro setup is wrong: could not type treehouse get into the lab pane"
  EARLIER_GET=
  for _ in $(seq 1 120); do
    [ ! -e "$TMP_ROOT/slow-fetch.started" ] || EARLIER_GET=$(pane_treehouse_get "$LEFTOVER_PANE")
    [ -z "$EARLIER_GET" ] || break
    sleep 0.25
  done
  [ -n "$EARLIER_GET" ] \
    || fail "repro setup is wrong: Herdr never reported the earlier treehouse get fetching in its lab pane '$LEFTOVER_PANE'"
  [ "$(real "$(pane_cwd "$LEFTOVER_PANE")")" = "$(real "$LEFTOVER_COPY")" ] \
    || fail "repro setup is wrong: the earlier treehouse get already left the leftover copy"
}

# --- 1. the earlier attempt refuses after it moved its pane into its copy ---

ID="retry$$"
leave_pane_in_its_slot 1
pass "setup: the earlier attempt refused before launch and left its pane inside the copy it leased"

# --- 2. the retry records, wires, and runs the worker in one copy -----------

spawn_attempt 2 || fail "the retry did not launch"$'\n'"$(cat "$TMP_ROOT/spawn2.err")"
assert_one_copy "leftover slot" "$LEFTOVER_COPY"
pass "the retry records, wires, and runs the worker in the copy it leased"

# --- 3. an earlier interactive treehouse get still fetches in the pane -------

ID="inflight$$"
leave_pane_in_its_slot 3
start_earlier_get 30
pass "setup: an earlier treehouse get still fetches in the leftover pane"

spawn_attempt 4 || fail "the retry behind an in-flight get did not launch"$'\n'"$(cat "$TMP_ROOT/spawn4.err")"
EARLIER_COPY=$(slot_held_by "$EARLIER_GET") \
  || fail "repro setup is wrong: Treehouse records no slot as held by the earlier treehouse get"
assert_one_copy "in-flight get" "$LEFTOVER_COPY" "$EARLIER_COPY"
pass "a retry behind an in-flight get records, wires, and runs the worker in the copy it leased"

# --- 4. a second earlier get waits in the pane's input behind the first -------

# A pane can hold two earlier gets: one fetching, and one queued in the pane's
# input that starts only once the first enters its slot. The test queues that
# second get by typing it into its own lab pane.
ID="queued$$"
leave_pane_in_its_slot 5
start_earlier_get 25
lab pane run "$LEFTOVER_PANE" 'treehouse get' >/dev/null \
  || fail "repro setup is wrong: could not queue a second treehouse get in the lab pane"
pass "setup: a second earlier treehouse get waits in the pane's input behind the first"

spawn_attempt 6 || fail "the retry behind two earlier gets did not launch"$'\n'"$(cat "$TMP_ROOT/spawn6.err")"
EARLIER_COPY=$(slot_held_by "$EARLIER_GET") \
  || fail "repro setup is wrong: Treehouse records no slot as held by the first earlier treehouse get"
QUEUED_GET=$(pgrep -P "$(pgrep -P "$EARLIER_GET" | head -1)" | head -1)
[ -n "$QUEUED_GET" ] || fail "repro setup is wrong: the queued earlier treehouse get never started"
QUEUED_COPY=$(slot_held_by "$QUEUED_GET") \
  || fail "repro setup is wrong: Treehouse records no slot as held by the queued earlier treehouse get"
assert_one_copy "two queued gets" "$LEFTOVER_COPY" "$EARLIER_COPY" "$QUEUED_COPY"
pass "a retry behind two earlier gets records, wires, and runs the worker in the copy it leased"

cleanup_all || exit 1
trap - EXIT
