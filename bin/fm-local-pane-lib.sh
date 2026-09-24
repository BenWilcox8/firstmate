#!/usr/bin/env bash
# Ended worker panes: home ownership, placement receipts, and proven close.
# Callers hold the task's control lock across inspection and mutation.
# fm_backend_agent_state owns the only gone predicate: dead or missing.
# Never infer process death from a hook status, terminal text, or a task status.

fm_local_pane_worker() { # <meta> <task-id>
  local meta=$1 id=$2 kind
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || return 1
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in ship|scout) ;; *) return 1 ;; esac
  case "$id" in MAIN|main|secondmate) return 1 ;; esac
  if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
    [ "$id" != "$(cat "$FM_HOME/.fm-secondmate-home")" ] || return 1
  fi
}

fm_local_pane_error() {
  echo "error: pane cleanup: $*" >&2
  return 1
}

# Presentation journal resolution is a separate recovery owner. Automatic flat
# cleanup must not interpret a projected pane as absent from the home workspace.
fm_local_pane_flat() {
  [ ! -e "${1%.meta}.herdr-presentation" ] && [ ! -L "${1%.meta}.herdr-presentation" ]
}

# Resolve by this home's labels, never by a pane ID that a restart can recycle.
# An empty target means a successful inventory found no owned pane.
# A failed inventory remains an error, never an absence proof.
fm_local_pane_resolve() { # <meta> <task-id>
  local meta=$1 id=$2 session inventory row count workspace panes tabs record
  FM_LOCAL_PANE_TARGET=
  FM_LOCAL_PANE_SLOT=
  FM_LOCAL_PANE_WORKSPACE=
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  fm_backend_source herdr || return 1
  session=$(fm_meta_get "$meta" herdr_session)
  [ -n "$session" ] || return 1
  if fm_backend_herdr_axi_available; then
    inventory=$("$FM_BACKEND_HERDR_AXI_BIN" list --session "$session" --json) || return 1
    row=$(printf '%s' "$inventory" | jq -ce --arg task "$id" '
      if (.crew | type) != "array" then error("missing crew inventory") else . end
      | [.crew[] | select(.task == $task)] as $rows
      | if ($rows | length) > 1 then error("duplicate task panes")
        elif ($rows | length) == 0 then {pane:null}
        elif $rows[0].pane == .supervisor then error("supervisor pane")
        else $rows[0] end') || return 1
    FM_LOCAL_PANE_WORKSPACE=$(printf '%s' "$inventory" | jq -er '.workspace.id') || return 1
    record=$("$FM_BACKEND_HERDR_AXI_BIN" get "$id" --session "$session" --json) || return 1
    FM_LOCAL_PANE_SLOT=$(printf '%s' "$record" | jq -r '.record.slot // empty') || return 1
  else
    inventory=$(fm_backend_herdr_cli "$session" workspace list) || return 1
    workspace=$(printf '%s' "$inventory" | jq -er --arg want "$(fm_backend_herdr_workspace_label)" '
      if (.result.workspaces | type) != "array" then error("missing workspace inventory") else . end
      | [.result.workspaces[] | select(.label == $want)]
      | if length == 0 then "absent" elif length == 1 then .[0].workspace_id
        else error("ambiguous home workspace") end') || return 1
    [ "$workspace" != absent ] || return 0
    FM_LOCAL_PANE_WORKSPACE=$workspace
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace") || return 1
    tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace") || return 1
    row=$(printf '%s' "$panes" | jq -ce --arg task "fm-$id" --argjson tabs "$tabs" '
      if (.result.panes | type) != "array" or ($tabs.result.tabs | type) != "array"
      then error("missing pane or tab inventory") else . end
      | .result.panes as $panes
      | [$panes[] | . as $pane | select(.label == $task or
          ((.label // "") == "" and
           ([$tabs.result.tabs[] | select(.tab_id == $pane.tab_id and .label == $task)] | length) == 1 and
           ([$panes[] | select(.tab_id == $pane.tab_id)] | length) == 1))]
      | if length == 0 then {pane:null} elif length == 1 then {pane:.[0].pane_id}
        else error("duplicate task panes") end') || return 1
  fi
  count=$(printf '%s' "$row" | jq -r '.pane // empty') || return 1
  if [ -n "$count" ]; then
    FM_LOCAL_PANE_TARGET="$session:$count"
  fi
}

# Keep a placement hint after freeing a slot. It is bound to the exact record.
# This file reserves nothing and never authorizes a close or displaces a worker.
fm_local_pane_remember() { # <meta> <task-id>
  local meta=$1 id=$2 receipt tmp
  receipt="${meta%.meta}.local-pane.json"
  [ -n "$FM_LOCAL_PANE_TARGET" ] || [ -n "$FM_LOCAL_PANE_SLOT" ] || return 0
  tmp=$(mktemp "${receipt}.XXXXXX") || return 1
  if jq -n --arg home "$(cd "$FM_HOME" && pwd -P)" --arg task "$id" \
      --arg source "$(fm_meta_get "$meta" window)" --arg gen "$(fm_meta_get "$meta" spawn_gen)" \
      --arg session "$(fm_meta_get "$meta" herdr_session)" --arg slot "$FM_LOCAL_PANE_SLOT" \
      --arg workspace "$FM_LOCAL_PANE_WORKSPACE" \
      '{version:1,home:$home,task:$task,source:$source,gen:$gen,session:$session,slot:$slot,workspace:$workspace}' > "$tmp" \
      && mv -f "$tmp" "$receipt"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

fm_local_pane_close() { # <meta> <task-id>
  local meta=$1 id=$2 target
  fm_local_pane_resolve "$meta" "$id" || return 1
  target=$FM_LOCAL_PANE_TARGET
  # The backend re-reads its recovery classifier immediately before the close.
  # Remembering the slot changes no endpoint and is safe before that read.
  fm_local_pane_remember "$meta" "$id" || return 1
  [ -n "$target" ] || return 0
  fm_backend_task_endpoint_close herdr "${meta%/*}" "$id" "$target" "$meta" \
    || fm_local_pane_error "$id at $target: $FM_BACKEND_TASK_CLOSE_REASON"
}

fm_local_pane_receipt() { # <meta> <task-id>
  local meta=$1 id=$2 receipt="${1%.meta}.local-pane.json"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  jq -ce --arg home "$(cd "$FM_HOME" && pwd -P)" --arg task "$id" \
    --arg source "$(fm_meta_get "$meta" window)" --arg gen "$(fm_meta_get "$meta" spawn_gen)" \
    --arg session "$(fm_meta_get "$meta" herdr_session)" '
      select(.version == 1 and .home == $home and .task == $task and .source == $source
             and .gen == $gen and .session == $session)
      | select((.slot | type) == "string" and (.workspace | type) == "string")' "$receipt"
}

fm_local_pane_relaunch_state() {
  local observed
  fm_local_pane_resolve "$RELAUNCH_META" "$ID" || return 1
  if [ -n "$FM_LOCAL_PANE_TARGET" ]; then
    observed=$(fm_backend_agent_state herdr "$FM_LOCAL_PANE_TARGET")
  else
    observed=missing
  fi
  case "$observed" in
    dead|missing) ;;
    *) fm_local_pane_error "$ID reads $observed; relaunch requires a proven stopped agent"; return 1 ;;
  esac
  FM_LOCAL_PANE_RELAUNCH=1
  # The upstream gate still checks every other backend. The later hook creates
  # the new Herdr endpoint only after the normal launch preflight succeeds.
  RELAUNCH_STATE=dead
}

fm_local_pane_relaunch_create() {
  local receipt slot session workspace out ids occupancy slot_tab slot_n
  local -a launch args
  # Fresh spawns and other relaunches must not take the requested slot between
  # this check and agent-axi's spawn. Never wait while holding a task lock.
  SPAWN_TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || return 1
  fm_lock_try_acquire "$SPAWN_TASK_SET_LOCK" \
    || { fm_local_pane_error 'this home has another spawn or teardown in progress'; return 1; }
  SPAWN_TASK_SET_LOCK_HELD=1
  fm_local_pane_close "$RELAUNCH_META" "$ID" || return 1
  session=$(fm_meta_get "$RELAUNCH_META" herdr_session)
  workspace=$FM_LOCAL_PANE_WORKSPACE
  [ -n "$workspace" ] || { fm_local_pane_error "$ID has no home workspace for relaunch"; return 1; }
  if fm_backend_herdr_axi_available; then
    receipt=$(fm_local_pane_receipt "$RELAUNCH_META" "$ID") \
      || { fm_local_pane_error "$ID has no placement receipt for its current record"; return 1; }
    slot=$(printf '%s' "$receipt" | jq -r '.slot')
    [[ "$slot" =~ ^t([1-9][0-9]*)/s([1-9][0-9]*)$ ]] \
      || { fm_local_pane_error "$ID has no recorded agent-axi slot"; return 1; }
    slot_tab=${BASH_REMATCH[1]}
    slot_n=${BASH_REMATCH[2]}
    occupancy=$("$FM_BACKEND_HERDR_AXI_BIN" slots --session "$session" --json) || return 1
    printf '%s' "$occupancy" | jq -e --argjson tab "$slot_tab" --argjson slot "$slot_n" '
      (.occupancy | type) == "array" and
      all(.occupancy[]; .tab != $tab or .n != $slot or .task == null)' >/dev/null \
      || { fm_local_pane_error "$ID cannot reclaim occupied slot $slot"; return 1; }
    args=(spawn "$ID" --session "$session" --workspace-id "$workspace" --cwd "$RELAUNCH_WT"
          --tab "$slot_tab" --slot "$slot_n" --json)
    if [ -n "$FM_BACKEND_HERDR_AXI_LAUNCH" ]; then
      read -r -a launch <<< "$FM_BACKEND_HERDR_AXI_LAUNCH"
    else
      launch=("${SHELL:-$(command -v bash)}" -l)
    fi
    FM_LOCAL_PANE_LAUNCH_ATTEMPTED=1
    out=$("$FM_BACKEND_HERDR_AXI_BIN" "${args[@]}" -- "${launch[@]}") || return 1
    ids=$(printf '%s' "$out" | jq -er '.spawn | select(.paneId != null and .tabId != null) | "\(.tabId) \(.paneId)"') || return 1
  else
    FM_LOCAL_PANE_LAUNCH_ATTEMPTED=1
    ids=$(fm_backend_herdr_create_task "$session:$workspace" "fm-$ID" "$RELAUNCH_WT" '') || return 1
  fi
  read -r HERDR_TAB_ID HERDR_PANE_ID <<< "$ids"
  [ -n "$HERDR_TAB_ID" ] && [ -n "$HERDR_PANE_ID" ] || return 1
  HERDR_SES=$session
  HERDR_WORKSPACE_ID=$workspace
  RELAUNCH_TARGET="$session:$HERDR_PANE_ID"
}

# Failed launches can leave a new shell. Preserve live or uncertain agents.
fm_local_pane_abort() { # <meta> <task-id>
  local meta=$1 id=$2 target observed
  fm_local_pane_resolve "$meta" "$id" || return 1
  target=$FM_LOCAL_PANE_TARGET
  [ -n "$target" ] || return 0
  observed=$(fm_backend_agent_state herdr "$target")
  case "$observed" in
    dead|missing) fm_local_pane_close "$meta" "$id" ;;
    *) printf 'warning: pane cleanup retained %s at %s (agent state %s)\n' "$id" "$target" "$observed" >&2 ;;
  esac
}
