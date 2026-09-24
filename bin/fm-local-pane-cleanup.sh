#!/usr/bin/env bash
# Close this home's ended Herdr worker panes without removing work or records.
# Usage: FM_HOME=<home> fm-local-pane-cleanup.sh sweep
# A sweep skips contended task locks and unproven process states.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || { echo 'error: pane cleanup requires an explicit FM_HOME' >&2; exit 1; }
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-local-pane-lib.sh
. "$SCRIPT_DIR/fm-local-pane-lib.sh"
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
declare -A INVENTORY=()

# Read-only and unlocked: one inventory read per session for the whole sweep.
# Only a candidate that reads gone here is locked and re-proven below.
husk_candidate() { # <meta> <task-id>
  local meta=$1 id=$2 session
  fm_local_pane_worker "$meta" "$id" || return 1
  fm_local_pane_flat "$meta" || return 1
  fm_backend_source herdr || return 1
  session=$(fm_meta_get "$meta" herdr_session)
  [ -n "$session" ] || return 1
  if fm_backend_herdr_axi_available && [ -z "${INVENTORY[$session]:-}" ]; then
    INVENTORY[$session]=$("$FM_BACKEND_HERDR_AXI_BIN" list --session "$session" --json) || return 1
  fi
  FM_LOCAL_PANE_INVENTORY=${INVENTORY[$session]:-} fm_local_pane_resolve "$meta" "$id" || return 1
  [ -n "$FM_LOCAL_PANE_TARGET" ] || return 1
  case "$(fm_backend_agent_state herdr "$FM_LOCAL_PANE_TARGET")" in
    dead|missing) return 0 ;;
    *) return 1 ;;
  esac
}

# A relaunch holds the control lock; a fresh spawn holds the meta lock from
# before its pane exists until its launch is delivered. Take both, in order.
close_one() ( # <meta> <task-id>
  local meta=$1 id=$2 control meta_lock target
  control="$STATE/.control-$id.lock"
  meta_lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_try_acquire "$control" || return 0
  trap 'fm_lock_release "$control"' EXIT
  fm_lock_try_acquire "$meta_lock" || return 0
  trap 'fm_lock_release "$meta_lock"; fm_lock_release "$control"' EXIT
  fm_local_pane_worker "$meta" "$id" || return 0
  fm_local_pane_flat "$meta" || return 0
  fm_local_pane_resolve "$meta" "$id" || return 1
  target=$FM_LOCAL_PANE_TARGET
  [ -n "$target" ] || return 0
  case "$(fm_backend_agent_state herdr "$target")" in
    dead|missing) ;;
    *) return 0 ;;
  esac
  fm_local_pane_close "$meta" "$id" || return 1
  printf 'closed %s pane=%s\n' "$id" "$target"
)

case "${1:-}" in
  sweep)
    [ "$#" -eq 1 ] || exit 2
    rc=0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}; id=${id%.meta}
      fm_task_id_creation_valid "$id" || { rc=1; continue; }
      husk_candidate "$meta" "$id" || continue
      close_one "$meta" "$id" || rc=1
    done
    exit "$rc"
    ;;
  *) echo 'usage: fm-local-pane-cleanup.sh sweep' >&2; exit 2 ;;
esac
