#!/usr/bin/env bash
# Fork hooks. Each case has one owner and leaves unrelated backends unchanged.
fm_local_hook() {
  case "$1" in
    provenance-*)
      # shellcheck source=bin/fm-local-send-provenance.sh
      . "$FM_BACKEND_LIB_DIR/fm-local-send-provenance.sh"
      case "$1" in
        provenance-init) fm_local_provenance_init "${@:2}" ;;
        provenance-typed) fm_local_provenance_typed "${@:2}" ;;
        provenance-launch) fm_local_provenance_launch "${@:2}" ;;
        provenance-remote-sent) fm_local_provenance_remote_sent ;;
        provenance-prune) fm_local_provenance_prune "${@:2}" ;;
        *) echo "error: unknown local hook: $1" >&2; return 1 ;;
      esac
      return
      ;;
  esac
  if [ "$1" = test-family ]; then
    awk -F '\t' -v name="$2" '$1 == name {print $2; found=1; exit} END {exit !found}' "$ROOT/bin/fm-local-test-families.tsv"
    return
  fi
  # This library is a canonical lint root; do not expand it through every caller.
  # shellcheck source=/dev/null
  . "$FM_BACKEND_LIB_DIR/fm-local-pane-lib.sh"
  # shellcheck disable=SC2034,SC2153 # Lifecycle scripts own META, STATE, and ID and read state.
  case "$1" in
    pane-exit-state)
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_local_pane_flat "$META" || return 0
      fm_local_pane_resolve "$META" "$ID" || return 1
      if [ -n "$FM_LOCAL_PANE_TARGET" ]; then
        T=$FM_LOCAL_PANE_TARGET
        state=$(fm_backend_agent_state herdr "$T")
      else
        state=dead
      fi
      ;;
    pane-exit-close)
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_local_pane_flat "$META" || return 0
      fm_local_pane_close "$META" "$ID"
      ;;
    pane-spawn-state)
      [ "${RESUME_SESSION:-0}" = 0 ] || return 0
      fm_local_pane_worker "$RELAUNCH_META" "$ID" || return 0
      fm_local_pane_flat "$RELAUNCH_META" || return 0
      fm_local_pane_relaunch_state
      ;;
    pane-spawn-create)
      [ "${FM_LOCAL_PANE_RELAUNCH:-0}" = 1 ] || return 0
      fm_local_pane_relaunch_create
      ;;
    pane-spawn-abort)
      [ "${2:-0}" != 0 ] && [ "${FM_LOCAL_PANE_LAUNCH_ATTEMPTED:-0}" = 1 ] || return 0
      fm_local_pane_abort "$RELAUNCH_META" "$ID"
      ;;
    pane-control-reserve)
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_local_pane_flat "$META" || return 0
      fm_local_pane_reserve "$ID"
      ;;
    pane-control-refresh)
      fm_local_pane_release
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_backend_validate_task_endpoint "$META" "$ID" || return 1
      T=$FM_BACKEND_VALIDATED_TARGET
      ;;
    pane-control-abort)
      local status=0
      if [ "${RELAUNCH_ACTIVE:-0}" = 1 ] && fm_local_pane_worker "$META" "$ID" && fm_local_pane_flat "$META"; then
        case "${RELAUNCH_PHASE:-}" in
          stopping|exited|launching) fm_local_pane_abort "$META" "$ID" || status=1 ;;
        esac
      fi
      fm_local_pane_release
      return "$status"
      ;;
    pane-teardown-target)
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_local_pane_flat "$META" || return 0
      if ! fm_local_pane_resolve "$META" "$ID"; then
        if [ "$FORCE" = --force ]; then
          echo "warning: pane cleanup: $ID ownership could not be verified; --force keeps recorded pane $T and closes no pane it cannot verify" >&2
          return 0
        fi
        fm_local_pane_error "$ID ownership could not be verified; nothing was changed - retry once the home inventory is readable"
        return 1
      fi
      [ -z "$FM_LOCAL_PANE_TARGET" ] || T=$FM_LOCAL_PANE_TARGET
      ;;
    pane-teardown-stop)
      local target=$T
      fm_local_pane_worker "$META" "$ID" || return 0
      if fm_local_pane_flat "$META"; then
        if ! fm_local_pane_resolve "$META" "$ID"; then
          [ "$FORCE" != --force ] || return 0
          fm_local_pane_error "$ID ownership could not be verified; nothing was removed - retry once the home inventory is readable"
          return 1
        fi
        [ -n "$FM_LOCAL_PANE_TARGET" ] || return 0
        target=$FM_LOCAL_PANE_TARGET
      fi
      [ "$(fm_backend_agent_state herdr "$target")" = alive ] || return 0
      fm_local_pane_stop "$META" "$ID" "$target" && return 0
      fm_local_pane_error "$ID's agent at $target is still running and teardown could not stop it; nothing was removed - stop it with bin/fm-control.sh $ID exit, then rerun teardown"
      ;;
    pane-teardown-close)
      # An unforced teardown closes the stopped worker's proven-gone pane before
      # the reap and the slot return, so an unconfirmed close refuses while the
      # slot is still leased. --force never refuses on the close, so the later
      # upstream close with its retry notices owns that path unchanged.
      [ "$FORCE" != --force ] || return 0
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_local_pane_flat "$META" || return 0
      fm_local_pane_close "$META" "$ID" 2>/dev/null && return 0
      [ "$(fm_backend_agent_state herdr "$T")" != alive ] || FM_LOCAL_PANE_GUARD_STATE=alive
      fm_local_pane_leak_report
      return 1
      ;;
    pane-teardown-gone)
      fm_local_pane_worker "$META" "$ID" || return 1
      fm_local_pane_flat "$META" || return 1
      fm_local_pane_resolve "$META" "$ID" || return 1
      [ -z "$FM_LOCAL_PANE_TARGET" ]
      ;;
    pane-teardown-guard)
      FM_LOCAL_PANE_GUARD_STATE=
      fm_local_pane_worker "$META" "$ID" || return 0
      if fm_local_pane_flat "$META"; then
        fm_local_pane_resolve "$META" "$ID" || return 1
        [ "$FM_LOCAL_PANE_TARGET" = "$T" ] || return 1
      fi
      FM_LOCAL_PANE_GUARD_STATE=$(fm_backend_agent_state herdr "$T")
      [ "$FM_LOCAL_PANE_GUARD_STATE" = dead ]
      ;;
    pane-teardown-report)
      fm_local_pane_worker "$META" "$ID" || return 1
      if fm_local_pane_flat "$META" && fm_local_pane_recorded_gone "$META" "$ID" "$T" 2>/dev/null; then
        echo "warning: $ID's recorded pane $T is gone or now belongs to other work, so pane cleanup neither closed nor reports it as this task's pane" >&2
        return 0
      fi
      fm_local_pane_leak_report
      ;;
    pane-teardown-confirm)
      fm_local_pane_worker "$META" "$ID" || return 0
      [ "$HERDR_CLOSE_CONFIRMED" = 1 ] || [ "$FORCE" = --force ]
      ;;
    pane-teardown-retired)
      rm -f "${META%.meta}.local-pane.json"
      ;;
    pane-sweep)
      # Detached and single-flight, like the watcher's other slow sweeps.
      if [ -n "${FM_LOCAL_PANE_SWEEP_PID:-}" ]; then
        ! kill -0 "$FM_LOCAL_PANE_SWEEP_PID" 2>/dev/null || return 0
        wait "$FM_LOCAL_PANE_SWEEP_PID" 2>/dev/null || true
      fi
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$FM_BACKEND_LIB_DIR/fm-local-pane-cleanup.sh" sweep </dev/null >/dev/null &
      FM_LOCAL_PANE_SWEEP_PID=$!
      ;;
    pane-bootstrap-repair)
      # Status 1 lets the caller run its unchanged repair; 0 means it was handled.
      local plan planned task pane closes=
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$FM_BACKEND_LIB_DIR/fm-local-pane-cleanup.sh" sweep >/dev/null || true
      fm_herdr_layout_applicable || return 0
      # With no task record here, no planned close can be a recorded task's.
      compgen -G "$STATE/*.meta" >/dev/null || return 1
      plan=$("$(fm_herdr_layout_bin)" layout --repair --dry-run --json 2>/dev/null) || return 0
      planned=$(printf '%s' "$plan" | jq -r '.repair.actions
        | if type == "array" then . else error("missing repair plan") end
        | .[] | select(.kind != "free-gone" and .kind != "rebind" and .kind != "adopt")
        | select((.taskId | type) == "string" and .taskId != "")
        | "\(.taskId)\t\(.paneId // "unknown")"') || return 0
      while IFS=$'\t' read -r task pane; do
        case "$task" in ''|.|..|*[!A-Za-z0-9._-]*) continue ;; esac
        [ -e "$STATE/$task.meta" ] || [ -L "$STATE/$task.meta" ] || continue
        closes="${closes:+$closes, }$task $pane"
      done <<< "$planned"
      [ -n "$closes" ] || return 1
      echo "BOOTSTRAP_INFO: skipped herdr layout repair; its plan would close recorded task panes that pane cleanup kept: $closes"
      ;;
    *) echo "error: unknown local hook: $1" >&2; return 1 ;;
  esac
}
