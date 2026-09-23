#!/usr/bin/env bash
# Live proof that park and resume keep a real worker's conversation, in an
# isolated Herdr lab session, for every harness with a native session contract
# that is installed here: claude, codex, and pi.
#
# Each case launches a REAL worker through the fleet's own launch path
# (bin/fm-spawn.sh --relaunch into a lab pane in a disposable git worktree) and
# gives it one turn that carries a unique word. Then:
#   1. bin/fm-control.sh park proves and records its native session, records
#      the park on a TEMPORARY Atlas store, exits the agent, and closes the pane;
#   2. for claude, the lab Herdr server is stopped and provisioned again, which
#      is what a machine reboot does to every pane;
#   3. bin/fm-control.sh resume unparks the ticket and reopens that exact
#      session in a new pane in the same worktree;
#   4. the resumed agent writes the word into a file from memory alone, so the
#      proof is the agent's new action, never a scrollback that still shows the
#      earlier turn.
#
# Safety: every Herdr call goes through the guarded lab helper, whose own
# tripwire proves the live default session is untouched. The worker panes are
# launched from a scrubbed environment so no parent session marker reaches
# them. The Atlas store is a throwaway git repository; the real store is never
# named. agent-axi is disabled so no layout call can leave the lab.
#
# Opt-in because it spends model tokens: FM_PARK_RESUME_LIVE_E2E=1 (or FM_LIVE=1).
#   FM_HERDR_LAB_HELPER          the guarded lab helper (default: this repo's)
#   FM_PARK_RESUME_ATLAS_DIR     an agent-dashboard checkout whose atlas-axi has
#                                `ticket park` (default: the installed one)
#   FM_PARK_RESUME_CLAUDE_MODEL  (default claude-sonnet-5)
#   FM_PARK_RESUME_CODEX_MODEL   (default gpt-5.6-terra)
#   FM_PARK_RESUME_PI_MODEL      (default: Pi's own configured model)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PARK_RESUME_LIVE_E2E herdr jq node git

# Scrub every marker a parent agent session exports, before the lab server
# is provisioned, so the server and every pane it creates start clean.
for v in $(compgen -e); do
  case "$v" in
    CLAUDECODE|CLAUDE_CODE_*|CLAUDE_PID|CLAUDE_EFFORT|HERDR_*|TMUX|TMUX_PANE|FM_TASK_ID|PI_CODING_AGENT|FM_PI_HARNESS|CODEX_*)
      unset "$v" ;;
  esac
done

LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || fail "the guarded Herdr lab helper is not executable: $LAB_HELPER"
CLAUDE_MODEL=${FM_PARK_RESUME_CLAUDE_MODEL:-claude-sonnet-5}
CODEX_MODEL=${FM_PARK_RESUME_CODEX_MODEL:-gpt-5.6-terra}
PI_MODEL=${FM_PARK_RESUME_PI_MODEL:-default}

ATLAS_DIR=${FM_PARK_RESUME_ATLAS_DIR:-}
if [ -z "$ATLAS_DIR" ] && command -v atlas-axi >/dev/null 2>&1; then
  ATLAS_DIR=$(cd "$(dirname "$(readlink -f "$(command -v atlas-axi)")")/.." && pwd)
fi
[ -n "$ATLAS_DIR" ] && [ -x "$ATLAS_DIR/bin/atlas-axi" ] \
  || fail "no atlas-axi found; set FM_PARK_RESUME_ATLAS_DIR to an agent-dashboard checkout"
"$ATLAS_DIR/bin/atlas-axi" ticket --help 2>&1 | grep -q 'ticket park' \
  || fail "$ATLAS_DIR/bin/atlas-axi has no 'ticket park'; set FM_PARK_RESUME_ATLAS_DIR to a build with the park verb"

HARNESSES=()
for h in claude codex pi; do
  if command -v "$h" >/dev/null 2>&1; then
    HARNESSES+=("$h")
  else
    printf 'skip: live: %s is not installed, so its park and resume are not proven here\n' "$h"
  fi
done
[ "${#HARNESSES[@]}" -gt 0 ] || fail "no harness with a native session contract is installed; nothing was checked"

SESSION=$("$LAB_HELPER" name park-resume) || fail "the guarded Herdr lab name could not be created"
TMP_ROOT=$(fm_test_tmproot fm-park-resume-live)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
STORE="$TMP_ROOT/atlas-store"
ORIGINAL_PATH=$PATH
TEARDOWN_PENDING=1
LIVE_IDS=()

cleanup_all() {  # <exit-status>
  local status=$1 id
  trap - EXIT INT TERM
  for id in "${LIVE_IDS[@]:-}"; do
    [ -n "$id" ] || continue
    fm_run "$ROOT/bin/fm-control.sh" "$id" exit >/dev/null 2>&1 || true
  done
  if [ "$TEARDOWN_PENDING" -eq 1 ]; then
    if ! "$LAB_HELPER" teardown "$SESSION"; then
      printf 'not ok - the lab teardown or default-session tripwire failed during cleanup\n' >&2
      status=1
    fi
  fi
  fm_test_cleanup
  exit "$status"
}
trap 'cleanup_all $?' EXIT
trap 'cleanup_all 130' INT
trap 'cleanup_all 143' TERM

"$LAB_HELPER" provision "$SESSION" || fail "the isolated Herdr lab session could not be provisioned"

# Every herdr call from firstmate's scripts is routed through the lab helper,
# which adds the lab session itself; any other session is refused outright.
mkdir -p "$FAKEBIN"
export LAB_HELPER SESSION ORIGINAL_PATH
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
ln -s "$ATLAS_DIR/bin/atlas-axi" "$FAKEBIN/atlas-axi"

lab() { "$LAB_HELPER" run "$SESSION" "$@"; }
atlas() { "$ATLAS_DIR/bin/atlas-axi" --repo "$STORE" --by park-live "$@"; }

# fm_run: a firstmate command against the lab home and session only.
fm_run() {
  env PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_BACKEND_HERDR_AXI_BIN='' FM_CONTROL_POLL=0.5 FM_CONTROL_EXIT_WAIT=60 \
    FM_CONTROL_LAUNCH_WAIT=120 "$@"
}

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$STORE/atlas"
printf '%s\n' "$STORE" > "$HOME_DIR/config/specs"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
git -C "$STORE" init -q
git -C "$STORE" -c user.name=park-live -c user.email=park-live@example.invalid commit -q --allow-empty -m init
atlas create "Park lab" --name parklab >/dev/null || fail "the temporary Atlas root could not be created"

pane_status() {  # <pane>
  lab agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

# settle <pane>: answer the dialogs a fresh launch can show - Codex's update
# offer (skip it), a first-run directory trust (accept it), and Codex's
# informational hooks modal (close it) - then wait for the agent to be idle.
settle() {  # <pane>
  local pane=$1 screen status i
  for i in $(seq 1 120); do
    screen=$(lab agent read "$pane" --source visible --lines 60 2>/dev/null || true)
    case "$screen" in
      *"Update available"*"Skip"*)
        lab agent send-keys "$pane" down >/dev/null; sleep 0.5
        lab agent send-keys "$pane" enter >/dev/null; sleep 2; continue ;;
      *"Do you trust the contents of this directory?"*)
        lab agent send-keys "$pane" enter >/dev/null; sleep 2; continue ;;
      *"Hooks"*"esc"*)
        lab agent send-keys "$pane" esc >/dev/null; sleep 1; continue ;;
    esac
    status=$(pane_status "$pane")
    case "$status" in idle|done) [ "$i" -gt 3 ] && return 0 ;; esac
    sleep 2
  done
  fail "the agent in pane $pane did not settle: $(printf '%s' "$screen" | tail -n 15)"
}

wait_for_recall() {  # <file> <word>
  local i
  for i in $(seq 1 120); do
    if [ -f "$1" ] && grep -qF "$2" "$1"; then return 0; fi
    sleep 2
  done
  return 1
}

# fm_out <label> <command...>: run a firstmate command, judge it by its stdout
# alone (unrelated guards print advisories on stderr), and fail with both
# streams when it refuses.
fm_out() {  # <label> <command...>
  local label=$1 err="$TMP_ROOT/last.err" out
  shift
  if ! out=$(fm_run "$@" 2>"$err"); then
    fail "$label failed: $out $(tail -n 5 "$err")"
  fi
  printf '%s' "$out"
}

meta_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta" | tail -n 1
}

run_case() {  # <harness> <model> <reboot:0|1>
  local h=$1 model=$2 reboot=$3 id="park-$1" word proj wt create pane tab ws ticket out sid
  local new_pane ask json
  word="WORD-$(printf '%s' "$h" | tr '[:lower:]' '[:upper:]')-$RANDOM$RANDOM"
  proj="$TMP_ROOT/proj-$h"; wt="$TMP_ROOT/wt-$h"
  fm_git_worktree "$proj" "$wt" "park-$h"
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
This is a live check of firstmate's park and resume. The codename of this check is $word; later in this conversation you will be asked to write it into a file.

## Firstmate spec
Do not run any tool and do not change any file now. Reply with exactly one word, noted, and then wait for the next instruction.
EOF
  # One node holds one crewmate, so each harness works its own node.
  atlas create "Park node $h" --under parklab --name "node-$h" >/dev/null \
    || fail "the temporary Atlas node for $h could not be created"
  out=$(atlas ticket queue "parklab/node-$h" "Park and resume $h" --captain-surface "none" \
    --story "as the captain I want a parked $h worker to resume with its context") \
    || fail "the $h ticket could not be queued: $out"
  ticket=$(printf '%s' "$out" | sed -n 's/^queued \(c[0-9]*\) .*/\1/p')
  [ -n "$ticket" ] || fail "the $h ticket id could not be read: $out"
  atlas ticket start "$ticket" --to "fm-$id" --task "$id" >/dev/null || fail "the $h ticket could not be started"

  create=$(lab workspace create --cwd "$wt" --label "fm-$id" --no-focus) \
    || fail "the $h lab pane could not be created"
  pane=$(printf '%s' "$create" | jq -er '.result.root_pane.pane_id') || fail "no $h pane id"
  tab=$(printf '%s' "$create" | jq -er '.result.root_pane.tab_id') || fail "no $h tab id"
  ws=$(printf '%s' "$create" | jq -er '.result.root_pane.workspace_id') || fail "no $h workspace id"
  {
    printf 'window=%s:%s\n' "$SESSION" "$pane"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$proj"
    printf 'harness=%s\n' "$h"
    printf 'kind=scout\n'
    printf 'model=%s\n' "$model"
    printf 'effort=default\n'
    printf 'backend=herdr\n'
    printf 'herdr_session=%s\n' "$SESSION"
    printf 'herdr_workspace_id=%s\n' "$ws"
    printf 'herdr_tab_id=%s\n' "$tab"
    printf 'herdr_pane_id=%s\n' "$pane"
    printf 'atlas_ticket=%s\n' "$ticket"
  } > "$HOME_DIR/state/$id.meta"

  out=$(fm_out "the $h launch" "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness "$h" --model "$model") || exit 1
  LIVE_IDS+=("$id")
  settle "$pane"
  pass "$h: a real worker launched through the fleet path and took its first turn"

  out=$(fm_out "$h park" "$ROOT/bin/fm-control.sh" "$id" park --reason "live park check") || exit 1
  case "$out" in "parked $id harness=$h session="*) ;; *) fail "$h park reported: $out" ;; esac
  sid=$(meta_field "$id" native_session)
  [ -n "$sid" ] || fail "$h park recorded no native session"
  [ -f "$(meta_field "$id" native_session_file)" ] || fail "$h park recorded a session file that does not exist"
  [ "$(lab pane get "$pane" 2>&1 | jq -r '.error.code // empty' 2>/dev/null)" = pane_not_found ] \
    || fail "$h park left its pane $pane open"
  json=$(atlas ticket show "$ticket" --json) || fail "the $h ticket could not be read"
  [ "$(printf '%s' "$json" | jq -r '.change.state')" = parked ] || fail "the $h ticket is not parked: $json"
  [ "$(printf '%s' "$json" | jq -r '.change.parked.session.id')" = "$sid" ] \
    || fail "the $h ticket does not name the recorded session: $json"
  [ "$(printf '%s' "$json" | jq -r '.change.parked.session.harness')" = "$h" ] \
    || fail "the $h ticket does not name the harness: $json"
  out=$(fm_run "$ROOT/bin/fm-crew-state.sh" "$id" 2>/dev/null)
  case "$out" in *"state: parked"*"source: park"*) ;; *) fail "$h crew state does not read parked: $out" ;; esac
  pass "$h: park recorded session $sid on the task and the Atlas ticket, and closed the pane"

  if [ "$reboot" = 1 ]; then
    "$LAB_HELPER" stop "$SESSION" >/dev/null || fail "the lab session could not be stopped"
    "$LAB_HELPER" provision "$SESSION" || fail "the lab session could not be provisioned again"
    pass "$h: the lab Herdr server was stopped and started again, as a reboot does"
  fi

  ask="Write the codename of this park and resume check, given earlier in this conversation, into a file named recall.txt in your current directory, with nothing else in it, then reply done."
  if [ "$h" = claude ]; then
    out=$(fm_out "$h resume" "$ROOT/bin/fm-control.sh" "$id" resume --note "$ask") || exit 1
  else
    out=$(fm_out "$h resume" "$ROOT/bin/fm-control.sh" "$id" resume) || exit 1
  fi
  case "$out" in "resumed $id harness=$h session=$sid"*) ;; *) fail "$h resume reported: $out" ;; esac
  [ "$(atlas ticket show "$ticket" --json | jq -r '.change.state')" = started ] \
    || fail "the $h ticket was not returned to started"
  [ -z "$(meta_field "$id" parked)" ] || fail "$h resume left the park record in place"
  new_pane=$(meta_field "$id" herdr_pane_id)
  [ -n "$new_pane" ] || fail "$h resume recorded no pane"
  if [ "$h" != claude ]; then
    settle "$new_pane"
    fm_run "$ROOT/bin/fm-send.sh" "$id" "$ask" >/dev/null 2>&1 || fail "the $h question could not be sent"
  fi
  if ! wait_for_recall "$wt/recall.txt" "$word"; then
    printf '# resumed %s pane %s screen:\n%s\n# inbox: %s\n' "$h" "$new_pane" \
      "$(lab agent read "$new_pane" --source recent --lines 40 2>&1 | tail -n 40)" \
      "$(find "$HOME_DIR/state/$id.inbox" 2>&1 | tr '\n' ' ')" >&2
    fail "the resumed $h agent did not recall the word; recall.txt holds: $(cat "$wt/recall.txt" 2>/dev/null || printf 'nothing')"
  fi
  pass "$h: the resumed agent recalled the word from its parked conversation"

  fm_run "$ROOT/bin/fm-control.sh" "$id" exit >/dev/null 2>&1 || true
}

for h in "${HARNESSES[@]}"; do
  case "$h" in
    claude) run_case claude "$CLAUDE_MODEL" 1 ;;
    codex) run_case codex "$CODEX_MODEL" 0 ;;
    pi) run_case pi "$PI_MODEL" 0 ;;
  esac
done

LIVE_IDS=()
TEARDOWN_PENDING=0
"$LAB_HELPER" teardown "$SESSION" || fail "the lab teardown or default-session tripwire failed"
pass "park and resume kept every installed harness's conversation, and the live default session is unchanged"
