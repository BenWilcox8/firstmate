#!/usr/bin/env bash
# Record an Atlas ticket lifecycle fact as a side effect of the fleet action that
# already proves it, so the map is written by the actor holding the evidence
# instead of by a supervisor's memory.
#
# Usage: fm-atlas-hook.sh start <task-id> [--actor <name>]
#        fm-atlas-hook.sh complete <task-id> --evidence <text> [--summary <text>]
#                                            [--restage <stage>] [--actor <name>]
#                                            [--captain-word <words>]
#        fm-atlas-hook.sh land <task-id> --evidence <text> [--summary <text>]
#                                        [--actor <name>] [--captain-word <words>]
#                                        [--defer-status]
#        fm-atlas-hook.sh abort <task-id> --reason <text> [--actor <name>]
#        fm-atlas-hook.sh state <task-id>
#        fm-atlas-hook.sh wired
#
#   start     tells the Atlas the task's recorded ticket is now being worked by
#             this task's crew: `ticket start <c> --to <holder> --task <task-id>`,
#             where <holder> is fm-<task-id> when the id lacks the prefix, or
#             <task-id> itself when it already starts with fm-.
#   complete  discharges the ticket after a merge: it restages the ticket's node
#             when --restage names a stage and the ticket is still started, then
#             `ticket complete <c> --evidence ... --summary ...`. A ticket that is
#             already completed is left alone.
#   land      is the same completion, followed by `release <node>`, followed by
#             `land <node> --evidence ...` when no open ticket remains on that
#             node. It is the teardown hook, called only where teardown has
#             already proved the work landed.
#   abort     is the discharge for a leg that produced NOTHING: `ticket abort <c>
#             "<reason>"` returns the ticket to the queue with the reason on its
#             record and releases the node, so a dispatch that died is never
#             recorded as work that shipped. Complete and land stay reserved for
#             proved work. The store itself refuses a completed or abandoned
#             ticket and treats an already queued one as a no-op, so a cleanup
#             may run this as often as it likes.
#   state     prints the recorded ticket's state (queued, started, completed,
#             abandoned) and nothing else, so a caller can tell a leg nobody
#             discharged from one a crewmate or a merge already closed. Read-only:
#             it prints nothing at all on any skip or failure.
#
#   wired     is the read-only query the rest of the fleet uses to ask whether
#             this home is wired to an Atlas at all. It prints the resolved repo
#             path when it is, prints nothing when it is not, and takes no task
#             id. Callers branch on empty output, never on an exit status, so
#             the never-blocks contract below holds here too.
#
#   --evidence is what proves the work (a merge range, a PR URL, a report path).
#   --reason   is what killed the dispatch, and abort refuses without it.
#   --summary  defaults to a short generated line naming the task and the actor.
#   --actor    is stamped as the Atlas `by:` author, so the log says which fleet
#              script wrote the entry. Defaults to fm-atlas-hook.
#   --captain-word  is the captain's exact words from chat. complete and land
#              first record them as the captain's Atlas approval, `ticket approve
#              <c> --word <words>`, on a ticket that is not yet closed, so a
#              captain-authorized merge or acceptance can pass the captain gate.
#   --defer-status  is for land only and prints a refusal's status line on
#              stdout instead of writing it (see THE CAPTAIN GATE), for teardown
#              to write after it retires the task's status log.
#
# THE CAPTAIN GATE. The Atlas refuses `ticket complete` and `land` while a ticket
# waits on the captain's approval, or promised the captain a look and has no
# testing brief. The Atlas is a map, never an authority, so a refusal never
# changes the merge or cleanup that called the hook. It changes only what the
# hook does next: complete and land still `release` the node, so a finished leg
# never holds it, and append ONE keyed, supervisor-actionable line to the task's
# status log:
#   blocked [key=atlas-gate-<ticket>]: the Atlas refused to <act> for task
#   <task-id>: <the missing gate, or the refusal's reason>; node <n> released
# The watcher wakes the supervisor on it, and the key keeps it an open blocker
# until the supervisor records the missing gate, closes the ticket, and resolves
# that key (the atlas-firstmate-bridge skill owns that repair). One warning line
# on stderr says the step was refused; a refused step is never reported as done.
# A failed complete or land call for any other reason takes the same path, with
# the Atlas's own first error line as the reason.
#
# BEST EFFORT, ALWAYS. This script never blocks or fails the action that calls it:
# every path exits 0, including an unusable Atlas, a missing atlas-axi, a missing
# jq, a hung call, and any internal error. A call that was attempted and failed
# prints exactly one warning line to stderr. Besides that warning, only state,
# wired, and a land --defer-status refusal line print anything. Callers
# still append `|| true` so a caller running under `set -e` is safe even if this
# script is replaced by an older copy.
#
# The hook stays silent, with no warning at all, when there is nothing to record:
#   - this home has no config/specs pointer to a local Atlas repo, or the pointer
#     does not name a readable directory holding atlas/;
#   - atlas-axi is not on PATH;
#   - the task's state/<task-id>.meta records no atlas_ticket= (the ordinary case
#     for work that was never given a ticket).
# Silence there is the design: a home without the Atlas wiring must behave exactly
# as it did before this hook existed.
#
# The Atlas repo is resolved from this home's own pointer:
# the content of <FM_HOME>/config/specs, an absolute path to the local Atlas repo
# (docs/configuration.md "Atlas pointer (config/specs)").
#
# FM_ATLAS_HOOK_TIMEOUT_SECS (default 20) bounds every single atlas-axi call when
# `timeout` is available, so a wedged Atlas cannot stall a spawn, a merge, or a
# teardown. An empty, zero, or non-numeric value falls back to the default.
#
# Re-running any of these is free: the Atlas appends nothing for a mutation that
# projects to no change, so a repeated hook is a no-op rather than a duplicate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-atlas-word-lib.sh
. "$SCRIPT_DIR/fm-atlas-word-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# One warning line, never more, and never on a path the hook is designed to skip.
warn() {  # <what-failed> [detail]
  local detail=${2:-}
  detail=$(printf '%s' "$detail" | tr '\n' ' ' | cut -c1-200)
  if [ -n "$detail" ]; then
    printf 'atlas-hook: %s (%s); the map was not updated\n' "$1" "$detail" >&2
  else
    printf 'atlas-hook: %s; the map was not updated\n' "$1" >&2
  fi
}

hook_timeout_secs() {
  local secs=${FM_ATLAS_HOOK_TIMEOUT_SECS:-20}
  case "$secs" in
    ''|*[!0-9]*|0) secs=20 ;;
  esac
  printf '%s\n' "$secs"
}

# The Atlas repo this home is wired to, or nothing at all.
atlas_repo() {
  local pointer="$CONFIG/specs" repo
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || return 1
  repo=$(head -n 1 "$pointer" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//') || return 1
  case "$repo" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -d "$repo/atlas" ] || return 1
  printf '%s\n' "$repo"
}

# Run one atlas-axi call under the shared repo, actor, and timeout. Prints the
# call's stdout on success. On failure it prints nothing, returns 1, and leaves
# the first line of the call's stderr in ATLAS_ERR, so a caller can say why; run
# it outside a command substitution when that reason is needed.
atlas_axi_try() {  # <arg>...
  local err out rc timeout_secs
  ATLAS_ERR=
  err=$(mktemp "${TMPDIR:-/tmp}/fm-atlas-hook.XXXXXX") || {
    ATLAS_ERR="no temp file"
    return 1
  }
  timeout_secs=$(hook_timeout_secs)
  if [ -n "$TIMEOUT_BIN" ]; then
    out=$("$TIMEOUT_BIN" "$timeout_secs" atlas-axi --repo "$REPO" --by "$ACTOR" "$@" 2>"$err")
  else
    out=$(atlas-axi --repo "$REPO" --by "$ACTOR" "$@" 2>"$err")
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ATLAS_ERR=$(head -n 1 "$err" 2>/dev/null)
    [ -n "$ATLAS_ERR" ] || ATLAS_ERR="atlas-axi exited $rc"
    rm -f -- "$err"
    return 1
  fi
  rm -f -- "$err"
  printf '%s\n' "$out"
}

# atlas_axi_try that also warns once on failure.
atlas_axi_call() {  # <label> <arg>...
  local label=$1
  shift
  atlas_axi_try "$@" && return 0
  warn "$label failed for $ID" "$ATLAS_ERR"
  return 1
}

# The ticket's node and state, read once into TICKET_NODE and TICKET_STATE.
ticket_read() {
  local json
  command -v jq >/dev/null 2>&1 || { warn "ticket lookup skipped for $ID" "jq is not installed"; return 1; }
  json=$(atlas_axi_call "ticket lookup" ticket show "$TICKET" --json) || return 1
  TICKET_NODE=$(printf '%s' "$json" | jq -r '.change.node // empty' 2>/dev/null)
  TICKET_STATE=$(printf '%s' "$json" | jq -r '.change.state // empty' 2>/dev/null)
  [ -n "$TICKET_NODE" ] || { warn "ticket lookup failed for $ID" "$TICKET names no node"; return 1; }
}

# Record the captain's exact words as the Atlas approval, before any act the
# captain gate stands in front of. Only an open ticket can take the captain's
# word; a failed approval warns and the close-out that follows reports the gate.
captain_approve() {
  [ -n "$CAPTAIN_WORD" ] || return 0
  case "$TICKET_STATE" in
    completed|abandoned) return 0 ;;
  esac
  atlas_axi_call "captain approval" ticket approve "$TICKET" --word "$CAPTAIN_WORD" >/dev/null || true
}

# Complete the ticket unless the crewmate already did. Silent: returns 1 with
# ATLAS_ERR set when the Atlas refused, and the caller reports the refusal.
ticket_complete_once() {
  if [ "$TICKET_STATE" = completed ] || [ "$TICKET_STATE" = abandoned ]; then
    return 0
  fi
  atlas_axi_try ticket complete "$TICKET" \
    --evidence "$EVIDENCE" --summary "$SUMMARY" >/dev/null
}

# A refused close-out. The node is released anyway, because a refusal must not
# leave a finished leg holding the node, and exactly one keyed status line says
# which gate is missing, so the watcher wakes the supervisor. That line goes to
# the task's status log, or to stdout under --defer-status for a caller about to
# retire that log. One warning line tells the caller the Atlas step did not
# succeed.
gate_refused() {  # <refused act> <node already released: yes|no>
  local act=$1 released=$2 refusal=$ATLAS_ERR gate node_note line
  case "$refusal" in
    *"no testing brief"*) gate="the testing brief is missing" ;;
    *"reviewed by the captain"*) gate="the captain's approval is missing" ;;
    *) gate="reason: $(printf '%s' "$refusal" | tr '\n' ' ' | cut -c1-160)" ;;
  esac
  if [ "$released" = yes ] || atlas_axi_try release "$TICKET_NODE" >/dev/null; then
    node_note="node $TICKET_NODE released"
  else
    node_note="node $TICKET_NODE could not be released ($(printf '%s' "$ATLAS_ERR" | cut -c1-80))"
  fi
  line="blocked [key=atlas-gate-$TICKET]: the Atlas refused to $act for task $ID: $gate; $node_note"
  if [ "$DEFER_STATUS" = 1 ]; then
    printf '%s\n' "$line"
    printf 'atlas-hook: %s refused for %s (%s); %s; the status line went to the caller\n' "$act" "$ID" "$gate" "$node_note" >&2
  elif printf '%s\n' "$line" >> "$STATE/$ID.status" 2>/dev/null; then
    printf 'atlas-hook: %s refused for %s (%s); %s; the status log says so\n' "$act" "$ID" "$gate" "$node_note" >&2
  else
    printf 'atlas-hook: %s refused for %s (%s); %s; the status line could not be written\n' "$act" "$ID" "$gate" "$node_note" >&2
  fi
}

node_has_open_ticket() {
  local json count
  json=$(atlas_axi_call "open-ticket check" ticket list "$TICKET_NODE" --json) || return 0
  count=$(printf '%s' "$json" \
    | jq -r '[.[] | select(.state == "queued" or .state == "started")] | length' 2>/dev/null)
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
    0) return 1 ;;
    *) return 0 ;;
  esac
}

# The dispatch died and produced nothing, so the ticket goes back to the queue
# with the reason on it. The act releases the node itself, and it is a no-op on
# a ticket that is already queued, so a cleanup may run it as often as it likes.
hook_abort() {
  atlas_axi_call "ticket abort" ticket abort "$TICKET" "$REASON" >/dev/null
}

# Read-only, and silent on every skip: the caller wants a state or nothing.
hook_state() {
  ticket_read >/dev/null 2>&1 || return 0
  [ -z "$TICKET_STATE" ] || printf '%s\n' "$TICKET_STATE"
}

hook_start() {
  atlas_axi_call "ticket start" ticket start "$TICKET" --to "$HOLDER" --task "$ID" >/dev/null
}

hook_complete() {
  ticket_read || return 1
  captain_approve
  if [ -n "$RESTAGE" ] && [ "$TICKET_STATE" = started ]; then
    # A restage the captain gate refuses says nothing the refused completion
    # below will not say, so only a restage failing for another reason warns.
    if ! atlas_axi_try restage "$TICKET_NODE" "$RESTAGE" >/dev/null; then
      case "$ATLAS_ERR" in
        *"reviewed by the captain"*) ;;
        *) warn "restage $RESTAGE failed for $ID" "$ATLAS_ERR" ;;
      esac
    fi
  fi
  ticket_complete_once && return 0
  gate_refused "complete ticket $TICKET" no
}

hook_land() {
  ticket_read || return 1
  captain_approve
  if ! ticket_complete_once; then
    gate_refused "complete ticket $TICKET" no
    return 0
  fi
  atlas_axi_call "release" release "$TICKET_NODE" >/dev/null || return 1
  if node_has_open_ticket; then
    return 0
  fi
  atlas_axi_try land "$TICKET_NODE" --evidence "$EVIDENCE" >/dev/null && return 0
  gate_refused "land node $TICKET_NODE for ticket $TICKET" yes
}

run_hook() {
  local want_value=

  VERB=${1:-}
  case "$VERB" in
    # Answered before anything task-scoped: wired asks about the HOME, so it
    # neither takes nor validates a task id.
    wired)
      [ "$#" -eq 1 ] || { warn "wired takes no arguments"; return 0; }
      atlas_repo || return 0
      return 0
      ;;
    start|complete|land|abort|state) ;;
    '') warn "no hook verb given"; return 0 ;;
    *) warn "unknown hook verb $VERB"; return 0 ;;
  esac
  shift

  # The task id becomes a state path and an Atlas crew name, so it is held to the
  # same closed character set fm-spawn records. A caller bug stops here rather
  # than reaching another home's records.
  ID=${1:-}
  case "$ID" in
    ''|-*|.*|*[!A-Za-z0-9._-]*) warn "$VERB called with an unusable task id"; return 0 ;;
  esac
  shift

  case "$ID" in
    fm-*) HOLDER=$ID ;;
    *)    HOLDER="fm-$ID" ;;
  esac

  ACTOR=fm-atlas-hook
  EVIDENCE=
  SUMMARY=
  RESTAGE=
  CAPTAIN_WORD=
  CAPTAIN_WORD_SUPPLIED=0
  DEFER_STATUS=0
  REASON=
  for a in "$@"; do
    if [ -n "$want_value" ]; then
      case "$want_value" in
        actor) ACTOR=$a ;;
        evidence) EVIDENCE=$a ;;
        summary) SUMMARY=$a ;;
        restage) RESTAGE=$a ;;
        reason) REASON=$a ;;
        captain-word)
          if ! fm_atlas_parse_captain_word --captain-word "$a"; then
            warn "$VERB called with an invalid --captain-word"
            return 0
          fi
          CAPTAIN_WORD=$FM_ATLAS_CAPTAIN_WORD
          CAPTAIN_WORD_SUPPLIED=1
          ;;
      esac
      want_value=
      continue
    fi
    case "$a" in
      --actor) want_value=actor ;;
      --actor=*) ACTOR=${a#--actor=} ;;
      --evidence) want_value=evidence ;;
      --evidence=*) EVIDENCE=${a#--evidence=} ;;
      --summary) want_value=summary ;;
      --summary=*) SUMMARY=${a#--summary=} ;;
      --restage) want_value=restage ;;
      --restage=*) RESTAGE=${a#--restage=} ;;
      --reason) want_value=reason ;;
      --reason=*) REASON=${a#--reason=} ;;
      --captain-word) want_value=captain-word ;;
      --captain-word=*)
        if ! fm_atlas_parse_captain_word "$a"; then
          warn "$VERB called with an invalid --captain-word"
          return 0
        fi
        CAPTAIN_WORD=$FM_ATLAS_CAPTAIN_WORD
        CAPTAIN_WORD_SUPPLIED=1
        ;;
      --defer-status)
        [ "$VERB" = land ] || { warn "$VERB called with --defer-status, which only land supports"; return 0; }
        DEFER_STATUS=1
        ;;
      *) warn "$VERB called with unknown argument $a"; return 0 ;;
    esac
  done
  [ -z "$want_value" ] || { warn "$VERB called with a valueless --$want_value"; return 0; }
  if [ "$CAPTAIN_WORD_SUPPLIED" = 1 ] && [ -z "$CAPTAIN_WORD" ]; then
    warn "$VERB called with an empty --captain-word"
    return 0
  fi
  [ -n "$ACTOR" ] || ACTOR=fm-atlas-hook

  case "$VERB" in
    complete|land)
      if [ -z "$EVIDENCE" ]; then
        warn "$VERB called for $ID with no --evidence"
        return 0
      fi
      ;;
    abort)
      if [ -z "$REASON" ]; then
        warn "abort called for $ID with no --reason"
        return 0
      fi
      ;;
  esac
  [ -n "$SUMMARY" ] || SUMMARY="Task $ID closed out by $ACTOR."

  # Silent skips: nothing here is a failure, it is a home with no Atlas to write.
  REPO=$(atlas_repo) || return 0
  command -v atlas-axi >/dev/null 2>&1 || return 0
  TICKET=$(sed -n 's/^atlas_ticket=//p' "$STATE/$ID.meta" 2>/dev/null | tail -n 1)
  [ -n "$TICKET" ] || return 0

  TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
  TICKET_NODE=
  TICKET_STATE=

  case "$VERB" in
    start) hook_start ;;
    complete) hook_complete ;;
    land) hook_land ;;
    abort) hook_abort ;;
    state) hook_state ;;
  esac
}

# The subshell is the last line of defence for the never-blocks contract: an
# unexpected internal error (an unbound variable under `set -u`, a killed
# child) dies with the subshell instead of the caller's spawn, merge, or
# teardown.
( run_hook "$@" ) || true
exit 0
