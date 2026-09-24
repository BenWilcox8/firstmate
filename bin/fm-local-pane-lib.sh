#!/usr/bin/env bash
# Ended worker panes: home ownership, placement receipts, and proven close.
# Callers hold the task's control lock across any inspection that leads to a mutation.
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

# A stopped session server answers no inventory read, and a restart keeps its
# pane ids. The upstream absence proof owns that case: it starts the recorded
# server, then re-reads the recorded pane to adopt, rebind, or refuse.
fm_local_pane_server_stopped() { # <meta>
  fm_backend_source herdr || return 1
  [ "$(fm_backend_herdr_server_running_state "$(fm_meta_get "$1" herdr_session)")" = stopped ]
}

# Presentation journal resolution is a separate recovery owner. Automatic flat
# cleanup must not interpret a projected pane as absent from the home workspace.
fm_local_pane_flat() {
  [ ! -e "${1%.meta}.herdr-presentation" ] && [ ! -L "${1%.meta}.herdr-presentation" ]
}

# Print this home's workspace id in <session>, or "absent" when no workspace
# carries its label. Several labeled workspaces resolve only to the task's
# recorded one. A failed or otherwise ambiguous listing is an error.
fm_local_pane_workspace() { # <session> <recorded-workspace-id>
  local inventory
  inventory=$(fm_backend_herdr_cli "$1" workspace list) || return 1
  printf '%s' "$inventory" | jq -er --arg want "$(fm_backend_herdr_workspace_label)" --arg recorded "$2" '
    if (.result.workspaces | type) != "array" then error("missing workspace inventory") else . end
    | [.result.workspaces[] | select(.label == $want)]
    | if length == 0 then "absent" elif length == 1 then .[0].workspace_id
      elif any(.[]; .workspace_id == $recorded) then $recorded
      else error("ambiguous home workspace") end'
}

fm_local_pane_path_within() { # <path> <dir>
  local path dir
  path=$(cd "$1" 2>/dev/null && pwd -P) || path=$1
  dir=$(cd "$2" 2>/dev/null && pwd -P) || dir=$2
  case "$path/" in "$dir"/*) return 0 ;; esac
  return 1
}

# A missing label proves nothing while the recorded pane still exists: a split
# tab or a renamed workspace can hide a running worker from label resolution.
# A restart can give the recorded id to another pane, so the pane counts as
# gone only when it is absent or evidence proves it belongs to other work:
# another fm- pane or tab label, or a foreground cwd outside this worktree.
fm_local_pane_recorded_gone() { # <meta> <task-id> <recorded-target>
  local meta=$1 id=$2 recorded=$3 out pane owner tabs seen
  if fm_backend_herdr_parse_target "$recorded"; then
    pane=$(fm_backend_herdr_bare_id "$FM_BACKEND_HERDR_PANE")
    out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$pane" 2>&1) || true
    owner=$(printf '%s' "$out" | jq -r --arg pane "$pane" --arg own "fm-$id" '
      if .error.code == "pane_not_found" then "gone"
      elif .result.pane.pane_id != $pane then "unknown"
      elif .result.pane.label == $own then "own"
      elif ((.result.pane.label // "") | startswith("fm-")) then "gone"
      else "present" end' 2>/dev/null) || owner=unknown
    if [ "$owner" = present ]; then
      tabs=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" tab list \
        --workspace "$(printf '%s' "$out" | jq -r '.result.pane.workspace_id // empty')" 2>/dev/null) || tabs=
      case "$(printf '%s' "$tabs" | jq -r --arg tab "$(printf '%s' "$out" | jq -r '.result.pane.tab_id // empty')" '
          [.result.tabs[]? | select(.tab_id == $tab) | .label // ""] | if length == 1 then .[0] else "" end' 2>/dev/null)" in
        "fm-$id") owner=own ;;
        fm-?*) owner=gone ;;
      esac
    fi
    if [ "$owner" = present ]; then
      seen=$(printf '%s' "$out" | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null)
      [ -z "$seen" ] || fm_local_pane_path_within "$seen" "$(fm_meta_get "$meta" worktree)" || owner=gone
    fi
    [ "$owner" != gone ] || return 0
  fi
  fm_local_pane_error "$id has no labeled pane here but its recorded pane $recorded is not proven gone; ownership is unverified"
}

# Resolve by this home's labels, never by a pane ID that a restart can recycle.
# An empty target means a successful inventory found no owned pane and the
# recorded pane is structurally gone.
# A failed inventory remains an error, never an absence proof.
# FM_LOCAL_PANE_INVENTORY may carry one agent-axi list read for unlocked checks.
fm_local_pane_resolve() { # <meta> <task-id>
  local meta=$1 id=$2 session inventory row count workspace panes tabs recorded
  FM_LOCAL_PANE_TARGET=
  FM_LOCAL_PANE_WORKSPACE=
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  recorded=$FM_BACKEND_VALIDATED_TARGET
  fm_backend_source herdr || return 1
  session=$(fm_meta_get "$meta" herdr_session)
  [ -n "$session" ] || return 1
  if fm_backend_herdr_axi_available; then
    inventory=${FM_LOCAL_PANE_INVENTORY:-}
    if [ -z "$inventory" ]; then
      workspace=$(fm_local_pane_workspace "$session" "$(fm_meta_get "$meta" herdr_workspace_id)") || return 1
      [ "$workspace" != absent ] || { fm_local_pane_recorded_gone "$meta" "$id" "$recorded"; return; }
      inventory=$("$FM_BACKEND_HERDR_AXI_BIN" list --session "$session" --json) || return 1
    fi
    row=$(printf '%s' "$inventory" | jq -ce --arg task "$id" '
      if (.crew | type) != "array" then error("missing crew inventory") else . end
      | [.crew[] | select(.task == $task)] as $rows
      | if ($rows | length) > 1 then error("duplicate task panes")
        elif ($rows | length) == 0 then {pane:null}
        elif $rows[0].pane == .supervisor then error("supervisor pane")
        else $rows[0] end') || return 1
    FM_LOCAL_PANE_WORKSPACE=$(printf '%s' "$inventory" | jq -er '.workspace.id') || return 1
  else
    workspace=$(fm_local_pane_workspace "$session" "$(fm_meta_get "$meta" herdr_workspace_id)") || return 1
    [ "$workspace" != absent ] || { fm_local_pane_recorded_gone "$meta" "$id" "$recorded"; return; }
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
    return 0
  fi
  fm_local_pane_recorded_gone "$meta" "$id" "$recorded"
}

# Keep a placement hint after freeing a slot. It is bound to the exact record.
# This file reserves nothing and never authorizes a close or displaces a worker.
fm_local_pane_remember() { # <meta> <task-id>
  local meta=$1 id=$2 receipt tmp session record slot=
  receipt="${meta%.meta}.local-pane.json"
  session=$(fm_meta_get "$meta" herdr_session)
  if fm_backend_herdr_axi_available; then
    record=$("$FM_BACKEND_HERDR_AXI_BIN" get "$id" --session "$session" --json) || return 1
    slot=$(printf '%s' "$record" | jq -r '.record.slot // empty') || return 1
  fi
  [ -n "$FM_LOCAL_PANE_TARGET" ] || [ -n "$slot" ] || return 0
  tmp=$(mktemp "${receipt}.XXXXXX") || return 1
  if jq -n --arg home "$(cd "$FM_HOME" && pwd -P)" --arg task "$id" \
      --arg source "$(fm_meta_get "$meta" window)" --arg gen "$(fm_meta_get "$meta" spawn_gen)" \
      --arg session "$session" --arg slot "$slot" \
      --arg workspace "$FM_LOCAL_PANE_WORKSPACE" \
      '{version:1,home:$home,task:$task,source:$source,gen:$gen,session:$session,slot:$slot,workspace:$workspace}' > "$tmp" \
      && mv -f "$tmp" "$receipt"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# "held" means the caller already holds the target session's presentation lock.
fm_local_pane_close() { # <meta> <task-id> [held]
  local meta=$1 id=$2 target
  fm_local_pane_resolve "$meta" "$id" || return 1
  target=$FM_LOCAL_PANE_TARGET
  # No home workspace means no owned pane and no slot to remember.
  [ -n "$FM_LOCAL_PANE_WORKSPACE" ] || return 0
  # The backend re-reads its recovery classifier immediately before the close.
  # Remembering the slot changes no endpoint and is safe before that read.
  fm_local_pane_remember "$meta" "$id" || return 1
  [ -n "$target" ] || return 0
  if [ "${3:-}" = held ]; then
    fm_local_pane_close_held "$id" "$target"
    return
  fi
  fm_backend_task_endpoint_close herdr "${meta%/*}" "$id" "$target" "$meta" \
    || fm_local_pane_error "$id at $target: $FM_BACKEND_TASK_CLOSE_REASON"
}

# The backend's flat close for a caller that already holds the session
# presentation lock, so the close never takes or releases that hold. Each
# attempt re-reads the recovery classifier and closes only an agent-free pane;
# only a structurally gone pane confirms the close.
FM_LOCAL_PANE_CLOSE_TRIES=3
fm_local_pane_close_held() { # <task-id> <target>
  local id=$1 target=$2 session pane observed attempt=0
  fm_backend_herdr_parse_target "$target" \
    || { fm_local_pane_error "$id at $target: the endpoint cannot be parsed exactly"; return 1; }
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  while [ "$attempt" -lt "$FM_LOCAL_PANE_CLOSE_TRIES" ]; do
    observed=$(fm_backend_agent_state herdr "$target")
    case "$observed" in
      missing) return 0 ;;
      dead) ;;
      alive) fm_local_pane_error "$id at $target: an agent is still running on it"; return 1 ;;
      *) fm_local_pane_error "$id at $target: its state reads '$observed', which never licenses a close"; return 1 ;;
    esac
    if fm_backend_herdr_axi_available; then
      "$FM_BACKEND_HERDR_AXI_BIN" teardown "$id" --session "$session" >/dev/null 2>&1 || true
    fi
    fm_backend_herdr_kill_serialized "$session" "$pane" >/dev/null 2>&1 || true
    attempt=$((attempt + 1))
    sleep 0.3
  done
  [ "$(fm_backend_agent_state herdr "$target")" = missing ] \
    || fm_local_pane_error "$id at $target: the pane could not be confirmed closed after $FM_LOCAL_PANE_CLOSE_TRIES attempts"
}

# The loud report for a task pane teardown could not close. Reads T, ID, FORCE,
# and FM_LOCAL_PANE_GUARD_STATE from the teardown caller.
fm_local_pane_leak_report() { # <close-attempts>
  echo "error: LEAKED HERDR PANE - $T for $ID is still open after $1 close attempts" >&2
  if [ "${FM_LOCAL_PANE_GUARD_STATE:-}" = alive ]; then
    echo "error: its agent is still running, so pane cleanup refused to close it" >&2
  else
    echo "error: its agent may already have exited, so it is likely showing as a bare terminal pane" >&2
  fi
  if [ "$FORCE" = --force ]; then
    echo "error: cleanup continued and this task's records are being removed, so close it by that exact pane id (a focused task tab, a contended session lock, or an unreachable server all block the close)" >&2
  else
    echo "error: teardown refused and this task's records are retained for a rerun, so close it by that exact pane id or rerun teardown (a focused task tab, a contended session lock, or an unreachable server all block the close)" >&2
  fi
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

# shellcheck disable=SC2034 # Output globals are read by fm-spawn.
fm_local_pane_relaunch_state() {
  local observed
  fm_local_pane_resolve "$RELAUNCH_META" "$ID" || return 1
  # With no home workspace, a missing recorded pane belongs to the upstream
  # absence proof and rebind, which re-create the labeled workspace. A recorded
  # pane that still exists here was proven to belong to other work.
  if [ -z "$FM_LOCAL_PANE_WORKSPACE" ]; then
    [ "$RELAUNCH_STATE" != missing ] || return 0
    fm_local_pane_error "$ID has no home workspace and its recorded pane $RELAUNCH_TARGET now belongs to other work; relaunch refused"
    return 1
  fi
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

# shellcheck disable=SC2034,SC2153 # fm-spawn owns STATE and reads the output globals.
fm_local_pane_relaunch_create() {
  local receipt slot session workspace out ids occupancy slot_tab slot_n
  local -a launch args
  # Fresh spawns and other relaunches must not take the requested slot between
  # this check and agent-axi's spawn. fm-control relaunch reserved the task set
  # before it stopped the old agent; a direct relaunch takes it here.
  SPAWN_TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || return 1
  if [ "${FM_LOCAL_PANE_TASK_SET_OWNER:-}" != "$PPID" ] \
     || [ "$(cat "$SPAWN_TASK_SET_LOCK/pid" 2>/dev/null)" != "$PPID" ]; then
    fm_lock_try_acquire "$SPAWN_TASK_SET_LOCK" \
      || { fm_local_pane_error 'this home has another spawn or teardown in progress'; return 1; }
    SPAWN_TASK_SET_LOCK_HELD=1
  fi
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

# fm-control relaunch reserves the home's task set before it stops the old
# agent, so a concurrent spawn cannot leave the task with no agent and no pane.
# Its fm-spawn child uses the reservation through FM_LOCAL_PANE_TASK_SET_OWNER.
fm_local_pane_reserve() { # <task-id>
  FM_LOCAL_PANE_TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || return 1
  if ! fm_lock_acquire_wait_bounded "$FM_LOCAL_PANE_TASK_SET_LOCK" "${FM_LOCAL_PANE_RESERVE_WAIT:-120}"; then
    FM_LOCAL_PANE_TASK_SET_LOCK=
    fm_local_pane_error "$1 relaunch refused before its agent was stopped: this home has another spawn or teardown in progress"
    return 1
  fi
  FM_LOCAL_PANE_TASK_SET_OWNER=$$
  export FM_LOCAL_PANE_TASK_SET_OWNER
}

fm_local_pane_release() {
  [ -n "${FM_LOCAL_PANE_TASK_SET_LOCK:-}" ] || return 0
  fm_lock_release "$FM_LOCAL_PANE_TASK_SET_LOCK" || true
  FM_LOCAL_PANE_TASK_SET_LOCK=
  unset FM_LOCAL_PANE_TASK_SET_OWNER
}

# Teardown ends a live worker with fm-control exit's steps while it holds the
# task control lock: interrupt a busy turn, submit the harness exit command,
# then wait for the proven-gone state. It never closes the pane itself.
fm_local_pane_stop() { # <meta> <task-id> <target>
  local meta=$1 id=$2 target=$3 harness key clear i=0 verdict
  local poll=${FM_CONTROL_POLL:-0.5} wait=${FM_CONTROL_EXIT_WAIT:-30} waited=0
  harness=$(fm_control_harness_family "$(fm_meta_get "$meta" harness)") || return 1
  fm_control_harness_supported "$harness" || return 1
  # shellcheck source=bin/fm-busy-lib.sh
  declare -F fm_busy_classify_meta >/dev/null || . "$FM_BACKEND_LIB_DIR/fm-busy-lib.sh"
  case "$(fm_busy_classify_meta "$meta" "$id" "${meta%/*}")" in
    busy*)
      key=$(fm_control_interrupt_key "$harness")
      clear=$(fm_control_interrupt_clear_key "$harness")
      fm_control_backend_supports_key herdr "$key" || return 1
      [ -z "$clear" ] || fm_control_backend_supports_key herdr "$clear" || return 1
      while [ "$i" -lt "$(fm_control_interrupt_repeat "$harness")" ]; do
        fm_backend_send_key herdr "$target" "$key" "fm-$id" || return 1
        i=$((i + 1))
        sleep 0.2
      done
      [ -z "$clear" ] || fm_backend_send_key herdr "$target" "$clear" "fm-$id" || return 1
      [ "$(fm_backend_agent_state herdr "$target")" != dead ] || return 0
      ;;
  esac
  verdict=$(fm_backend_send_text_submit herdr "$target" "$(fm_control_exit_command "$harness")" 3 "$poll" 1.2 "fm-$id") \
    || return 1
  [ "$verdict" != send-failed ] || return 1
  until [ "$(fm_backend_agent_state herdr "$target")" = dead ]; do
    awk -v e="$waited" -v t="$wait" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$poll"
    waited=$(awk -v e="$waited" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
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
