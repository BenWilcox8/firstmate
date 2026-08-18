#!/usr/bin/env bash
# fm-cswap-rotate.sh - do one claude-swap rotation tick as a watcher check.
#
# cswap owns the rotation. `cswap auto --once` compares the Claude accounts of
# the captain against the configured threshold, cooldown, hysteresis, and
# strategy, and it switches the live login when the active account runs out.
# This script is the firstmate side of that. It does one tick under a hard time
# bound, and it speaks the custom-check language of the watcher: one line when
# firstmate must wake, and silence at all other times.
#
# Usage:
#   fm-cswap-rotate.sh            do one tick and report only what needs a wake
#   fm-cswap-rotate.sh --dry-run  evaluate without a switch, and report the same
#
# Output contract (docs/configuration.md "Claude accounts (cswap)"):
#   A switch, an account fleet with no headroom, an account that left the
#   rotation, and a tick error each print one line. A tick that changed nothing
#   prints nothing. An armed check is therefore silent while the active account
#   has headroom.
#
# The exit status is always 0, except when the tick cannot run at all. The
# watcher reads the output as the signal, and a tick that correctly did nothing
# is not an error. The `--once` exit codes of cswap (0 switched, 1 error,
# 2 no action) are read here and are not passed on, because a no-action tick
# must not look like a failed check.
#
# Rotation threshold: `autoswitch.threshold` in cswap is the percent USED of the
# tightest window. It must stay below the standing 95% ceiling of the captain,
# so that a rotation occurs before an account reaches that ceiling. The default
# of 90 in cswap obeys this rule. To change it, use
# `cswap config set autoswitch.threshold <n>`. The threshold is stored in the
# settings of cswap and not in the firstmate configuration, so there is one
# place to read it or to change it.
#
# Environment:
#   FM_CSWAP_TIMEOUT   hard bound in whole seconds for the tick (default 20).
#                      This bound must stay below FM_CHECK_TIMEOUT.
#   FM_CSWAP_BIN       absolute path to the cswap executable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-cswap-lib.sh
. "$SCRIPT_DIR/fm-cswap-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

auto_args=(auto --once --json)
[ "$DRY_RUN" -eq 0 ] || auto_args+=(--dry-run)

if ! command -v jq >/dev/null 2>&1; then
  echo "claude accounts: the rotation check needs jq, which is not installed"
  exit 0
fi

OUT=$(fm_cswap_run "${auto_args[@]}" 2>/dev/null)
RC=$?
if [ "$RC" -eq 127 ]; then
  echo "claude accounts: the rotation check found no cswap on PATH"
  exit 0
fi
if [ -z "$OUT" ]; then
  echo "claude accounts: the rotation tick produced no result (exit $RC)"
  exit 0
fi

# cswap prints one JSON object per line. Only the event kinds that need a
# supervisor become a line. The poll, no-switch, and sleep kinds stay silent.
# Output that is not valid JSON is itself reported, because the alternative is a
# check that quietly stops to mean anything.
printf '%s\n' "$OUT" | jq -r '
  def ref($r): if $r == null then "?" else "\($r.number) (\($r.email))" end;
  if .event == "switch" then
    "claude accounts: " + (if .dryRun then "would switch" else "switched" end)
      + " from account " + ref(.from) + " to account " + ref(.to)
      + " (" + (.trigger // "rotation") + ")"
  elif .event == "all-exhausted" then
    "claude accounts: every account is out of headroom"
      + (if .earliestResetAt then "; earliest reset " + .earliestResetAt else "" end)
  elif .event == "account-quarantined" then
    "claude accounts: account \(.number) (\(.email)) dropped out of rotation: \(.reason)"
  elif .event == "error" then
    "claude accounts: rotation error: \(.message)"
  else
    empty
  end
' 2>/dev/null || echo "claude accounts: the rotation tick printed output that cannot be read"

exit 0
