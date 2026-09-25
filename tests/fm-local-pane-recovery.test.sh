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
  'workspace list')
    ws='[{"workspace_id":"w1","label":"firstmate"}]'
    jq -n --argjson ws "${FM_LOCAL_RECOVERY_WORKSPACES:-$ws}" '{result:{workspaces:$ws}}' ;;
  'tab list') echo '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-ended"}]}}' ;;
  'pane list')
    if [ -e "$FM_LOCAL_RECOVERY_FIXTURE/closed" ]; then echo '{"result":{"panes":[]}}'
    elif [ -n "${FM_LOCAL_RECOVERY_PANES:-}" ]; then jq -n --argjson panes "$FM_LOCAL_RECOVERY_PANES" '{result:{panes:$panes}}'
    else echo '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2","label":"fm-ended"}]}}'; fi ;;
  'pane get')
    if [ -e "$FM_LOCAL_RECOVERY_FIXTURE/closed" ] || [ -n "${FM_LOCAL_RECOVERY_GONE:-}" ]; then
      echo '{"error":{"code":"pane_not_found"}}'; exit 1
    fi
    pane='{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2","label":"fm-ended","terminal_id":"terminal-1"}'
    jq -n --argjson pane "$pane" --argjson with "${FM_LOCAL_RECOVERY_PANE_GET:-null}" '{result:{pane:($pane + ($with // {}))}}' ;;
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
[ -f "$META" ]
[ -f "$tmp/closed" ]
echo 'ok - recovery closes an ended worker pane while preserving its task record'

# A duplicated home label resolves only to the task's recorded workspace.
rm "$tmp/closed"
FM_LOCAL_RECOVERY_WORKSPACES='[{"workspace_id":"w9","label":"firstmate"},{"workspace_id":"w8","label":"firstmate"}]' \
  "$ROOT/bin/fm-local-pane-cleanup.sh" sweep 2>/dev/null
[ ! -e "$tmp/closed" ]
FM_LOCAL_RECOVERY_WORKSPACES='[{"workspace_id":"w9","label":"firstmate"},{"workspace_id":"w1","label":"firstmate"}]' \
  "$ROOT/bin/fm-local-pane-cleanup.sh" sweep
[ -f "$META" ]
[ -f "$tmp/closed" ]
echo 'ok - a duplicated home label resolves to the recorded workspace, never to a guess'

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

# agent-axi cannot list a home whose workspace is gone. The native workspace
# listing proves that absence, while other inventory failures still refuse.
cat > "$tmp/bin/agent-axi-unreadable" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FM_LOCAL_RECOVERY_FIXTURE/axi.log"
echo 'error: agent-axi inventory unavailable' >&2
exit 1
SH
chmod +x "$tmp/bin/agent-axi-unreadable"
absent_home="$tmp/absent-home"
mkdir -p "$absent_home/state"
{ cat "$tmp/original.meta"; echo harness=pi; } > "$absent_home/state/ended.meta"
rm -f "$tmp/closed"
out=$(FM_HOME="$absent_home" FM_BACKEND_HERDR_AXI_BIN="$tmp/bin/agent-axi-unreadable" FM_LOCAL_RECOVERY_WORKSPACES='[]' \
  FM_LOCAL_RECOVERY_GONE=1 "$ROOT/bin/fm-control.sh" ended exit)
case "$out" in already-stopped*) ;; *) echo "not ok - exit output: $out" >&2; exit 1 ;; esac
[ ! -e "$tmp/closed" ]
[ -f "$absent_home/state/ended.meta" ]
echo 'ok - exit treats a missing home workspace as proof that no task pane remains'
if FM_HOME="$absent_home" FM_BACKEND_HERDR_AXI_BIN="$tmp/bin/agent-axi-unreadable" FM_LOCAL_RECOVERY_WORKSPACES='[]' \
    "$ROOT/bin/fm-control.sh" ended exit > "$tmp/renamed.out" 2>&1; then
  echo "not ok - a renamed home workspace hid a recorded pane that still exists: $(cat "$tmp/renamed.out")" >&2
  exit 1
fi
grep -F 'recorded pane test:w1:p2 is not proven gone' "$tmp/renamed.out" >/dev/null
[ ! -e "$tmp/closed" ]
[ -f "$absent_home/state/ended.meta" ]
echo 'ok - exit refuses when the home workspace is missing but the recorded pane still exists'
if FM_HOME="$absent_home" FM_BACKEND_HERDR_AXI_BIN="$tmp/bin/agent-axi-unreadable" \
    "$ROOT/bin/fm-control.sh" ended exit > "$tmp/unreadable.out" 2>&1; then
  echo 'not ok - an unreadable crew inventory was accepted as an absence proof' >&2
  exit 1
fi
[ ! -e "$tmp/closed" ]
echo 'ok - exit refuses when the home workspace exists but its crew inventory is unreadable'

# One failed inventory read covers every task in that session for the sweep.
sed 's/^endpoint_task_id=.*/endpoint_task_id=other/' "$absent_home/state/ended.meta" > "$absent_home/state/other.meta"
: > "$tmp/axi.log"
FM_HOME="$absent_home" FM_BACKEND_HERDR_AXI_BIN="$tmp/bin/agent-axi-unreadable" \
  "$ROOT/bin/fm-local-pane-cleanup.sh" sweep 2>/dev/null
[ "$(grep -c '^list ' "$tmp/axi.log")" = 1 ] || { cat "$tmp/axi.log"; exit 1; }
[ ! -e "$tmp/closed" ]
echo 'ok - a sweep reads a failed session inventory once and closes nothing'

# A captain split leaves the worker pane unlabeled in a two-pane task tab.
# Label resolution then finds no owned pane, but the recorded pane still exists.
split_home="$tmp/split-home"
mkdir -p "$split_home/state" "$split_home/data" "$split_home/config"
{ cat "$tmp/original.meta"; echo harness=pi; } > "$split_home/state/ended.meta"
split_panes='[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t2"}]'
export FM_LOCAL_RECOVERY_PANE_GET='{"label":null,"foreground_cwd":"/"}'
rm -f "$tmp/closed"
if FM_HOME="$split_home" FM_LOCAL_RECOVERY_PANES="$split_panes" \
    "$ROOT/bin/fm-control.sh" ended exit > "$tmp/split-exit.out" 2>&1; then
  echo "not ok - exit reported a split-tab worker as stopped: $(cat "$tmp/split-exit.out")" >&2
  exit 1
fi
grep -F 'recorded pane test:w1:p2 is not proven gone' "$tmp/split-exit.out" >/dev/null
[ ! -e "$tmp/closed" ]
[ -f "$split_home/state/ended.meta" ]
echo 'ok - exit refuses when a split tab hides the recorded worker pane from label resolution'
if FM_HOME="$split_home" FM_STATE_OVERRIDE="$split_home/state" FM_LOCAL_RECOVERY_PANES="$split_panes" \
    "$ROOT/bin/fm-teardown.sh" ended > "$tmp/split-teardown.out" 2>&1; then
  echo "not ok - teardown retired a split-tab worker: $(cat "$tmp/split-teardown.out")" >&2
  exit 1
fi
grep -F 'ownership could not be verified' "$tmp/split-teardown.out" >/dev/null
[ ! -e "$tmp/closed" ]
[ -f "$split_home/state/ended.meta" ]
echo 'ok - teardown refuses and keeps the records when a split tab hides the recorded worker pane'
FM_HOME="$split_home" FM_LOCAL_RECOVERY_PANES="$split_panes" "$ROOT/bin/fm-local-pane-cleanup.sh" sweep
[ ! -e "$tmp/closed" ]
echo 'ok - recovery leaves a split-tab worker pane untouched'
unset FM_LOCAL_RECOVERY_PANE_GET

# After a restart the recorded pane id can name another pane. Evidence that the
# pane belongs to other work proves this task's own pane is gone.
recycled_exit() { # <pane-get-overrides>
  FM_HOME="$split_home" FM_LOCAL_RECOVERY_PANE_GET="$1" \
    FM_LOCAL_RECOVERY_PANES="[$(jq -c '{pane_id:"w1:p2",tab_id,label}' <<< "$1")]" \
    "$ROOT/bin/fm-control.sh" ended exit
}
for overrides in '{"tab_id":"w1:t9","label":"fm-other"}' '{"tab_id":"w1:t9","label":null,"foreground_cwd":"/"}'; do
  rm -f "$tmp/closed"
  out=$(recycled_exit "$overrides") || { echo "not ok - a recycled pane id blocked exit ($overrides): $out" >&2; exit 1; }
  case "$out" in already-stopped*) ;; *) echo "not ok - recycled exit output: $out" >&2; exit 1 ;; esac
  [ ! -e "$tmp/closed" ]
  [ -f "$split_home/state/ended.meta" ]
done
echo 'ok - exit treats a recorded pane id that now names other work as gone and closes nothing'
if recycled_exit '{"tab_id":"w1:t9","label":null,"foreground_cwd":"'"$tmp"'/worktree"}' > "$tmp/recycled.out" 2>&1; then
  echo "not ok - an unlabeled pane inside this worktree was treated as gone: $(cat "$tmp/recycled.out")" >&2
  exit 1
fi
grep -F 'recorded pane test:w1:p2 is not proven gone' "$tmp/recycled.out" >/dev/null
echo 'ok - exit still refuses an unlabeled recorded pane that runs inside this worktree'

# With no home workspace, a relaunch never adopts a recorded pane id that now
# names other work, even when that pane reads as a stopped shell.
cp "$split_home/state/ended.meta" "$tmp/split-before.meta"
for overrides in '{"tab_id":"w1:t9","label":"fm-other"}' '{"tab_id":"w1:t9","label":null,"foreground_cwd":"/"}'; do
  rm -f "$tmp/closed"
  if FM_HOME="$split_home" FM_STATE_OVERRIDE="$split_home/state" FM_LOCAL_RECOVERY_WORKSPACES='[]' \
      FM_LOCAL_RECOVERY_PANE_GET="$overrides" "$ROOT/bin/fm-spawn.sh" ended --relaunch > "$tmp/recycled-relaunch.out" 2>&1; then
    echo "not ok - relaunch adopted a recycled pane id ($overrides): $(cat "$tmp/recycled-relaunch.out")" >&2
    exit 1
  fi
  grep -F 'ended has no home workspace and its recorded pane test:w1:p2 now belongs to other work; relaunch refused' \
    "$tmp/recycled-relaunch.out" >/dev/null \
    || { echo "not ok - recycled relaunch output ($overrides): $(cat "$tmp/recycled-relaunch.out")" >&2; exit 1; }
  [ ! -e "$tmp/closed" ]
  cmp -s "$tmp/split-before.meta" "$split_home/state/ended.meta"
done
echo 'ok - relaunch with no home workspace refuses a recorded pane id that now names other work'

# Forced retirement with unreadable ownership never names other work's pane
# as this task's leaked pane.
mv "$tmp/bin/herdr" "$tmp/bin/herdr.inventory"
cat > "$tmp/bin/herdr" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" != 'workspace list' ] || exit 1
exec "$tmp/bin/herdr.inventory" "\$@"
SH
chmod +x "$tmp/bin/herdr"
rm -f "$tmp/closed"
FM_HOME="$split_home" FM_STATE_OVERRIDE="$split_home/state" FM_LOCAL_RECOVERY_PANE_GET='{"tab_id":"w1:t9","label":"fm-other"}' \
  FM_TEARDOWN_HERDR_CLOSE_RETRY_WAIT_SECS=0 "$ROOT/bin/fm-teardown.sh" ended --force > "$tmp/recycled-force.out" 2>&1 \
  || { echo "not ok - forced teardown failed: $(cat "$tmp/recycled-force.out")" >&2; exit 1; }
if grep -F 'LEAKED HERDR PANE' "$tmp/recycled-force.out" >/dev/null; then
  echo "not ok - other work's pane was reported as leaked: $(cat "$tmp/recycled-force.out")" >&2
  exit 1
fi
grep -F 'is gone or now belongs to other work' "$tmp/recycled-force.out" >/dev/null
[ ! -e "$tmp/closed" ]
[ ! -e "$split_home/state/ended.meta" ]
mv "$tmp/bin/herdr.inventory" "$tmp/bin/herdr"
echo 'ok - forced teardown does not report a recycled recorded pane as this task leaked pane'

# Teardown's stop follows fm-control exit: an interrupt that ends the agent
# needs no exit command, which would otherwise be typed into the bare shell.
stop_dir="$tmp/stop"
mkdir -p "$stop_dir"
{ cat "$tmp/original.meta"; echo harness=grok; } > "$stop_dir/grok.meta"
(
  . "$ROOT/bin/fm-backend.sh"
  . "$ROOT/bin/fm-control-lib.sh"
  . "$ROOT/bin/fm-local-pane-lib.sh"
  fm_busy_classify_meta() { printf 'busy'; }
  fm_backend_send_key() { touch "$stop_dir/interrupted"; }
  fm_backend_agent_state() { if [ -e "$stop_dir/interrupted" ]; then printf dead; else printf alive; fi; }
  fm_backend_send_text_submit() { touch "$stop_dir/exit-submitted"; printf submitted; }
  fm_local_pane_stop "$stop_dir/grok.meta" ended test:w1:p2
)
[ -e "$stop_dir/interrupted" ]
[ ! -e "$stop_dir/exit-submitted" ]
echo 'ok - teardown stop submits no exit command after an interrupt ends the agent'
