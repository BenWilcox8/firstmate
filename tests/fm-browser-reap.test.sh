#!/usr/bin/env bash
# Behavior tests for bin/fm-browser-reap.sh - the orphaned-browser sweep.
#
# The leak this pins: a headless browser chain started by an agent session
# outlives it. A launcher-started Chrome calls setsid, so nothing in the
# process tree notices the owner leaving. Observed 2026-08-18 as about
# fifty nine-day-old browser processes holding roughly 11 GB, load at 80, the
# machine swapping, and cleared only by a manual sweep.
#
# Everything here runs over real sleep-based process trees that present the
# recognised command lines. Each fixture is put in its own process group with
# job control, exactly as the real detached chains are, and an
# orphan is made the way the leak makes one: an intermediate parent exits and
# the kernel reparents the child to whatever adopts this account's orphans -
# init in a container, the per-user manager on a systemd login session. The
# cases:
#   (a) an orphaned browser chain older than the gate is reaped whole, and the
#       log records its pid, age, and reason
#   (b) a chain whose parent is alive is never touched, at any age - the
#       ownership gate is first and the age gate second
#   (c) an orphaned chain younger than the gate is left alone
#   (d) --dry-run lists the candidates over the whole machine and signals
#       nothing, and writes no log line
#   (e) a recorded owner pid outranks the parent test, in both directions
#   (f) a recorded owner younger than the chain it supposedly launched is a
#       recycled pid, not a live owner
#   (g) a process outside the recognised family is never a candidate, however
#       old and however orphaned
#   (h) a process that only NAMES a browser in its own arguments is never in
#       the family, however orphaned - the shape of every crewmate here
#   (i) a real watcher seeds the sweep cadence when it arms, runs the sweep
#       from that cadence with no daemon of its own, and honours the off switch
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAPER="$ROOT/bin/fm-browser-reap.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-reap)
BASH_BIN=$(command -v bash)
LOG="$TMP_ROOT/browser-reap.log"

TRACKED_PIDS=()
browser_reap_cleanup() {
  local pid
  for pid in "${TRACKED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap browser_reap_cleanup EXIT

track() { TRACKED_PIDS+=("$1"); }
alive() { kill -0 "$1" 2>/dev/null; }
ppid_of() { ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]'; }

wait_gone() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive "$pid" || return 0
    sleep 0.1
  done
  ! alive "$pid"
}

wait_child() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(pgrep -P "$pid" 2>/dev/null || true)" ] && return 0
    sleep 0.1
  done
  return 1
}

# --- fixtures ---------------------------------------------------------------
#
# A fake browser presents the command line the sweep recognises - a program
# whose basename is a Chrome binary plus an automation flag - and forks one
# renderer child, so a case can prove the WHOLE chain goes, not just its root.

# With FM_TEST_OWNER_FILE set, the fixture waits for that file, exports its
# contents as the recorded owner pid and re-executes itself. exec keeps the pid
# and the original start time, which is the only way to bind an owner that did
# not exist when the chain started - and so the only way to test the ordering.
make_fake_browser() { # <path>
  local path=$1
  mkdir -p "$(dirname "$path")"
  {
    printf '#!%s\n' "$BASH_BIN"
    cat <<'SH'
# Fake headless browser: one renderer child, then idle forever.
set -u
if [ -n "${FM_TEST_OWNER_FILE:-}" ]; then
  while [ ! -s "$FM_TEST_OWNER_FILE" ]; do sleep 0.1; done
  FM_TEST_OWNER_PID=$(cat "$FM_TEST_OWNER_FILE")
  export FM_TEST_OWNER_PID
  unset FM_TEST_OWNER_FILE
  exec "$0" "$@"
fi
if [ "${1:-}" = --type=renderer ]; then
  while :; do sleep 0.2; done
fi
"$0" --type=renderer &
while :; do sleep 0.2; done
SH
  } > "$path"
  chmod +x "$path"
}

# A process that is not a browser but talks about one in its own arguments -
# the shape every crewmate in this repo has, because its whole brief is argv.
make_impostor() { # <path>
  local path=$1
  mkdir -p "$(dirname "$path")"
  {
    printf '#!%s\n' "$BASH_BIN"
    cat <<'SH'
set -u
while :; do sleep 0.2; done
SH
  } > "$path"
  chmod +x "$path"
}

# Both spawners publish through SPAWNED_PID rather than stdout: a command
# substitution would run them in a subshell that then exits, which would both
# lose the cleanup registration and orphan the very fixture that is supposed to
# have a live parent.
SPAWNED_PID=

# Start <cmd...> in its own process group as a child of this test. The chain
# has a live parent, which is the alive-owner shape.
spawn_owned() {
  set -m
  "$@" >/dev/null 2>&1 &
  SPAWNED_PID=$!
  set +m
  track "$SPAWNED_PID"
}

# Start <cmd...> in its own process group under a parent that exits at once, so
# the kernel reparents it. This is how the production leak is made. The
# intermediate runs synchronously, so it has already exited - and the kernel has
# already reparented the child - by the time this returns.
spawn_orphan() {
  local pidfile pid
  pidfile=$(mktemp "$TMP_ROOT/orphan-pid.XXXXXX")
  # shellcheck disable=SC2016 # $0, $@ and $! must expand in the intermediate shell.
  "$BASH_BIN" -c 'set -m; "$@" >/dev/null 2>&1 & printf "%s\n" "$!" > "$0"' "$pidfile" "$@"
  pid=$(cat "$pidfile" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  SPAWNED_PID=$pid
  track "$pid"
}

# The intermediate is already reaped by the time spawn_orphan returns, so the
# fixture's parent is whatever adopted it. It is never this test's shell, and
# `kill -0` is no liveness test for it because init is not this account's.
assert_orphaned() { # <pid> <what>
  local parent
  parent=$(ppid_of "$1")
  [ -n "$parent" ] || fail "$2 exited before it could be judged"
  [ "$parent" != "$$" ] || fail "$2 is still a child of this test, so it does not reproduce the leak"
}

BROWSER="$TMP_ROOT/bin/chromium"
IMPOSTOR="$TMP_ROOT/bin/review-helper"
make_fake_browser "$BROWSER"
make_impostor "$IMPOSTOR"

reap() { # <args...>
  FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_BROWSER_REAP_LOG="$LOG" \
    FM_BROWSER_REAP_LOCK="$TMP_ROOT/reap.lock" \
    FM_BROWSER_REAP_OWNER_VARS=FM_TEST_OWNER_PID \
    "$REAPER" "$@" 2>&1
}

# --- (a) an orphaned browser chain older than the gate is reaped whole -------

spawn_orphan "$BROWSER" --headless=new --remote-debugging-port=9911 \
  --user-data-dir="$TMP_ROOT/profile-a" || fail "could not start the orphaned browser fixture"
ORPHAN=$SPAWNED_PID
assert_orphaned "$ORPHAN" "the orphaned browser fixture"
wait_child "$ORPHAN" 10 || fail "the orphaned browser fixture never started its renderer child"
ORPHAN_CHILD=$(pgrep -P "$ORPHAN" | head -n 1)

out=$(reap --max-age 0 --grace 3 --pid "$ORPHAN") || fail "the reaper failed: $out"
assert_contains "$out" "reaped orphaned browser chain $ORPHAN" \
  "the reaper did not report reaping the orphaned browser chain"
wait_gone "$ORPHAN" 20 || fail "the orphaned browser chain survived the reaper"
wait_gone "$ORPHAN_CHILD" 20 || fail "the orphaned browser's renderer child outlived its root"
pass "an orphaned browser chain past the age gate is reaped whole"

assert_contains "$(cat "$LOG")" "pid=$ORPHAN" "the reap log did not record the reaped pid"
assert_contains "$(cat "$LOG")" "reason=owner-session-gone" "the reap log did not record the reason"
grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z reap pid=$ORPHAN age=[0-9]+s reason=owner-session-gone chain=[0-9]+ members=[0-9]+(,[0-9]+)* program=chromium result=(terminated|killed)$" "$LOG" ||
  fail "the reap log line is not the documented pid/age/reason record: $(cat "$LOG")"
pass "each reap is logged with its pid, age, and reason"

# --- (b) a chain whose owner is alive is never touched, at any age -----------

spawn_owned "$BROWSER" --headless=new --remote-debugging-port=9912 \
  --user-data-dir="$TMP_ROOT/profile-b" || fail "could not start the owned browser fixture"
OWNED=$SPAWNED_PID
wait_child "$OWNED" 10 || fail "the owned browser fixture never started its renderer child"
OWNED_CHILD=$(pgrep -P "$OWNED" | head -n 1)
[ "$(ppid_of "$OWNED")" = "$$" ] ||
  fail "the owned browser fixture is not a child of this test, so its owner is not provably alive"

out=$(reap --max-age 0 --grace 3 --pid "$OWNED") || fail "the reaper failed: $out"
assert_not_contains "$out" "$OWNED" "the reaper reported a browser chain whose owner is alive"
alive "$OWNED" || fail "the reaper stopped a browser chain whose owner is alive"
alive "$OWNED_CHILD" || fail "the reaper stopped the renderer of a browser chain whose owner is alive"
pass "a browser chain whose owning session is alive is never touched, even with the age gate open"

# --- (c) the age gate is the second gate ------------------------------------

spawn_orphan "$BROWSER" --headless=new --remote-debugging-port=9913 \
  --user-data-dir="$TMP_ROOT/profile-c" || fail "could not start the young orphan fixture"
YOUNG=$SPAWNED_PID
assert_orphaned "$YOUNG" "the young orphan fixture"

out=$(reap --max-age 86400 --grace 3 --pid "$YOUNG") || fail "the reaper failed: $out"
assert_not_contains "$out" "$YOUNG" "the reaper reported an orphan younger than the age gate"
alive "$YOUNG" || fail "the reaper stopped an orphan younger than the age gate"
pass "an orphaned chain younger than the age gate is left alone"

# --- (d) the dry run, over the whole machine --------------------------------
#
# Unscoped on purpose: this is the only case that proves selection across the
# real process table rather than a named pid, and a dry run signals nothing, so
# it can be run that way safely.

spawn_orphan sleep 600 || fail "could not start the non-browser fixture"
PLAIN=$SPAWNED_PID
assert_orphaned "$PLAIN" "the non-browser fixture"

LOG_BEFORE=$(cat "$LOG")
out=$(reap --dry-run --max-age 0) || fail "the reaper dry run failed: $out"
assert_contains "$out" "would reap orphaned browser chain $YOUNG" \
  "the dry run did not find the orphaned browser chain by scanning the process table"
assert_not_contains "$out" "chain $OWNED" "the dry run listed a chain whose owner is alive"
assert_not_contains "$out" "chain $PLAIN" "the dry run listed a process outside the browser family"
alive "$YOUNG" || fail "the dry run stopped the orphaned browser chain"
alive "$OWNED" || fail "the dry run stopped a chain whose owner is alive"
alive "$PLAIN" || fail "the dry run stopped a process outside the browser family"
[ "$(cat "$LOG")" = "$LOG_BEFORE" ] || fail "the dry run wrote to the reap log"
pass "a dry run lists the candidates it finds, signals nothing, and logs nothing"

# --- (g) a process outside the recognised family is never reaped ------------

out=$(reap --max-age 0 --grace 3 --pid "$PLAIN") || fail "the reaper failed: $out"
assert_not_contains "$out" "$PLAIN" "the reaper reported a process outside the browser family"
alive "$PLAIN" || fail "the reaper stopped an orphaned process outside the browser family"
pass "an orphaned process outside the recognised browser family is never reaped"

# --- (e) a recorded owner pid outranks the parent test ---------------------
#
# The recorded owner is the stronger signal, so it decides the chain in both
# directions even though the chain has been reparented to a reaper.

spawn_owned sleep 0.1 || fail "could not start the short-lived owner fixture"
DEAD_OWNER=$SPAWNED_PID
wait "$DEAD_OWNER" 2>/dev/null || true
wait_gone "$DEAD_OWNER" 10 || fail "the recorded dead owner is somehow still alive"

spawn_orphan env "FM_TEST_OWNER_PID=$$" "$BROWSER" --headless=new \
  --remote-debugging-port=9914 --user-data-dir="$TMP_ROOT/profile-e1" ||
  fail "could not start the live-owner browser fixture"
LIVE_OWNED=$SPAWNED_PID
assert_orphaned "$LIVE_OWNED" "the live-owner browser fixture"
spawn_orphan env "FM_TEST_OWNER_PID=$DEAD_OWNER" "$BROWSER" --headless=new \
  --remote-debugging-port=9915 --user-data-dir="$TMP_ROOT/profile-e2" ||
  fail "could not start the dead-owner browser fixture"
DEAD_OWNED=$SPAWNED_PID
assert_orphaned "$DEAD_OWNED" "the dead-owner browser fixture"

out=$(reap --max-age 0 --grace 3 --pid "$LIVE_OWNED" --pid "$DEAD_OWNED") ||
  fail "the reaper failed: $out"
assert_not_contains "$out" "chain $LIVE_OWNED" \
  "the reaper reported a reparented chain whose recorded owner is alive"
alive "$LIVE_OWNED" || fail "the reaper stopped a reparented chain whose recorded owner is alive"
assert_contains "$out" "reaped orphaned browser chain $DEAD_OWNED" \
  "the reaper did not reap the chain whose recorded owner is gone"
wait_gone "$DEAD_OWNED" 20 || fail "the chain whose recorded owner is gone survived the reaper"
pass "a recorded owner pid decides a reparented chain in both directions"

# --- (h) a process whose argv only NAMES a browser is not in the family -----
#
# This repo puts a crewmate's whole brief in its argv, so a family decided by
# substring alone would adopt any process that talks about browsers - and every
# child of an agent inherits that agent's recorded owner pid.

spawn_orphan env "FM_TEST_OWNER_PID=$DEAD_OWNER" "$IMPOSTOR" \
  "run chromium --headless=new --remote-debugging-port=9918 for the review" ||
  fail "could not start the argv impostor fixture"
IMPOSTOR_PID=$SPAWNED_PID
assert_orphaned "$IMPOSTOR_PID" "the argv impostor fixture"

out=$(reap --max-age 0 --grace 3 --pid "$IMPOSTOR_PID") || fail "the reaper failed: $out"
assert_not_contains "$out" "chain $IMPOSTOR_PID" \
  "the reaper adopted a process that only names a browser in its own arguments"
alive "$IMPOSTOR_PID" || fail "the reaper stopped a process that only names a browser in its arguments"
pass "a process that only names a browser in its own arguments is never in the family"

# --- (f) a recorded owner younger than its chain is a recycled pid ----------

OWNER_FILE=$(mktemp "$TMP_ROOT/late-owner.XXXXXX")
: > "$OWNER_FILE"
spawn_orphan env "FM_TEST_OWNER_FILE=$OWNER_FILE" "$BROWSER" --headless=new \
  --remote-debugging-port=9916 --user-data-dir="$TMP_ROOT/profile-f" ||
  fail "could not start the recycled-owner browser fixture"
RECYCLED=$SPAWNED_PID
assert_orphaned "$RECYCLED" "the recycled-owner browser fixture"
# The owner must be measurably younger than the chain it claims to have
# launched; ps elapsed time has one-second resolution.
sleep 2
spawn_owned sleep 600 || fail "could not start the late owner fixture"
LATE_OWNER=$SPAWNED_PID
printf '%s\n' "$LATE_OWNER" > "$OWNER_FILE"

deadline=$(( $(date +%s) + 10 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  ps -p "$RECYCLED" -o args= 2>/dev/null | grep -q -- "--remote-debugging-port=9916" && break
  sleep 0.1
done
alive "$RECYCLED" || fail "the recycled-owner browser fixture exited before it could be judged"

out=$(reap --max-age 0 --grace 3 --pid "$RECYCLED") || fail "the reaper failed: $out"
assert_contains "$out" "reaped orphaned browser chain $RECYCLED" \
  "a recorded owner younger than its own chain was accepted as the live owner"
wait_gone "$RECYCLED" 20 || fail "the chain with a recycled owner pid survived the reaper"
alive "$LATE_OWNER" || fail "the reaper stopped the unrelated process that reused the recorded pid"
pass "a recorded owner younger than the chain it claims to have launched reads as gone"

# --- (i) the sweep runs from the existing supervision cadence ---------------
#
# Proven against a real watcher over a copy of bin/ whose only edit is a
# recording stand-in for the reaper, so the cadence, the interval and the
# detached call are the production ones and nothing here signals a process.

BINROOT="$TMP_ROOT/binroot"
CALLS="$TMP_ROOT/reap-calls"
mkdir -p "$BINROOT"
cp -R "$ROOT/bin" "$BINROOT/bin"
{
  printf '#!%s\n' "$BASH_BIN"
  printf 'printf "%%s\\n" "$*" >> %s\n' "$CALLS"
} > "$BINROOT/bin/fm-browser-reap.sh"
chmod +x "$BINROOT/bin/fm-browser-reap.sh"

WATCH_STATE="$TMP_ROOT/watch-state"
mkdir -p "$WATCH_STATE"

start_watcher() { # <interval>
  FM_HOME="$BINROOT" FM_STATE_OVERRIDE="$WATCH_STATE" FM_POLL=1 \
    FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_BROWSER_REAP_INTERVAL="$1" \
    "$BINROOT/bin/fm-watch.sh" > "$TMP_ROOT/watch.out" 2>&1 &
  WATCHER_PID=$!
  track "$WATCHER_PID"
  local i=0
  while [ "$i" -lt 100 ]; do
    [ -e "$WATCH_STATE/.last-watcher-beat" ] && return 0
    alive "$WATCHER_PID" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_watcher() {
  kill -TERM "$WATCHER_PID" 2>/dev/null || true
  wait_gone "$WATCHER_PID" 15 || kill -KILL "$WATCHER_PID" 2>/dev/null || true
}

start_watcher 86400 || fail "the watcher did not start over the copied toolbelt: $(cat "$TMP_ROOT/watch.out")"
sleep 3
[ ! -s "$CALLS" ] ||
  fail "a freshly armed watcher swept the machine immediately instead of seeding its cadence"
[ -e "$WATCH_STATE/.last-browser-reap" ] ||
  fail "the watcher did not seed the sweep cadence marker"
stop_watcher
pass "a newly armed watcher seeds the sweep cadence instead of sweeping at once"

start_watcher 1 || fail "the watcher did not restart over the copied toolbelt: $(cat "$TMP_ROOT/watch.out")"
deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ -s "$CALLS" ] && break
  sleep 0.2
done
stop_watcher
[ -s "$CALLS" ] ||
  fail "the watcher never ran the sweep on its cadence, so the reaper has no supervision owner"
pass "the watcher runs the sweep on its own cadence, with no daemon of its own"

# The off switch, on the same real watcher: this is the only thing in the poll
# loop that reaches outside the home, so a home must be able to stop it.
: > "$CALLS"
start_watcher 0 || fail "the watcher did not restart over the copied toolbelt: $(cat "$TMP_ROOT/watch.out")"
sleep 4
stop_watcher
[ ! -s "$CALLS" ] || fail "an interval of 0 did not turn the sweep off"
pass "an interval of 0 turns the sweep off"
