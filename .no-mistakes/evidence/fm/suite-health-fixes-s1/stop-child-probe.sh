#!/usr/bin/env bash
# Probe: a background child that loses its first TERM.
# Old reap (one TERM + unbounded wait) versus fm_test_stop_child.
set -u
WT=$1
# shellcheck source=/dev/null
. "$WT/tests/lib.sh"
start_child() {
  local ready=$1
  bash -c 'n=0; trap '\''n=$((n + 1)); [ "$n" -ge 2 ] && exit 7'\'' TERM; : > "$1"; while :; do sleep 0.1; done' _ "$ready" &
  CHILD=$!
  while [ ! -e "$ready" ]; do sleep 0.05; done
}
d=$(mktemp -d)
echo "== old reap: kill \$pid; wait \$pid (bounded here by a 5 s watchdog) =="
start_child "$d/r1"
old_reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
s=$SECONDS
( sleep 5; kill -KILL "$CHILD" 2>/dev/null ) & dog=$!
old_reap "$CHILD"; rc=$?
echo "old reap returned after $((SECONDS - s)) s; child ended only because the watchdog sent KILL"
wait "$dog" 2>/dev/null
echo "== new reap: fm_test_stop_child =="
start_child "$d/r2"
s=$SECONDS
st=0; fm_test_stop_child "$CHILD" || st=$?
echo "fm_test_stop_child returned after $((SECONDS - s)) s with child status $st (7 = exited through the re-sent TERM)"
fm_test_process_running "$CHILD" && echo "FAIL: still running" || echo "child is gone"
echo "== new reap on a child that ignores TERM, bound 2 s =="
bash -c 'trap "" TERM; : > "$1"; while :; do sleep 0.1; done' _ "$d/r3" & CHILD=$!
while [ ! -e "$d/r3" ]; do sleep 0.05; done
s=$SECONDS; st=0; fm_test_stop_child "$CHILD" 20 || st=$?
echo "returned after $((SECONDS - s)) s with status $st (137 = KILL at bound)"
rm -rf "$d"
