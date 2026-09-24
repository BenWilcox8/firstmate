#!/usr/bin/env bash
# Worker restore after a restart: the real lifecycle in a guarded Herdr lab.
#
# A home holds five workers, each a Claude stand-in in its own lab pane and
# worktree: one working, one parked, one finished, one waiting on the captain,
# and one whose worktree another task takes after the restart. The lab session
# is stopped and provisioned again (every agent dies), the boot id moves, and
# the home's restart-record path runs as its first locked session start would.
# Only the working worker comes back, in its own slot and worktree. The worker
# whose slot was taken is reported, and a relaunch into that worktree refuses.
# The stand-ins make no model requests, so this runs by default wherever Herdr,
# jq, and agent-axi exist.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/fm-local-herdr-fixture.sh"
fm_live_gate default-on FM_LOCAL_HERDR_LIVE herdr jq agent-axi
trap 'printf "not ok - lab line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
fm_local_lab_start reboot-recovery-r2
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
export FM_BACKEND_HERDR_AXI_BIN=agent-axi
# The relaunch writes Claude workspace trust here, not to the real store. HOME
# stays real: the Herdr client finds its sessions through it.
export CLAUDE_CONFIG_DIR="$FM_LOCAL_LAB_ROOT/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR"
L=$FM_LOCAL_LAB_ROOT
LAUNCHES="$L/launches"
: > "$LAUNCHES"

# The Claude stand-in: a bash copy named claude that logs where it started and
# waits for /exit.
mkdir -p "$L/agent"
cp "$(command -v bash)" "$L/agent/claude"
cat > "$L/tools/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --help|--version) echo 'Claude lifecycle stand-in'; exit 0 ;; esac
printf '%s\n' "\$PWD" >> '$LAUNCHES'
exec '$L/agent/claude' -c 'while IFS= read -r line; do case "\$line" in /exit|/quit) exit 0;; esac; done'
SH
chmod +x "$L/tools/claude"
# Every lab pane, including a fresh relaunch pane, starts this shell, so a typed
# `claude` always resolves to the stand-in and never to a real Claude.
printf '#!%s\nexec env PATH=%s:"$PATH" %s --noprofile --norc -i\n' "$(command -v bash)" "$L/tools" "$(command -v bash)" > "$L/lab-shell"
chmod +x "$L/lab-shell"
export FM_BACKEND_HERDR_AXI_LAUNCH="$L/lab-shell"

project="$L/project"
mkdir -p "$project"
git -C "$project" init -q
printf 'base\n' > "$project/base.txt"
git -C "$project" add base.txt
git -C "$project" -c user.name=Tests -c user.email=tests@example.invalid commit -qm base
container_raw=$(fm_backend_herdr_container_ensure "$project")
container=${container_raw%%$'\t'*}
workspace=${container#*:}

launches_in() { grep -cFx "$1" "$LAUNCHES" || true; }

wait_alive() {  # <target>
  local deadline=$((SECONDS + 120)) stable=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(fm_backend_agent_state herdr "$1")" = alive ]; then
      stable=$((stable + 1))
      [ "$stable" -lt 3 ] || return 0
    else
      stable=0
    fi
    sleep 0.2
  done
  echo "not ok - $1 never read alive" >&2
  return 1
}

# worker <id> <worktree> <spawn-epoch>: a Claude worker record with a live
# stand-in in a new lab pane.
worker() {
  local id=$1 wt=$2 ids tab pane
  [ -d "$wt" ] || git -C "$project" worktree add --quiet -b "fm/$id" "$wt"
  ids=$(fm_backend_herdr_create_task "$container" "fm-$id" "$wt" '')
  read -r tab pane <<< "$ids"
  mkdir -p "$FM_HOME/data/$id"
  printf "# Task\n## Captain's intent\nKeep working.\n\n## Firstmate spec\nKeep working.\n" > "$FM_HOME/data/$id/brief.md"
  cat > "$FM_HOME/state/$id.meta" <<META
window=$HERDR_SESSION:$pane
endpoint_task_id=$id
worktree=$wt
project=$project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$L/tasktmp-$id
backend=herdr
spawn_gen=s$3.1.1
herdr_session=$HERDR_SESSION
herdr_workspace_id=$workspace
herdr_tab_id=$tab
herdr_pane_id=$pane
META
  sleep 1
  local before
  before=$(launches_in "$wt")
  fm_backend_herdr_send_text_line "$HERDR_SESSION:$pane" claude
  wait_alive "$HERDR_SESSION:$pane"
  [ "$(launches_in "$wt")" -gt "$before" ] || { echo "not ok - $id did not start the Claude stand-in" >&2; exit 1; }
}

worker working "$L/wt-working" 1790000001
worker parked "$L/wt-parked" 1790000002
worker finished "$L/wt-finished" 1790000003
worker waiting "$L/wt-waiting" 1790000004
worker reused "$L/wt-reused" 1790000005
printf 'working: building the parser\n' > "$FM_HOME/state/working.status"
printf 'parked=2026-09-24T01:00:00Z\nparked_reason=captain call on scope\n' >> "$FM_HOME/state/parked.meta"
printf 'done: PR https://example.invalid/pull/1 checks green\n' > "$FM_HOME/state/finished.status"
printf 'needs-decision [key=scope]: pick A or B\n' > "$FM_HOME/state/waiting.status"
printf 'working: building\n' > "$FM_HOME/state/reused.status"
working_slot=$(agent-axi get working --session "$HERDR_SESSION" --json | jq -r '.record.slot')
echo "ok - five Claude workers run in their own lab panes and worktrees"

record() {  # <boot-id>
  printf '%s\n' "$1" > "$L/boot_id"
  FM_RESTART_BOOT_ID_FILE="$L/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=120 \
    "$ROOT/bin/fm-local-restart-recovery.sh" record
}
record boot-1 > "$L/record-1.out"
! grep -q 'Worker restore' "$L/record-1.out"

# The restart: every agent dies with the lab session.
PATH=$FM_LOCAL_LAB_REAL_PATH "$FM_LOCAL_LAB_HELPER" stop "$FM_LOCAL_LAB_SESSION"
PATH=$FM_LOCAL_LAB_REAL_PATH "$FM_LOCAL_LAB_HELPER" provision "$FM_LOCAL_LAB_SESSION"
for id in working parked finished waiting reused; do
  state=$(fm_backend_agent_state herdr "$(fm_meta_get "$FM_HOME/state/$id.meta" window)")
  case "$state" in dead|missing) ;; *) echo "not ok - $id reads $state after the restart" >&2; exit 1 ;; esac
done
echo "ok - the lab restart stopped every worker"

# Another task takes the reused worker's worktree before its home restores.
worker taker "$L/wt-reused" 1790000900
taker_target=$(fm_meta_get "$FM_HOME/state/taker.meta" window)
before_working=$(launches_in "$L/wt-working")
before_reused=$(launches_in "$L/wt-reused")

record boot-2 > "$L/record-2.out"
grep -F 'Worker restore is relaunching' "$L/record-2.out" >/dev/null
deadline=$((SECONDS + 300))
until grep -q 'check: worker restore' "$FM_HOME/state/.wake-queue" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || { echo 'not ok - worker restore never reported' >&2; exit 1; }
  sleep 1
done
summary=$(grep 'check: worker restore' "$FM_HOME/state/.wake-queue" | cut -f5-)
printf '%s\n' "$summary"
printf '%s' "$summary" | grep -F 'restored 1 (working)' >/dev/null
printf '%s' "$summary" | grep -F 'slot-reused 1 (reused: its worktree is now recorded for taker' >/dev/null
printf '%s' "$summary" | grep -F 'failed 0' >/dev/null
[ "$(launches_in "$L/wt-working")" -eq $((before_working + 1)) ]
for id in parked finished waiting; do
  [ "$(launches_in "$L/wt-$id")" -eq 1 ] || { echo "not ok - $id was relaunched" >&2; exit 1; }
done
[ "$(launches_in "$L/wt-reused")" -eq "$before_reused" ]
working_target=$(fm_meta_get "$FM_HOME/state/working.meta" window)
wait_alive "$working_target"
[ "$(fm_backend_current_path herdr "$working_target")" = "$L/wt-working" ]
[ "$(agent-axi get working --session "$HERDR_SESSION" --json | jq -r '.record.slot')" = "$working_slot" ]
[ "$(fm_backend_agent_state herdr "$taker_target")" = alive ]
echo "ok - only the working worker came back, in its own slot and worktree; the others stayed down"

# The lease re-check: relaunching the reused worker refuses, and the task
# that holds its worktree keeps running.
if FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=30 "$ROOT/bin/fm-control.sh" reused relaunch \
    --note 'Try the reused worktree.' > "$L/reused.out" 2>&1; then
  echo 'not ok - a relaunch into a reused worktree succeeded' >&2
  cat "$L/reused.out" >&2
  exit 1
fi
grep -F 'worktree-lease' "$L/reused.out" >/dev/null
[ "$(launches_in "$L/wt-reused")" -eq "$before_reused" ]
[ "$(fm_backend_agent_state herdr "$taker_target")" = alive ]
echo "ok - a relaunch into a worktree leased to another task refuses and leaves that task running"

# A second session start for the same restart restores nothing again.
record boot-2 > "$L/record-3.out"
sleep 3
[ "$(grep -c 'check: worker restore' "$FM_HOME/state/.wake-queue")" -eq 1 ]
[ "$(launches_in "$L/wt-working")" -eq $((before_working + 1)) ]
echo "ok - a restart is restored once"
