#!/usr/bin/env bash
# Demo transcript: a worker agent ends; fm-control exit closes its bare-shell
# Herdr pane at once while the task record, worktree, and uncommitted work stay.
# Every Herdr call goes through the guarded fm-herdr-lab.sh helper.
set -euo pipefail
ROOT=${ROOT:?}
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/fm-local-herdr-fixture.sh"
fm_local_lab_start
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
export FM_BACKEND_HERDR_AXI_BIN=agent-axi
wt="$FM_LOCAL_LAB_ROOT/worktree"; project="$FM_LOCAL_LAB_ROOT/project"
mkdir -p "$project"; git -C "$project" init -q
echo base > "$project/base.txt"; git -C "$project" add base.txt
git -C "$project" -c user.name=T -c user.email=t@example.invalid commit -qm base
git -C "$project" worktree add --quiet -b worker "$wt"
echo 'unlanded work' > "$wt/keep.txt"
c=$(fm_backend_herdr_container_ensure "$wt"); c=${c%%$'\t'*}; ws=${c#*:}
read -r tab pane <<< "$(fm_backend_herdr_create_task "$c" fm-demo "$wt" '')"
mkdir -p "$FM_HOME/data/demo"; echo '# Task' > "$FM_HOME/data/demo/brief.md"
cat > "$FM_HOME/state/demo.meta" <<META
window=$HERDR_SESSION:$pane
endpoint_task_id=demo
worktree=$wt
project=$project
harness=pi
kind=ship
mode=no-mistakes
backend=herdr
herdr_session=$HERDR_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
META
show() { echo "\$ herdr pane list --workspace $ws   # via fm-herdr-lab.sh run <private-session>"
  herdr pane list --workspace "$ws" | jq -r '.result.panes[] | "  \(.pane_id)\tlabel=\(.label // "-")\ttab=\(.tab_id)"'; }
echo "== Worker pane for task 'demo' whose agent has ended (bare shell); agent state: $(fm_backend_agent_state herdr "$HERDR_SESSION:$pane")"
show
echo; echo "\$ fm-control.sh demo exit"
FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 "$ROOT/bin/fm-control.sh" demo exit 2>&1 | sed 's/^/  /'
echo; echo "== After exit"; show
echo; echo "task record kept: $(test -f "$FM_HOME/state/demo.meta" && echo yes || echo NO)"
echo "worktree kept:    $(test -d "$wt" && echo yes || echo NO)"
echo "uncommitted file: $(cat "$wt/keep.txt")"
echo "agent-axi slot:   $(agent-axi get demo --session "$HERDR_SESSION" --json | jq -c '.record | if . == null then "released" else .state end')"
