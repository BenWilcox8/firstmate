#!/usr/bin/env bash
# fm-claude-account.sh - choose which Claude account a claude-harness agent runs on.
#
# The captain may hold more than one Claude subscription. Each one is a separate
# Claude config directory (`CLAUDE_CONFIG_DIR`), and each has its own independent
# session and weekly usage windows. This script is the single owner of the
# account-selection mechanics: which accounts exist, how their headroom is
# scored, which ceilings make one ineligible, and which one a spawn should use.
# bin/fm-spawn.sh consumes the answer and threads it onto the claude launch;
# docs/configuration.md "Claude accounts (config/claude-accounts.json)" owns the
# config schema.
#
# The feature is inert with no config file: `select` then reports "no accounts
# configured" through exit status 3 and prints nothing, and fm-spawn keeps its
# pre-existing single-store behavior byte for byte.
#
# Usage:
#   fm-claude-account.sh select [--account <name>]
#         Print "<name>\t<config-dir>" for the account to launch on.
#         Without --account, the account with the most headroom wins.
#         With --account, that exact configured account wins with no quota read.
#   fm-claude-account.sh list
#         Print "<name>\t<config-dir>" for every configured account, in file order.
#   fm-claude-account.sh score
#         Print "<name>\t<config-dir>\t<session-remaining>\t<weekly-remaining>\t<status>"
#         for every configured account. session/weekly are percentRemaining, or
#         "-" when that account could not be scored. status is one of:
#           eligible    scored and within both standing ceilings
#           ceiling     scored but at or beyond a standing ceiling
#           unscorable  no usable quota reading for that account
#
# Exit status:
#   0  a line was printed
#   1  the config file is present but invalid, or --account named an unknown
#      account, or a required tool is missing while a config file exists
#   2  usage error
#   3  no config file: the feature is off and the caller keeps its default
#
# Scoring: an account's score is the MINIMUM percentRemaining across its session
# (`five_hour`) and weekly (`seven_day`) windows, read from
# `CLAUDE_CONFIG_DIR=<dir> quota-axi --provider claude --json`. The minimum is
# used because either window running out stops that account outright, so the
# tighter of the two is the real headroom. Highest score wins; ties keep the
# earlier account in file order, so selection is deterministic.
#
# Standing ceilings (the captain's, not a tunable): an account at or beyond 90%
# session used or 95% weekly used is ineligible. Ineligible accounts are skipped
# while any eligible account exists. When EVERY account breaches a ceiling -
# including the single-account case - the one with the most headroom is still
# selected and a warning is printed, because refusing to spawn at all is worse
# than spawning on a tight account.
#
# Degradation: an account with no usable quota reading is never selected by
# score. When NO account can be scored (quota-axi missing, unreadable, timing
# out, or reporting windows this script cannot parse), the FIRST configured
# account is selected and a warning is printed on stderr. List the account that
# should serve as that fallback first in the config file.
#
# Malformed configuration is never degraded around: it exits 1 with the exact
# reason so the caller fails loudly rather than silently launching on the wrong
# subscription.
#
# Environment:
#   FM_CLAUDE_ACCOUNT_QUOTA_TIMEOUT   hard per-account bound in whole seconds for
#                                     the quota read (default 20). A quota read
#                                     cannot be bounded without `timeout` or
#                                     `gtimeout` on PATH, so when neither exists
#                                     every account is treated as unscorable
#                                     rather than risking a wedged spawn.
#   FM_HOME, FM_CONFIG_OVERRIDE       resolve the config directory, exactly as in
#                                     every other bin/ script.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ACCOUNTS_FILE="$CONFIG/claude-accounts.json"

# The captain's standing ceilings, expressed as percent USED. They are policy,
# deliberately not environment-tunable, so a tight-quota spawn cannot quietly
# raise its own limit.
SESSION_CEILING_USED=90
WEEKLY_CEILING_USED=95

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $1" >&2
  exit "${2:-1}"
}

# --- configuration ----------------------------------------------------------

# Print "<name>\t<absolute-config-dir>" per configured account, in file order.
# Returns 3 when no config file exists, 1 when one exists but is unusable.
accounts_load() {
  local err rows name dir
  [ -f "$ACCOUNTS_FILE" ] || return 3
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to read $ACCOUNTS_FILE" >&2
    return 1
  fi
  if ! jq -e . "$ACCOUNTS_FILE" >/dev/null 2>&1; then
    echo "error: invalid $ACCOUNTS_FILE - malformed JSON" >&2
    return 1
  fi
  err=$(jq -r '
    def entries: (.accounts // []);
    def bad_name: [entries[] | select((.name? | type) != "string" or (.name | length) == 0)] | length;
    def bad_name_chars: [entries[] | .name? | strings | select(test("^[A-Za-z0-9._-]+$") | not)] | length;
    def bad_dir: [entries[] | select((.configDir? | type) != "string" or (.configDir | length) == 0)] | length;
    if type != "object" then "top-level value must be an object"
    elif (has("accounts") | not) then "accounts is required"
    elif (.accounts | type) != "array" then "accounts must be an array"
    elif (.accounts | length) == 0 then "accounts needs at least one account"
    elif ([entries[] | select(type != "object")] | length) > 0 then "each account must be an object"
    elif bad_name > 0 then "each account needs a non-empty name"
    elif bad_name_chars > 0 then
      "account names may use only letters, digits, dot, underscore, and dash: "
        + ([entries[] | .name? | strings | select(test("^[A-Za-z0-9._-]+$") | not)] | join(", "))
    elif bad_dir > 0 then "each account needs a non-empty configDir"
    elif ((entries | map(.name) | unique | length) != (entries | length)) then "account names must be unique"
    else empty
    end
  ' "$ACCOUNTS_FILE" 2>/dev/null)
  if [ -n "$err" ]; then
    echo "error: invalid $ACCOUNTS_FILE - $err" >&2
    return 1
  fi
  rows=$(jq -r '.accounts[] | "\(.name)\t\(.configDir)"' "$ACCOUNTS_FILE" 2>/dev/null)
  if [ -z "$rows" ]; then
    echo "error: invalid $ACCOUNTS_FILE - no readable accounts" >&2
    return 1
  fi
  while IFS=$'\t' read -r name dir; do
    [ -n "$name" ] || continue
    # A leading ~ is expanded here rather than by the shell, because the value
    # arrives from JSON where no shell expansion ever happened.
    case "$dir" in
      \~) dir="${HOME:-}" ;;
      \~/*) dir="${HOME:-}/${dir#\~/}" ;;
    esac
    # A relative config dir would resolve against whatever working directory the
    # launched agent happens to start in, which is never the captain's intent.
    case "$dir" in
      /*) ;;
      *)
        echo "error: invalid $ACCOUNTS_FILE - account '$name' configDir must be an absolute path (or start with ~/): $dir" >&2
        return 1
        ;;
    esac
    if [ ! -d "$dir" ]; then
      echo "error: invalid $ACCOUNTS_FILE - account '$name' configDir is not a directory: $dir" >&2
      return 1
    fi
    printf '%s\t%s\n' "$name" "$dir"
  done <<EOF
$rows
EOF
}

# --- quota reading ----------------------------------------------------------

quota_timeout_seconds() {
  local value=${FM_CLAUDE_ACCOUNT_QUOTA_TIMEOUT:-20}
  case "$value" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$value"
}

# Read one account's claude quota JSON under a hard time bound. Every failure
# mode is a plain non-zero return: the caller turns that into "unscorable", never
# into a guess.
quota_read() {
  local dir=$1 timeout_bin seconds
  command -v quota-axi >/dev/null 2>&1 || return 1
  seconds=$(quota_timeout_seconds) || return 1
  timeout_bin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null) || return 1
  [ -n "$timeout_bin" ] || return 1
  CLAUDE_CONFIG_DIR="$dir" "$timeout_bin" "$seconds" quota-axi --provider claude --json 2>/dev/null </dev/null
}

# Print "<session-remaining>\t<weekly-remaining>" for one account, or return 1.
# Both windows are required: a reading missing either one cannot be compared
# against the ceilings, so it is unscorable rather than half-trusted.
account_windows() {
  local dir=$1 json
  json=$(quota_read "$dir") || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -er '
    def pct($id):
      first(.windows[]? | select(.id == $id) | .percentRemaining | numbers | select(. >= 0 and . <= 100));
    first(.providers[]? | select(.provider == "claude"))
    | pct("five_hour") as $session
    | pct("seven_day") as $weekly
    | "\($session)\t\($weekly)"
  ' 2>/dev/null
}

# Print "<name>\t<dir>\t<session>\t<weekly>\t<status>" per configured account.
accounts_score() {
  local rows name dir windows session weekly status
  rows=$(accounts_load) || return $?
  while IFS=$'\t' read -r name dir; do
    [ -n "$name" ] || continue
    if windows=$(account_windows "$dir"); then
      IFS=$'\t' read -r session weekly <<EOF
$windows
EOF
      status=$(awk -v s="$session" -v w="$weekly" \
        -v sc="$SESSION_CEILING_USED" -v wc="$WEEKLY_CEILING_USED" \
        'BEGIN { print (100 - s >= sc || 100 - w >= wc) ? "ceiling" : "eligible" }')
    else
      session=-
      weekly=-
      status=unscorable
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$dir" "$session" "$weekly" "$status"
  done <<EOF
$rows
EOF
}

# --- subcommands ------------------------------------------------------------

cmd_list() {
  local rows rc
  rows=$(accounts_load)
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$rows"
}

cmd_score() {
  local rows rc
  rows=$(accounts_score)
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$rows"
}

# Print "<name>\t<dir>" for an explicitly requested account.
select_named() {
  local want=$1 rows rc name dir names=
  rows=$(accounts_load)
  rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "error: --account $want was requested but $ACCOUNTS_FILE does not exist" >&2
    return 1
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS=$'\t' read -r name dir; do
    [ -n "$name" ] || continue
    if [ "$name" = "$want" ]; then
      printf '%s\t%s\n' "$name" "$dir"
      return 0
    fi
    names="${names:+$names, }$name"
  done <<EOF
$rows
EOF
  echo "error: unknown claude account '$want'; configured accounts: $names" >&2
  return 1
}

# Print "<name>\t<dir>" for the account with the most headroom.
select_scored() {
  local scored rc choice outcome name dir
  scored=$(accounts_score)
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # Highest score wins; a strict comparison keeps the earliest account on a tie,
  # so the same fixture always resolves to the same account.
  choice=$(printf '%s\n' "$scored" | awk -F'\t' '
    NR == 1 { first = $1 "\t" $2 }
    $5 == "eligible" {
      score = ($3 < $4) ? $3 : $4
      if (best_eligible == "" || score > best_eligible_score) {
        best_eligible = $1 "\t" $2
        best_eligible_score = score
      }
      next
    }
    $5 == "ceiling" {
      score = ($3 < $4) ? $3 : $4
      if (best_ceiling == "" || score > best_ceiling_score) {
        best_ceiling = $1 "\t" $2
        best_ceiling_score = score
      }
    }
    END {
      if (best_eligible != "") print "eligible\t" best_eligible
      else if (best_ceiling != "") print "ceiling\t" best_ceiling
      else print "unscorable\t" first
    }
  ')
  IFS=$'\t' read -r outcome name dir <<EOF
$choice
EOF
  [ -n "${name:-}" ] || { echo "error: no claude account could be selected from $ACCOUNTS_FILE" >&2; return 1; }
  case "$outcome" in
    ceiling)
      echo "warning: every configured Claude account is at or beyond a standing usage ceiling; using '$name', the one with the most headroom" >&2
      ;;
    unscorable)
      echo "warning: no Claude account usage could be read; falling back to the first configured account '$name'" >&2
      ;;
  esac
  printf '%s\t%s\n' "$name" "$dir"
}

cmd_select() {
  local want=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --account)
        [ "$#" -gt 1 ] || die "--account requires a value" 2
        want=$2
        [ -n "$want" ] || die "--account requires a non-empty value" 2
        shift 2
        ;;
      --account=*)
        want=${1#--account=}
        [ -n "$want" ] || die "--account requires a non-empty value" 2
        shift
        ;;
      *) die "unknown select argument: $1" 2 ;;
    esac
  done
  if [ -n "$want" ]; then
    select_named "$want"
  else
    select_scored
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  select) shift; cmd_select "$@"; exit $? ;;
  list) shift; [ "$#" -eq 0 ] || die "list takes no arguments" 2; cmd_list; exit $? ;;
  score) shift; [ "$#" -eq 0 ] || die "score takes no arguments" 2; cmd_score; exit $? ;;
  '') die "a subcommand is required: select, list, or score (see --help)" 2 ;;
  *) die "unknown subcommand: $1 (see --help)" 2 ;;
esac
