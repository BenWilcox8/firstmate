#!/usr/bin/env bash
# tests/fm-spawn-retry-leftover-pane-e2e.test.sh - isolated real-Herdr,
# real-Treehouse regression test for a spawn retried in the pane an earlier
# attempt left behind.
#
# The guarantee under test: the copy fm-spawn records as worktree=, the copy its
# per-task wiring names, and the copy the worker actually runs in are the same,
# including on a retry in the pane an earlier attempt left behind.
#
# Three sequences leave such a pane, and agent-axi hands it back to the retry in
# each. In the first, the earlier attempt enters a Treehouse slot whose setup is
# slow and transiently dirty, so the clean check refuses it and fm-spawn exits,
# leaving its pane inside that slot's Treehouse subshell. In the second, the
# earlier attempt stops while its own `treehouse get` still fetches. In the
# third, a second earlier get also waits in the pane's input behind that one.
# Each way the retry's `treehouse get` fetches a slow origin inside a slot the
# retry did not acquire, so the pane reports that slot for several reads before
# it enters a new one. Without the fix, the retry recorded that slot and wired
# the worker there while the worker ran in the new slot.
#
# This drives the REAL bin/fm-spawn.sh, treehouse, and agent-axi, because the
# defect spans the whole handoff and no adapter primitive holds it alone.
#
# Safety (tests/herdr-test-safety.sh): every Herdr call goes through
# bin/fm-herdr-lab.sh, which scopes it to this test's own named session and
# verifies the default fleet session is unchanged after teardown.
set -u

ROOT="${E2E_ROOT:?set E2E_ROOT to the checkout under test}"

fail() { printf "not ok - %s\n" "$1" >&2; for f in "$TMP_ROOT"/spawn*.err; do [ -s "$f" ] && printf "  [%s]\n%s\n" "${f##*/}" "$(tail -5 "$f")" >&2; done; cleanup_all; exit 1; }
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

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-spawn-retry) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
POOL="$TMP_ROOT/pool"

CLEANED=0
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  pkill -f "$FIXTURE_AGENT $FIXTURE_SCRIPT" 2>/dev/null || true
  for wt in "$POOL"/.treehouse/*/*/proj; do
    [ -d "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
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
# A slow origin, like a real network fetch: `treehouse get` fetches before it
# moves the pane, so the pane keeps reporting where it already was.
git -C "$PROJ" config remote.origin.uploadpack "sleep 4; git-upload-pack"
# The first slot's setup is slow and leaves an untracked file in the slot for a
# few seconds, so the first attempt's clean check refuses it.
cat > "$PROJ/.git/hooks/post-checkout" <<EOF
#!/bin/sh
[ -e "$TMP_ROOT/dirtied" ] && exit 0
: > "$TMP_ROOT/dirtied"
echo transient > setup-in-progress.txt
sleep 6
rm -f setup-in-progress.txt
EOF
chmod +x "$PROJ/.git/hooks/post-checkout"

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

# assert_one_copy <label> <slot>: the retry for $ID launched, and the copy it
# recorded, the copy its wiring names, and the copy its new worker runs in are
# one copy, which is not <slot>, a slot the retry's own get did not acquire.
WORKERS=
assert_one_copy() {
  local meta="$HOME_DIR/state/$ID.meta" recorded pane agent_pid worker wired
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
  printf "  [%s] meta worktree=%s\n  [%s] hook wiring workspace_root=%s\n  [%s] worker cwd=%s\n  [%s] slot the retry did not acquire=%s\n" "$1" "$recorded" "$1" "$wired" "$1" "$worker" "$1" "$2"
  [ "$(real "$recorded")" = "$(real "$worker")" ] \
    || fail "$1: the retry recorded '$recorded' but the worker runs in '$worker'"
  [ "$(real "$wired")" = "$(real "$worker")" ] \
    || fail "$1: the retry wired the worker to '$wired' but the worker runs in '$worker'"
  [ "$(real "$recorded")" != "$(real "$2")" ] \
    || fail "$1: the retry recorded '$2', a slot its own treehouse get did not acquire"
}

# --- 1. the first attempt refuses its transiently dirty slot -----------------

ID=retry1
write_brief "$ID"
spawn_attempt 1 && fail "the first attempt launched despite its dirty slot"$'\n'"$(cat "$TMP_ROOT/spawn1.err")"
printf "  [attempt 1 stderr] %s\n" "$(grep -m1 "not clean" "$TMP_ROOT/spawn1.err")"
grep -q "is not clean" "$TMP_ROOT/spawn1.err" \
  || fail "the first attempt did not refuse as not clean"$'\n'"$(cat "$TMP_ROOT/spawn1.err")"
[ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "the refused attempt published a task record"
# Let Treehouse finish entering the first slot, as it does after a refusal.
sleep 8
LEFTOVER_PANE=$(task_pane)
[ -n "$LEFTOVER_PANE" ] || fail "repro setup is wrong: the refused attempt left no pane behind"
LEFTOVER_COPY=$(pane_cwd "$LEFTOVER_PANE")
case "$LEFTOVER_COPY" in
  "$POOL"/.treehouse/*) ;;
  *) fail "repro setup is wrong: the leftover pane is not inside a Treehouse slot ('$LEFTOVER_COPY')" ;;
esac
pass "setup: the first attempt refused its dirty slot and left its pane inside that slot"

# --- 2. the retry records, wires, and runs the worker in one copy -----------

spawn_attempt 2 || fail "the retry did not launch"$'\n'"$(cat "$TMP_ROOT/spawn2.err")"
assert_one_copy "leftover slot" "$LEFTOVER_COPY"
pass "fixed: the retry records, wires, and runs the worker in the copy its treehouse get entered"

# stop_attempt_mid_get <n>: start attempt <n> for $ID and stop its fm-spawn
# while that attempt's own `treehouse get` still fetches in the project, as a
# spawn interrupted mid-get leaves its pane. Sets LEFTOVER_PANE and EARLIER_GET.
stop_attempt_mid_get() {
  local attempt spawn
  spawn_attempt "$1" 2>/dev/null &
  attempt=$!
  LEFTOVER_PANE=
  EARLIER_GET=
  for _ in $(seq 1 120); do
    [ -n "$LEFTOVER_PANE" ] || LEFTOVER_PANE=$(task_pane)
    [ -z "$LEFTOVER_PANE" ] || EARLIER_GET=$(pane_treehouse_get "$LEFTOVER_PANE")
    [ -z "$EARLIER_GET" ] || break
    sleep 0.25
  done
  [ -n "$EARLIER_GET" ] \
    || fail "repro setup is wrong: Herdr never reported the earlier attempt's own treehouse get in its lab pane '${LEFTOVER_PANE:-none}'"
  spawn=$(pgrep -P "$attempt" -f 'bin/fm-spawn\.sh' | head -1)
  [ -n "$spawn" ] \
    || fail "repro setup is wrong: no fm-spawn started by this test's earlier attempt is still running"
  kill -TERM "$spawn" 2>/dev/null
  wait "$attempt" 2>/dev/null
  [ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "the stopped attempt published a task record"
  [ "$(task_pane)" = "$LEFTOVER_PANE" ] || fail "repro setup is wrong: the stopped attempt left no pane behind"
  [ "$(real "$(pane_cwd "$LEFTOVER_PANE")")" = "$(real "$PROJ")" ] \
    || fail "repro setup is wrong: the earlier attempt's treehouse get already left the project"
}

# --- 3. the earlier attempt stops while its own treehouse get still fetches --

# A slower origin, so the earlier attempt's get still fetches in the project
# when the retry reaches the same pane.
git -C "$PROJ" config remote.origin.uploadpack "sleep 15; git-upload-pack"
ID=inflight1
write_brief "$ID"
stop_attempt_mid_get 3
pass "setup: the earlier attempt stopped while its own treehouse get still fetches in its pane"

spawn_attempt 4 || fail "the retry behind an in-flight get did not launch"$'\n'"$(cat "$TMP_ROOT/spawn4.err")"
EARLIER_COPY=$(proc_cwd "$(pgrep -P "$EARLIER_GET" | head -1)")
case "$EARLIER_COPY" in
  "$POOL"/.treehouse/*) ;;
  *) fail "repro setup is wrong: the earlier attempt's get did not enter a Treehouse slot ('$EARLIER_COPY')" ;;
esac
assert_one_copy "in-flight get" "$EARLIER_COPY"
pass "fixed: a retry behind an in-flight get records, wires, and runs the worker in the copy its own get entered"

# --- 4. a second earlier get waits in the pane's input behind the first -------

# A retry that typed its get behind an earlier get still in flight leaves two
# earlier gets in the pane: one fetching, and one queued in the pane's input
# that starts only once the first enters its slot. The test queues that second
# get by typing it into its own lab pane, as such a retry did.
git -C "$PROJ" config remote.origin.uploadpack "sleep 10; git-upload-pack"
ID=queued1
write_brief "$ID"
stop_attempt_mid_get 5
lab pane run "$LEFTOVER_PANE" 'treehouse get' >/dev/null \
  || fail "repro setup is wrong: could not queue a second treehouse get in the lab pane"
pass "setup: a second earlier treehouse get waits in the pane's input behind the first"

spawn_attempt 6 || fail "the retry behind two earlier gets did not launch"$'\n'"$(cat "$TMP_ROOT/spawn6.err")"
QUEUED_GET=$(pgrep -P "$(pgrep -P "$EARLIER_GET" | head -1)" | head -1)
QUEUED_COPY=$(proc_cwd "$(pgrep -P "$QUEUED_GET" | head -1)")
case "$QUEUED_COPY" in
  "$POOL"/.treehouse/*) ;;
  *) fail "repro setup is wrong: the queued earlier get did not enter a Treehouse slot ('$QUEUED_COPY')" ;;
esac
assert_one_copy "two queued gets" "$QUEUED_COPY"
pass "fixed: a retry behind two earlier gets records, wires, and runs the worker in the copy its own get entered"

cleanup_all || exit 1
trap - EXIT
