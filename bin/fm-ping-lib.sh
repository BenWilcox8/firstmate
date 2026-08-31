#!/usr/bin/env bash
# fm-ping-lib.sh - the routine-wake close-out contract.
#
# ONE owner of the `%%dash-ping: <origin>%%` marker grammar, the origin
# vocabulary, and the durable close-out record format. bin/fm-ping-ack.sh is
# the agent-facing command, bin/fm-watch.sh stamps the marker on the wake it
# authors for a worker's own status escalation, and bin/fm-task-inbox-lib.sh
# stamps it on the steering doorbell; none of them restates the grammar.
#
# Why a marker at all: the captain reads an agent's history on a dashboard, and
# a routine wake handled with a paragraph of prose is indistinguishable there
# from real work. The marker lets the dashboard fold every routine
# acknowledgement under its own type, so the timeline shows work and decisions
# only. The dashboard classifier consumes `script`, `agent`, or no marker at
# all, so an unmarked line stays valid and this contract is additive.
#
# Origin vocabulary (exactly two values; there is no default):
#   script   a mechanism produced the wake - a watcher nudge, a turn-end hook,
#            a heartbeat, a scheduled or self-set check-in.
#   agent    a person or agent produced it - a supervisor steer, a worker
#            escalation, a routed reply.
# The origin is never inferred. A caller that cannot state one is refused,
# because a guessed origin silently mis-files the wake on the dashboard.
#
# Marker grammar (one line, stable):
#   %%dash-ping: <origin>%%
#
# Durable record (one line per close-out, appended to <state>/ping-acks.log):
#   fm-ping-ack.v1<TAB><epoch><TAB><iso8601><TAB><origin><TAB><wake><TAB><note>
# Six tab-separated fields, in that order, forever. <wake> is the wake this
# close-out answers (a queue key such as `heartbeat` or `t1.status`) or `-`
# when the caller named none. <note> is the tiny structured note and may be
# empty; tabs, carriage returns, and newlines are replaced by spaces so one
# close-out is always exactly one line. New fields, if they are ever needed,
# are appended after <note> so an existing parser keeps working.
#
# Dependency-light and side-effect-free on source: no state directory is
# created and no path is resolved here. The caller owns its own state dir.
# set -u / set -e safe.

FM_PING_SCHEMA='fm-ping-ack.v1'
FM_PING_RECORD_BASENAME='ping-acks.log'
# Advisory: the dashboard renders a close-out as one folded line, so a longer
# note is warned about by bin/fm-ping-ack.sh and still recorded.
FM_PING_NOTE_SOFT_MAX=120
# Hard bound, refused rather than truncated: a close-out note is a handful of
# words by contract, and holding the whole record well inside one small append
# is what keeps two concurrent close-outs from interleaving a half line.
FM_PING_NOTE_MAX=512

# True when <origin> is one of the two accepted values.
fm_ping_origin_valid() {  # <origin>
  case "${1-}" in
    script|agent) return 0 ;;
  esac
  return 1
}

# The dashboard marker for <origin>. Fails closed on an absent or unknown
# origin rather than printing a marker the dashboard would mis-classify.
fm_ping_marker() {  # <origin>
  fm_ping_origin_valid "${1-}" || return 2
  printf '%%%%dash-ping: %s%%%%' "$1"
}

# Collapse anything that would break the one-line record shape.
fm_ping_clean_field() {  # <text>
  printf '%s' "${1-}" | LC_ALL=C tr '\t\r\n' '   '
}

# The exact durable record line (no trailing newline) for one close-out.
fm_ping_record_line() {  # <epoch> <iso8601> <origin> <wake> <note>
  local epoch=$1 iso=$2 origin=$3 wake=${4:-} note=${5:-}
  fm_ping_origin_valid "$origin" || return 2
  case "$epoch" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "${#note}" -le "$FM_PING_NOTE_MAX" ] || return 2
  [ "${#wake}" -le "$FM_PING_NOTE_MAX" ] || return 2
  [ -n "$wake" ] || wake='-'
  printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$FM_PING_SCHEMA" "$epoch" "$iso" "$origin" \
    "$(fm_ping_clean_field "$wake")" "$(fm_ping_clean_field "$note")"
}

# Append one close-out to <state>/ping-acks.log. The state directory is the
# caller's to create, and the whole record is built before any I/O so it is
# written by one bounded append rather than assembled in the file.
fm_ping_record_append() {  # <state-dir> <origin> <wake> <note>
  local state=$1 origin=$2 wake=${3:-} note=${4:-} line epoch iso
  epoch=$(date +%s) || return 1
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
  line=$(fm_ping_record_line "$epoch" "$iso" "$origin" "$wake" "$note") || return 2
  [ -d "$state" ] || return 1
  printf '%s\n' "$line" >> "$state/$FM_PING_RECORD_BASENAME" || return 1
}
