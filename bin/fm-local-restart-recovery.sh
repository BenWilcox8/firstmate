#!/usr/bin/env bash
# fm-local-restart-recovery.sh - restart detection and supervisor relaunch.
#
# A machine reboot, a restart of the user service manager (for example a
# logout while lingering is off), or a Herdr-only restart stops Herdr and every
# agent in it. This script is the one owner of noticing such a restart and of
# bringing the supervisor layer back: the primary firstmate in its recorded
# Herdr pane, and every authorized second mate in its own pane, one at a time.
# Working crews are not relaunched here; the relaunched supervisors reconcile
# them.
#
# Usage:
#   fm-local-restart-recovery.sh record
#   fm-local-restart-recovery.sh fingerprint
#   fm-local-restart-recovery.sh run
#   fm-local-restart-recovery.sh liveness-skip <secondmate-id>
#   fm-local-restart-recovery.sh status
#   fm-local-restart-recovery.sh launch-line
#
#   record       Run at every locked session start through the restart-record
#                hook in bin/fm-session-start.sh. It stores the restart
#                fingerprint in state/.restart-fingerprint and prints one
#                RESTART line when the fingerprint changed since the last
#                locked start. In a second mate home that line points at the
#                primary home, which runs recovery and keeps its ledger.
#                In a primary home (no .fm-secondmate-home
#                marker) that runs in a Herdr pane, it also writes the primary
#                endpoint record state/.primary-endpoint: the pane, its
#                workspace, the home, the harness, the harness launch flags,
#                and the harness's native session id, bound to the boot id.
#                Outside a Herdr pane it removes that record, so recovery never
#                types into a pane the primary no longer uses.
#   fingerprint  Print the current fingerprint: boot_id (the kernel boot id),
#                user_manager (the invocation id of user@<uid>.service),
#                herdr_session, and herdr_start (the modification time of that
#                Herdr session's API socket, which Herdr re-creates at every
#                server start).
#                A changed boot_id is a reboot; otherwise a changed
#                user_manager is a user service manager restart; otherwise a
#                changed herdr_start is a Herdr-only restart. A Herdr live
#                handoff also re-creates the socket; recovery then finds every
#                agent already running and relaunches nothing.
#   run          The entry point of the restart recovery user unit
#                (firstmate-restart-recovery.service in the dotfiles flake,
#                ordered after herdr-server.service and pulled in by each of
#                its starts). In order it:
#                  1. takes this boot's single-flight lock; a second
#                     invocation while a pass runs exits 0 and does nothing;
#                  2. waits for the recorded Herdr session to answer, at most
#                     FM_RESTART_HERDR_WAIT seconds, and otherwise stops with
#                     exit 4 and no relaunch;
#                  3. compares the current fingerprint with the one the last
#                     locked session start stored, as read when the pass took
#                     its lock (a session start during the wait cannot hide the
#                     restart), and exits 0 when there is no baseline, no
#                     restart, or this restart was already recovered;
#                  4. refuses with exit 3 when FM_RESTART_MAX_PASSES passes
#                     already started within FM_RESTART_WINDOW seconds (a
#                     restart loop);
#                  5. relaunches, one at a time, every second mate this home
#                     registers in data/secondmates.md and records in
#                     state/<id>.meta, except dormant ones
#                     (bin/fm-local-dormant.sh), remote ones (they recover on
#                     their own host), and ones already running. An agent-free
#                     pane gets `bin/fm-control.sh <id> relaunch` in place; a
#                     pane that is gone gets `bin/fm-spawn.sh <id>
#                     --secondmate`. Each relaunch appends one unkeyed
#                     `working:` line to state/<id>.status, so a blocker
#                     recorded before the restart does not read as current;
#                  6. relaunches the primary firstmate last, in its recorded
#                     pane when that pane holds only a shell in the recorded
#                     home, else in a new tab of the recorded workspace, else
#                     (only when that workspace is gone) in a new workspace;
#                     the pass record names the tab or workspace and the pane
#                     it created. It resumes the recorded native
#                     session when its transcript is still on disk and starts
#                     a fresh one otherwise, with the recorded launch flags and
#                     the session-start operational input as its first prompt.
#                     A live session lock, an agent already in the pane, or a
#                     live Claude process whose working directory is this home
#                     and that started after the Herdr server did
#                     means the primary is already running (a manual
#                     relaunch), and nothing is launched. The pass checks this
#                     again right before it types the launch. Only Claude
#                     primaries are relaunched;
#                  7. writes a pass record under state/restart-recovery/ and
#                     appends one `check` wake for firstmate.
#                The second mates go first so that the relaunched primary's
#                own session start finds them running rather than racing
#                them.
#                Exit status: 0 done or nothing to do, 3 rate limited,
#                4 Herdr unavailable, 1 usage or setup error.
#                A rate-limited or Herdr-unavailable run raises one alert
#                (a pass record plus a wake) per FM_RESTART_WINDOW, not one per
#                attempt.
#   liveness-skip  The secondmate-liveness-skip hook in bin/fm-bootstrap.sh's
#                startup liveness sweep. Exit 0 (leave the second mate alone)
#                when it is dormant or while a recovery pass runs, and exit 1
#                otherwise. A dormant skip prints a BOOTSTRAP_INFO fact only
#                under FM_BOOTSTRAP_VERBOSE_FACTS=1; a skip for a running pass
#                always prints one.
#   status       Print the recent pass ledger and the newest pass record.
#   launch-line  Print the command a relaunch would type into the primary
#                pane for the current primary endpoint record, and on stderr
#                how its session would start. Nothing is launched.
#
# Files, all in this home's state/:
#   .restart-fingerprint             the fingerprint the last locked start saw
#   .primary-endpoint                the primary endpoint record
#   .restart-recovery.log            the pass ledger: epoch, event, restart key,
#                                    detail (tab separated, bounded)
#   .restart-recovery.<boot>.lock    the single-flight lock of one boot
#   restart-recovery/<epoch>.txt     pass and alert records (newest 20 kept)
#
# Environment:
#   FM_HOME                  the home to recover (default: this code root)
#   FM_RESTART_HERDR_WAIT    seconds to wait for Herdr to answer (120)
#   FM_RESTART_HERDR_CALL_TIMEOUT  seconds one Herdr call may take (10)
#   FM_RESTART_POLL          poll interval in seconds (2)
#   FM_RESTART_LAUNCH_WAIT   seconds to wait for the primary agent (90)
#   FM_RESTART_MAX_PASSES    passes allowed per window (2)
#   FM_RESTART_WINDOW        rate-limit window in seconds (1800)
#   FM_RESTART_BOOT_ID_FILE  boot id source (/proc/sys/kernel/random/boot_id)
#   FM_RESTART_USER_MANAGER_ID  literal user manager invocation id; when unset
#                            it is read from systemctl
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_HOME

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-native-session-lib.sh
. "$SCRIPT_DIR/fm-native-session-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

RR_FINGERPRINT="$STATE/.restart-fingerprint"
RR_ENDPOINT="$STATE/.primary-endpoint"
RR_LEDGER="$STATE/.restart-recovery.log"
RR_RECORDS="$STATE/restart-recovery"
RR_WAIT=${FM_RESTART_HERDR_WAIT:-120}
RR_POLL=${FM_RESTART_POLL:-2}
RR_LAUNCH_WAIT=${FM_RESTART_LAUNCH_WAIT:-90}
RR_MAX_PASSES=${FM_RESTART_MAX_PASSES:-2}
RR_WINDOW=${FM_RESTART_WINDOW:-1800}
RR_SESSION_START_BODY="Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions."

CUR_BOOT=
CUR_UM=
CUR_SESSION=
CUR_HS=
RR_LOCK=
RR_NOTES=()
RR_LAUNCH_LINE=
RR_LAUNCH_DESC=

rr_say() {
  printf 'fm-restart-recovery: %s\n' "$*"
}

rr_note() {
  RR_NOTES+=("$*")
  rr_say "$*"
}

# --- fingerprint --------------------------------------------------------

rr_clean() {
  tr -cd 'A-Za-z0-9._:-'
}

rr_boot_id() {
  local file=${FM_RESTART_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id} value=
  [ -r "$file" ] && IFS= read -r value < "$file"
  printf '%s' "$value" | rr_clean
}

rr_user_manager() {
  if [ "${FM_RESTART_USER_MANAGER_ID+set}" = set ]; then
    printf '%s' "$FM_RESTART_USER_MANAGER_ID" | rr_clean
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 0
  fm_run_timed 5 systemctl show "user@$(id -u).service" -p InvocationID --value 2>/dev/null | rr_clean
}

# rr_herdr <session> <herdr arguments...>: one bounded Herdr call scoped to
# <session> by Herdr's own trailing --session flag.
rr_herdr() {
  local session=$1
  shift
  command -v herdr >/dev/null 2>&1 || return 127
  HERDR_SESSION="$session" fm_run_timed "${FM_RESTART_HERDR_CALL_TIMEOUT:-10}" herdr "$@" --session "$session"
}

rr_mtime() {  # <path>
  stat -c '%.9Y' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

rr_herdr_start() {  # <session>
  local session=$1 socket
  socket=$(rr_herdr "$session" session list --json 2>/dev/null \
    | jq -r --arg name "$session" '.sessions[]? | select(.name == $name) | .socket_path // empty' 2>/dev/null \
    | head -n 1)
  [ -n "$socket" ] && [ -e "$socket" ] || return 0
  rr_mtime "$socket"
}

rr_read_current() {  # <herdr-session>
  CUR_BOOT=$(rr_boot_id)
  CUR_UM=$(rr_user_manager)
  CUR_SESSION=$1
  CUR_HS=$(rr_herdr_start "$1")
}

rr_print_current() {
  printf 'boot_id=%s\nuser_manager=%s\nherdr_session=%s\nherdr_start=%s\n' \
    "$CUR_BOOT" "$CUR_UM" "$CUR_SESSION" "$CUR_HS"
}

rr_key() {
  printf '%s|%s|%s' "$CUR_BOOT" "$CUR_UM" "$CUR_HS"
}

# rr_field <text> <key>: the last <key>= value in the key=value lines of <text>.
rr_field() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -n 1
}

# rr_classify <stored-fingerprint-text>: reboot, user-manager, herdr, none, or
# no-baseline (empty text). A signal counts only when both sides read it.
rr_classify() {
  local stored=$1 boot um session hs
  [ -n "$stored" ] || { printf 'no-baseline'; return 0; }
  boot=$(rr_field "$stored" boot_id)
  um=$(rr_field "$stored" user_manager)
  session=$(rr_field "$stored" herdr_session)
  hs=$(rr_field "$stored" herdr_start)
  if [ -n "$boot" ] && [ -n "$CUR_BOOT" ] && [ "$boot" != "$CUR_BOOT" ]; then
    printf 'reboot'
  elif [ -n "$um" ] && [ -n "$CUR_UM" ] && [ "$um" != "$CUR_UM" ]; then
    printf 'user-manager'
  elif [ -n "$hs" ] && [ -n "$CUR_HS" ] && [ "$session" = "$CUR_SESSION" ] && [ "$hs" != "$CUR_HS" ]; then
    printf 'herdr'
  else
    printf 'none'
  fi
}

rr_label() {  # <class>
  case "$1" in
    reboot) printf 'machine reboot' ;;
    user-manager) printf 'user service manager restart' ;;
    herdr) printf 'Herdr server restart' ;;
    *) printf 'restart' ;;
  esac
}

rr_detail() {  # <class>
  case "$1" in
    reboot) printf 'the boot id changed' ;;
    user-manager) printf 'the user manager invocation changed, as after a logout while lingering is off' ;;
    herdr) printf "the Herdr server re-created its API socket" ;;
  esac
}

rr_write_atomic() {  # <path>: stdin becomes <path>
  local path=$1 tmp
  tmp=$(mktemp "$path.XXXXXX") || return 1
  if cat > "$tmp" && mv "$tmp" "$path"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- ledger, records, wakes ------------------------------------------------

rr_ledger() {  # <event> <key> [detail]
  local tmp
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$(printf '%s' "${3:-}" | tr '\t\n' '  ')" >> "$RR_LEDGER"
  if [ "$(wc -l < "$RR_LEDGER")" -gt 400 ]; then
    tmp=$(tail -n 200 "$RR_LEDGER") && printf '%s\n' "$tmp" | rr_write_atomic "$RR_LEDGER"
  fi
}

rr_ledger_has() {  # <event> <key>
  [ -f "$RR_LEDGER" ] || return 1
  awk -F '\t' -v e="$1" -v k="$2" '$2 == e && $3 == k { found = 1 } END { exit !found }' "$RR_LEDGER"
}

rr_ledger_count_since() {  # <event-prefix> <epoch>
  [ -f "$RR_LEDGER" ] || { printf '0'; return 0; }
  awk -F '\t' -v e="$1" -v t="$2" '$1 >= t && index($2, e) == 1 { n++ } END { print n + 0 }' "$RR_LEDGER"
}

rr_record() {  # <body>: write a pass or alert record and print its path
  local path
  mkdir -p "$RR_RECORDS" || return 1
  path="$RR_RECORDS/$(date +%s).$$.txt"
  printf '%s\n' "$1" > "$path" || return 1
  # shellcheck disable=SC2012 # record names are generated, whitespace-free
  ls -1t "$RR_RECORDS" 2>/dev/null | tail -n +21 | while IFS= read -r old; do
    rm -f "$RR_RECORDS/$old"
  done
  printf '%s' "$path"
}

rr_rel() {  # <path> relative to this home when inside it
  case "$1" in
    "$FM_HOME"/*) printf '%s' "${1#"$FM_HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# rr_alert_once <kind> <message>: one record and one wake per window.
rr_alert_once() {
  local kind=$1 message=$2 since path
  since=$(( $(date +%s) - RR_WINDOW ))
  if [ "$(rr_ledger_count_since "alert-$kind" "$since")" -gt 0 ]; then
    rr_ledger "suppressed-$kind" "$(rr_key)" "$message"
    rr_say "$message (alert already raised in this window)"
    return 0
  fi
  path=$(rr_record "restart recovery alert ($kind), $(date -u +%Y-%m-%dT%H:%M:%SZ)"$'\n'"$message") || path=
  rr_ledger "alert-$kind" "$(rr_key)" "$message"
  fm_wake_append check "restart-recovery-alert:$kind:$(date +%s)" \
    "check: restart recovery alert - $message${path:+ (record $(rr_rel "$path"))}" \
    || rr_say "could not queue the alert wake"
  rr_say "$message"
}

# --- single-flight lock ------------------------------------------------------

rr_lock_holder_is_pass() {  # <lock>
  local pid
  pid=$(cat "$1/pid" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q 'fm-local-restart-recovery' || return 1
  fi
  return 0
}

rr_pass_active() {
  local lock
  for lock in "$STATE"/.restart-recovery.*.lock; do
    [ -e "$lock" ] || [ -L "$lock" ] || continue
    rr_lock_holder_is_pass "$lock" && return 0
  done
  return 1
}

rr_prune_old_locks() {  # <current-lock>
  local lock
  for lock in "$STATE"/.restart-recovery.*.lock; do
    [ -e "$lock" ] || [ -L "$lock" ] || continue
    [ "$lock" != "$1" ] || continue
    rr_lock_holder_is_pass "$lock" && continue
    fm_lock_remove_path "$lock" || true
  done
}

rr_release() {
  [ -z "$RR_LOCK" ] || fm_lock_release "$RR_LOCK"
  RR_LOCK=
}

rr_wait_herdr() {  # <session>
  local session=$1 start running
  start=$(date +%s)
  while :; do
    running=$(rr_herdr "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = true ] && return 0
    [ $(( $(date +%s) - start )) -lt "$RR_WAIT" ] || return 1
    sleep "$RR_POLL"
  done
}

# --- record ------------------------------------------------------------------

rr_harness_name() {  # <pid>
  local comm args name
  comm=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$1" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  if [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ]; then
    printf 'claude'
    return 0
  fi
  name=$(basename -- "$comm")
  for comm in "${FM_HARNESS_NAMES[@]}"; do
    [ "$name" = "$comm" ] && { printf '%s' "$name"; return 0; }
  done
  fm_harness_path_name "${args%% *}" || printf 'unknown'
}

# rr_argv_lines <pid>: the harness command and its arguments, from the kernel.
rr_argv_lines() {
  local file="/proc/$1/cmdline" arg first=1
  [ -r "$file" ] || return 1
  while IFS= read -r -d '' arg; do
    case "$arg" in *$'\n'*|*$'\r'*) return 1 ;; esac
    if [ "$first" -eq 1 ]; then
      printf 'command=%s\n' "$arg"
      first=0
    else
      printf 'arg=%s\n' "$arg"
    fi
  done < "$file"
  [ "$first" -eq 0 ]
}

# rr_claude_session <pid>...: the session id Claude Code records for one of
# these exact processes (bound by its kernel start time) and the configuration
# directory it runs against. The transcript may not exist yet at a fresh start;
# recovery checks it before it resumes.
rr_claude_session() {
  local pid cfg record start rec_pid rec_start sid cwd
  for pid in "$@"; do
    cfg=$(fm_native_session_claude_config "$pid")
    record="$cfg/sessions/$pid.json"
    [ -f "$record" ] || continue
    start=$(fm_native_session_proc_start "$pid") || continue
    rec_pid=$(jq -r '.pid // empty' "$record" 2>/dev/null)
    rec_start=$(jq -r '.procStart // empty | tostring' "$record" 2>/dev/null)
    sid=$(jq -r '.sessionId // empty' "$record" 2>/dev/null)
    cwd=$(jq -r '.cwd // empty' "$record" 2>/dev/null)
    [ "$rec_pid" = "$pid" ] && [ -n "$rec_start" ] && [ "$rec_start" = "$start" ] || continue
    fm_native_session_is_uuid "$sid" || continue
    fm_native_session_same_dir "$cwd" "$FM_HOME" || continue
    printf 'native_session=%s\nclaude_config=%s\n' "$sid" "$cfg"
    return 0
  done
  return 1
}

rr_record_endpoint() {
  local session pane workspace label pid pids harness start
  fm_root_is_secondmate_home "$FM_HOME" && return 0
  if [ "${HERDR_ENV:-}" != 1 ] || [ -z "${HERDR_PANE_ID:-}" ]; then
    rm -f "$RR_ENDPOINT"
    return 0
  fi
  pid=$(fm_harness_ancestry_pid 2>/dev/null) || { rm -f "$RR_ENDPOINT"; return 0; }
  pids=$(fm_harness_ancestry_pids 2>/dev/null) || pids=$pid
  harness=$(rr_harness_name "$pid") || harness=unknown
  session=${HERDR_SESSION:-default}
  pane=$HERDR_PANE_ID
  workspace=${HERDR_WORKSPACE_ID:-${pane%%:*}}
  label=$(rr_herdr "$session" workspace list 2>/dev/null \
    | jq -r --arg ws "$workspace" '.result.workspaces[]? | select(.workspace_id == $ws) | .label // empty' 2>/dev/null \
    | head -n 1)
  start=$(fm_native_session_proc_start "$pid" 2>/dev/null) || start=
  {
    printf 'backend=herdr\n'
    printf 'herdr_session=%s\n' "$session"
    printf 'pane=%s\n' "$pane"
    printf 'workspace=%s\n' "$workspace"
    [ -z "$label" ] || printf 'workspace_label=%s\n' "$label"
    printf 'cwd=%s\n' "$FM_HOME"
    printf 'harness=%s\n' "$harness"
    printf 'harness_pid=%s\n' "$pid"
    printf 'harness_start=%s\n' "$start"
    printf 'boot_id=%s\n' "$CUR_BOOT"
    if [ "$harness" = claude ]; then
      # shellcheck disable=SC2086 # the ancestry is one pid per word
      rr_claude_session $pids || true
    fi
    rr_argv_lines "$pid" || true
    printf 'recorded_at=%s\n' "$(date +%s)"
  } | rr_write_atomic "$RR_ENDPOINT" || true
}

rr_pass_note() {  # <key>
  if fm_root_is_secondmate_home "$FM_HOME"; then
    printf "The primary firstmate's home runs restart recovery for second mates and keeps its ledger and pass records; this home keeps none."
  elif rr_ledger_has 'done' "$1"; then
    printf 'Restart recovery already relaunched the authorized supervisors; its record is under state/restart-recovery/.'
  elif rr_ledger_has start "$1" || rr_pass_active; then
    printf 'A restart recovery pass is relaunching the authorized supervisors; its summary arrives as a check notification.'
  else
    printf 'No restart recovery pass ran for it: check bin/fm-local-restart-recovery.sh status, and relaunch authorized second mates one at a time.'
  fi
}

cmd_record() {
  local class stored_session
  mkdir -p "$STATE" || return 0
  stored_session=${HERDR_SESSION:-default}
  rr_read_current "$stored_session"
  class=$(rr_classify "$(cat "$RR_FINGERPRINT" 2>/dev/null)")
  rr_print_current | { cat; printf 'recorded_at=%s\n' "$(date +%s)"; } | rr_write_atomic "$RR_FINGERPRINT" || true
  case "$class" in
    reboot|user-manager|herdr)
      printf 'RESTART: %s since the last session start (%s). %s\n' \
        "$(rr_label "$class")" "$(rr_detail "$class")" "$(rr_pass_note "$(rr_key)")"
      ;;
  esac
  rr_record_endpoint
  return 0
}

# --- run: second mates ---------------------------------------------------------

rr_status_boundary() {  # <id> <class>
  printf 'working: relaunched after a %s by restart recovery\n' "$(rr_label "$2")" >> "$STATE/$1.status" 2>/dev/null || true
}

rr_first_line() {
  printf '%s\n' "$1" | awk 'NF { print; exit }'
}

rr_secondmates() {  # <class>
  local class=$1 meta id reason backend target state out
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -qx 'kind=secondmate' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      rr_note "second mate $id: skipped: it runs on another host, which recovers it"
      continue
    fi
    if reason=$("$SCRIPT_DIR/fm-local-dormant.sh" is "$id" 2>/dev/null); then
      rr_note "second mate $id: left down: dormant ($reason)"
      continue
    fi
    if ! secondmate_registry_line_for_id "$DATA/secondmates.md" "$id"; then
      rr_note "second mate $id: skipped: not registered in data/secondmates.md"
      continue
    fi
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    case "$backend" in
      herdr|tmux) ;;
      *) rr_note "second mate $id: skipped: restart recovery does not relaunch on backend '$backend'"; continue ;;
    esac
    # Read right before acting, so a second mate the captain relaunched by
    # hand a moment ago reads alive and is left alone.
    state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
    case "$state" in
      alive)
        rr_note "second mate $id: already running"
        ;;
      dead)
        if out=$(FM_SPAWN_NO_GUARD=1 "$SCRIPT_DIR/fm-control.sh" "$id" relaunch 2>&1); then
          rr_status_boundary "$id" "$class"
          rr_note "second mate $id: relaunched in its pane"
        else
          rr_note "second mate $id: relaunch failed: $(rr_first_line "$out")"
        fi
        ;;
      missing)
        if out=$(FM_SPAWN_NO_GUARD=1 "$SCRIPT_DIR/fm-spawn.sh" "$id" --secondmate 2>&1); then
          rr_status_boundary "$id" "$class"
          rr_note "second mate $id: relaunched in a new pane (its pane was gone)"
        else
          rr_note "second mate $id: relaunch failed: $(rr_first_line "$out")"
        fi
        ;;
      *)
        rr_note "second mate $id: skipped: its endpoint reads $state"
        ;;
    esac
  done
}

# --- run: primary --------------------------------------------------------------

# rr_launch_args <record>: the recorded harness arguments, one per line, minus
# Claude's session selectors and an operational-input first prompt (a primary
# that an earlier pass relaunched carries one), which the relaunch sets itself.
rr_launch_args() {
  local record=$1 skip_value=0 arg
  while IFS= read -r arg; do
    if [ "$skip_value" -eq 1 ]; then
      skip_value=0
      case "$arg" in -*) ;; *) continue ;; esac
    fi
    case "$arg" in
      --resume|-r) skip_value=1 ;;
      --session-id) skip_value=1 ;;
      --resume=*|--session-id=*|--continue|-c|--fork-session) ;;
      "$FM_OPERATIONAL_PREFIX"*) ;;
      *) printf '%s\n' "$arg" ;;
    esac
  done < <(sed -n 's/^arg=//p' "$record")
}

# rr_launch_line <record> <prompt-file>: sets RR_LAUNCH_LINE to the command
# typed into the pane and RR_LAUNCH_DESC to how its session starts.
rr_launch_line() {
  local record=$1 prompt=$2 line arg cwd sid cfg file
  cwd=$(fm_meta_get "$record" cwd)
  line="cd -- $(fm_native_session_shell_quote "$cwd") &&"
  cfg=$(fm_meta_get "$record" claude_config)
  if [ -n "$cfg" ] && [ "$cfg" != "$HOME/.claude" ]; then
    line="$line CLAUDE_CONFIG_DIR=$(fm_native_session_shell_quote "$cfg")"
  fi
  line="$line claude"
  while IFS= read -r arg; do
    line="$line $(fm_native_session_shell_quote "$arg")"
  done < <(rr_launch_args "$record")
  sid=$(fm_meta_get "$record" native_session)
  RR_LAUNCH_DESC="a fresh Claude session (no session was recorded)"
  if [ -n "$sid" ]; then
    if file=$(fm_native_session_claude_transcript "${cfg:-$HOME/.claude}" "$sid") \
      && fm_native_session_locate claude "$sid" "$file" "$cwd" "${cfg:-$HOME/.claude}"; then
      line="$line --resume $(fm_native_session_shell_quote "$sid")"
      RR_LAUNCH_DESC="resuming Claude session $sid"
    else
      RR_LAUNCH_DESC="a fresh Claude session (session $sid has no transcript to resume)"
    fi
  fi
  line="$line \"\$($(fm_native_session_shell_quote "$SCRIPT_DIR/fm-operational-input.sh") encode session-start < $(fm_native_session_shell_quote "$prompt"))\""
  RR_LAUNCH_LINE=$line
}

rr_agent_state() {  # <target>
  fm_backend_agent_state herdr "$1" 2>/dev/null || printf 'unreadable'
}

rr_wait_state() {  # <target> <state> <seconds>
  local start
  start=$(date +%s)
  while :; do
    [ "$(rr_agent_state "$1")" = "$2" ] && return 0
    [ $(( $(date +%s) - start )) -lt "$3" ] || return 1
    sleep "$RR_POLL"
  done
}

# rr_new_primary_pane <record>: opens a pane in the recorded home, in a new tab
# of the recorded workspace while that workspace exists, else in a new
# workspace. Sets RR_NEW_TARGET to the pane target and RR_NEW_DESC to what it
# created.
rr_new_primary_pane() {
  local record=$1 session workspace label cwd found out ws tab pane
  RR_NEW_TARGET=
  RR_NEW_DESC=
  session=$(fm_meta_get "$record" herdr_session)
  workspace=$(fm_meta_get "$record" workspace)
  label=$(fm_meta_get "$record" workspace_label)
  label=${label:-firstmate}
  cwd=$(fm_meta_get "$record" cwd)
  found=$(rr_herdr "$session" workspace list 2>/dev/null \
    | jq -r --arg ws "$workspace" '.result.workspaces | if type == "array" then any(.[]; .workspace_id == $ws) else empty end' 2>/dev/null)
  case "$found" in true|false) ;; *) return 1 ;; esac
  if [ "$found" = true ]; then
    out=$(rr_herdr "$session" tab create --workspace "$workspace" --cwd "$cwd" --label firstmate --no-focus 2>/dev/null) || return 1
  else
    out=$(rr_herdr "$session" workspace create --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  fi
  pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id // empty' 2>/dev/null) || return 1
  tab=$(printf '%s' "$out" | jq -r '.result.root_pane.tab_id // "unknown"' 2>/dev/null)
  ws=$(printf '%s' "$out" | jq -r '.result.root_pane.workspace_id // "unknown"' 2>/dev/null)
  RR_NEW_TARGET="$session:$pane"
  if [ "$found" = true ]; then
    RR_NEW_DESC="a new tab $tab in the recorded workspace $ws, pane $RR_NEW_TARGET"
  else
    RR_NEW_DESC="a new workspace $ws labeled '$label' (the recorded workspace $workspace is gone), pane $RR_NEW_TARGET"
  fi
}

# rr_primary_running <cleared-pid>: prints what shows that a primary already
# runs outside the pane recovery would use: a live session holding the fleet
# lock (other than <cleared-pid>, the lock of an earlier boot that recovery
# cleared), or a live Claude harness whose working directory is this home and
# that started at or after the current Herdr server start. An older one outlived
# a Herdr-only restart as an orphan and is not a manual relaunch.
rr_primary_running() {
  local cleared=$1 lock_pid home since boot_time tick dir pid start comm args
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  if [ -n "$lock_pid" ] && [ "$lock_pid" != "$cleared" ] && fm_harness_pid_alive "$lock_pid"; then
    printf 'a live session holds the fleet lock, pid %s' "$lock_pid"
    return 0
  fi
  [ -d /proc/self ] || return 1
  home=$(fm_native_session_realpath "$FM_HOME") || return 1
  since=${CUR_HS%%.*}
  boot_time=$(awk '$1 == "btime" { print $2 }' /proc/stat 2>/dev/null)
  tick=$(getconf CLK_TCK 2>/dev/null) || tick=100
  case "$since" in *[!0-9]*) since= ;; esac
  case "$boot_time" in ''|*[!0-9]*) since= ;; esac
  case "$tick" in ''|0|*[!0-9]*) since= ;; esac
  for dir in /proc/[0-9]*; do
    [ "$(readlink "$dir/cwd" 2>/dev/null)" = "$home" ] || continue
    pid=${dir#/proc/}
    if [ -n "$since" ]; then
      start=$(fm_native_session_proc_start "$pid") || continue
      case "$start" in ''|*[!0-9]*) continue ;; esac
      [ $(( boot_time + start / tick )) -ge "$since" ] || continue
    fi
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args" && [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ]; then
      printf 'a Claude process runs in this home, pid %s' "$pid"
      return 0
    fi
  done
  return 1
}

rr_primary() {
  local record=$RR_ENDPOINT harness lock_pid cleared='' running target where state seen cwd prompt line
  if [ ! -f "$record" ]; then
    rr_note "primary firstmate: not relaunched: no primary endpoint is recorded (a locked session start inside a Herdr pane records it)"
    return 0
  fi
  if [ "$(fm_meta_get "$record" backend)" != herdr ]; then
    rr_note "primary firstmate: not relaunched: it was not recorded in a Herdr pane"
    return 0
  fi
  harness=$(fm_meta_get "$record" harness)
  if [ "$harness" != claude ]; then
    rr_note "primary firstmate: not relaunched: restart recovery relaunches only a Claude primary, and this one ran '$harness'"
    return 0
  fi
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  if [ -n "$lock_pid" ] && fm_harness_pid_alive "$lock_pid" \
    && [ "$lock_pid" = "$(fm_meta_get "$record" harness_pid)" ] \
    && [ -n "$CUR_BOOT" ] && [ "$(fm_meta_get "$record" boot_id)" != "$CUR_BOOT" ]; then
    # The lock names the primary of an earlier boot, and a new process now
    # has its pid. Clear it so the relaunched primary can take the helm.
    rm -f "$STATE/.lock"
    cleared=$lock_pid
    rr_say "cleared a session lock whose pid belonged to the primary of an earlier boot"
  fi
  if running=$(rr_primary_running "$cleared"); then
    rr_note "primary firstmate: already running ($running)"
    return 0
  fi
  cwd=$(fm_meta_get "$record" cwd)
  target="$(fm_meta_get "$record" herdr_session):$(fm_meta_get "$record" pane)"
  where="pane $target"
  state=$(rr_agent_state "$target")
  case "$state" in
    alive)
      rr_note "primary firstmate: already running in its pane $target"
      return 0
      ;;
    dead)
      seen=$(fm_backend_current_path herdr "$target" 2>/dev/null || true)
      if [ -z "$seen" ] || ! fm_native_session_same_dir "$seen" "$cwd"; then
        rr_note "primary firstmate: not relaunched: its pane $target sits in '${seen:-unknown}', not $cwd"
        return 0
      fi
      ;;
    missing)
      rr_new_primary_pane "$record" || {
        rr_note "primary firstmate: not relaunched: its pane $target is gone and a new one could not be opened"
        return 0
      }
      target=$RR_NEW_TARGET
      where=$RR_NEW_DESC
      rr_wait_state "$target" dead 15 || {
        rr_note "primary firstmate: not relaunched: it opened $where, which did not settle to a shell"
        return 0
      }
      ;;
    *)
      rr_note "primary firstmate: not relaunched: its pane $target reads $state"
      return 0
      ;;
  esac
  prompt="$STATE/.restart-recovery.prompt"
  printf '%s\n' "$RR_SESSION_START_BODY" > "$prompt" || {
    rr_note "primary firstmate: not relaunched: could not write its first prompt"
    return 0
  }
  rr_launch_line "$record" "$prompt"
  line=$RR_LAUNCH_LINE
  # One last read: a captain who started firstmate by hand while the second
  # mates came back owns this pane now, or runs the primary in another one.
  if [ "$(rr_agent_state "$target")" = alive ]; then
    rr_note "primary firstmate: already running in $where"
    return 0
  fi
  if running=$(rr_primary_running "$cleared"); then
    rr_note "primary firstmate: already running ($running); nothing was typed into $where"
    return 0
  fi
  if ! fm_backend_source herdr || ! fm_backend_herdr_send_text_line "$target" "$line"; then
    rr_note "primary firstmate: relaunch failed: the launch could not be typed into $where"
    return 0
  fi
  if rr_wait_state "$target" alive "$RR_LAUNCH_WAIT"; then
    rr_note "primary firstmate: relaunched in $where, $RR_LAUNCH_DESC"
  else
    rr_note "primary firstmate: relaunch unconfirmed: no agent started in $where within ${RR_LAUNCH_WAIT}s ($RR_LAUNCH_DESC)"
  fi
}

# --- run -----------------------------------------------------------------------

rr_pass() {  # <class> <key>
  local class=$1 key=$2 body note path relaunched=0 down=0 failed=0 summary primary
  rr_ledger start "$key" "$class"
  rr_say "restart recovery after $(rr_label "$class") ($(rr_detail "$class"))"
  rr_secondmates "$class"
  rr_primary
  [ ! -e "$STATE/.afk" ] \
    || rr_note "away mode: state/.afk survived the restart; the relaunched firstmate re-enters it"
  rr_note "crews: not relaunched by this pass; firstmate reconciles them after its session start"
  body="restart recovery after $(rr_label "$class") ($(rr_detail "$class")), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  primary="not relaunched"
  for note in ${RR_NOTES[@]+"${RR_NOTES[@]}"}; do
    body="$body"$'\n'"- $note"
    case "$note" in
      "second mate "*": relaunched"*) relaunched=$((relaunched + 1)) ;;
      "second mate "*": left down"*) down=$((down + 1)) ;;
      "second mate "*"failed"*) failed=$((failed + 1)) ;;
      "primary firstmate: relaunched"*) primary=relaunched ;;
      "primary firstmate: already running"*) primary="already running" ;;
      "primary firstmate: relaunch"*) primary="relaunch failed or unconfirmed" ;;
    esac
  done
  path=$(rr_record "$body") || path=
  summary="firstmate $primary; second mates relaunched $relaunched, left down $down, failed $failed"
  fm_wake_append check "restart-recovery:$(date +%s)" \
    "check: restart recovery after $(rr_label "$class"): $summary${path:+; record $(rr_rel "$path")}" \
    || rr_say "could not queue the summary wake"
  rr_ledger 'done' "$key" "$summary"
  rr_say "restart recovery after $(rr_label "$class") finished: $summary"
}

cmd_run() {
  local boot baseline class key session since
  mkdir -p "$STATE" || { rr_say "cannot create $STATE"; return 1; }
  boot=$(rr_boot_id)
  RR_LOCK="$STATE/.restart-recovery.${boot:-unknown}.lock"
  rr_prune_old_locks "$RR_LOCK"
  if ! fm_lock_try_acquire "$RR_LOCK"; then
    RR_LOCK=
    rr_say "another restart recovery pass is running (pid ${FM_LOCK_HELD_PID:-unknown}); leaving this restart to it"
    return 0
  fi
  trap rr_release EXIT
  trap 'exit 1' HUP INT TERM
  baseline=$(cat "$RR_FINGERPRINT" 2>/dev/null)
  session=$(rr_field "$baseline" herdr_session)
  [ -n "$session" ] || session=$(fm_meta_get "$RR_ENDPOINT" herdr_session)
  [ -n "$session" ] || session=default
  if ! rr_wait_herdr "$session"; then
    CUR_BOOT=$boot
    rr_alert_once herdr-unavailable "Herdr did not answer for session '$session' within ${RR_WAIT}s, so nothing was relaunched; start Herdr, then run bin/fm-local-restart-recovery.sh run"
    return 4
  fi
  rr_read_current "$session"
  class=$(rr_classify "$baseline")
  case "$class" in
    no-baseline)
      rr_say "no restart baseline: no locked session start has recorded one, so nothing is known to relaunch"
      return 0
      ;;
    none)
      rr_say "no restart since the last session start; nothing to relaunch"
      return 0
      ;;
  esac
  key=$(rr_key)
  if rr_ledger_has 'done' "$key"; then
    rr_say "this $(rr_label "$class") was already recovered"
    return 0
  fi
  since=$(( $(date +%s) - RR_WINDOW ))
  if [ "$(rr_ledger_count_since start "$since")" -ge "$RR_MAX_PASSES" ]; then
    rr_alert_once rate-limit "restart recovery hit its rate limit ($RR_MAX_PASSES passes in ${RR_WINDOW}s), so the $(rr_label "$class") was not recovered; the host may be in a restart loop: inspect it, then relaunch by hand"
    rr_ledger rate-limited "$key" "$class"
    return 3
  fi
  rr_pass "$class" "$key"
  return 0
}

cmd_liveness_skip() {
  local id=${1:-} reason
  [ -n "$id" ] || return 1
  if reason=$("$SCRIPT_DIR/fm-local-dormant.sh" is "$id" 2>/dev/null); then
    [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] \
      || printf 'BOOTSTRAP_INFO: secondmate %s left down: dormant (%s)\n' "$id" "$reason"
    return 0
  fi
  if rr_pass_active; then
    printf 'BOOTSTRAP_INFO: secondmate %s left to the running restart recovery pass\n' "$id"
    return 0
  fi
  return 1
}

cmd_status() {
  local newest
  printf 'ledger (%s):\n' "$(rr_rel "$RR_LEDGER")"
  if [ -f "$RR_LEDGER" ]; then
    tail -n 20 "$RR_LEDGER" | awk -F '\t' '{ printf "  %s  %s  %s\n", $1, $2, $4 }'
  else
    printf '  (empty)\n'
  fi
  # shellcheck disable=SC2012 # record names are generated, whitespace-free
  newest=$(ls -1t "$RR_RECORDS" 2>/dev/null | head -n 1)
  if [ -n "$newest" ]; then
    printf 'newest record (%s):\n' "$(rr_rel "$RR_RECORDS/$newest")"
    sed 's/^/  /' "$RR_RECORDS/$newest"
  fi
  if rr_pass_active; then
    printf 'a recovery pass is running now\n'
  fi
}

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  record) cmd_record ;;
  fingerprint)
    RR_FP_SESSION=$(fm_meta_get "$RR_FINGERPRINT" herdr_session)
    rr_read_current "${RR_FP_SESSION:-${HERDR_SESSION:-default}}"
    rr_print_current
    ;;
  run) cmd_run ;;
  liveness-skip) shift; cmd_liveness_skip "$@" ;;
  status) cmd_status ;;
  launch-line)
    [ -f "$RR_ENDPOINT" ] || { rr_say "no primary endpoint is recorded"; exit 1; }
    rr_launch_line "$RR_ENDPOINT" "$STATE/.restart-recovery.prompt"
    printf '%s\n' "$RR_LAUNCH_LINE"
    rr_say "$RR_LAUNCH_DESC" >&2
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
