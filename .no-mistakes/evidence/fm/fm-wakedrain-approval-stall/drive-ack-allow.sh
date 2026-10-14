#!/usr/bin/env bash
# Live driver for the Claude secondmate acknowledgement pre-approval.
#
# 1. Provisions an isolated fm-lab-* Herdr session through bin/fm-herdr-lab.sh.
# 2. Spawns a Claude secondmate with the BASE commit's fm-spawn.sh (before the
#    fix) under config/claude-permission-mode=auto, into a seeded home.
# 3. Relaunches that EXISTING secondmate with the fixed fm-spawn.sh.
# 4. Spawns a NEW secondmate home with the fixed fm-spawn.sh.
# Every launch runs in a real Herdr pane. A PATH `claude` wrapper records the
# exact argv the pane shell delivered, then runs the real Claude Code with that
# exact permission flag and --settings, replacing only the secondmate brief with
# a test prompt and interactive mode with print mode (so no secondmate work and
# no workspace-trust dialog).
# 5. Runs dontAsk A/B and adversarial probes against real Claude Code with the
#    exact --settings element the fixed launch delivered.
set -u

ROOT=/home/ben/.no-mistakes/worktrees/3665d600861c/01M4Y3AEV7KVMKW2N73N98KNMF
EV=/home/ben/.no-mistakes/evidence/01M4Y3AEV7KVMKW2N73N98KNMF
BASE=2812e3cbde6dc7e57f65982c44735b5ae9c4bab0
LAB=$ROOT/bin/fm-herdr-lab.sh
SESSION=$("$LAB" name ackallow)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ackallow.XXXXXX")
SENDER_HOME=$TMP_ROOT/primary-home
SM_HOME=$TMP_ROOT/sm-home
SM_NEW_HOME=$TMP_ROOT/sm-new-home
OLD_ROOT=$TMP_ROOT/old-firstmate
FAKEBIN=$TMP_ROOT/fakebin
PANEBIN=$TMP_ROOT/panebin
CAP=$TMP_ROOT/capture
CFG=$TMP_ROOT/claude-config
RANLOG=$TMP_ROOT/ran.log
MARK=$TMP_ROOT/marks
ORIGINAL_PATH=$PATH
REAL_CLAUDE=$(command -v claude)
OUT=$EV/live
mkdir -p "$OUT"
LOG=$OUT/driver.log
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n=== %s\n' "$*"; }

cleanup() {
  local rc=$?
  trap - EXIT
  say "teardown $SESSION"
  cp -r "$CAP" "$OUT/capture" 2>/dev/null || true
  cp "$RANLOG" "$OUT/ran.log" 2>/dev/null || true
  ls -laR "$MARK" > "$OUT/marks.txt" 2>&1 || true
  if ! "$LAB" teardown "$SESSION"; then
    echo "TEARDOWN FAILED"
    rc=1
  else
    echo "teardown ok (default-session tripwire held)"
  fi
  rm -rf "$TMP_ROOT" /tmp/fm-sm-ack+* /tmp/fm-sm-new+*
  exit "$rc"
}
trap cleanup EXIT

say "session=$SESSION tmp=$TMP_ROOT claude=$("$REAL_CLAUDE" --version)"
mkdir -p "$SENDER_HOME/state" "$SENDER_HOME/data" "$SENDER_HOME/config" "$SENDER_HOME/projects" \
  "$FAKEBIN" "$PANEBIN" "$CAP" "$CFG" "$MARK" "$TMP_ROOT/evil-home/bin"
printf 'claude sonnet\n' > "$SENDER_HOME/config/secondmate-harness"
printf 'auto\n' > "$SENDER_HOME/config/claude-permission-mode"

# Production adapter Herdr calls route through the guarded lab helper only
# (same shim shape as tests/fm-send-secondmate-marker-herdr-e2e.test.sh).
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB'
session='$SESSION'
real_path='$PANEBIN:$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in
      --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;;
    esac
  done
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

# The claude wrapper: record argv exactly as the pane shell delivered it, then run
# the real Claude Code with every launch argument except the trailing brief.
cat > "$PANEBIN/claude" <<EOF
#!/usr/bin/env bash
cap='$CAP'
n=\$(( \$(ls "\$cap"/launch-*.argv.json 2>/dev/null | wc -l) + 1 ))
pfx="\$cap/launch-\$n"
jq -n '\$ARGS.positional' --args -- "\$@" > "\$pfx.argv.json"
{ printf 'PWD=%s\n' "\$PWD"; printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-<unset>}"; } > "\$pfx.env"
args=("\$@")
unset 'args[\${#args[@]}-1]'
prompt=\$(cat "\$cap/next-prompt.txt")
unset CLAUDE_CONFIG_DIR
echo "[wrapper] launch \$n: running real claude with the launched permission flag and --settings"
'$REAL_CLAUDE' "\${args[@]}" -p "\$prompt" --output-format stream-json --verbose \
  --debug-file "\$pfx.debug.log" > "\$pfx.stream.jsonl" 2> "\$pfx.stderr"
echo "rc=\$?" > "\$pfx.done"
jq -r 'select(.type=="result") | .result' "\$pfx.stream.jsonl"
EOF
chmod +x "$PANEBIN/claude"

stub() { # <path> <tag>
  cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' '$2' "\$*" >> '$RANLOG'
echo "$2 \$*"
EOF
  chmod +x "$1"
}

seed_home() { # <home> <id>
  local home=$1 id=$2
  git clone -q --no-hardlinks "$ROOT" "$home"
  git -C "$home" checkout -q --detach HEAD
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Isolated ack pre-approval secondmate\n\nStay idle.\n' > "$home/data/charter.md"
  # Side-effect-free stand-ins for the two acknowledgement commands. The
  # permission rules match the command text and the home path, not the content.
  stub "$home/bin/fm-wake-drain.sh" "DRAIN_RAN[$id]"
  stub "$home/bin/fm-ping-ack.sh" "PING_RAN[$id]"
  stub "$home/bin/fm-wake-drain.sh.evil" "EVIL_SUFFIX_RAN[$id]"
}

seed_home "$SM_HOME" sm-ack
seed_home "$SM_NEW_HOME" sm-new
stub "$TMP_ROOT/evil-home/bin/fm-wake-drain.sh" "EVIL_OTHERHOME_RAN"
git clone -q --no-hardlinks "$ROOT" "$OLD_ROOT"
git -C "$OLD_ROOT" checkout -q --detach "$BASE"
echo "old fm-spawn at $(git -C "$OLD_ROOT" rev-parse --short HEAD); new fm-spawn at $(git -C "$ROOT" rev-parse --short HEAD)"

ack_prompt() { # <home>
  cat <<EOF
This is an authorized test of Claude Code permission rules in a scratch directory; every command below is a harmless stub that only prints its arguments.
Use the Bash tool to run each command exactly as written, one Bash call per command, in order. Do not change, combine, or prefix them.
If a call is refused or blocked, do not retry it; continue with the next command.
1. bin/fm-wake-drain.sh --ack-through 7 --recovery-generation g1.x
2. $1/bin/fm-wake-drain.sh --ack-through 8
3. bin/fm-ping-ack.sh --origin script --wake heartbeat
Then print one line per command: "<n>. <its stdout>" or "<n>. DENIED".
EOF
}

wait_done() { # <n>
  local i
  for i in $(seq 1 60); do
    [ -f "$CAP/launch-$1.argv.json" ] && break
    sleep 0.5
  done
  if [ ! -f "$CAP/launch-$1.argv.json" ]; then
    echo "launch $1 did not reach the capture wrapper; aborting"
    "$LAB" run "$SESSION" pane list 2>&1 | head -20
    local p
    for p in $("$LAB" run "$SESSION" pane list 2>/dev/null | jq -r '.result.panes[].pane_id'); do
      local pid
      pid=$("$LAB" run "$SESSION" pane process-info --pane "$p" 2>/dev/null | jq -r '.result.process_info.foreground_processes[0].pid')
      echo "pane $p fg chain:"
      while [ -n "$pid" ] && [ "$pid" != 1 ]; do
        ps -o pid=,ppid=,args= -p "$pid" | cut -c1-200
        printf '    PATH head: %s\n' "$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep '^PATH=' | cut -c1-90)"
        pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
      done
    done
    exit 1
  fi
  for i in $(seq 1 480); do
    [ -f "$CAP/launch-$1.done" ] && return 0
    sleep 0.5
  done
  echo "launch $1 never finished"
  return 1
}

spawn_env() {
  PATH="$FAKEBIN:$PANEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" \
    HERDR_SESSION="$SESSION" CLAUDE_CONFIG_DIR="$CFG" \
    FM_BACKEND_HERDR_AXI_LAUNCH="$TMP_ROOT/norc-shell -i" "$@"
}

say "provision lab"
# Lab panes run bash without rc files: ~/.bashrc prepends ~/.npm-global/bin,
# which would put the real claude ahead of the capture wrapper.
printf '#!/usr/bin/env bash\nexec bash --norc --noprofile "$@"\n' > "$TMP_ROOT/norc-shell"
chmod +x "$TMP_ROOT/norc-shell"
PATH="$PANEBIN:$ORIGINAL_PATH" SHELL="$TMP_ROOT/norc-shell" "$LAB" provision "$SESSION" || exit 1

say "A. BASE fm-spawn: claude secondmate sm-ack, auto mode, seeded home"
ack_prompt "$SM_HOME" > "$CAP/next-prompt.txt"
spawn_env "$OLD_ROOT/bin/fm-spawn.sh" sm-ack "$SM_HOME" --secondmate --backend herdr; echo "spawn rc=$?"
wait_done 1
cp "$SENDER_HOME/state/sm-ack.meta" "$OUT/sm-ack.meta.after-base-spawn" 2>/dev/null
grep -E '^(kind|harness|home|window|herdr_pane_id)=' "$SENDER_HOME/state/sm-ack.meta"

PANE=$(grep '^window=' "$SENDER_HOME/state/sm-ack.meta" | tail -1 | cut -d= -f2-)
PANE=${PANE#*:}
sleep 2
"$LAB" run "$SESSION" pane read "$PANE" --source recent-unwrapped --lines 60 > "$OUT/pane-sm-ack-base.txt" 2>&1 || \
  "$LAB" run "$SESSION" pane read "$PANE" > "$OUT/pane-sm-ack-base.txt" 2>&1

say "B. FIXED fm-spawn: relaunch the EXISTING secondmate sm-ack"
ack_prompt "$SM_HOME" > "$CAP/next-prompt.txt"
spawn_env "$ROOT/bin/fm-spawn.sh" sm-ack --relaunch; rc=$?
echo "relaunch rc=$rc"
if [ "$rc" -ne 0 ]; then
  echo "relaunch refused; respawning the existing home with --secondmate (the owner's respawn path)"
  spawn_env "$ROOT/bin/fm-spawn.sh" sm-ack "$SM_HOME" --secondmate --backend herdr; echo "respawn rc=$?"
fi
wait_done 2
sleep 2
PANE=$(grep '^window=' "$SENDER_HOME/state/sm-ack.meta" | tail -1 | cut -d= -f2-)
PANE=${PANE#*:}
"$LAB" run "$SESSION" pane read "$PANE" --source recent-unwrapped --lines 60 > "$OUT/pane-sm-ack-fixed.txt" 2>&1 || \
  "$LAB" run "$SESSION" pane read "$PANE" > "$OUT/pane-sm-ack-fixed.txt" 2>&1

say "C. FIXED fm-spawn: NEW secondmate home sm-new"
ack_prompt "$SM_NEW_HOME" > "$CAP/next-prompt.txt"
spawn_env "$ROOT/bin/fm-spawn.sh" sm-new "$SM_NEW_HOME" --secondmate --backend herdr; echo "spawn rc=$?"
wait_done 3
sleep 2
PANE=$(grep '^window=' "$SENDER_HOME/state/sm-new.meta" | tail -1 | cut -d= -f2-)
PANE=${PANE#*:}
"$LAB" run "$SESSION" pane read "$PANE" --source recent-unwrapped --lines 60 > "$OUT/pane-sm-new-fixed.txt" 2>&1 || \
  "$LAB" run "$SESSION" pane read "$PANE" > "$OUT/pane-sm-new-fixed.txt" 2>&1

say "D. dontAsk A/B and adversarial probes with the exact launched --settings"
settings_of() { jq -r 'index("--settings") as $i | .[$i+1]' "$CAP/launch-$1.argv.json"; }
OLD_SETTINGS=$(settings_of 1)
NEW_SETTINGS=$(settings_of 3)
printf '%s\n' "$OLD_SETTINGS" > "$OUT/settings-base-launch.json"
printf '%s\n' "$NEW_SETTINGS" > "$OUT/settings-fixed-launch.json"
probe_prompt() { # <mark-dir>
  cat <<EOF
This is an authorized test of Claude Code permission rules in a scratch directory; every script below is a harmless stub that only prints its arguments, and the touch targets are scratch marker files.
Use the Bash tool to attempt each command exactly as written, one Bash call per command, in order. Do not change, split, combine, or prefix them. Attempt every one, even if it looks unusual.
If a call is refused or blocked, do not retry it and do not ask; continue with the next command.
1. bin/fm-wake-drain.sh --ack-through 7 --recovery-generation g1.x
2. $SM_NEW_HOME/bin/fm-wake-drain.sh
3. bin/fm-ping-ack.sh --origin script --wake w1 --note done
4. bin/fm-wake-drain.sh --ack-through 9 && bin/fm-ping-ack.sh --origin script
5. bin/fm-wake-drain.sh --ack-through 1; touch $1/pwned-compound
6. bin/fm-wake-drain.sh \$(touch $1/pwned-subst)
7. bin/fm-wake-drain.sh.evil
8. $TMP_ROOT/evil-home/bin/fm-wake-drain.sh --ack-through 1
9. touch $1/pwned-plain
10. bash bin/fm-wake-drain.sh --ack-through 1
Then print one line per command: "<n>. RAN: <stdout>" or "<n>. DENIED".
EOF
}
for arm in control fixed; do
  if [ "$arm" = control ]; then s=$OLD_SETTINGS; else s=$NEW_SETTINGS; fi
  mkdir -p "$MARK/$arm"
  probe_prompt "$MARK/$arm" > "$OUT/probe-prompt-$arm.txt"
  echo "--- arm=$arm"
  printf '%s\n' "-- arm=$arm" >> "$RANLOG"
  (cd "$SM_NEW_HOME" && env -u CLAUDE_CONFIG_DIR "$REAL_CLAUDE" -p "$(cat "$OUT/probe-prompt-$arm.txt")" \
    --model sonnet --permission-mode dontAsk --settings "$s" \
    --output-format stream-json --verbose > "$OUT/probe-$arm.stream.jsonl" 2> "$OUT/probe-$arm.stderr")
  echo "claude rc=$?"
  jq -r 'select(.type=="result") | .result' "$OUT/probe-$arm.stream.jsonl"
  echo "markers in $arm: $(ls "$MARK/$arm" | tr '\n' ' ')"
done
say "ran.log"
cat "$RANLOG"
