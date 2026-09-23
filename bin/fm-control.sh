#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>]
#                                         (--note <text> | --note-file <path>)
#        fm-control.sh <task-id> park --reason <text> [--on <ticket|node>]
#        fm-control.sh <task-id> resume [--note <text> | --note-file <path>]
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              Already-stopped is success (idempotent).
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME endpoint and SAME worktree, on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. An explicit `default` model or effort clears that
#              axis for the replacement. With no explicit axis, a secondmate
#              re-resolves its durable config/secondmate-harness pin (harness
#              plus its optional model and effort tokens) exactly as any other
#              respawn does, while a ship or scout keeps the exact adapter
#              already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/fm-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running. A PARKED task is resumed instead of started fresh:
#              relaunch reopens its recorded native session (see resume), and
#              refuses a harness, model, or effort change for it.
#   park       Worker gone, work preserved. Proves the running worker's native
#              session (bin/fm-native-session-lib.sh owns the proof per
#              harness), records it with the reason in the task record
#              (parked=, parked_reason=, parked_on=, native_session=,
#              native_session_harness=, native_session_file=), records the park
#              on the task's Atlas ticket when it has one, exits the agent
#              through `exit`, then closes ONLY its endpoint with proof it is
#              gone. The worktree, branch, task record, backlog item, status log,
#              and inbox all stay. A session that cannot be proven, or that the
#              resume launch would not find, refuses with nothing changed. A ship
#              or scout only. Parking a parked task again only updates its reason
#              and blocker and re-records the Atlas park; it never closes a pane
#              (resume closes the task's own leftover pane).
#   resume     Reopens a parked task's recorded session: confirms the session
#              file still exists, returns the Atlas ticket to started (ticket
#              unpark) and requires the Atlas to confirm it, then launches the
#              recorded harness with its native resume of that exact session in
#              the task's worktree through bin/fm-spawn.sh --relaunch
#              --resume-session, always in a new endpoint: the recorded id can
#              name another pane by now, so only a pane sitting in the task's
#              worktree counts as its own - an agent-free one is closed first,
#              an agent running there refuses, and any other pane is left
#              alone. A missing session file refuses, with the task still parked;
#              a resume never falls back to a fresh session. --note is delivered
#              as a durable inbox steer once the agent runs. The park record is
#              cleared only after the resumed agent is confirmed running; a
#              failure after the unpark re-records the Atlas park.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
# landed-work test.
#
# park and resume exist only for adapters with a proven native session
# (bin/fm-control-lib.sh's header owns that reasoning); every other adapter uses
# relaunch, because the brief on disk is its durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
# fm-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit`, `relaunch`, `park`, and `resume` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, and cmux are refused rather
#     than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
#   FM_CONTROL_STATE_SETTLE      park/resume re-sample window for an endpoint
#                                that reads transiently unclassifiable (10)
#   FM_CONTROL_READY_WAIT        resume's wait for the resumed agent's empty
#                                composer before it rings the note (60)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-native-session-lib.sh
. "$SCRIPT_DIR/fm-native-session-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}
STATE_SETTLE=${FM_CONTROL_STATE_SETTLE:-10}
READY_WAIT=${FM_CONTROL_READY_WAIT:-60}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! fm_control_verb_allowed "$VERB"; then
  {
    echo "error: '$VERB' is not a control verb"
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NOTE=
NOTE_SET=0
REASON=
REASON_SET=0
PARK_ON=
PARK_ON_SET=0
control_want_value=
for control_arg in "$@"; do
  if [ -n "$control_want_value" ]; then
    case "$control_arg" in
      --*) die "--$control_want_value requires a value" ;;
    esac
    case "$control_want_value" in
      harness) NEW_HARNESS=$control_arg; HARNESS_SET=1 ;;
      model) NEW_MODEL=$control_arg; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$control_arg; EFFORT_SET=1 ;;
      note) NOTE=$control_arg; NOTE_SET=1 ;;
      reason) REASON=$control_arg; REASON_SET=1 ;;
      on) PARK_ON=$control_arg; PARK_ON_SET=1 ;;
      note_file)
        [ -f "$control_arg" ] || die "--note-file '$control_arg' is not a readable file"
        NOTE=$(cat "$control_arg")
        NOTE_SET=1
        ;;
    esac
    control_want_value=
    continue
  fi
  case "$control_arg" in
    --harness) control_want_value=harness ;;
    --harness=*) NEW_HARNESS=${control_arg#--harness=}; HARNESS_SET=1 ;;
    --model) control_want_value=model ;;
    --model=*) NEW_MODEL=${control_arg#--model=}; MODEL_SET=1 ;;
    --effort) control_want_value=effort ;;
    --effort=*) NEW_EFFORT=${control_arg#--effort=}; EFFORT_SET=1 ;;
    --note) control_want_value=note ;;
    --note=*) NOTE=${control_arg#--note=}; NOTE_SET=1 ;;
    --note-file) control_want_value=note_file ;;
    --reason) control_want_value=reason ;;
    --reason=*) REASON=${control_arg#--reason=}; REASON_SET=1 ;;
    --on) control_want_value=on ;;
    --on=*) PARK_ON=${control_arg#--on=}; PARK_ON_SET=1 ;;
    --note-file=*)
      [ -f "${control_arg#--note-file=}" ] || die "--note-file '${control_arg#--note-file=}' is not a readable file"
      NOTE=$(cat "${control_arg#--note-file=}")
      NOTE_SET=1
      ;;
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] \
    || die "--harness, --model, and --effort apply to 'relaunch' only"
fi
case "$VERB" in
  relaunch|resume) ;;
  *) [ "$NOTE_SET" = 0 ] || die "--note applies to 'relaunch' and 'resume' only" ;;
esac
if [ "$VERB" = park ]; then
  [ -n "$REASON" ] || die "park requires a non-empty --reason that says what the work waits on"
  [ "$PARK_ON_SET" = 0 ] || [ -n "$PARK_ON" ] || die "--on requires a non-empty value"
else
  [ "$REASON_SET" = 0 ] && [ "$PARK_ON_SET" = 0 ] || die "--reason and --on apply to 'park' only"
fi
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max" ;;
esac

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! fm_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/fm-lease-lib.sh; no-op in homes without leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_guard "$ID" "lifecycle control (fm-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    fm-*)
      if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#fm-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (fm-control resolves an exact task id only)"
fi

# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed secondmate on $(fm_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the secondmate recovery path rather than this plane"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"

fm_backend_validate "$BACKEND" || exit 1

# --- shared helpers ---------------------------------------------------------

agent_state() {
  fm_backend_agent_state "$BACKEND" "$T"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

# agent_state_settled: a recovery-grade read that re-samples, for up to
# STATE_SETTLE seconds, an endpoint that reads neither alive, dead, nor
# missing. An agent's own short-lived children (its hooks, a status line) can
# make the classifier's two process samples disagree, which it correctly
# reports as unreadable; a re-sample is read-only, so waiting briefly for a
# positive answer is safe. Prints the last observed state.
agent_state_settled() {
  local state elapsed=0
  while :; do
    state=$(agent_state)
    case "$state" in
      alive|dead|missing) printf '%s' "$state"; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$STATE_SETTLE" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
}

# park_stop_agent: stop the agent through the exit verb. An exit refused while
# the endpoint read transiently unclassifiable is retried, up to three times,
# while a settled read still finds the agent alive; an agent a settled read
# finds stopped is stopped. Prints the last attempt's refusal on failure.
park_stop_agent() {
  local attempt=0 err state
  err=$(mktemp "$STATE/.$ID.park-exit.XXXXXX") || return 1
  while :; do
    # do_exit refuses through die, which exits its shell: keep it in a subshell.
    if ( do_exit ) >/dev/null 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    attempt=$((attempt + 1))
    state=$(agent_state_settled)
    case "$state" in
      dead|missing) rm -f "$err"; return 0 ;;
      alive) [ "$attempt" -lt 3 ] && continue ;;
    esac
    cat "$err" >&2
    rm -f "$err"
    return 1
  done
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it.
send_interrupt_keys() {
  local key repeat clear i=0
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -ge "$repeat" ] || sleep 0.2
  done
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery.
deliver_interrupt() {
  local cancel
  prepare_interrupt_ack
  send_interrupt_keys
  cancel=$(interrupt_cancel_claim)
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof=agent-alive
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

retire_busy_incarnation() {
  if [ -f "$STATE/$ID.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --current-gen >/dev/null 2>&1 || true
  fi
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped` or `stopped`.
do_exit() {
  local state cmd verdict cancel interrupt_result=not-needed
  require_state_verified_backend exit
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    missing) die "task $ID's recorded endpoint is gone, so there is no agent to stop; reconcile the task before any further control action" ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint" ;;
  esac
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS")
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter.
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  [ "$verdict" != send-failed ] \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

relaunch_rollback() {
  local state
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=none-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state'; the durable record and progress note were retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
      fi
      ;;
  esac
  return 0
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = secondmate ]; then
    # A secondmate's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the secondmate-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. Crewmates
    # and scouts deliberately do NOT resolve config here: their harness comes
    # from firstmate's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    CONFIG_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    CONFIG_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    CONFIG_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    fm_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured secondmate harness '$CONFIG_HARNESS' is not verified; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" = secondmate ]; then
    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$WT/.fm-secondmate-home" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded secondmate home (marker: ${marker:-none}); refusing to relaunch"
    [ -d "$WT/state" ] \
      || die "secondmate $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to relaunch"
    find "$WT/state" -mindepth 1 -maxdepth 1 -print >/dev/null 2>&1 \
      || die "secondmate $ID's child records cannot be traversed; refusing to relaunch"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "secondmate $ID's child record $child_meta is not a readable regular file; refusing to relaunch"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        echo "First, check your instruction inbox: list $STATE/$ID.inbox/*.msg, act on"
        echo "each message in numeric order, then mv each handled file into"
        echo "$STATE/$ID.inbox/handled/. A steer sent before the relaunch survives there."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line
  local -a spawn_args

  require_state_verified_backend relaunch
  resolve_relaunch_profile

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    secondmate)
      # The charter in the secondmate's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  safe_checkpoint
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  exit_result=$(do_exit)
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"
  RELAUNCH_ACTIVE=0
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
}

# --- park and resume ----------------------------------------------------------
#
# A park is the ONE act for "worker gone, work preserved". Its durable record is
# six keys in the task record, written only by this plane:
#   parked=<utc>            the park; its presence IS the parked state
#   parked_reason=<text>    what the work waits on
#   parked_on=<blocker>     optional blocking ticket or node
#   native_session=<id>     the proven native session a resume reopens
#   native_session_harness=<adapter>
#   native_session_file=<path>  the file that proves it and that resume needs
# bin/fm-native-session-lib.sh owns what "proven" means per harness.

PARK_KEYS="parked parked_reason parked_on native_session native_session_harness native_session_file"

# The Claude configuration a resume launches with (bin/fm-spawn.sh forwards
# the same one), so the park and the resume look for a session in one place.
resume_claude_config() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

one_line() {  # <text>: a meta value is one line
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/^ *//; s/ *$//'
}

# park_meta_write [key=value]...: replace every park key in this task's record
# with exactly the given lines, atomically under the task's meta lock. No
# arguments clears the park record.
park_meta_write() {
  local lock tmp status=0
  lock=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$lock"
  tmp=$(mktemp "$STATE/.$ID.meta.park.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  awk -F= -v keys="$PARK_KEYS" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) drop[k[i]] = 1 }
    !($1 in drop)' "$META" > "$tmp" || status=1
  if [ "$status" -eq 0 ] && [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >> "$tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    mv -f "$tmp" "$META" || status=1
  fi
  [ "$status" -eq 0 ] || rm -f "$tmp"
  fm_lock_release "$lock"
  return "$status"
}

# The name this home gives the Atlas as a park's supervising home: a secondmate
# home's own identity, or `main` for the primary home.
park_home_name() {
  local id rc=0
  id=$(fm_parent_channel_home_id "$FM_HOME") || rc=$?
  case "$rc" in
    0) printf '%s' "$id" ;;
    1) printf 'main' ;;
    *) return 1 ;;
  esac
}

atlas_hook() {  # <verb> <hook-args>...
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-atlas-hook.sh" "$@" --actor fm-control
}

# Whether this task's park must be mirrored on an Atlas ticket: the task names
# one and this home is wired to an Atlas.
atlas_ticketed() {
  [ -n "$(fm_meta_get "$META" atlas_ticket)" ] || return 1
  [ -n "$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-atlas-hook.sh" wired 2>/dev/null)" ]
}

atlas_ticket_state() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-atlas-hook.sh" state "$ID" 2>/dev/null
}

atlas_ticket_parked() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-atlas-hook.sh" parked "$ID" 2>/dev/null
}

park_field() {  # <parked-read> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# atlas_park <reason> <harness> <session> <blocker> <new>: record the park on
# the ticket and require the Atlas to read back exactly that park. The hook
# itself never fails its caller, so the read-back is the proof. A refused park
# on a ticket that was already parked still reads parked, so the reason and
# session must match, the blocker must be present exactly when one was sent
# (the Atlas stores the id it resolved it to), and a park that differs from the
# one already recorded (<new> is 1) must carry a new Atlas record.
atlas_park() {  # <reason> <harness> <session> <blocker> <new>
  local reason=$1 harness=$2 session=$3 on=$4 new=$5 home before after got sent=0 held=0
  home=$(park_home_name) \
    || { echo "error: this home's secondmate identity marker is unusable, so the Atlas park cannot name its home" >&2; return 1; }
  before=$(atlas_ticket_parked)
  if [ -n "$on" ]; then
    atlas_hook park "$ID" --reason "$reason" --home "$home" --harness "$harness" --session "$session" --on "$on"
  else
    atlas_hook park "$ID" --reason "$reason" --home "$home" --harness "$harness" --session "$session"
  fi
  after=$(atlas_ticket_parked)
  if [ -z "$after" ]; then
    got=$(atlas_ticket_state)
    echo "error: the Atlas did not record ticket $(fm_meta_get "$META" atlas_ticket) as parked (it reads '${got:-unreadable}')" >&2
    return 1
  fi
  [ -z "$on" ] || sent=1
  [ -z "$(park_field "$after" on)" ] || held=1
  if [ "$(park_field "$after" why)" != "$reason" ] || [ "$(park_field "$after" session)" != "$session" ] \
    || [ "$held" != "$sent" ] \
    || { [ "$new" = 1 ] && [ "$(park_field "$after" at)" = "$(park_field "$before" at)" ]; }; then
    echo "error: the Atlas did not record this park on ticket $(fm_meta_get "$META" atlas_ticket); its park in force reads: $(printf '%s' "$after" | tr '\n' ' ')" >&2
    return 1
  fi
}

# atlas_unpark [note]: return the ticket to started and require the Atlas to
# read it back as started.
atlas_unpark() {  # [note]
  local got
  if [ -n "${1:-}" ]; then
    atlas_hook unpark "$ID" --reason "$1"
  else
    atlas_hook unpark "$ID"
  fi
  got=$(atlas_ticket_state)
  [ "$got" = started ] || {
    echo "error: the Atlas did not return ticket $(fm_meta_get "$META" atlas_ticket) to started (it reads '${got:-unreadable}')" >&2
    return 1
  }
}

park_require_kind() {  # <verb>
  case "$KIND" in
    ship|scout) ;;
    *) die "task $ID is a $KIND; only a ship or scout worker can be ${1}d, because its conversation is the work being preserved" ;;
  esac
}

park_require_harness() {  # <verb>
  fm_native_session_supported "$HARNESS" \
    || die "task $ID runs on $HARNESS, which has no verified native session $1; relaunch it with a progress note instead"
  [ "$RECORDED_HARNESS" = "$HARNESS" ] \
    || die "task $ID records the raw launch command '$RECORDED_HARNESS', whose session cannot be reopened through the $HARNESS adapter"
}

do_park() {
  local state pids gen sid file parked stamp reason on key value new=1
  local -a record prior
  park_require_kind park
  require_state_verified_backend park
  park_require_harness park
  reason=$(one_line "$REASON")
  on=$(one_line "$PARK_ON")
  parked=$(fm_meta_get "$META" parked)
  if [ -n "$parked" ]; then
    # Parking a parked task refreshes only its reason, blocker, and Atlas park.
    # It never touches a pane: the recorded id can name another pane by now,
    # and resume closes the task's own leftover pane.
    if [ "$(agent_state_settled)" = alive ] && [ "$(resume_endpoint_owner)" = own ]; then
      die "task $ID is recorded as parked, but an agent runs in its worktree at $T; reconcile it before parking again"
    fi
    sid=$(fm_meta_get "$META" native_session)
    file=$(fm_meta_get "$META" native_session_file)
    [ -n "$sid" ] || die "task $ID is recorded as parked with no native session; reconcile its record before parking again"
    stamp=$parked
    [ "$reason" != "$(fm_meta_get "$META" parked_reason)" ] || [ "$on" != "$(fm_meta_get "$META" parked_on)" ] || new=0
    for key in $PARK_KEYS; do
      value=$(fm_meta_get "$META" "$key")
      [ -z "$value" ] || prior+=("$key=$value")
    done
  else
    state=$(agent_state_settled)
    case "$state" in
      alive) ;;
      dead|missing) die "task $ID has no running agent (its endpoint reads '$state'), so there is no live session to prove; nothing was changed" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to park an unattributed endpoint" ;;
    esac
    pids=$(fm_backend_foreground_pids "$BACKEND" "$T") \
      || die "the processes in task $ID's endpoint $T could not be read, so its session cannot be proven; nothing was changed"
    gen=$(fm_meta_get "$META" busy_gen)
    # shellcheck disable=SC2086 # One pid per word.
    fm_native_session_capture "$HARNESS" "$WT" "$STATE" "$ID" "$gen" $pids \
      || die "task $ID cannot be parked: $FM_NATIVE_SESSION_REASON; nothing was changed"
    sid=$FM_NATIVE_SESSION_ID
    file=$FM_NATIVE_SESSION_FILE
    fm_native_session_locate "$HARNESS" "$sid" "$file" "$WT" "$(resume_claude_config)" \
      || die "task $ID cannot be parked, because its resume would not find the session: $FM_NATIVE_SESSION_REASON; nothing was changed"
    stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  record=("parked=$stamp" "parked_reason=$reason")
  [ -z "$on" ] || record+=("parked_on=$on")
  record+=("native_session=$sid" "native_session_harness=$HARNESS" "native_session_file=$file")
  park_meta_write "${record[@]}" \
    || die "task $ID's park could not be recorded in $META; nothing else was changed"
  if atlas_ticketed && ! atlas_park "$reason" "$HARNESS" "$sid" "$on" "$new"; then
    if [ -n "$parked" ]; then
      park_meta_write "${prior[@]}" || true
      die "task $ID's park was not updated, because its Atlas ticket could not record it; its prior park record was kept"
    fi
    park_meta_write || true
    die "task $ID was not parked, because its Atlas ticket could not record the park; its worker is still running and nothing else was changed"
  fi
  if [ -n "$parked" ]; then
    echo "parked $ID harness=$HARNESS session=$sid backend=$BACKEND worktree=$WT"
    return 0
  fi
  if ! park_stop_agent; then
    if atlas_ticketed; then
      atlas_unpark "park of $ID was refused: its worker did not stop" || true
    fi
    park_meta_write || true
    die "task $ID was not parked, because its worker did not stop; the park record was withdrawn"
  fi
  fm_backend_task_endpoint_close "$BACKEND" "$STATE" "$ID" "$T" "$META" \
    || die "task $ID is parked with its session recorded, but its endpoint $T could not be closed: $FM_BACKEND_TASK_CLOSE_REASON; close that pane by hand, or resume the task, which closes its own leftover pane first"
  echo "parked $ID harness=$HARNESS session=$sid backend=$BACKEND endpoint=$T worktree=$WT"
}

RESUME_UNPARKED=0
RESUME_SESSION=
RESUME_REASON=

# resume_wait_composer_ready: wait up to READY_WAIT seconds for the resumed
# agent's composer to read empty.
resume_wait_composer_ready() {
  local elapsed=0
  while :; do
    [ "$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null)" = empty ] && return 0
    awk -v e="$elapsed" -v t="$READY_WAIT" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
}

# Whether the recorded endpoint's pane sits in this task's worktree (own), in
# another directory (other), or cannot be located (unknown).
resume_endpoint_owner() {
  local seen
  seen=$(fm_backend_current_path "$BACKEND" "$T" 2>/dev/null) || seen=
  if [ -z "$seen" ]; then
    printf 'unknown'
  elif fm_native_session_same_dir "$seen" "$WT"; then
    printf 'own'
  else
    printf 'other'
  fi
}

resume_rollback() {
  [ "$RESUME_UNPARKED" = 1 ] || return 0
  RESUME_UNPARKED=0
  atlas_park "$RESUME_REASON" "$HARNESS" "$RESUME_SESSION" "$(fm_meta_get "$META" parked_on)" 1 >/dev/null 2>&1 \
    || echo "error: task $ID's Atlas ticket could not be parked again after the failed resume; park it again with bin/fm-control.sh $ID park" >&2
}

do_resume() {
  local parked file state model effort
  local -a spawn_args
  park_require_kind resume
  require_state_verified_backend resume
  parked=$(fm_meta_get "$META" parked)
  [ -n "$parked" ] \
    || die "task $ID is not parked; resume reopens only a parked task's recorded session (use relaunch to replace a running agent)"
  park_require_harness resume
  RESUME_SESSION=$(fm_meta_get "$META" native_session)
  RESUME_REASON=$(fm_meta_get "$META" parked_reason)
  file=$(fm_meta_get "$META" native_session_file)
  [ "$(fm_meta_get "$META" native_session_harness)" = "$HARNESS" ] \
    || die "task $ID's recorded session belongs to '$(fm_meta_get "$META" native_session_harness)', not its recorded harness $HARNESS; it stays parked"
  [ -n "$WT" ] && [ -d "$WT" ] \
    || die "task $ID's recorded worktree '${WT:-none}' is missing; its session cannot be resumed where its work lives, and it stays parked"
  fm_native_session_locate "$HARNESS" "$RESUME_SESSION" "$file" "$WT" "$(resume_claude_config)" \
    || die "task $ID cannot be resumed: $FM_NATIVE_SESSION_REASON. It stays parked and nothing was changed; it is never restarted as a fresh session"
  # The park closed the recorded endpoint, and its id can now name another pane
  # (Herdr pane ids restart low after a server restart), so only a pane that
  # sits in this task's worktree is treated as the task's own. The resume
  # always opens a new endpoint; it first closes the task's own agent-free pane
  # left by a park whose close never finished, and leaves any other pane alone.
  state=$(agent_state_settled)
  case "$state" in
    missing) ;;
    dead|alive)
      case "$(resume_endpoint_owner)" in
        own)
          [ "$state" = dead ] \
            || die "an agent already runs in task $ID's worktree at $T; refusing to resume a second one onto the same work"
          fm_backend_task_endpoint_close "$BACKEND" "$STATE" "$ID" "$T" "$META" \
            || die "task $ID's leftover pane $T could not be closed before the resume: $FM_BACKEND_TASK_CLOSE_REASON; it stays parked and nothing was changed"
          ;;
        other) ;;
        *) die "task $ID's recorded endpoint $T still exists but its location cannot be read, so it cannot be told apart from the task's own pane; refusing to resume" ;;
      esac
      ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to resume" ;;
  esac
  if atlas_ticketed; then
    atlas_unpark "$NOTE" \
      || die "task $ID was not resumed, because its Atlas ticket could not be returned to started; it stays parked"
    RESUME_UNPARKED=1
  fi
  model=$(fm_meta_get "$META" model)
  effort=$(fm_meta_get "$META" effort)
  spawn_args=("$ID" --relaunch --resume-session --harness "$HARNESS")
  [ -z "$model" ] || [ "$model" = default ] || spawn_args+=(--model "$model")
  [ -z "$effort" ] || [ "$effort" = default ] || spawn_args+=(--effort "$effort")
  if ! "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    resume_rollback
    die "the resumed agent for $ID could not be launched; it stays parked with its session recorded, and its work is preserved at $WT"
  fi
  fm_backend_validate_task_endpoint "$META" "$ID" \
    || { resume_rollback; die "task $ID's record names no valid endpoint after the resume launch; it stays parked"; }
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  T=$FM_BACKEND_VALIDATED_TARGET
  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    resume_rollback
    die "the resumed agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint $T reads '$state'); it stays parked"
  }
  RESUME_UNPARKED=0
  park_meta_write \
    || echo "warning: task $ID's resumed agent runs, but its park record could not be cleared from $META" >&2
  if [ -n "$NOTE" ]; then
    # A resumed TUI replays its conversation before its composer takes input,
    # and a doorbell typed earlier can be lost. The steer is durable either
    # way (the watcher re-rings an unhandled one), so the wait is bounded and
    # the note is sent when it ends.
    resume_wait_composer_ready || true
    "$SCRIPT_DIR/fm-send.sh" "$ID" "$NOTE" >/dev/null \
      || echo "warning: task $ID resumed, but its note could not be delivered as a steer; send it again with bin/fm-send.sh $ID" >&2
  fi
  echo "resumed $ID harness=$HARNESS session=$RESUME_SESSION backend=$BACKEND endpoint=$T worktree=$WT"
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  relaunch)
    if [ -n "$(fm_meta_get "$META" parked)" ]; then
      # A parked task keeps its recorded conversation: relaunch reopens it.
      { [ "$HARNESS_SET" = 0 ] || [ "$NEW_HARNESS" = "$HARNESS" ]; } \
        && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] \
        || die "task $ID is parked; its recorded $HARNESS session resumes on its recorded profile, so relaunch refuses a harness, model, or effort change for it"
      do_resume
    else
      do_relaunch
    fi
    ;;
  park)
    do_park
    ;;
  resume)
    do_resume
    ;;
esac
