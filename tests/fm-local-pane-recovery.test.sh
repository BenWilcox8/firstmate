#!/usr/bin/env bash
# pane-cleanup-on-exit: watcher/bootstrap recovery and ownership boundaries.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
families=$("$ROOT/bin/fm-test-run.sh" --family backend-dispatch --list)
printf '%s\n' "$families" | grep -Fx 'tests/fm-local-pane-recovery.test.sh' >/dev/null
echo 'ok - pane-cleanup-on-exit tests are registered through the fork family hook'
tmp=$(mktemp -d)
. "$ROOT/tests/fm-local-herdr-process-fixture.sh"
fm_local_test_shell_start "$tmp"
cleanup() {
  if [ -n "${watch_pid:-}" ]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  kill "$FM_LOCAL_TEST_SHELL_PID" 2>/dev/null || true
  wait "$FM_LOCAL_TEST_SHELL_PID" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
export FM_HOME="$tmp/home" FM_BACKEND_HERDR_AXI_BIN='' FM_GATE_REFUSE_BYPASS=1
export FM_LOCAL_TEST_PROCESS_HELPER="$ROOT/tests/fm-local-herdr-process-fixture.sh"
export FM_LOCAL_RECOVERY_FIXTURE=$tmp
mkdir -p "$FM_HOME/state" "$tmp/bin"
cat > "$tmp/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1 $2" in
  'status --json') echo '{"server":{"running":true}}' ;;
  'session list') jq -n --arg path "$FM_LOCAL_RECOVERY_FIXTURE/socket" '{sessions:[{name:"test",running:true,socket_path:$path}]}' ;;
  'workspace list') echo '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}' ;;
  'tab list') echo '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-ended"}]}}' ;;
  'pane list')
    if [ -e "$FM_LOCAL_RECOVERY_FIXTURE/closed" ]; then echo '{"result":{"panes":[]}}'
    else echo '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2","label":"fm-ended"}]}}'; fi ;;
  'pane get')
    if [ -e "$FM_LOCAL_RECOVERY_FIXTURE/closed" ]; then echo '{"error":{"code":"pane_not_found"}}'; exit 1; fi
    echo '{"result":{"pane":{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2","label":"fm-ended","terminal_id":"terminal-1"}}}' ;;
  'agent get') echo '{"error":{"code":"agent_not_found"}}' ;;
  'pane process-info') exec "$FM_LOCAL_TEST_PROCESS_HELPER" "$@" ;;
  'pane close')
    touch "$FM_LOCAL_RECOVERY_FIXTURE/closed" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/herdr"
export PATH="$tmp/bin:$PATH"
cat > "$FM_HOME/state/ended.meta" <<META
window=test:w1:p2
endpoint_task_id=ended
kind=ship
worktree=$tmp/worktree
project=$tmp/project
backend=herdr
spawn_gen=old
herdr_session=test
herdr_workspace_id=w1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
META
META="$FM_HOME/state/ended.meta"
cp "$META" "$tmp/original.meta"

# A fresh spawn holds the task meta lock while its new pane is still a shell.
. "$ROOT/bin/fm-wake-lib.sh"
fm_lock_try_acquire "$FM_HOME/state/.meta-ended.lock"
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
[ ! -e "$tmp/closed" ]
fm_lock_release "$FM_HOME/state/.meta-ended.lock"
echo 'ok - recovery skips a pane whose fresh spawn holds the task meta lock'
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
[ -f "$META" ] && [ -f "$tmp/closed" ]
echo 'ok - recovery closes an ended worker pane while preserving its task record'

# Unknown process evidence cannot authorize a close.
rm "$tmp/closed"
cp "$tmp/original.meta" "$META"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/unreadable-ps"
chmod +x "$tmp/unreadable-ps"
FM_HERDR_PS_BIN="$tmp/unreadable-ps" "$ROOT/bin/fm-local-pane-cleanup.sh" sweep
[ ! -e "$tmp/closed" ]
echo 'ok - automatic cleanup preserves a pane with unreadable process evidence'

# Supervisor task records cannot authorize automatic pane cleanup.
sed 's/kind=ship/kind=secondmate/' "$META" > "$META.tmp"
mv "$META.tmp" "$META"
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
[ ! -e "$tmp/closed" ]
echo 'ok - automatic cleanup preserves a secondmate supervisor pane'

# Drive the actual watcher entry point, not its helper alone.
watch_home="$tmp/watch-home"
mkdir -p "$watch_home/state" "$watch_home/config" "$watch_home/data" "$watch_home/projects"
cp "$tmp/original.meta" "$watch_home/state/ended.meta"
FM_HOME="$watch_home" FM_STATE_OVERRIDE="$watch_home/state" FM_POLL=0.1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$tmp/watch.log" 2>&1 &
watch_pid=$!
for ((i=0; i<300; i++)); do
  [ ! -e "$tmp/closed" ] || break
  kill -0 "$watch_pid" 2>/dev/null || break
  sleep 0.1
done
[ -e "$tmp/closed" ] || { cat "$tmp/watch.log"; exit 1; }
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
watch_pid=
echo 'ok - watcher poll closes an ended worker pane through its hook'

# Drive bootstrap locally, with no network phase or project repositories.
rm "$tmp/closed"
FM_HOME="$watch_home" FM_STATE_OVERRIDE="$watch_home/state" FM_BOOTSTRAP_NETWORK=skip \
  "$ROOT/bin/fm-bootstrap.sh" > "$tmp/bootstrap.log" 2>&1
[ -e "$tmp/closed" ] || { cat "$tmp/bootstrap.log"; exit 1; }
echo 'ok - bootstrap cleans restored shells before layout repair'

cat > "$tmp/bin/agent-axi-fixture" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'list '*) echo '{"workspace":{"id":"w1"},"crew":[]}' ;;
  'layout --repair --dry-run --json') cat "$FM_LOCAL_RECOVERY_FIXTURE/plan.json" ;;
  'layout --repair --json')
    touch "$FM_LOCAL_RECOVERY_FIXTURE/mutating-repair"
    echo '{"repair":{"converged":false,"counts":{"freed":1}}}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/agent-axi-fixture"
bootstrap_repair() {
  FM_HOME="$watch_home" FM_STATE_OVERRIDE="$watch_home/state" FM_BOOTSTRAP_NETWORK=skip \
    FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN="$tmp/bin/agent-axi-fixture" \
    "$ROOT/bin/fm-bootstrap.sh" > "$tmp/bootstrap.log" 2>&1
}
sed 's/^endpoint_task_id=.*/endpoint_task_id=protected/' "$tmp/original.meta" > "$watch_home/state/protected.meta"
echo '{"repair":{"converged":false,"actions":[{"kind":"close-husk","taskId":"retired","paneId":"w1:p5"},{"kind":"close-husk","taskId":"protected","paneId":"w1:p3"}]}}' > "$tmp/plan.json"
bootstrap_repair
[ ! -e "$tmp/mutating-repair" ] || { cat "$tmp/bootstrap.log"; exit 1; }
grep -F 'skipped herdr layout repair' "$tmp/bootstrap.log" > "$tmp/skip.log"
grep -F 'protected w1:p3' "$tmp/skip.log" >/dev/null && ! grep -F 'retired' "$tmp/skip.log" >/dev/null
echo 'ok - bootstrap skips and reports a layout repair whose plan would close a recorded task pane'
echo '{"repair":{"converged":false,"actions":[{"kind":"close-husk","taskId":"retired","paneId":"w1:p5"},{"kind":"close-orphan-husk","paneId":"w1:p6"}]}}' > "$tmp/plan.json"
bootstrap_repair
[ -e "$tmp/mutating-repair" ] || { cat "$tmp/bootstrap.log"; exit 1; }
rm "$tmp/mutating-repair"
echo 'ok - bootstrap still heals husks that have no task record in this home'
echo '{"repair":{"converged":false,"actions":[{"kind":"free-gone","taskId":"gone","paneId":"w1:p4"}]}}' > "$tmp/plan.json"
bootstrap_repair
[ -e "$tmp/mutating-repair" ] || { cat "$tmp/bootstrap.log"; exit 1; }
grep -F 'BOOTSTRAP_INFO: healed herdr layout drift: 0 husk(s), 0 rebind, 1 freed' "$tmp/bootstrap.log" >/dev/null
echo 'ok - bootstrap runs the existing layout repair when its plan closes no pane'
