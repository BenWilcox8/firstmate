#!/usr/bin/env bash
# Run every live stale-floor case in parallel against its own lab pane.
# Each case has its own scratch FM_HOME under /tmp/fm-floor-live/<case>/home.
set -u
ROOT=/home/ben/.no-mistakes/worktrees/3665d600861c/01M4Y4B6EVRB772CYCH2EDT1ZA
EV=/home/ben/.no-mistakes/evidence/01M4Y4B6EVRB772CYCH2EDT1ZA
LAB=$(cat /tmp/fm-floor-lab.name)
D=$EV/live-driver.sh
NEW=$ROOT/bin/fm-watch.sh
OLD=/tmp/fm-floor-live/base/bin/fm-watch.sh   # git archive of base commit 2812e3cb
pane() { awk -v n="$1" '$1 == n { print $2 }' /tmp/fm-floor-live/panes.txt; }
lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$LAB" "$@"; }

# 1. Default floor (knob unset), default 15s poll, static pane.
"$D" default "$NEW" "$(pane default)" UNSET &
# 2. Non-numeric knob falls back to 240.
"$D" garbage "$NEW" "$(pane garbage)" abc &
# 3. Base commit watcher on the same kind of static pane (before the change).
"$D" baseline "$OLD" "$(pane baseline)" UNSET &

# 4. Hash change restarts the floor: knob 60, the pane prints new output 40s in.
(
  "$D" change "$NEW" "$(pane change)" 60 &
  sleep 40
  lab pane send-text "$(pane change)" "go" >/dev/null
  lab pane send-keys "$(pane change)" enter >/dev/null
  echo "pane changed (new output printed) at $(date '+%H:%M:%S') epoch=$(date +%s)" >> "$EV/case-change.log"
  wait
) &

# 5. Captain-relevant (terminal) status: needs-decision. Run 1 wakes on the
#    status signal at once; firstmate drains and acks; run 2 is the stale path.
(
  export STATUS_LINE='needs-decision: pick the API shape (A or B)' TASK=terminal
  "$D" terminal "$NEW" "$(pane terminal)" UNSET
  H=/tmp/fm-floor-live/terminal/home
  err=$(FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p')
  gen=$(printf '%s' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
  FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  echo "firstmate drained and acked the signal wake (seq=$seq) at $(date '+%H:%M:%S'); restarting the watcher" >> "$EV/case-terminal.log"
  echo >> "$EV/case-terminal.log"
  "$D" terminal "$NEW" "$(pane terminal)" UNSET
) &

# 6. Away mode (.afk present): the daemon handoff keeps two-poll timing.
mkdir -p /tmp/fm-floor-live/afk/home/state
: > /tmp/fm-floor-live/afk/home/state/.afk
"$D" afk "$NEW" "$(pane afk)" UNSET &

# 7. Provably working pane: absorbed, and the wedge timer escalates on
#    FM_STALE_ESCALATE_SECS=60 even with the default 240s floor in force.
#    The crew-state verdict is a stub: a real one needs a live no-mistakes run.
mkdir -p /tmp/fm-floor-live/escalate
cat > /tmp/fm-floor-live/escalate/crew-state.sh <<'SH'
#!/usr/bin/env bash
echo 'state: working · source: run-step · ci running'
SH
chmod +x /tmp/fm-floor-live/escalate/crew-state.sh
"$D" escalate "$NEW" "$(pane escalate)" UNSET \
  FM_CREW_STATE_BIN=/tmp/fm-floor-live/escalate/crew-state.sh FM_STALE_ESCALATE_SECS=60 &

wait
echo "all cases done at $(date '+%H:%M:%S')"
