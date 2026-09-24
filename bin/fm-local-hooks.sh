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
    pane-control-refresh)
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_backend_validate_task_endpoint "$META" "$ID" || return 1
      T=$FM_BACKEND_VALIDATED_TARGET
      ;;
    pane-control-abort)
      [ "${RELAUNCH_ACTIVE:-0}" = 1 ] || return 0
      case "${RELAUNCH_PHASE:-}" in stopping|exited|launching) ;; *) return 0 ;; esac
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_local_pane_flat "$META" || return 0
      fm_local_pane_abort "$META" "$ID"
      ;;
    pane-teardown-target)
      fm_local_pane_worker "$META" "$ID" || return 0
      fm_local_pane_flat "$META" || return 0
      fm_local_pane_resolve "$META" "$ID" || {
        fm_local_pane_error "$ID ownership could not be verified; nothing was changed - retry once the home inventory is readable"
        return 1
      }
      [ -z "$FM_LOCAL_PANE_TARGET" ] || T=$FM_LOCAL_PANE_TARGET
      ;;
    pane-teardown-gone)
      fm_local_pane_worker "$META" "$ID" || return 1
      fm_local_pane_flat "$META" || return 1
      fm_local_pane_resolve "$META" "$ID" || return 1
      [ -z "$FM_LOCAL_PANE_TARGET" ]
      ;;
    pane-teardown-guard)
      fm_local_pane_worker "$META" "$ID" || return 0
      if fm_local_pane_flat "$META"; then
        fm_local_pane_resolve "$META" "$ID" || return 1
        [ "$FM_LOCAL_PANE_TARGET" = "$T" ] || return 1
      fi
      [ "$(fm_backend_agent_state herdr "$T")" = dead ]
      ;;
    pane-teardown-report)
      fm_local_pane_worker "$META" "$ID" || return 1
      printf 'error: LEAKED HERDR PANE - %s for %s; close could not be confirmed; a bare terminal may remain.\n' "$T" "$ID" >&2
      if [ "$FORCE" = --force ]; then
        echo 'warning: --force permits task record retirement despite the unclosed pane' >&2
      else
        echo 'error: teardown refused; task records retained for retry' >&2
      fi
      ;;
    pane-teardown-confirm)
      fm_local_pane_worker "$META" "$ID" || return 0
      [ "$HERDR_CLOSE_CONFIRMED" = 1 ] || [ "$FORCE" = --force ] || return 1
      rm -f "${META%.meta}.local-pane.json"
      ;;
    pane-sweep)
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$FM_BACKEND_LIB_DIR/fm-local-pane-cleanup.sh" sweep >/dev/null
      ;;
    pane-bootstrap-repair)
      fm_local_hook pane-sweep || true
      fm_herdr_layout_applicable || return 0
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$FM_BACKEND_LIB_DIR/fm-local-pane-cleanup.sh" repair || true
      ;;
    *) echo "error: unknown local hook: $1" >&2; return 1 ;;
  esac
}
