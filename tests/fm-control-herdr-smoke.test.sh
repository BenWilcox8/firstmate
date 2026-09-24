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
# Cases cover a live process, a plain shell, and a stale agent registration.
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
cat > "$HOME_DIR/data/hsmoke/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr lifecycle control safely.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"
PROJ_REAL=$(cd "$PROJ" && pwd -P)
WT_REAL=$(cd "$WT" && pwd -P)

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

# --- the recovery-grade read, against the real binary ------------------------
#
# The classification that decides whether a task can be recovered at all is read
# out of what herdr actually answers, so a stub can only confirm the assumption
# already written into the stub. Its logic is pinned portably in
# tests/fm-backend-herdr.test.sh; this is the check that notices when the real
# client stops answering the way that logic expects, and it names the version so
# a release change is attributed rather than mysterious.
HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a real, present, agent-free pane reads '$STATE' rather than 'dead'; every relaunch would be refused"

# `status --json` is the second signal, and the only one that answers for a
# session whose operational calls cannot be reached at all. A release that drops
# or renames `.server.running` would silently make every gone endpoint
# unrecoverable again, so it is asserted by name on both a live and an absent
# session.
[ "$(fm_backend_herdr_server_running_state "$SESSION")" = running ] \
  || version_fail "this run's own live lab session does not report .server.running=true through status --json"
[ "$(fm_backend_herdr_server_running_state "fm-lab-never-started-$$")" = stopped ] \
  || version_fail "a session with no server does not report .server.running=false, so authoritative absence can no longer be told from an unreadable read"

# Issue #4091's exact stranding shape: an endpoint recorded in a session whose
# server is not running used to read `unreadable` and block recovery.
[ "$(fm_backend_agent_state herdr "fm-lab-never-started-$$:w1:p2")" = missing ] \
  || version_fail "an endpoint in a session with no running server is not classified as recoverable"

# And the safety direction: an uninterpretable read must never license recovery.
[ "$(fm_backend_agent_state herdr "no-separator-here")" = unreadable ] \
  || version_fail "a malformed endpoint target does not stay unreadable"
pass "real herdr $HERDR_VERSION: a gone session reads recoverable while a live pane and a malformed target do not"

FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
printf -v PROJ_Q '%q' "$PROJ"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the inert test harness on the pane PATH"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd -- $PROJ_Q" \
  || fail "could not move the agent-free pane out of its recorded worktree"
PRIOR_HARNESS=$(sed -n 's/^harness=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)
for _ in $(seq 1 20); do
  [ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" != "$PROJ_REAL" ] || break
  sleep 0.1
done
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$PROJ_REAL" ] \
  || fail "the real Herdr pane did not drift out of its recorded worktree"

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a drifted, agent-free Herdr pane should be re-homed and relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$WT_REAL" ] \
  || fail "the relaunched Herdr shell did not end up in its recorded worktree"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the Herdr relaunch replaced its endpoint instead of reusing it"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the Herdr relaunch removed the endpoint it was required to reuse"
awk -F= -v h="$PRIOR_HARNESS" '$1 == "harness" {$0="harness=" h} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint"

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

# --- the stale registration (issue #4115) does not block relaunch -----------
#
# This is the shape a crew leaves behind when its agent exits but Herdr keeps
# the registration. Before the fix it read alive forever, so every relaunch
# was refused. The registry read below makes the case non-vacuous: Herdr still
# reports the agent, and only the process-level view disagrees.
REGISTERED=$("$LAB_HELPER" run "$SESSION" agent get "$PANE_ID" 2>/dev/null \
  | jq -r '.result.agent.agent_status // empty')
[ -n "$REGISTERED" ] \
  || version_fail "Herdr released the registration, so this run cannot prove the stale-registration relaunch"
PRIOR_HARNESS=$(sed -n 's/^harness=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)
rm -f "$SCRATCH/codex-launched"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a stale-registration Herdr pane should be relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched after the stale registration"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the stale-registration relaunch replaced its endpoint instead of reusing it"
"$LAB_HELPER" run "$SESSION" pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the stale-registration relaunch removed the endpoint it was required to reuse"
[ -d "$WT" ] || fail "the stale-registration relaunch must never remove the task's local copy"
awk -F= -v h="$PRIOR_HARNESS" '$1 == "harness" {$0="harness=" h} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a stale registration does not block relaunch, and the endpoint and local copy survive"

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
  fail "exit should fail closed when the agent's composer is not proven empty: $OUT"
fi
case "$OUT" in
  *"not proven empty"*) : ;;
  *) fail "the exit failure should say the composer is not proven empty, got: $OUT" ;;
esac
pass "real herdr: an agent behind an unproven composer fails closed instead of typing an exit command into it"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
