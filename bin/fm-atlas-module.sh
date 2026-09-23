#!/usr/bin/env bash
# The optional Atlas module's entry point for firstmate's core hook points.
#
# Every Atlas-specific behavior in firstmate lives in the module, and each core
# script reaches it through one stable call to this file or to
# bin/fm-atlas-hook.sh. docs/atlas-module/README.md is the module map.
#
# Usage: fm-atlas-module.sh supervisor-block
#        fm-atlas-module.sh crewmate-brief <task-id> [--ticket <ticket-id>]
#        fm-atlas-module.sh dispatch-check <task-id> [--ticket <ticket-id>]
#
#   supervisor-block  prints the supervisor instructions for an Atlas-wired home:
#                     a banner, then docs/atlas-module/supervisor-block.md.
#                     bin/fm-session-start.sh prints it right after the harness
#                     supervision block, so every firstmate and secondmate session
#                     in a wired home reads it and no other session does.
#   crewmate-brief    prints docs/atlas-module/crewmate-brief.md with {TICKET}
#                     set to the task's ticket and {HOLDER} set to its Atlas
#                     author name. bin/fm-spawn.sh appends it to a ship or scout
#                     worker's launch brief. The ticket is --ticket when given,
#                     else the task's recorded atlas_ticket= in
#                     state/<task-id>.meta, so a relaunch keeps the fragment. It
#                     prints nothing for a task with no ticket.
#   dispatch-check    warns on stderr, in one line, when a wired home dispatches a
#                     ship or scout with no ticket, because that work will not
#                     appear on the map. bin/fm-spawn.sh calls it for a fresh ship
#                     or scout spawn. The warning is advisory and never blocks.
#
# The author name is fm-<task-id>, or the task id itself when it already starts
# with fm-. It is the same holder name `fm-atlas-hook.sh start` gives the ticket,
# so the worker's own writes carry the name the ticket is held under.
#
# A home is wired when `fm-atlas-hook.sh wired` resolves its config/specs
# pointer; that hook owns the resolution rule. In a home that is not wired, every
# verb prints nothing, so the home behaves as if the module did not exist.
#
# NEVER BLOCKS. Every path exits 0, including a missing fragment, an unusable
# id, and any internal error, so a caller under `set -e` is safe. Callers still
# append `|| true`. A caller that must know whether anything printed checks for
# empty output, never the exit status.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/docs/atlas-module"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

atlas_wired() {
  [ -n "$("$SCRIPT_DIR/fm-atlas-hook.sh" wired 2>/dev/null || true)" ]
}

# Ids become sed replacements and state paths, so they keep fm-spawn's closed
# character set.
safe_id() {
  case "$1" in
    ''|-*|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

holder_for() {  # <task-id>
  case "$1" in
    fm-*) printf '%s\n' "$1" ;;
    *) printf 'fm-%s\n' "$1" ;;
  esac
}

print_supervisor_block() {
  local fragment="$MODULE_DIR/supervisor-block.md"
  atlas_wired || return 0
  [ -r "$fragment" ] || return 0
  printf '%s\n' '================================================================================'
  printf '%s\n' 'ATLAS MODULE - supervisor instructions for this Atlas-wired home'
  printf '%s\n' '================================================================================'
  cat "$fragment"
  printf '\n'
}

# Sets TICKET from --ticket in the arguments after the task id; empty when absent.
parse_ticket() {
  TICKET=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ticket)
        TICKET=${2:-}
        if [ "$#" -ge 2 ]; then shift 2; else shift; fi
        ;;
      --ticket=*) TICKET=${1#--ticket=}; shift ;;
      *) shift ;;
    esac
  done
}

print_crewmate_brief() {  # <task-id> [--ticket <ticket-id>]
  local id=${1:-} ticket fragment="$MODULE_DIR/crewmate-brief.md" holder
  safe_id "$id" || return 0
  shift
  parse_ticket "$@"
  ticket=$TICKET
  [ -n "$ticket" ] || ticket=$(sed -n 's/^atlas_ticket=//p' "$STATE/$id.meta" 2>/dev/null | tail -n 1)
  [ -n "$ticket" ] || return 0
  safe_id "$ticket" || return 0
  atlas_wired || return 0
  [ -r "$fragment" ] || return 0
  holder=$(holder_for "$id")
  printf '\n'
  sed -e "s|{TICKET}|$ticket|g" -e "s|{HOLDER}|$holder|g" "$fragment"
}

# The one advisory line a wired home gets for ticket-less ship or scout work.
print_dispatch_check() {  # <task-id> [--ticket <ticket-id>]
  local id=${1:-}
  safe_id "$id" || return 0
  shift
  parse_ticket "$@"
  [ -z "$TICKET" ] || return 0
  atlas_wired || return 0
  echo "warning: $id is being dispatched without --ticket; Atlas doctrine carries work on a ticket, so this task will not appear on the map" >&2
}

run_module() {
  local verb=${1:-}
  [ "$#" -eq 0 ] || shift
  case "$verb" in
    -h|--help) usage ;;
    supervisor-block) print_supervisor_block ;;
    crewmate-brief) print_crewmate_brief "$@" ;;
    dispatch-check) print_dispatch_check "$@" ;;
    *) printf 'fm-atlas-module: unknown verb %s\n' "${verb:-(none)}" >&2 ;;
  esac
}

( run_module "$@" ) || true
exit 0
