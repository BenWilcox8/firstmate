#!/usr/bin/env bash
# Hold AGENTS.md under its tracked token ceiling.
# Usage:
#   fm-agentsmd-ceiling.sh [check]
#   fm-agentsmd-ceiling.sh read
#   fm-agentsmd-ceiling.sh report
#
# `check` is the default and is what CI runs: it exits 0 when AGENTS.md is
# within the ceiling and exits 1 naming the overage when it is not.  `read`
# prints the validated ceiling.  `report` prints the accounting as key=value
# lines and exits 0 whenever it could measure, because check owns the verdict.
# A missing or malformed ceiling, or an unreadable AGENTS.md, exits 2:
# the check refuses rather than passing on a value it could not establish.
#
# The ceiling lives in the tracked .agentsmd-ceiling file, not in gitignored
# config/, because it is a repo invariant every fork and CI run must see, and
# because raising it must be a reviewed commit rather than a local setting.
# AGENTS.md is loaded by every session of every fleet member, so growth is a
# fleet-wide cost; this check turns that growth into a decision.
#
# The estimate and the ceiling parser are reused from
# bin/fm-startup-memory-budget-lib.sh, which stays the owner of both.  This
# command never reads, writes, or repairs the startup-memory budget.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

CEILING_FILE=".agentsmd-ceiling"
CEILING_PATH="$FM_ROOT/$CEILING_FILE"
AGENTS_MD_PATH="$FM_ROOT/AGENTS.md"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,23{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'agentsmd-ceiling: %s\n' "$1" >&2
}

read_ceiling() {
  if ! fm_startup_memory_budget_file_valid "$CEILING_PATH"; then
    print_error "invalid $CEILING_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$FM_STARTUP_MEMORY_BUDGET_VALUE"
}

# Sets CEILING, BYTES, and TOKENS, or reports the concrete reason it could not.
measure() {
  CEILING=""
  BYTES=""
  TOKENS=""
  CEILING=$(read_ceiling) || return 2
  if [ ! -f "$AGENTS_MD_PATH" ] || [ -L "$AGENTS_MD_PATH" ]; then
    print_error "AGENTS.md is not an ordinary regular file: $AGENTS_MD_PATH"
    return 2
  fi
  if ! fm_startup_memory_measure_file "$AGENTS_MD_PATH" >/dev/null; then
    print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 2
  fi
  BYTES=$FM_STARTUP_MEMORY_MEASURE_BYTES
  TOKENS=$FM_STARTUP_MEMORY_MEASURE_TOKENS
}

report() {
  measure || return $?
  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'ceiling_tokens=%s\n' "$CEILING"
  printf 'file=AGENTS.md bytes=%s estimated_tokens=%s\n' "$BYTES" "$TOKENS"
  if fm_startup_memory_decimal_le "$TOKENS" "$CEILING"; then
    printf 'ceiling_status=within-ceiling\n'
    printf 'headroom_tokens=%s\n' "$((CEILING - TOKENS))"
  else
    printf 'ceiling_status=over-ceiling\n'
    printf 'overage_tokens=%s\n' "$((TOKENS - CEILING))"
  fi
}

check() {
  measure || return $?
  if fm_startup_memory_decimal_le "$TOKENS" "$CEILING"; then
    printf 'AGENTS.md is %s estimated tokens, within ceiling %s (%s to spare).\n' \
      "$TOKENS" "$CEILING" "$((CEILING - TOKENS))"
    return 0
  fi
  # The failure has to say what to do about it, because the reader is whoever
  # just made AGENTS.md bigger and the answer is rarely "raise the ceiling".
  printf 'AGENTS.md is %s estimated tokens (%s bytes), over the ceiling %s in %s by %s tokens.\n' \
    "$TOKENS" "$BYTES" "$CEILING" "$CEILING_FILE" "$((TOKENS - CEILING))" >&2
  printf 'Route the new detail to a skill or doc per the firstmate-coding-guidelines knowledge-placement tree, or raise the ceiling deliberately in %s.\n' \
    "$CEILING_FILE" >&2
  return 1
}

case "${1:-check}" in
  check)
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    check
    ;;
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_ceiling || exit 2
    ;;
  report)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
