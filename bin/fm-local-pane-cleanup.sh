#!/usr/bin/env bash
# Close this home's ended Herdr worker panes without removing work or records.
# Usage: FM_HOME=<home> fm-local-pane-cleanup.sh sweep
#        FM_HOME=<home> fm-local-pane-cleanup.sh close <task-id>
#        FM_HOME=<home> fm-local-pane-cleanup.sh repair
# A sweep skips contended task locks and unproven process states.
# A close reports failure unless an owned pane is proven gone.
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

close_one() ( # <task-id> <sweep|close>
  local id=$1 mode=$2 meta lock target state
  fm_task_id_creation_valid "$id" || return 1
  meta="$STATE/$id.meta"
  fm_local_pane_worker "$meta" "$id" || return 0
  fm_local_pane_flat "$meta" || return 0
  lock="$STATE/.control-$id.lock"
  if ! fm_lock_try_acquire "$lock"; then
    [ "$mode" = sweep ] && return 0
    fm_local_pane_error "$id has a lifecycle action in progress"
    return 1
  fi
  trap 'fm_lock_release "$lock"' EXIT
  fm_local_pane_worker "$meta" "$id" || return 0
  fm_local_pane_resolve "$meta" "$id" || return 1
  target=$FM_LOCAL_PANE_TARGET
  [ -n "$target" ] || return 0
  state=$(fm_backend_agent_state herdr "$target")
  case "$state" in
    dead|missing) ;;
    *)
      [ "$mode" = sweep ] && return 0
      fm_local_pane_error "$id at $target reads $state; no pane was closed"
      return 1 ;;
  esac
  fm_local_pane_close "$meta" "$id" || return 1
  printf 'closed %s pane=%s\n' "$id" "$target"
)

# Repair must not bypass a skipped classifier or task lock. Until agent-axi can
# accept a close allowlist atomically, defer repair while any crew pane remains.
# Empty-workspace ledger repair still runs, with fresh spawns excluded.
repair_layout() (
  local lock inventory plan out session summary
  fm_backend_source herdr || return 1
  fm_backend_herdr_axi_available || return 0
  lock=$(fm_task_set_lock_path "$STATE") || return 1
  fm_lock_try_acquire "$lock" || return 0
  trap 'fm_lock_release "$lock"' EXIT
  session=${HERDR_SESSION:-default}
  inventory=$("$FM_BACKEND_HERDR_AXI_BIN" list --session "$session" --json) || return 1
  printf '%s' "$inventory" | jq -e '(.crew | type) == "array" and (.crew | length) == 0' >/dev/null || return 0
  plan=$("$FM_BACKEND_HERDR_AXI_BIN" layout --repair --dry-run --session "$session" --json) || return 1
  printf '%s' "$plan" | jq -e '(.repair.actions | type) == "array" and
    all(.repair.actions[]; .kind == "free-gone" or .kind == "rebind")' >/dev/null || return 0
  out=$("$FM_BACKEND_HERDR_AXI_BIN" layout --repair --session "$session" --json) || return 1
  # shellcheck source=bin/fm-herdr-layout-lib.sh
  . "$SCRIPT_DIR/fm-herdr-layout-lib.sh"
  [ "$(printf '%s' "$out" | jq -r '.repair.converged')" != true ] || return 0
  summary=$(fm_herdr_layout_counts_summary "$out") || return 1
  printf 'BOOTSTRAP_INFO: healed herdr layout drift: %s\n' "$summary"
)

case "${1:-}" in
  sweep)
    [ "$#" -eq 1 ] || exit 2
    rc=0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}; id=${id%.meta}
      close_one "$id" sweep || rc=1
    done
    exit "$rc"
    ;;
  close)
    [ "$#" -eq 2 ] || exit 2
    close_one "$2" close
    ;;
  repair)
    [ "$#" -eq 1 ] || exit 2
    repair_layout
    ;;
  *) echo 'usage: fm-local-pane-cleanup.sh sweep | close <task-id> | repair' >&2; exit 2 ;;
esac
