#!/usr/bin/env bash
# Print how many firstmate workers are open in Herdr right now, and the
# concurrent agent limit that bin/fm-spawn.sh enforces.
# Usage: fm-agent-count.sh [--json] [--session <name>]...
#   A counted agent is a Herdr pane whose foreground process is an agent
#   harness and that a firstmate home records as a ship or scout task.
#   Supervisors (MAIN and secondmates) and unmanaged agent panes are listed
#   apart and never counted. Ghost legs, closed panes (a parked ticket's
#   pane is closed), and exited agents never count; a task agent still open in
#   its pane always counts. bin/fm-agent-limit-lib.sh owns the rules.
#   Every local firstmate home on this machine is counted, from any home.
#   --json      print one JSON document: count, limit (a number, or null when
#               the limit is off), limit_source (default or config), override
#               (off when config/agent-limit says off, else none),
#               at_limit, sessions, and the pane lists agents, supervisors,
#               unmanaged, and unreadable. Each pane entry has session, pane,
#               workspace, home, task, kind, and harness; unknown values are
#               null. Unreadable panes retain pane-list workspace and matching
#               task-record fields when they are available.
#   --session   count only this Herdr session (repeatable, deduplicated). The default is
#               every session a home's Herdr task record names.
# The limit is config/agent-limit: one positive whole number, or `off`.
# Absent means the default (30). To go past the limit once, pass --over-limit
# to bin/fm-spawn.sh; to disable it, write `off` to config/agent-limit.
# Exit status: 0 on success, 1 when Herdr or the limit file cannot be read.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

JSON=0
SESSIONS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1 ;;
    --session)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "error: --session requires a name" >&2; exit 1; }
      SESSIONS+=("$2")
      shift
      ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-agent-limit-lib.sh
. "$SCRIPT_DIR/fm-agent-limit-lib.sh"
fm_backend_source herdr

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LIMIT=$(fm_agent_limit_read "$CONFIG") || exit 1
LIMIT_SOURCE=$(fm_agent_limit_source "$CONFIG")
DOC=$(fm_agent_limit_count_json "$FM_HOME" "${SESSIONS[@]+"${SESSIONS[@]}"}") || exit 1
DOC=$(printf '%s' "$DOC" | jq --arg limit "$LIMIT" --arg source "$LIMIT_SOURCE" '
  (if $limit == "off" then null else ($limit | tonumber) end) as $l
  | {count, limit: $l, limit_source: $source,
     override: (if $limit == "off" then "off" else "none" end),
     at_limit: ($l != null and .count >= $l)} + del(.count)')

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$DOC"
  exit 0
fi
printf '%s' "$DOC" | jq -r '
  def line: "  \(.home // "-") \(.task // "-") \(.harness) \(.session):\(.pane)";
  "agents: \(.count) / \(.limit // "off") (limit from \(.limit_source))",
  (.agents[] | line),
  (if (.supervisors | length) > 0 then "supervisors (not counted):", (.supervisors[] | line) else empty end),
  (if (.unmanaged | length) > 0 then "unmanaged agents (not counted):", (.unmanaged[] | line) else empty end),
  (if (.unreadable | length) > 0 then "unreadable panes (not counted):", (.unreadable[] | "  \(.session):\(.pane)") else empty end)'
