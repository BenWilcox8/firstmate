#!/usr/bin/env bash
# Live driver for the stale-wake floor (FM_STALE_FIRST_WAKE_SECS).
# It runs the REAL bin/fm-watch.sh against a REAL pane in a named fm-lab-*
# Herdr session. Every Herdr CLI call of the watcher goes through
# bin/fm-herdr-lab.sh run <lab>, by the same shim pattern as
# tests/fm-herdr-session-cleanup-e2e.test.sh.
#
# Usage: live-driver.sh <case> <watch-script> <pane> <knob|UNSET> [VAR=value ...]
# Writes /home/ben/.no-mistakes/evidence/<run>/case-<case>.log
set -u
ROOT=/home/ben/.no-mistakes/worktrees/3665d600861c/01M4Y4B6EVRB772CYCH2EDT1ZA
EV=/home/ben/.no-mistakes/evidence/01M4Y4B6EVRB772CYCH2EDT1ZA
LAB=$(cat /tmp/fm-floor-lab.name)
CASE=$1 WATCH=$2 PANE=$3 KNOB=$4
shift 4
BASE=/tmp/fm-floor-live/$CASE
HOME_DIR=$BASE/home
FAKEBIN=/tmp/fm-floor-live/fakebin
LOG=$EV/case-$CASE.log
TASK=${TASK:-$CASE}
STATUS_LINE=${STATUS_LINE:-}

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN"
REAL_HERDR=$(command -v herdr)
ORIG_PATH=$PATH
if [ ! -x "$FAKEBIN/herdr" ]; then
  cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -u
args=("\$@")
last=\$((\${#args[@]} - 1))
flag=\$((last - 1))
if [ "\${#args[@]}" -ge 2 ] && [ "\${args[\$flag]}" = --session ] && [ "\${args[\$last]}" = "$LAB" ]; then
  unset "args[\$last]" "args[\$flag]"
fi
set -- "\${args[@]}"
for arg in "\$@"; do
  case "\$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "\${1:-}" = --version ]; then
  exec "$REAL_HERDR" "\$@" --session "$LAB"
fi
exec env PATH="$ORIG_PATH" "$ROOT/bin/fm-herdr-lab.sh" run "$LAB" "\$@"
SH
  chmod +x "$FAKEBIN/herdr"
fi

if [ ! -f "$HOME_DIR/state/$TASK.meta" ]; then
  {
    printf 'window=%s:%s\n' "$LAB" "$PANE"
    printf 'backend=herdr\n'
    printf 'herdr_pane_id=%s\n' "$PANE"
    printf 'endpoint_task_id=%s\n' "$TASK"
    printf 'kind=ship\n'
    printf 'harness=codex\n'
  } > "$HOME_DIR/state/$TASK.meta"
  [ -z "$STATUS_LINE" ] || printf '%s\n' "$STATUS_LINE" > "$HOME_DIR/state/$TASK.status"
fi

knob_env=()
if [ "$KNOB" = UNSET ]; then knob_env=(-u FM_STALE_FIRST_WAKE_SECS); else knob_env=(FM_STALE_FIRST_WAKE_SECS="$KNOB"); fi

{
  echo "== case $CASE"
  echo "watcher: $WATCH"
  echo "lab session: $LAB  pane: $PANE  window: $LAB:$PANE"
  echo "FM_STALE_FIRST_WAKE_SECS: $KNOB   extra env: $*"
  echo "pane now shows: $("$ROOT/bin/fm-herdr-lab.sh" run "$LAB" pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -v '^$' | tail -2 | tr '\n' '|')"
  echo "start: $(date '+%H:%M:%S') epoch=$(date +%s)"
} >> "$LOG"
start=$(date +%s)
# FM_GATE_REFUSE_BYPASS=1 is the repo's own sandbox hatch (tests/lib.sh): this
# run drives a scratch FM_HOME and a lab session, never the real fleet.
cd "$BASE" || exit 1
timeout "${CASE_TIMEOUT:-600}" env "${knob_env[@]}" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$BASE/watch.out" 2> "$BASE/watch.err"
rc=$?
end=$(date +%s)
key=$(printf '%s' "$LAB:$PANE" | tr ':/.' '___')
hash_mtime=$(stat -c %Y "$HOME_DIR/state/.hash-$key" 2>/dev/null || echo none)
{
  echo "exit: $(date '+%H:%M:%S') epoch=$end rc=$rc  watcher ran $((end - start))s"
  echo ".hash marker mtime (last hash change): $hash_mtime  -> wake came $((end - ${hash_mtime/none/$end}))s after the last hash change"
  echo "watcher stdout (the wake reason):"
  sed 's/^/  | /' "$BASE/watch.out"
  echo "triage log:"
  sed 's/^/  | /' "$HOME_DIR/state/.watch-triage.log" 2>/dev/null
  echo "wake queue:"
  sed 's/^/  | /' "$HOME_DIR/state/.wake-queue" 2>/dev/null
  echo "watcher stderr (tail):"
  tail -5 "$BASE/watch.err" | sed 's/^/  | /'
  echo
} >> "$LOG"
