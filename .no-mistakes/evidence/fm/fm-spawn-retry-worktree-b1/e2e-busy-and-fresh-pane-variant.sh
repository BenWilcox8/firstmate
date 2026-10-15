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

EVIDENCE_DIR=${EVIDENCE_DIR:?}
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

# --- A. adversarial: the leftover pane is busy with a long command ----------
# The test starts `sleep 917` in its own lab pane, so the pane's foreground is
# not an idle shell. The retry must refuse within its bound, name the pane,
# not type `treehouse get`, and leave the pane open.
lab pane run "$LEFTOVER_PANE" 'sleep 917' >/dev/null || fail "could not start a long command in the lab pane"
BUSY_PID=
for _ in $(seq 1 40); do
  BUSY_PID=$(lab pane process-info --pane "$LEFTOVER_PANE" 2>/dev/null | jq -r '.result.process_info.foreground_processes[]? | select(.argv == ["sleep","917"]) | .pid' | head -1)
  [ -z "$BUSY_PID" ] || break
  sleep 0.25
done
[ -n "$BUSY_PID" ] || fail "repro setup is wrong: Herdr never reported sleep 917 in the lab pane foreground"
printf '  [busy pane] leftover pane %s foreground: %s\n' "$LEFTOVER_PANE" "$(lab pane process-info --pane "$LEFTOVER_PANE" | jq -c '[.result.process_info.foreground_processes[] | .argv]')"
lab pane read "$LEFTOVER_PANE" --source visible --format text > "$EVIDENCE_DIR/busy-pane-screen-before-retry.txt" 2>&1
SLOTS_BEFORE=$(ls -d "$POOL"/.treehouse/*/*/proj 2>/dev/null | sort | tr '\n' ' ')
t0=$(date +%s)
spawn_attempt 2 && fail "the retry launched into a busy leftover pane"$'\n'"$(cat "$TMP_ROOT/spawn2.out")"
t1=$(date +%s)
printf '  [busy pane] retry exited non-zero after %ss\n' "$((t1 - t0))"
printf '  [busy pane] retry stderr: %s\n' "$(grep '^error' "$TMP_ROOT/spawn2.err")"
grep -q "was left behind by an earlier attempt for task $ID, and no idle shell held its foreground" "$TMP_ROOT/spawn2.err" \
  || fail "busy pane: the retry did not refuse for a busy leftover pane"
grep -qF "$LEFTOVER_PANE" "$TMP_ROOT/spawn2.err" || fail "busy pane: the refusal did not name the leftover pane"
[ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "busy pane: the refused retry published a task record"
[ "$(task_pane)" = "$LEFTOVER_PANE" ] || fail "busy pane: the leftover pane was closed"
printf '  [busy pane] leftover pane still open after refusal: %s\n' "$(task_pane)"
# Prove nothing was typed into the pane: stop the test's own sleep and watch
# for a `treehouse get` that would have waited behind it.
kill "$BUSY_PID" 2>/dev/null
sleep 6
lab pane read "$LEFTOVER_PANE" --source visible --format text >"$EVIDENCE_DIR/busy-pane-screen-after-refusal.txt" 2>&1
QUEUED=$(lab pane process-info --pane "$LEFTOVER_PANE" | jq -r '.result.process_info.foreground_processes[]? | select(.argv[0] == "treehouse") | .pid')
[ -z "$QUEUED" ] || fail "busy pane: a treehouse get ran after the sleep ended, so the refused retry typed into the pane"
SLOTS_AFTER=$(ls -d "$POOL"/.treehouse/*/*/proj 2>/dev/null | sort | tr '\n' ' ')
printf '  [busy pane] pool slots before retry: %s\n  [busy pane] pool slots after retry and sleep end: %s\n' "$SLOTS_BEFORE" "$SLOTS_AFTER"
[ "$SLOTS_BEFORE" = "$SLOTS_AFTER" ] || fail "busy pane: a new Treehouse slot appeared, so the refused retry typed treehouse get"
GETS_SHOWN_BEFORE=$(grep -c 'treehouse get' "$EVIDENCE_DIR/busy-pane-screen-before-retry.txt")
GETS_SHOWN_AFTER=$(grep -c 'treehouse get' "$EVIDENCE_DIR/busy-pane-screen-after-refusal.txt")
printf '  [busy pane] typed treehouse get lines on the pane screen: before retry %s, after refusal %s\n' "$GETS_SHOWN_BEFORE" "$GETS_SHOWN_AFTER"
[ -s "$EVIDENCE_DIR/busy-pane-screen-after-refusal.txt" ] || fail "busy pane: could not read the pane screen"
[ "$GETS_SHOWN_BEFORE" = "$GETS_SHOWN_AFTER" ] || fail "busy pane: the pane screen shows a treehouse get the refused retry typed"
pass "busy pane: the retry refused within its bound, named the leftover pane, typed nothing, and left the pane open"

# --- B. regression: a normal spawn in a fresh pane is unchanged -------------
: > "$TMP_ROOT/dirtied"   # the post-checkout hook leaves the next slot clean
ID=fresh1
write_brief "$ID"
t0=$(date +%s)
spawn_attempt 3 || fail "a fresh spawn did not launch"$'\n'"$(cat "$TMP_ROOT/spawn3.err")"
t1=$(date +%s)
printf '  [fresh pane] spawn launched in %ss\n' "$((t1 - t0))"
! grep -q "left behind by an earlier attempt" "$TMP_ROOT/spawn3.err" || fail "fresh pane: the spawn took the reused-pane path"
LEFTOVER_PANE=$(task_pane)
assert_one_copy "fresh pane" "/nonexistent"
pass "fresh pane: a first spawn in a new pane records, wires, and runs the worker in one copy"

cleanup_all || exit 1
trap - EXIT
