#!/usr/bin/env bash
# orphan-check.sh <tree> <suite> [term-after-seconds]
# Runs <tree>/tests/<suite> with a private TMPDIR. With a delay, sends SIGTERM to
# the suite after that many seconds, the way a runner bound or a Ctrl-C ends a
# suite mid-case. Then waits 3 s and lists every process of this user that still
# carries that TMPDIR in its environment, command line or cwd: a fixture
# process the suite started and did not reap.
set -u
tree=$1 suite=$2 term=${3:-}
P=$(mktemp -d /tmp/fm-orphan.XXXXXX)
mkdir -p "$P/tmp"
( cd "$tree" && exec env TMPDIR="$P/tmp" bash "tests/$suite" ) > "$P/out" 2>&1 &
spid=$!
if [ -n "$term" ]; then
  sleep "$term"; echo "sending SIGTERM to the suite (pid $spid) after ${term}s"; kill -TERM "$spid" 2>/dev/null
fi
wait "$spid"; rc=$?
echo "suite exit: $rc; case lines: $(grep -cE '^(ok|not ok) ' "$P/out"); not ok: $(grep -c '^not ok' "$P/out")"
grep '^not ok' "$P/out" | head -5
sleep 3
found=0
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  [ "$pid" = "$$" ] && continue
  [ -O "$d" ] || continue
  if { tr "\0" "\n" < "$d/environ"; } 2>/dev/null | grep -qxF "TMPDIR=$P/tmp" \
     || tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -qF "$P/" \
     || readlink "$d/cwd" 2>/dev/null | grep -qF "$P/"; then
    found=$((found + 1))
    printf 'LEFT ALIVE pid=%s comm=%s cmd=%s\n' "$pid" "$(cat "$d/comm" 2>/dev/null)" "$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | cut -c1-140)"
  fi
done
echo "fixture processes left alive: $found"
# Clean up after the check so nothing outlives this evidence run.
for d in /proc/[0-9]*; do
  pid=${d#/proc/}; [ "$pid" = "$$" ] && continue; [ -O "$d" ] || continue
  { tr "\0" "\n" < "$d/environ"; } 2>/dev/null | grep -qxF "TMPDIR=$P/tmp" && kill -KILL "$pid" 2>/dev/null
done
rm -rf "$P" 2>/dev/null
