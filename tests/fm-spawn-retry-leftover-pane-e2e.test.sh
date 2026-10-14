#!/usr/bin/env bash
# tests/fm-spawn-retry-leftover-pane-e2e.test.sh - isolated real-Herdr,
# real-Treehouse regression test for a spawn retried after a "not clean"
# refusal.
#
# The guarantee under test: the copy fm-spawn records as worktree=, the copy its
# per-task wiring names, and the copy the worker actually runs in are the same,
# including on a retry after the first attempt refused its copy as not clean.
#
# The first attempt enters a Treehouse slot whose setup is slow and transiently
# dirty, so the clean check refuses it and fm-spawn exits. Its pane stays behind
# inside that slot's Treehouse subshell, and agent-axi hands the same pane back
# to the retry. The retry's `treehouse get` fetches a slow origin before it
# moves, so the pane keeps reporting the old slot for several reads and then
# enters a new one. Before the fix, the retry recorded the old slot and wired the
# worker there while the worker ran in the new slot.
#
# This drives the REAL bin/fm-spawn.sh, treehouse, and agent-axi, because the
# defect spans the whole handoff and no adapter primitive holds it alone.
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

ID=retry1
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/$ID"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Exercise a spawn retry for $ID.

## Firstmate spec
Verify the recorded copy is the copy the worker runs in.
EOF

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

# --- 1. the first attempt refuses its transiently dirty slot -----------------

spawn_attempt 1 && fail "the first attempt launched despite its dirty slot"$'\n'"$(cat "$TMP_ROOT/spawn1.err")"
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
META="$HOME_DIR/state/$ID.meta"
RECORDED=$(grep '^worktree=' "$META" | cut -d= -f2-)
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ "$PANE" = "$LEFTOVER_PANE" ] \
  || fail "repro setup is wrong: the retry was not handed the leftover pane back ($PANE, not $LEFTOVER_PANE)"
AGENT_PID=
for _ in $(seq 1 20); do
  AGENT_PID=$(pgrep -f "$FIXTURE_AGENT $FIXTURE_SCRIPT" | head -1)
  [ -z "$AGENT_PID" ] || break
  sleep 0.5
done
[ -n "$AGENT_PID" ] || fail "the retry's worker never started"
WORKER_COPY=$(readlink "/proc/$AGENT_PID/cwd" 2>/dev/null || lsof -a -p "$AGENT_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
WIRED=$(grep '^workspace_root=' "$HOME_DIR/state/$ID.cursor-session" | cut -d= -f2-)

[ "$(real "$RECORDED")" = "$(real "$WORKER_COPY")" ] \
  || fail "the retry recorded '$RECORDED' but the worker runs in '$WORKER_COPY'"
[ "$(real "$WIRED")" = "$(real "$WORKER_COPY")" ] \
  || fail "the retry wired the worker to '$WIRED' but the worker runs in '$WORKER_COPY'"
[ "$(real "$RECORDED")" != "$(real "$LEFTOVER_COPY")" ] \
  || fail "the retry recorded the copy the leftover pane was already in"
pass "fixed: the retry records, wires, and runs the worker in the copy its treehouse get entered"

cleanup_all || exit 1
trap - EXIT
