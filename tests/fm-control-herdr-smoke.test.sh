#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# requires stable lifecycle-registry evidence and exact process ownership.
#
# No model-backed agent is launched.
# A process named `pi` models the exact foreground-process identity that the
# recovery classifier requires in addition to Herdr's hook registry.
#
# Always runs through the guarded helper on a private, named, throwaway lab
# session, never the default one.
# It skips cleanly when Herdr, jq, or the helper is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || { echo "skip: guarded Herdr lab helper not found"; exit 0; }
SESSION=$("$LAB_HELPER" name "control-smoke-$$") \
  || { echo "skip: could not generate a guarded Herdr lab name"; exit 0; }
export HERDR_SESSION="$SESSION"
unset HERDR_PANE_ID HERDR_TERMINAL_ID HERDR_WORKSPACE_ID HERDR_TAB_ID
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT
"$LAB_HELPER" provision "$SESSION" >/dev/null \
  || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# Keep this lifecycle smoke on the adapter's native one-pane path.
export FM_BACKEND_HERDR_AXI_BIN=
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=pi"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" 'exec bash --noprofile --norc -i' \
  || fail "could not establish the childless shell fixture"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" = dead ] && break
  sleep 0.1
done
[ "$STATE" = dead ] || fail "the childless shell fixture should classify as dead, got '$STATE'"

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a stale hook cannot replace process evidence ---------------------------

"$LAB_HELPER" run "$SESSION" pane report-agent "$PANE_ID" \
  --source full_lifecycle_hook_authority --agent pi --state idle >/dev/null 2>&1 \
  || fail "could not register the stale lifecycle-hook fixture"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] || fail "a stale hook over a shell-only pane should classify as dead, got '$STATE'"
OUT=$(run_control hsmoke exit) || fail "exit should accept the proved shell-only stale record: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "the stale hook should not keep the exited agent alive, got: $OUT" ;;
esac
pass "real herdr: stale lifecycle-hook status does not keep a shell-only pane alive"

# --- an exact foreground agent process remains protected --------------------

BASH_BIN=$(command -v bash)
[ -x "$BASH_BIN" ] || fail "could not find the Bash fixture executable"
cp "$BASH_BIN" "$SCRATCH/pi"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "$SCRATCH/pi -c 'trap \"\" INT TERM HUP; while :; do sleep 300; done'" \
  || fail "could not start the foreground Pi process fixture"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" != alive ] || break
  sleep 0.1
done
[ "$STATE" = alive ] || fail "the exact foreground Pi process should classify as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against an active agent process should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=pi backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt protects an exact foreground agent process"

"$LAB_HELPER" run "$SESSION" pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because the fake Pi process does not implement Pi's exit command.
# The control plane must report that it remains alive.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
