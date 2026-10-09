#!/usr/bin/env bash
# tests/fm-watch-triage-gone-endpoint.test.sh - how bin/fm-watch.sh reports a
# worker endpoint that is gone: delivered once instead of escalating forever,
# re-armed when the endpoint comes back, and reported in full for a successor.
#
# Shared fixtures live in tests/watch-triage-helpers.sh, which documents how
# the watch-triage suite is split across files.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-gone-tests)

# --- a record whose agent is GONE reports once, instead of alarming forever ---
# Observed on a live fleet: two finished lanes reached 226 and 203 CONSECUTIVE
# wedge escalations, one alarm roughly every FM_STALE_ESCALATE_SECS, indefinitely -
# from lanes with no agent running at all. `bin/fm-control.sh <id> exit` answered
# `already-stopped` and `bin/fm-crew-state.sh` read `failed - run failed`. Closing
# the pane did not stop it either: with the pane gone (`herdr pane read` ->
# `pane_not_found`) the count still climbed, because the poll is driven by the
# durable record's `window=` line, not by the pane. The escalate path clears its
# own idle timer and re-arms with nothing bounding the count, and a dead agent's
# pane never churns to reset it, so the ladder had no ceiling. The cost is not the
# repetition: it is that ~400 notifications a day from two finished lanes drown
# the alarms that matter, and the captain stopped reading them.
#
# fm_backend_agent_state already separated an agent that is THINKING from one that
# is gone; the escalation path simply never asked it. Both directions are pinned
# below, for the reason the declared-wait cases above give: a bound proved only in
# the quiet direction is indistinguishable from deleting wedge detection.
# Related, and deliberately NOT closed by this: upstream #4412, #4482, #4316.

# The two endpoint verdicts that are PROOF an agent is gone, as the lane fixture
# above reaches them: `dead` is the recorded window still present in the session
# inventory with a bare shell in front of it (the husk a crashed agent leaves),
# and `missing` is an inventory that no longer carries that window at all.
gone_endpoint_env() {  # <dead|missing> -> assignments for the round below
  case "$1" in
    dead)    FM_TEST_PANE_COMMAND=bash FM_TEST_TMUX_WINDOWS=fm-wedge ;;
    missing) FM_TEST_PANE_COMMAND=bash FM_TEST_TMUX_WINDOWS=fm-someone-else ;;
  esac
}

test_gone_endpoint_delivery_survives_output_failure() {
  local dir state fakebin capture window
  local failed='state: failed · source: run-step · run failed'
  window='test:fm-wedge'
  dir=$(wedge_threshold_fixture gone-output-failure 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  gone_endpoint_env missing
  export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  # A closed stdout is portable and makes the final wake write fail.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_TMUX_CURRENT_COMMAND="$FM_TEST_PANE_COMMAND" \
    FM_FAKE_TMUX_WINDOWS="$FM_TEST_TMUX_WINDOWS" FM_FAKE_CREW_STATE="$failed" \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" >&- 2> "$dir/error" &
  local pid=$!
  local rc=0
  wait_for_exit "$pid" 150 || rc=$?
  [ "$rc" = 1 ] || fail "closed-output watcher returned $rc, expected its output error"
  [ "$(wedge_stale_wakes "$state" "$window")" = 1 ] || fail 'missing endpoint was not durably queued'
  grep -F 'agent missing' "$state/.watch-deliveries.log" >/dev/null 2>&1 \
    || fail 'queued endpoint report lost its delivery record when stdout failed'
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  pass 'a queued endpoint report retains delivery evidence when stdout fails'
}

test_gone_endpoint_reports_once_instead_of_escalating_forever() {
  local dir state fakebin out capture window key verdict round
  local failed='state: failed · source: run-step · run failed'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for verdict in dead missing; do
    dir=$(wedge_threshold_fixture "gone-endpoint-$verdict" 'working: still compiling' 0)
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    gone_endpoint_env "$verdict"
    export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS

    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
      || fail "a $verdict endpoint was never reported at the wedge threshold: $(cat "$out")"
    grep -F "agent $verdict" "$out" >/dev/null \
      || fail "the $verdict report did not name the endpoint verdict: $(cat "$out")"
    grep -F 'possible wedge' "$out" >/dev/null \
      && fail "a $verdict endpoint was still reported as a possible wedge: $(cat "$out")"
    [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] \
      || fail "a $verdict endpoint queued $(wedge_stale_wakes "$state" "$window") wakes instead of one"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "a $verdict endpoint advanced the wedge escalation count"
    ack_stopped_cycle "$state" || fail "could not acknowledge the $verdict report"

    # The defect itself: every later threshold repeated the alarm, 226 times over.
    # Each of these rounds is several thresholds, and every one must stay quiet.
    round=1
    while [ "$round" -le 3 ]; do
      : > "$out"
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" absorb \
        || fail "a $verdict endpoint re-alarmed on later threshold $round: $(cat "$out")"
      [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
        || fail "a $verdict endpoint queued a repeat wake on round $round: $(cat "$state/.wake-queue")"
      [ ! -e "$state/.wedge-escalations-$key" ] \
        || fail "a $verdict endpoint advanced the escalation count on round $round"
      round=$((round + 1))
    done
    unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  done
  pass "a record whose endpoint is dead or missing reports itself once and is never re-escalated"
}

# The load-bearing direction. A genuinely wedged LIVE agent must escalate exactly
# as it did before, and so must every verdict short of proof: an unattributable
# foreground process (`ambiguous`) and an unreadable endpoint keep the identical
# schedule, reason and count, because neither shows the agent is gone.
test_live_and_unproven_endpoints_still_wedge_escalate() {
  local dir state fakebin out capture window key spec verdict comm inventory
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for spec in 'alive|grok|fm-wedge' 'ambiguous|node|fm-wedge' 'unreadable||fm-wedge'; do
    verdict=${spec%%|*}; comm=${spec#*|}; inventory=${comm#*|}; comm=${comm%%|*}
    dir=$(wedge_threshold_fixture "wedge-live-$verdict" 'working: still compiling' 0)
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    FM_TEST_PANE_COMMAND=$comm FM_TEST_TMUX_WINDOWS=$inventory
    export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS

    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an $verdict endpoint stopped escalating at the wedge threshold: $(cat "$out")"
    grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
      || fail "an $verdict endpoint lost its wedge reason: $(cat "$out")"
    [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] \
      || fail "an $verdict endpoint did not advance the escalation count"
    ack_stopped_cycle "$state" || fail "could not acknowledge the $verdict escalation"

    # And it keeps escalating, with the count climbing exactly as it always did.
    : > "$out"
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an $verdict endpoint escalated only once: $(cat "$out")"
    grep -F 'possible wedge, escalation 2' "$out" >/dev/null \
      || fail "an $verdict endpoint did not keep counting: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the second $verdict escalation"
    unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  done
  pass "a live wedged agent, an unattributable one, and an unreadable endpoint escalate unchanged"
}

# Reporting once must not mean reporting once forever: a replacement launched into
# the same window has to get the full alarm back, and its own later death has to be
# reported again rather than silenced by the record of the first one.
test_gone_report_rearms_when_the_endpoint_comes_back() {
  local dir state fakebin out capture window key
  local failed='state: failed · source: run-step · run failed'
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture gone-rearm 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"

  gone_endpoint_env missing; export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "the gone endpoint was never reported: $(cat "$out")"
  [ -s "$state/.dead-reported-$key" ] || fail "the once-only report left no record of itself"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first gone report"

  # A replacement is launched into the same window and then wedges for real.
  FM_TEST_PANE_COMMAND=grok FM_TEST_TMUX_WINDOWS=fm-wedge
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a replacement agent's wedge was swallowed by the earlier gone report: $(cat "$out")"
  grep -F 'possible wedge, escalation' "$out" >/dev/null \
    || fail "a replacement agent did not escalate as a wedge: $(cat "$out")"
  [ ! -e "$state/.dead-reported-$key" ] \
    || fail "the once-only record survived an endpoint that reads live again"
  ack_stopped_cycle "$state" || fail "could not acknowledge the replacement's wedge escalation"

  # And when the replacement dies too, that death is reported in full.
  gone_endpoint_env dead
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "a second death in the same window was never reported: $(cat "$out")"
  grep -F 'agent dead' "$out" >/dev/null \
    || fail "a second death was not reported as a gone endpoint: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the second gone report"
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  pass "the once-only gone report re-arms when the endpoint comes back, and reports a later death again"
}

# The swallow the once-marker must be bound against: death #1 is reported, then a
# replacement launches into the same window - churning the pane hash, which
# resets the stale suppressor, wedge timer and escalation count while NO reset
# site touches the once-marker - and then the replacement itself dies and the
# pane settles static at ITS hash. The relaunch round ends before any threshold,
# so no backend probe ever read the replacement alive; no incarnation token is
# armed for this fixture, so the marker's pane-hash fallback is all that can tell
# this death apart from the one already reported, and the second death must
# report in full, while later thresholds on the SAME dead pane stay
# silent and never advance the escalation count.
test_second_death_after_a_same_window_relaunch_reports_in_full() {
  local dir state fakebin out capture window key
  local failed='state: failed · source: run-step · run failed'
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture gone-relaunch-swallow 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"

  # Death #1: the endpoint is gone and reported once, in full.
  gone_endpoint_env missing; export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "the first death was never reported: $(cat "$out")"
  grep -F 'agent missing' "$out" >/dev/null \
    || fail "the first death report did not name the endpoint verdict: $(cat "$out")"
  [ -s "$state/.dead-reported-$key" ] || fail "the first death left no once-record"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first death report"

  # A replacement launches: the pane churns and the bookkeeping resets, but the
  # round ends before the fresh timer could reach a threshold, so no probe runs
  # and the once-record survives the churn untouched.
  FM_TEST_PANE_COMMAND=grok FM_TEST_TMUX_WINDOWS=fm-wedge
  printf '%s\n' 'waiting on the build queue' > "$capture"
  : > "$out"
  FM_TEST_STALE_ESCALATE=999 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
    || fail "a replacement launch churned the pane without absorbing: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "the relaunch round escalated before its fresh window elapsed: $(cat "$out")"
  [ -s "$state/.dead-reported-$key" ] \
    || fail "the relaunch churn dropped the first death's once-record"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the relaunch churn left a wedge escalation count behind"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "the relaunch churn queued a wake: $(cat "$state/.wake-queue")"

  # The replacement dies too, without any intervening probe reading it alive:
  # the second death must still produce its own detailed report naming the
  # verdict, and must not be absorbed by the first death's record.
  gone_endpoint_env missing
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "a second death after a same-window relaunch was never reported: $(cat "$out")"
  grep -F 'agent missing' "$out" >/dev/null \
    || fail "the second death was not reported as a gone endpoint: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "the second death queued $(wedge_stale_wakes "$state" "$window") wakes instead of one"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the second death advanced the wedge escalation count"
  ack_stopped_cycle "$state" || fail "could not acknowledge the second death report"

  # And later thresholds on the same unchanged dead pane stay silent: the
  # bound still holds once the replacement's own death is the reported one.
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" absorb \
    || fail "an unchanged dead pane re-alarmed after the second report: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "an unchanged dead pane queued a repeat wake: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "an unchanged dead pane advanced the escalation count"
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  pass "a second death after a same-window relaunch reports in full without a live probe, and an unchanged dead pane stays silent"
}

# The collision the pane-hash discriminator cannot see: a successor whose dead
# display is BYTE-IDENTICAL to the death already reported - the common case,
# since a dead husk display is deterministic (a bare shell in the same cwd,
# restored empty scrollback). The successor dies without any threshold probe
# reading it alive, so the pane never churns and no hash change can announce the
# replacement; only the busy incarnation, re-armed through the real writer
# (bin/fm-busy-event.sh arm, exactly as a relaunch replaces the previous one),
# can tell this death from the reported one. It must report in full, while later
# thresholds on the same dead pane under the SAME incarnation still absorb and
# never advance the escalation count.
test_identical_dead_display_of_a_successor_still_reports() {
  local dir state fakebin out capture window key
  local failed='state: failed · source: run-step · run failed'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture identical-dead-display 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"

  # The lane's busy contract is armed at spawn, so the first death's once-record
  # is keyed on that incarnation.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" wedge >/dev/null \
    || fail "could not arm the lane's busy incarnation"

  # Death #1: the endpoint is gone and reported once, in full.
  gone_endpoint_env missing; export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "the first death was never reported: $(cat "$out")"
  grep -F 'agent missing' "$out" >/dev/null \
    || fail "the first death report did not name the endpoint verdict: $(cat "$out")"
  [ -s "$state/.dead-reported-$key" ] || fail "the first death left no once-record"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "the first death queued $(wedge_stale_wakes "$state" "$window") wakes instead of one"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first death report"

  # A successor occupies the lane: the relaunch re-arms the busy incarnation
  # through the real writer, and the successor stays quiet under the threshold
  # for a round, so no probe reads it alive and the pane never churns - the
  # display captured here and in the death rounds is byte-identical throughout.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" wedge >/dev/null \
    || fail "could not re-arm the successor's busy incarnation"
  : > "$out"
  FM_TEST_STALE_ESCALATE=999 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" absorb \
    || fail "the successor's quiet round was never absorbed: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "the successor's quiet round queued a wake: $(cat "$state/.wake-queue")"

  # The successor dies into the same byte-identical display. A pane-hash marker
  # absorbs this death silently; the incarnation half must report it in full.
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "a byte-identical dead display absorbed the successor's death: $(cat "$out")"
  grep -F 'agent missing' "$out" >/dev/null \
    || fail "the successor's death was not reported as a gone endpoint: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "the successor's death queued $(wedge_stale_wakes "$state" "$window") wakes instead of one"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the successor's death advanced the wedge escalation count"
  ack_stopped_cycle "$state" || fail "could not acknowledge the successor's death report"

  # Later thresholds on the same unchanged dead pane under the SAME incarnation
  # stay silent: the once-only bound still holds within one incarnation.
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" absorb \
    || fail "an unchanged dead pane re-alarmed under the same incarnation: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "an unchanged dead pane queued a repeat wake: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "an unchanged dead pane advanced the escalation count"
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  pass "a successor's byte-identical dead display reports in full, and the same incarnation still absorbs"
}

test_gone_endpoint_reports_once_instead_of_escalating_forever
test_live_and_unproven_endpoints_still_wedge_escalate
test_gone_report_rearms_when_the_endpoint_comes_back
test_second_death_after_a_same_window_relaunch_reports_in_full
test_identical_dead_display_of_a_successor_still_reports
test_gone_endpoint_delivery_survives_output_failure
