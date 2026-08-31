#!/usr/bin/env bash
# fm-ping-ack.sh - close out a ROUTINE wake without writing prose.
#
# A routine wake is one that needs no narration: a watcher nudge, a turn-end
# hook, a heartbeat, a scheduled or self-set check-in, a steer you simply did.
# Answering one with a paragraph costs the captain a screen of dashboard
# timeline and costs credits to write. Run this instead: it prints the
# dashboard marker and appends one durable record saying the wake was handled.
#
# Real findings, decisions, failures, and anything the captain must act on are
# NOT routine. Write those in prose, as before. This command replaces the
# acknowledgement, never the report.
#
# Usage:
#   fm-ping-ack.sh --origin script|agent [--wake <key>] [--note "<short>"]
#   fm-ping-ack.sh -h | --help
#
# Options:
#   --origin script|agent   REQUIRED, never inferred. `script` when a mechanism
#                           produced the wake (watcher nudge, turn-end check,
#                           heartbeat, scheduled check-in); `agent` when a
#                           person or agent did (a supervisor steer, a worker
#                           escalation, a routed reply). Absent or unknown is
#                           refused rather than guessed, because a wrong origin
#                           silently mis-files the wake on the dashboard.
#   --wake <key>            optional wake this close-out answers, as the wake
#                           queue names it (`heartbeat`, `t1.status`, ...).
#                           Recorded, never printed.
#   --note "<short>"        optional tiny note, one line, a handful of words.
#                           Over 120 characters warns on stderr and still
#                           records - the same courtesy the dashboard signal
#                           verbs give an over-long line. Past the hard bound
#                           in bin/fm-ping-lib.sh it is refused instead: at that
#                           length it is a report, and a report belongs in prose.
#
# Output (stdout, exactly one line):
#   %%dash-ping: <origin>%% [<note>]
# End the wake-handling turn with that line and nothing else. The dashboard
# folds it under its own type instead of rendering it as a work turn.
#
# Durable record: one appended line in <state>/ping-acks.log.
# bin/fm-ping-lib.sh owns the marker grammar and the record format; read that
# header before parsing the log.
#
# This command does NOT acknowledge firstmate's durable wake queue. That stays
# bin/fm-wake-drain.sh's generation-bound `--ack-through`, run as it always
# was; this one closes out the CONVERSATION, not the queue.
#
# Environment:
#   FM_HOME              operational home whose state/ receives the record.
#
# Exit status: 0 recorded; 2 refused (missing or invalid argument); 1 the
# record could not be written, and the marker is not printed - a close-out
# nobody can audit later is not a close-out.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-ping-lib.sh
. "$SCRIPT_DIR/fm-ping-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'fm-ping-ack: %s\n' "$*" >&2
  exit 2
}

ORIGIN=
WAKE=
NOTE=
NOTE_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --origin)
      [ "$#" -gt 1 ] || refuse "--origin requires script or agent"
      ORIGIN=$2
      shift 2
      ;;
    --origin=*)
      ORIGIN=${1#--origin=}
      shift
      ;;
    --wake)
      [ "$#" -gt 1 ] || refuse "--wake requires a wake key"
      WAKE=$2
      shift 2
      ;;
    --wake=*)
      WAKE=${1#--wake=}
      shift
      ;;
    --note)
      [ "$#" -gt 1 ] || refuse "--note requires text"
      NOTE=$2
      NOTE_SET=1
      shift 2
      ;;
    --note=*)
      NOTE=${1#--note=}
      NOTE_SET=1
      shift
      ;;
    --)
      shift
      [ "$#" -eq 0 ] || refuse "unexpected argument: $1"
      ;;
    *)
      refuse "unexpected argument: $1 (see --help)"
      ;;
  esac
done

[ -n "$ORIGIN" ] || refuse "--origin script|agent is required and is never inferred"
fm_ping_origin_valid "$ORIGIN" \
  || refuse "unknown origin '$ORIGIN': use script (a mechanism woke you) or agent (a person or agent did)"
[ "$NOTE_SET" -eq 0 ] || [ -n "$NOTE" ] || refuse "--note was given no text; omit it instead"

NOTE=$(fm_ping_clean_field "$NOTE")
WAKE=$(fm_ping_clean_field "$WAKE")
[ "${#NOTE}" -le "$FM_PING_NOTE_MAX" ] \
  || refuse "note is ${#NOTE} characters; a close-out carries at most $FM_PING_NOTE_MAX, so write this one in prose instead"
[ "${#WAKE}" -le "$FM_PING_NOTE_MAX" ] \
  || refuse "wake key is ${#WAKE} characters; that is not a wake key"
if [ "${#NOTE}" -gt "$FM_PING_NOTE_SOFT_MAX" ]; then
  printf 'fm-ping-ack: note is %s characters; a close-out note should be a handful of words (recorded anyway)\n' \
    "${#NOTE}" >&2
fi

MARKER=$(fm_ping_marker "$ORIGIN") || refuse "could not render the marker for origin '$ORIGIN'"

mkdir -p "$STATE" 2>/dev/null || true
if ! fm_ping_record_append "$STATE" "$ORIGIN" "$WAKE" "$NOTE"; then
  printf 'fm-ping-ack: could not record the close-out under %s\n' "$STATE" >&2
  exit 1
fi

if [ -n "$NOTE" ]; then
  printf '%s %s\n' "$MARKER" "$NOTE"
else
  printf '%s\n' "$MARKER"
fi
