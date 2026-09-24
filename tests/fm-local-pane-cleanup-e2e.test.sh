#!/usr/bin/env bash
# pane-cleanup-on-exit: real lifecycle seams with process stand-ins and guarded Herdr.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/fm-local-herdr-fixture.sh"
fm_live_gate default-on FM_LOCAL_HERDR_LIVE herdr jq agent-axi
trap 'printf "not ok - lab line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
fm_local_lab_start
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
export FM_BACKEND_HERDR_AXI_BIN=agent-axi
fm_backend_herdr_cli "$HERDR_SESSION" status --json | jq -r '"herdr client=\(.client.version) protocol=\(.client.protocol)"'
wt="$FM_LOCAL_LAB_ROOT/worktree"
project="$FM_LOCAL_LAB_ROOT/project"
mkdir -p "$project"
git -C "$project" init -q
printf "base\n" > "$project/base.txt"
git -C "$project" add base.txt
git -C "$project" -c user.name=Tests -c user.email=tests@example.invalid commit -qm base
git -C "$project" worktree add --quiet -b worker "$wt"
printf 'unlanded work\n' > "$wt/keep.txt"
container_raw=$(fm_backend_herdr_container_ensure "$wt")
container=${container_raw%%$'\t'*}
workspace=${container#*:}
supervisor=$(fm_backend_herdr_cli "$HERDR_SESSION" pane list --workspace "$workspace" | jq -r '.result.panes[0].pane_id')

task_create() {
  local id=$1 ids
  ids=$(fm_backend_herdr_create_task "$container" "fm-$id" "$wt" '')
  read -r tab pane <<< "$ids"
  mkdir -p "$FM_HOME/data/$id"
  printf '# Task\nExercise the lifecycle with a local process stand-in.\n' > "$FM_HOME/data/$id/brief.md"
  cat > "$FM_HOME/state/$id.meta" <<META
window=$HERDR_SESSION:$pane
endpoint_task_id=$id
worktree=$wt
project=$project
harness=pi
kind=ship
mode=no-mistakes
yolo=off
backend=herdr
spawn_gen=gen-$id
herdr_session=$HERDR_SESSION
herdr_workspace_id=$workspace
herdr_tab_id=$tab
herdr_pane_id=$pane
META
  for ((i=0; i<30; i++)); do
    [ "$(fm_backend_agent_state herdr "$HERDR_SESSION:$pane")" != dead ] || return 0
    sleep 0.1
  done
  echo 'fixture did not settle to a bare shell' >&2
  return 1
}

assert_missing() {
  local panes
  panes=$(fm_backend_herdr_cli "$HERDR_SESSION" pane list --workspace "$workspace")
  if ! printf '%s' "$panes" | jq -e --arg pane "$1" 'all(.result.panes[]; .pane_id != $pane)' >/dev/null; then
    echo "not ok - stopped task pane $1 remains" >&2
    return 1
  fi
}

# Herdr's agent registry reports an unknown status for some seconds after a
# known agent starts, so the classifier reads unreadable until it is stable.
# Wait for three consecutive alive reads, so a later lifecycle verb sees the
# same state. Use a time limit, not a poll count, because each poll is slow on
# a loaded host. On timeout, print the last samples so that the failure
# explains itself.
wait_live_agent() {
  local target=$1 limit=120 deadline state stable=0 snapshot tree
  deadline=$((SECONDS + limit))
  while [ "$SECONDS" -lt "$deadline" ]; do
    state=$(fm_backend_agent_state herdr "$target")
    if [ "$state" = alive ]; then
      stable=$((stable + 1))
      [ "$stable" -lt 3 ] || return 0
    else
      stable=0
    fi
    sleep 0.1
  done
  snapshot=$(fm_backend_herdr_recovery_process_snapshot "$HERDR_SESSION" "${target#*:}") || snapshot='(unreadable)'
  tree=$(fm_backend_herdr_recovery_process_tree_sample "$snapshot") || tree='(unreadable)'
  {
    echo "not ok - $target did not read alive three times in a row within ${limit}s"
    echo "state: $state"
    echo "registry: $(fm_backend_herdr_recovery_registry_sample "$HERDR_SESSION" "${target#*:}")"
    echo "process tree: ${tree%%$'\n'*}"
  } >&2
  return 1
}

assert_present() {
  fm_backend_herdr_cli "$HERDR_SESSION" pane get "$1" | jq -e --arg pane "$1" '.result.pane.pane_id == $pane' >/dev/null
}

task_create ended
FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 "$ROOT/bin/fm-control.sh" ended exit
assert_missing "$pane"
assert_present "$supervisor"
[ "$(cat "$wt/keep.txt")" = 'unlanded work' ]
[ -f "$FM_HOME/state/ended.meta" ]
agent-axi get ended --session "$HERDR_SESSION" --json | jq -e '.record == null or .record.state == "gone"' >/dev/null
echo 'ok - exit removes a shell pane and frees its slot while work and supervisor remain'
FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 "$ROOT/bin/fm-control.sh" ended exit
echo 'ok - repeated exit is idempotent after its pane is gone'

# A sweep must not close a pane while a relaunch holds this task's lock.
. "$ROOT/bin/fm-wake-lib.sh"
task_create crashed
crashed=$pane
fm_lock_try_acquire "$FM_HOME/state/.control-crashed.lock"
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
assert_present "$crashed"
fm_lock_release "$FM_HOME/state/.control-crashed.lock"
fm_lock_try_acquire "$FM_HOME/state/.meta-crashed.lock"
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
assert_present "$crashed"
fm_lock_release "$FM_HOME/state/.meta-crashed.lock"
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
assert_missing "$crashed"
echo 'ok - recovery skips held relaunch and spawn locks and cleans the pane after release'

# A real process accepts lifecycle commands without making model requests.
mkdir -p "$FM_LOCAL_LAB_ROOT/agent"
cp "$(command -v bash)" "$FM_LOCAL_LAB_ROOT/agent/pi"
export FM_LOCAL_LAB_ROOT
cat > "$FM_LOCAL_LAB_ROOT/tools/pi" <<'PI'
#!/usr/bin/env bash
case "${1:-}" in --help|--version) echo 'Pi lifecycle stand-in'; exit 0 ;; esac
exec "$(dirname "$0")/../agent/pi" -c 'while IFS= read -r line; do case "$line" in /exit|/quit) exit 0;; esac; done'
PI
chmod +x "$FM_LOCAL_LAB_ROOT/tools/pi"

restart="restart-$$"
[ ! -e "/tmp/fm-$restart" ] || { echo 'not ok - task scratch path already exists' >&2; exit 1; }
FM_LOCAL_LAB_TASK_TMP="/tmp/fm-$restart"
task_create "$restart"
old_pane=$pane
slot=$(agent-axi get "$restart" --session "$HERDR_SESSION" --json | jq -r '.record.slot')
FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=120 "$ROOT/bin/fm-control.sh" "$restart" relaunch --note 'Continue in the same worktree.'
new_target=$(fm_meta_get "$FM_HOME/state/$restart.meta" window)
new_pane=${new_target#*:}
[ "$old_pane" != "$new_pane" ]
assert_missing "$old_pane"
[ "$(fm_backend_agent_state herdr "$new_target")" = alive ]
[ "$(agent-axi get "$restart" --session "$HERDR_SESSION" --json | jq -r '.record.slot')" = "$slot" ]
[ "$(fm_backend_current_path herdr "$new_target")" = "$wt" ]
[ "$(cat "$wt/keep.txt")" = 'unlanded work' ]
echo 'ok - relaunch replaces the pane in the same slot and worktree'

"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
[ "$(fm_backend_agent_state herdr "$new_target")" = alive ]
echo 'ok - recovery retains a live foreground agent'

# A relaunch takes the home's task-set reservation before it stops the old agent.
fm_lock_try_acquire "$FM_HOME/state/.task-set.lock"
if FM_LOCAL_PANE_RESERVE_WAIT=1 FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=10 \
    "$ROOT/bin/fm-control.sh" "$restart" relaunch --note 'Check the reservation refusal.' 2> "$FM_LOCAL_LAB_ROOT/reserve.err"; then
  echo 'not ok - relaunch ran while another operation held the task set' >&2
  exit 1
fi
fm_lock_release "$FM_HOME/state/.task-set.lock"
grep -F 'relaunch refused before its agent was stopped' "$FM_LOCAL_LAB_ROOT/reserve.err" >/dev/null
[ "$(fm_backend_agent_state herdr "$new_target")" = alive ]
[ "$(fm_meta_get "$FM_HOME/state/$restart.meta" window)" = "$new_target" ]
echo 'ok - relaunch refuses a held task-set reservation before it stops the old agent'

# Kill only the process whose executable is our private fixture binary.
agent_pid=
for candidate in $(fm_backend_foreground_pids herdr "$new_target"); do
  [ "$(ps -p "$candidate" -o comm= | tr -d '[:space:]')" = pi ] || continue
  ps -p "$candidate" -o args= | grep -F "$FM_LOCAL_LAB_ROOT/" >/dev/null || continue
  [ -z "$agent_pid" ] || { echo 'not ok - ambiguous fixture process' >&2; exit 1; }
  agent_pid=$candidate
done
[[ "$agent_pid" =~ ^[0-9]+$ ]]
kill -KILL "$agent_pid"
for ((i=0; i<30; i++)); do
  [ "$(fm_backend_agent_state herdr "$new_target")" != dead ] || break
  sleep 0.1
done
[ "$(fm_backend_agent_state herdr "$new_target")" = dead ]
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
assert_missing "$new_pane"
[ "$(cat "$wt/keep.txt")" = 'unlanded work' ]
echo 'ok - recovery closes a killed agent husk without changing its work'

FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=120 "$ROOT/bin/fm-control.sh" "$restart" relaunch --note 'Recover the killed agent.'
new_target=$(fm_meta_get "$FM_HOME/state/$restart.meta" window)
[ "$(agent-axi get "$restart" --session "$HERDR_SESSION" --json | jq -r '.record.slot')" = "$slot" ]
fm_backend_herdr_send_text_line "$new_target" /exit
for ((i=0; i<30; i++)); do
  [ "$(fm_backend_agent_state herdr "$new_target")" != dead ] || break
  sleep 0.1
done
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
assert_missing "${new_target#*:}"
echo 'ok - recovery closes an agent that exits on its own'

# Fail after creating the replacement pane: the launcher returns to its shell.
cat > "$FM_LOCAL_LAB_ROOT/tools/pi" <<'PI'
#!/usr/bin/env bash
case "${1:-}" in --help|--version) echo 'Pi lifecycle stand-in'; exit 0 ;; esac
exit 1
PI
if FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=2 "$ROOT/bin/fm-control.sh" "$restart" relaunch --note 'Exercise failed start.'; then
  echo 'not ok - a failed start was reported as running' >&2
  exit 1
fi
agent-axi list --session "$HERDR_SESSION" --json | jq -e --arg id "$restart" 'all(.crew[]; .task != $id)' >/dev/null
[ -f "$FM_HOME/state/$restart.meta" ]
[ "$(cat "$wt/keep.txt")" = 'unlanded work' ]
echo 'ok - a failed replacement leaves no shell pane and preserves the task and work'

task_create occupant
occupant_pane=$pane
[ "$(agent-axi get occupant --session "$HERDR_SESSION" --json | jq -r '.record.slot')" = "$slot" ]
if FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=2 "$ROOT/bin/fm-control.sh" "$restart" relaunch --note 'Check occupied-slot refusal.'; then
  echo 'not ok - relaunch displaced the occupant of its old slot' >&2
  exit 1
fi
assert_present "$occupant_pane"
echo 'ok - relaunch refuses an occupied slot without closing its occupant'

task_create mate-owned
mate_pane=$pane
sed 's/kind=ship/kind=secondmate/' "$FM_HOME/state/mate-owned.meta" > "$FM_HOME/state/mate-owned.meta.tmp"
mv "$FM_HOME/state/mate-owned.meta.tmp" "$FM_HOME/state/mate-owned.meta"
task_create unmanaged
unmanaged_pane=$pane
rm "$FM_HOME/state/unmanaged.meta"
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
assert_present "$mate_pane"
assert_present "$unmanaged_pane"
assert_present "$supervisor"
echo 'ok - recovery retains supervisor, secondmate, and unmanaged panes'

foreign_home="$FM_LOCAL_LAB_ROOT/foreign-home"
mkdir -p "$foreign_home/state" "$foreign_home/config"
printf 'foreign\n' > "$foreign_home/.fm-secondmate-home"
foreign_ids=$(FM_HOME="$foreign_home" bash -c '
  . "$1/bin/fm-backend.sh"
  fm_backend_source herdr
  container=$(fm_backend_herdr_container_ensure "$2")
  fm_backend_herdr_create_task "${container%%$'\''\t'\''*}" fm-foreign "$2" ""
' _ "$ROOT" "$wt")
read -r foreign_tab foreign_pane <<< "$foreign_ids"
foreign_workspace=$(fm_backend_herdr_cli "$HERDR_SESSION" pane get "$foreign_pane" | jq -r '.result.pane.workspace_id')
cat > "$FM_HOME/state/foreign.meta" <<META
window=$HERDR_SESSION:$foreign_pane
endpoint_task_id=foreign
worktree=$wt
project=$project
kind=ship
backend=herdr
herdr_session=$HERDR_SESSION
herdr_workspace_id=$foreign_workspace
herdr_tab_id=$foreign_tab
herdr_pane_id=$foreign_pane
META
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
assert_present "$foreign_pane"
echo 'ok - a local record cannot authorize cleanup in another home workspace'

# Exercise teardown against the real pane and Git safety checks. The private
# Treehouse stand-in releases only the known clean Git fixture worktree.
cat > "$FM_LOCAL_LAB_ROOT/tools/no-mistakes" <<'NM'
#!/usr/bin/env bash
exit 0
NM
cat > "$FM_LOCAL_LAB_ROOT/tools/treehouse" <<'TH'
#!/usr/bin/env bash
set -eu
[ "$#" = 3 ] && [ "$1" = return ] && [ "$2" = --force ] && [ "$3" = "$FM_LOCAL_LAB_RETURN_WT" ] || exit 1
exec git -C "$FM_LOCAL_LAB_PROJECT" worktree remove "$3"
TH
chmod +x "$FM_LOCAL_LAB_ROOT/tools/no-mistakes" "$FM_LOCAL_LAB_ROOT/tools/treehouse"
export FM_LOCAL_LAB_PROJECT=$project FM_LOCAL_LAB_RETURN_WT="$FM_LOCAL_LAB_ROOT/retired-worktree"
task_create unlanded
unlanded_pane=$pane
sed 's/mode=no-mistakes/mode=local-only/' "$FM_HOME/state/unlanded.meta" > "$FM_HOME/state/unlanded.meta.tmp"
mv "$FM_HOME/state/unlanded.meta.tmp" "$FM_HOME/state/unlanded.meta"
if "$ROOT/bin/fm-teardown.sh" unlanded > "$FM_LOCAL_LAB_ROOT/dirty.out" 2>&1; then
  echo 'not ok - teardown accepted uncommitted work' >&2
  exit 1
fi
grep -F 'uncommitted changes' "$FM_LOCAL_LAB_ROOT/dirty.out" >/dev/null
assert_present "$unlanded_pane"
[ "$(cat "$wt/keep.txt")" = 'unlanded work' ]
git -C "$project" worktree add --quiet -b "retired-$$" "$FM_LOCAL_LAB_RETURN_WT"
saved_wt=$wt
wt=$FM_LOCAL_LAB_RETURN_WT
task_create retired
retired_pane=$pane
wt=$saved_wt
sed 's/mode=no-mistakes/mode=local-only/' "$FM_HOME/state/retired.meta" > "$FM_HOME/state/retired.meta.tmp"
mv "$FM_HOME/state/retired.meta.tmp" "$FM_HOME/state/retired.meta"
"$ROOT/bin/fm-teardown.sh" retired
assert_missing "$retired_pane"
[ ! -e "$FM_HOME/state/retired.meta" ]
[ ! -d "$FM_LOCAL_LAB_RETURN_WT" ]
assert_present "$supervisor"
[ "$(cat "$wt/keep.txt")" = 'unlanded work' ]
echo 'ok - teardown removes a landed worker pane and refuses to discard unlanded work'

# A landed worker whose agent still runs: teardown stops it before the close.
cat > "$FM_LOCAL_LAB_ROOT/tools/pi-live" <<'PI'
#!/usr/bin/env bash
exec "$(dirname "$0")/../agent/pi" -c 'while IFS= read -r line; do case "$line" in /exit|/quit) exit 0;; esac; done'
PI
chmod +x "$FM_LOCAL_LAB_ROOT/tools/pi-live"
git -C "$project" worktree add --quiet -b "live-$$" "$FM_LOCAL_LAB_RETURN_WT"
wt=$FM_LOCAL_LAB_RETURN_WT
task_create live
live_target="$HERDR_SESSION:$pane"
wt=$saved_wt
sed 's/mode=no-mistakes/mode=local-only/; s/harness=pi/harness=unverified-agent/' "$FM_HOME/state/live.meta" > "$FM_HOME/state/live.meta.tmp"
mv "$FM_HOME/state/live.meta.tmp" "$FM_HOME/state/live.meta"
fm_backend_herdr_send_text_line "$live_target" "$FM_LOCAL_LAB_ROOT/tools/pi-live"
wait_live_agent "$live_target"
if "$ROOT/bin/fm-teardown.sh" live > "$FM_LOCAL_LAB_ROOT/live.out" 2>&1; then
  echo 'not ok - teardown retired a live agent it could not stop' >&2
  cat "$FM_LOCAL_LAB_ROOT/live.out" >&2
  exit 1
fi
grep -F 'is still running and teardown could not stop it' "$FM_LOCAL_LAB_ROOT/live.out" >/dev/null
[ "$(fm_backend_agent_state herdr "$live_target")" = alive ]
[ -f "$FM_HOME/state/live.meta" ] && [ -d "$FM_LOCAL_LAB_RETURN_WT" ]
echo 'ok - teardown refuses before removing anything when it cannot stop a live agent'
sed 's/harness=unverified-agent/harness=pi/' "$FM_HOME/state/live.meta" > "$FM_HOME/state/live.meta.tmp"
mv "$FM_HOME/state/live.meta.tmp" "$FM_HOME/state/live.meta"
FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 "$ROOT/bin/fm-teardown.sh" live
assert_missing "${live_target#*:}"
[ ! -e "$FM_HOME/state/live.meta" ] && [ ! -d "$FM_LOCAL_LAB_RETURN_WT" ]
assert_present "$supervisor"
[ "$(cat "$wt/keep.txt")" = 'unlanded work' ]
echo 'ok - teardown stops a live agent, then closes its proven-gone pane'

# A real named-session stop restores this task as a shell on re-provision.
task_create restored
PATH=$FM_LOCAL_LAB_REAL_PATH "$FM_LOCAL_LAB_HELPER" stop "$FM_LOCAL_LAB_SESSION"
PATH=$FM_LOCAL_LAB_REAL_PATH "$FM_LOCAL_LAB_HELPER" provision "$FM_LOCAL_LAB_SESSION"
"$ROOT/bin/fm-local-pane-cleanup.sh" sweep
agent-axi list --session "$HERDR_SESSION" --json | jq -e 'all(.crew[]; .task != "restored")' >/dev/null
[ "$(cat "$wt/keep.txt")" = 'unlanded work' ]
echo 'ok - recovery closes restored bare shells by task identity after a session restart'
