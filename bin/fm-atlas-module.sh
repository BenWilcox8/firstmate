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
#        fm-atlas-module.sh worker-env <task-id>
#        fm-atlas-module.sh launch-env-names
#
#   supervisor-block  prints the supervisor instructions for an Atlas-wired home:
#                     a banner, then docs/atlas-module/supervisor-block.md.
#                     bin/fm-session-start.sh prints it right after the harness
#                     supervision block, so every firstmate and secondmate session
#                     in a wired home reads it and no other session does.
#   crewmate-brief    prints docs/atlas-module/crewmate-brief.md with {TICKET}
#                     set to the task's ticket and {HOLDER} set to its Atlas
#                     author name. bin/fm-spawn.sh appends it to a ship or scout
#                     worker's launch brief. A fresh spawn passes --ticket, empty
#                     when the spawn has no ticket, and only that value counts,
#                     so an older record under the same id never adds a ticket.
#                     A relaunch passes no --ticket, so the ticket is the task's
#                     recorded atlas_ticket= in state/<task-id>.meta and the
#                     fragment stays. It prints nothing for a task with no ticket.
#   dispatch-check    warns on stderr, in one line, when a wired home dispatches a
#                     ship or scout with no ticket, because that work will not
#                     appear on the map. bin/fm-spawn.sh calls it for a fresh ship
#                     or scout spawn. The warning is advisory and never blocks.
#   worker-env        prints the shell lines a ship or scout worker pane needs for
#                     the Atlas, each `export NAME=<value>` or `unset NAME...`. In
#                     a wired home: `unset SPECS_REPO`, then
#                     `export ATLAS_AXI_BY=<its crew name>`, so every atlas-axi
#                     write it makes is attributed to its task, then
#                     `export ATLAS_REPO=<the repo, shell-quoted>`, so a bare
#                     atlas-axi reaches this home's map. In a home that is not
#                     wired: `unset ATLAS_REPO SPECS_REPO ATLAS_AXI_BY`, so a value
#                     the firstmate shell inherited never reaches the worker.
#                     bin/fm-spawn.sh sends each line to the worker pane, fresh and
#                     relaunched. It exports only names that launch-env-names
#                     prints, so each value also passes the launch environment.
#   launch-env-names  prints ATLAS_AXI_BY and ATLAS_REPO, one name on each line.
#                     When config/launch-env-allowlist turns on the filtered launch
#                     environment, bin/fm-spawn.sh passes these names through it
#                     for every pane kind, secondmates included, so a value that
#                     the pane shell holds still reaches a bare atlas-axi.
#
# worker-env and launch-env-names are the exceptions to the rule below, because
# they print in every home: to clear or pass through an inherited value is not
# an Atlas call.
#
# The author name is the task's crew name, the same name `fm-atlas-hook.sh start`
# holds the ticket under, so the worker's own writes carry that name.
#
# A home is wired when its config/specs pointer resolves. bin/fm-atlas-lib.sh owns
# that rule and the crew-name rule. In a home that is not wired, every
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
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-atlas-lib.sh
. "$SCRIPT_DIR/fm-atlas-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

atlas_wired() {
  fm_atlas_repo "$CONFIG" >/dev/null
}

# Ids become sed replacements and state paths, so they keep fm-spawn's closed
# character set.
safe_id() {
  case "$1" in
    ''|-*|.*|*[!A-Za-z0-9._-]*) return 1 ;;
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

# Sets TICKET from --ticket in the arguments after the task id, and TICKET_GIVEN
# to 1 when --ticket appears at all, even with an empty value.
parse_ticket() {
  TICKET=
  TICKET_GIVEN=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ticket)
        TICKET=${2:-}
        TICKET_GIVEN=1
        if [ "$#" -ge 2 ]; then shift 2; else shift; fi
        ;;
      --ticket=*) TICKET=${1#--ticket=}; TICKET_GIVEN=1; shift ;;
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
  [ "$TICKET_GIVEN" -eq 1 ] || ticket=$(sed -n 's/^atlas_ticket=//p' "$STATE/$id.meta" 2>/dev/null | tail -n 1)
  [ -n "$ticket" ] || return 0
  safe_id "$ticket" || return 0
  atlas_wired || return 0
  [ -r "$fragment" ] || return 0
  holder=$(fm_atlas_holder "$id")
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

print_worker_env() {  # <task-id>
  local id=${1:-} repo
  safe_id "$id" || return 0
  if ! repo=$(fm_atlas_repo "$CONFIG"); then
    printf 'unset ATLAS_REPO SPECS_REPO ATLAS_AXI_BY\n'
    return 0
  fi
  printf 'unset SPECS_REPO\n'
  printf 'export ATLAS_AXI_BY=%s\n' "$(fm_atlas_holder "$id")"
  printf "export ATLAS_REPO='%s'\n" "$(printf '%s' "$repo" | sed "s/'/'\\\\''/g")"
}

print_launch_env_names() {
  printf '%s\n' ATLAS_AXI_BY ATLAS_REPO
}

run_module() {
  local verb=${1:-}
  [ "$#" -eq 0 ] || shift
  case "$verb" in
    -h|--help) usage ;;
    supervisor-block) print_supervisor_block ;;
    crewmate-brief) print_crewmate_brief "$@" ;;
    dispatch-check) print_dispatch_check "$@" ;;
    worker-env) print_worker_env "$@" ;;
    launch-env-names) print_launch_env_names ;;
    *) printf 'fm-atlas-module: unknown verb %s\n' "${verb:-(none)}" >&2 ;;
  esac
}

( run_module "$@" ) || true
exit 0
