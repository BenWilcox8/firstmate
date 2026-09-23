#!/usr/bin/env bash
# fm-native-session.sh - read-only CLI over bin/fm-native-session-lib.sh, the
# owner of a worker agent's native session identity (which harnesses can prove
# one, and how). bin/fm-control.sh's park and resume verbs source the library
# directly; this entry point exists so an operator or a test can ask the same
# question without changing anything.
#
# Usage:
#   fm-native-session.sh capture --harness <h> --worktree <dir> --pid <pid>...
#                                [--state <dir> --id <task-id> --gen <busy-gen>]
#       Prove the native session of the agent running as <pid> (repeatable:
#       pass the endpoint's foreground processes) in <dir>. --state, --id, and
#       --gen locate and authenticate the Pi extension's session record.
#   fm-native-session.sh locate --harness <h> --session <id> --file <path>
#                               --worktree <dir> [--claude-config <dir>]
#       Confirm a recorded session can still be resumed: its file must exist
#       and still name that session.
#
# Output on success is key=value lines (session=, file=). A refusal exits 1
# with the reason on stderr and prints nothing on stdout.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-native-session-lib.sh
. "$SCRIPT_DIR/fm-native-session-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

cmd=${1:-}
case "$cmd" in
  -h|--help|'') usage; [ -n "$cmd" ]; exit $? ;;
  capture|locate) shift ;;
  *) echo "error: unknown command '$cmd'" >&2; usage >&2; exit 2 ;;
esac

harness='' wt='' state='' id='' gen='' session='' file='' claude_config=''
pids=()
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
  case "$1" in
    --harness) harness=$2 ;;
    --worktree) wt=$2 ;;
    --pid) pids+=("$2") ;;
    --state) state=$2 ;;
    --id) id=$2 ;;
    --gen) gen=$2 ;;
    --session) session=$2 ;;
    --file) file=$2 ;;
    --claude-config) claude_config=$2 ;;
    *) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
  esac
  shift 2
done

case "$cmd" in
  capture)
    fm_native_session_capture "$harness" "$wt" "$state" "$id" "$gen" "${pids[@]}" || {
      echo "error: $FM_NATIVE_SESSION_REASON" >&2
      exit 1
    }
    ;;
  locate)
    fm_native_session_locate "$harness" "$session" "$file" "$wt" "$claude_config" || {
      echo "error: $FM_NATIVE_SESSION_REASON" >&2
      exit 1
    }
    ;;
esac
printf 'session=%s\nfile=%s\n' "$FM_NATIVE_SESSION_ID" "$FM_NATIVE_SESSION_FILE"
