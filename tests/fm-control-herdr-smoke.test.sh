#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
# pane-cleanup-on-exit: stopped worker panes close; live and supervisor panes stay.
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

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
# A relaunch replaces a worker's pane, and a new pane starts from the lab
# server's environment rather than the caller's. So the server starts with the
# inert test harness first on PATH and a shell that reads no profile, which
# would otherwise put an installed harness first.
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr-bin.XXXXXX")
FM_LOCAL_LAB_TASK_TMP=$FAKEBIN  # fm_local_lab_finish removes it
printf '#!%s\nexec %s --noprofile --norc -i\n' "$(command -v bash)" "$(command -v bash)" > "$FAKEBIN/shell"
chmod +x "$FAKEBIN/shell"
PATH="$FAKEBIN:$PATH"
# shellcheck source=tests/fm-local-herdr-fixture.sh
. "$ROOT/tests/fm-local-herdr-fixture.sh"
SHELL="$FAKEBIN/shell" fm_local_lab_start || fail "could not prepare isolated Herdr lab session"
SESSION=$FM_LOCAL_LAB_SESSION
LAB_HELPER=$FM_LOCAL_LAB_HELPER
SCRATCH=$FM_LOCAL_LAB_ROOT
HOME_DIR=$FM_HOME
mkdir -p "$HOME_DIR/data/hsmoke"
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
SUPERVISOR_PANE=$(fm_backend_herdr_pane_for_tab "$SESSION" "$WORKSPACE_ID" "$SEEDED_TAB_ID")

new_task_pane() {
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "") \
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
}
new_task_pane

run_control() {
  env FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

settle_shell() {
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" 'exec bash --noprofile --norc -i' \
  || fail "could not establish the childless shell fixture"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" = dead ] && break
  sleep 0.1
done
[ "$STATE" = dead ] || fail "the childless shell fixture should classify as dead, got '$STATE'"
}
settle_shell

assert_task_closed() {
  fm_backend_herdr_endpoint_confirmed_gone "$SESSION:$PANE_ID" || fail "exit left a terminal pane"
  "$LAB_HELPER" run "$SESSION" pane get "$SUPERVISOR_PANE" >/dev/null || fail "exit removed the supervisor pane"
  [ -d "$WT" ] || fail "exit removed the worktree"
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
assert_task_closed
pass "real herdr: exit closes an agent-free pane and preserves the supervisor and worktree"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

new_task_pane
settle_shell

# --- the recovery-grade read, against the real binary ------------------------
#
# The classification that decides whether a task can be recovered at all is read
# out of what herdr actually answers, so a stub can only confirm the assumption
# already written into the stub. Its logic is pinned portably in
# tests/fm-backend-herdr.test.sh; this is the check that notices when the real
# client stops answering the way that logic expects, and it names the version so
# a release change is attributed rather than mysterious.
# The lab's herdr wrapper refuses every other session, so the reads that name a
# session with no server use the real client directly.
HERDR_VERSION=$(PATH=$FM_LOCAL_LAB_REAL_PATH herdr --version 2>&1 | head -1)
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
[ "$(PATH=$FM_LOCAL_LAB_REAL_PATH fm_backend_herdr_server_running_state "fm-lab-never-started-$$")" = stopped ] \
  || version_fail "a session with no server does not report .server.running=false, so authoritative absence can no longer be told from an unreadable read"

# Issue #4091's exact stranding shape: an endpoint recorded in a session whose
# server is not running used to read `unreadable` and block recovery.
[ "$(PATH=$FM_LOCAL_LAB_REAL_PATH fm_backend_agent_state herdr "fm-lab-never-started-$$:w1:p2")" = missing ] \
  || version_fail "an endpoint in a session with no running server is not classified as recoverable"

# And the safety direction: an uninterpretable read must never license recovery.
[ "$(fm_backend_agent_state herdr "no-separator-here")" = unreadable ] \
  || version_fail "a malformed endpoint target does not stay unreadable"
pass "real herdr $HERDR_VERSION: a gone session reads recoverable while a live pane and a malformed target do not"

# A worker relaunch replaces its pane (pane-cleanup-on-exit): the old pane is
# confirmed gone and the record names one new pane in the same session, which
# the rest of this test then drives.
take_relaunched_pane() {  # <case>
  local old=$PANE_ID target
  target=$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)
  [ "${target%%:*}" = "$SESSION" ] || fail "$1 moved the task out of its recorded session: $target"
  PANE_ID=${target#*:}
  [ "$PANE_ID" != "$old" ] || fail "$1 kept the old pane instead of replacing it"
  fm_backend_herdr_endpoint_confirmed_gone "$SESSION:$old" || fail "$1 left the old pane open"
  "$LAB_HELPER" run "$SESSION" pane get "$PANE_ID" >/dev/null 2>&1 \
    || fail "$1 recorded a pane that does not exist"
}

cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
printf -v PROJ_Q '%q' "$PROJ"
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
  || fail "a drifted, agent-free Herdr pane should be relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
take_relaunched_pane "the drifted relaunch"
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$WT_REAL" ] \
  || fail "the relaunched Herdr shell did not end up in its recorded worktree"
awk -F= -v h="$PRIOR_HARNESS" '$1 == "harness" {$0="harness=" h} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a drifted agent-free shell relaunches in a new pane in its worktree and the old pane closes"

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
assert_task_closed
pass "real herdr: stale lifecycle-hook status does not keep a shell-only pane alive"
new_task_pane
settle_shell

# --- the stale registration (issue #4115) does not block relaunch -----------
#
# This is the shape a crew leaves behind when its agent exits but Herdr keeps
# the registration. Before the fix it read alive forever, so every relaunch
# was refused. The registry read below makes the case non-vacuous: Herdr still
# reports the agent, and only the process-level view disagrees.
"$LAB_HELPER" run "$SESSION" pane report-agent "$PANE_ID" \
  --source full_lifecycle_hook_authority --agent pi --state idle >/dev/null 2>&1 \
  || fail "could not register the stale agent on the fresh pane"
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
take_relaunched_pane "the stale-registration relaunch"
[ -d "$WT" ] || fail "the stale-registration relaunch must never remove the task's local copy"
awk -F= -v h="$PRIOR_HARNESS" '$1 == "harness" {$0="harness=" h} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a stale registration does not block relaunch into a new pane, and the local copy survives"

# --- an exact foreground agent process remains protected --------------------

BASH_BIN=$(command -v bash)
[ -x "$BASH_BIN" ] || fail "could not find the Bash fixture executable"
cp "$BASH_BIN" "$SCRATCH/pi"
"$LAB_HELPER" run "$SESSION" pane report-agent "$PANE_ID" \
  --source full_lifecycle_hook_authority --agent pi --state idle >/dev/null 2>&1 \
  || fail "could not register the live lifecycle-hook fixture on its fresh pane"
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
"$LAB_HELPER" run "$SESSION" pane get "$SUPERVISOR_PANE" >/dev/null || fail "interrupt removed the supervisor pane"
pass "real herdr: interrupt preserves the live worker, supervisor, and local copy"

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
