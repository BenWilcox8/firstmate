#!/usr/bin/env bash
# fm-local-dormant.sh - the durable dormant marker for second mates.
#
# A dormant second mate is one the captain has ordered to stay down. Its home,
# records, and registry route stay, but no automatic relaunch may start it:
# bin/fm-bootstrap.sh's startup liveness sweep (through the
# secondmate-liveness-skip hook) and bin/fm-local-restart-recovery.sh's restart
# recovery pass both read this marker and leave it down.
# A deliberate `bin/fm-spawn.sh <id> --secondmate` or `bin/fm-control.sh <id>
# relaunch` does not read it: a relaunch by hand is the captain's own call, so
# clear the marker when the captain authorizes the domain again.
# Setting the marker does not stop a running second mate; use
# `bin/fm-control.sh <id> exit` for that.
#
# Usage:
#   fm-local-dormant.sh set <id> --reason <text>
#   fm-local-dormant.sh clear <id>
#   fm-local-dormant.sh list
#   fm-local-dormant.sh is <id>      exit 0 and print the reason when dormant
#
# Storage: data/secondmate-dormant in this home, one line per second mate:
#   <id><TAB><YYYY-MM-DD><TAB><reason>
# `set` accepts only a second mate this home registers in data/secondmates.md
# or records as kind=secondmate in state/<id>.meta, so a typo cannot mark
# nothing. Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DORMANT_FILE="$DATA/secondmate-dormant"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

valid_id() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The dormant line for <id>, or nothing.
dormant_line() {  # <id>
  [ -f "$DORMANT_FILE" ] || return 1
  awk -F '\t' -v id="$1" '$1 == id { print; found = 1; exit } END { exit !found }' "$DORMANT_FILE"
}

registered() {  # <id>
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$1" && return 0
  [ -f "$STATE/$1.meta" ] && grep -qx 'kind=secondmate' "$STATE/$1.meta"
}

# Rewrite the marker file without <id>, then append <line> when given.
rewrite() {  # <id> [<line>]
  local id=$1 line=${2:-} tmp
  mkdir -p "$DATA" || die "cannot create $DATA"
  tmp=$(mktemp "$DATA/.secondmate-dormant.XXXXXX") || die "cannot write $DATA"
  if [ -f "$DORMANT_FILE" ]; then
    awk -F '\t' -v id="$id" '$1 != id' "$DORMANT_FILE" > "$tmp" || { rm -f "$tmp"; die "cannot read $DORMANT_FILE"; }
  fi
  [ -z "$line" ] || printf '%s\n' "$line" >> "$tmp"
  if [ -s "$tmp" ]; then
    mv "$tmp" "$DORMANT_FILE" || { rm -f "$tmp"; die "cannot update $DORMANT_FILE"; }
  else
    rm -f "$tmp" "$DORMANT_FILE"
  fi
}

cmd_set() {
  local id=${1:-} reason=''
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || die "--reason needs a value"; reason=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  valid_id "$id" || die "set needs a second mate id"
  reason=$(printf '%s' "$reason" | tr '\t\r\n' '   ')
  [ -n "${reason// /}" ] || die "set needs --reason <text>: the captain order that keeps $id down"
  registered "$id" || die "$id is not a second mate this home registers; refusing to mark it dormant"
  rewrite "$id" "$(printf '%s\t%s\t%s' "$id" "$(date +%Y-%m-%d)" "$reason")"
  printf 'dormant: %s (%s)\n' "$id" "$reason"
}

cmd_clear() {
  local id=${1:-}
  valid_id "$id" || die "clear needs a second mate id"
  dormant_line "$id" >/dev/null || { printf 'not dormant: %s\n' "$id"; return 0; }
  rewrite "$id"
  printf 'cleared: %s\n' "$id"
}

cmd_list() {
  [ -f "$DORMANT_FILE" ] || return 0
  awk -F '\t' 'NF >= 3 { printf "%s  since %s  %s\n", $1, $2, $3 }' "$DORMANT_FILE"
}

cmd_is() {
  local id=${1:-} line
  valid_id "$id" || return 1
  line=$(dormant_line "$id") || return 1
  printf '%s\n' "$line" | awk -F '\t' '{ print $3 }'
}

case "${1:-}" in
  set) shift; cmd_set "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  list) cmd_list ;;
  is) shift; cmd_is "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
