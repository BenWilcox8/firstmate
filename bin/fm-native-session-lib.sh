#!/usr/bin/env bash
# fm-native-session-lib.sh - the ONE owner of a worker agent's NATIVE session
# identity: which harnesses firstmate can prove a resumable session for, how
# that proof is read from the running worker, how a recorded session is found
# again before a resume, and the launch arguments that resume it.
#
# A park (bin/fm-control.sh <id> park) records this identity so the same
# conversation can continue later with no information loss. A wrong id is worse
# than none - it resumes some other conversation, or silently starts a fresh
# one - so every function here proves what it reports from structural evidence
# the harness itself keeps, and refuses rather than guesses:
#
#   claude     Claude Code keeps one record per live process at
#              <config>/sessions/<pid>.json naming its sessionId, cwd, and the
#              kernel start time of that process (procStart). The capture binds
#              the record to the exact running process by comparing procStart
#              with field 22 of /proc/<pid>/stat, so a record left behind by a
#              dead process whose pid was reused can never match. <config> is
#              the CLAUDE_CONFIG_DIR in the process's own environment, else
#              $HOME/.claude. The session file is the transcript
#              <config>/projects/*/<sessionId>.jsonl, found by exact name.
#              Resume: claude --resume <sessionId>.
#   codex      The codex process holds its rollout file
#              (.../sessions/**/rollout-<ts>-<uuid>.jsonl) and its thread lock
#              (.../thread-writer-locks/<uuid>.lock) open for the life of the
#              session; /proc/<pid>/fd names both. Exactly one rollout must be
#              open, every open lock must agree with it, and the rollout's
#              session_meta header must carry the same id and the worktree as
#              its cwd. A session with no rollout yet (no completed turn) is
#              not resumable and refuses. Resume: codex resume <uuid>.
#   pi         Pi keeps no session file open, so the proof comes from Pi
#   pi-signed  itself: the Firstmate worker extension (written by
#              bin/fm-spawn.sh) records ctx.sessionManager's session id and
#              file on every session_start into state/<id>.pi-session, tagged
#              with the incarnation's busy generation. The record must belong
#              to the current incarnation, and the session file's header must
#              carry the same id and the worktree as its cwd.
#              Resume: pi --session <session-file>.
#
# Every other harness has no verified native session contract and refuses.
# The proofs read Linux /proc; a host without it refuses rather than guessing.
#
# Results are returned through globals so callers need no output parsing:
#   FM_NATIVE_SESSION_ID      the proven session id
#   FM_NATIVE_SESSION_FILE    the file that proves it and that a resume needs
#   FM_NATIVE_SESSION_REASON  why a capture or locate refused
#
# FM_NATIVE_SESSION_PROC overrides /proc for tests only.

FM_NATIVE_SESSION_PROC=${FM_NATIVE_SESSION_PROC:-/proc}
FM_NATIVE_SESSION_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# The harnesses with a verified native session capture and resume.
fm_native_session_supported() {  # <harness>
  case "${1-}" in
    claude|codex|pi|pi-signed) return 0 ;;
  esac
  return 1
}

fm_native_session_refuse() {  # <reason>
  # shellcheck disable=SC2034 # Output global consumed by sourcing callers.
  FM_NATIVE_SESSION_REASON=$1
  return 1
}

fm_native_session_reset() {
  FM_NATIVE_SESSION_ID=
  FM_NATIVE_SESSION_FILE=
  # shellcheck disable=SC2034 # Output global consumed by sourcing callers.
  FM_NATIVE_SESSION_REASON=
}

fm_native_session_is_uuid() {  # <value>
  printf '%s' "${1-}" | grep -Eq "$FM_NATIVE_SESSION_UUID_RE"
}

fm_native_session_realpath() {  # <path>
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

fm_native_session_same_dir() {  # <a> <b>
  local a b
  a=$(fm_native_session_realpath "$1") || return 1
  b=$(fm_native_session_realpath "$2") || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# The kernel start time of <pid>: field 22 of /proc/<pid>/stat, parsed after
# the last ')' because the command name may itself contain spaces or parens.
fm_native_session_proc_start() {  # <pid>
  local stat rest
  stat=$(cat "$FM_NATIVE_SESSION_PROC/$1/stat" 2>/dev/null) || return 1
  rest=${stat##*) }
  [ "$rest" != "$stat" ] || return 1
  # shellcheck disable=SC2086 # Deliberate word split of the numeric fields.
  set -- $rest
  [ -n "${20:-}" ] || return 1
  printf '%s' "${20}"
}

# One variable from <pid>'s own environment, as the kernel recorded it at exec.
fm_native_session_proc_env() {  # <pid> <name>
  tr '\0' '\n' < "$FM_NATIVE_SESSION_PROC/$1/environ" 2>/dev/null \
    | sed -n "s/^$2=//p" | head -n 1
}

# The Claude config directory <pid> runs against.
fm_native_session_claude_config() {  # <pid>
  local cfg home
  cfg=$(fm_native_session_proc_env "$1" CLAUDE_CONFIG_DIR)
  if [ -z "$cfg" ]; then
    home=$(fm_native_session_proc_env "$1" HOME)
    [ -n "$home" ] || home=$HOME
    cfg="$home/.claude"
  fi
  printf '%s' "$cfg"
}

# The one transcript of <session-id> under <config>, by exact file name.
fm_native_session_claude_transcript() {  # <config> <session-id>
  local found=() path
  for path in "$1"/projects/*/"$2".jsonl; do
    [ -f "$path" ] && [ -s "$path" ] && found+=("$path")
  done
  [ "${#found[@]}" -eq 1 ] || return 1
  printf '%s' "${found[0]}"
}

fm_native_session_capture_claude() {  # <worktree> <pid>...
  local wt=$1 pid cfg record start rec_pid rec_start rec_sid rec_cwd sid='' file='' seen=0
  shift
  for pid in "$@"; do
    cfg=$(fm_native_session_claude_config "$pid")
    record="$cfg/sessions/$pid.json"
    [ -f "$record" ] || continue
    seen=1
    start=$(fm_native_session_proc_start "$pid") \
      || fm_native_session_refuse "the start time of claude process $pid cannot be read, so its session record cannot be bound to it" || return 1
    rec_pid=$(jq -r '.pid // empty' "$record" 2>/dev/null)
    rec_start=$(jq -r '.procStart // empty | tostring' "$record" 2>/dev/null)
    rec_sid=$(jq -r '.sessionId // empty' "$record" 2>/dev/null)
    rec_cwd=$(jq -r '.cwd // empty' "$record" 2>/dev/null)
    [ "$rec_pid" = "$pid" ] && [ -n "$rec_start" ] && [ "$rec_start" = "$start" ] \
      || fm_native_session_refuse "claude session record $record does not belong to the running process $pid (a record left by an earlier process with the same pid)" || return 1
    fm_native_session_is_uuid "$rec_sid" \
      || fm_native_session_refuse "claude session record $record names no valid session id" || return 1
    fm_native_session_same_dir "$rec_cwd" "$wt" \
      || fm_native_session_refuse "claude process $pid runs in '${rec_cwd:-unknown}', not the task worktree $wt" || return 1
    if [ -n "$sid" ] && [ "$sid" != "$rec_sid" ]; then
      fm_native_session_refuse "more than one claude session runs in this endpoint ($sid and $rec_sid); refusing to choose one"
      return 1
    fi
    sid=$rec_sid
    file=$(fm_native_session_claude_transcript "$cfg" "$sid") \
      || fm_native_session_refuse "claude session $sid has no single saved transcript under $cfg/projects, so it cannot be resumed" || return 1
  done
  [ "$seen" = 1 ] \
    || fm_native_session_refuse "no running claude process in this endpoint has a session record" || return 1
  FM_NATIVE_SESSION_ID=$sid
  FM_NATIVE_SESSION_FILE=$file
}

# The session id a codex rollout or thread-lock path names, or nothing.
fm_native_session_codex_path_id() {  # <path>
  local base=${1##*/} id
  case "$1" in
    */sessions/*/rollout-*.jsonl) id=${base%.jsonl} ;;
    */thread-writer-locks/*.lock) id=${base%.lock} ;;
    *) return 1 ;;
  esac
  id=${id: -36}
  fm_native_session_is_uuid "$id" || return 1
  printf '%s' "$id"
}

# fm_native_session_codex_header_ok: the rollout's first line is its
# session_meta and names <id> with <worktree> as its cwd. Prints a refusal
# fragment on mismatch.
fm_native_session_codex_header_ok() {  # <rollout> <id> <worktree>
  local rollout=$1 id=$2 wt=$3 header_id header_cwd
  header_id=$(head -n 1 "$rollout" 2>/dev/null | jq -r 'select(.type == "session_meta") | .payload.id // empty' 2>/dev/null)
  [ "$header_id" = "$id" ] \
    || fm_native_session_refuse "codex rollout $rollout has a header naming '${header_id:-no session}', not $id" || return 1
  header_cwd=$(head -n 1 "$rollout" 2>/dev/null | jq -r '.payload.cwd // empty' 2>/dev/null)
  fm_native_session_same_dir "$header_cwd" "$wt" \
    || fm_native_session_refuse "codex session $id ran in '${header_cwd:-unknown}', not the task worktree $wt" || return 1
}

fm_native_session_capture_codex() {  # <worktree> <pid>...
  local wt=$1 pid fd target id rollout_id='' rollout='' lock_ids=''
  shift
  for pid in "$@"; do
    for fd in "$FM_NATIVE_SESSION_PROC/$pid/fd"/*; do
      target=$(readlink "$fd" 2>/dev/null) || continue
      id=$(fm_native_session_codex_path_id "$target") || continue
      case "$target" in
        *.jsonl)
          if [ -n "$rollout_id" ] && [ "$rollout_id" != "$id" ]; then
            fm_native_session_refuse "more than one codex rollout is open in this endpoint ($rollout_id and $id); refusing to choose one"
            return 1
          fi
          rollout_id=$id
          rollout=$target
          ;;
        *.lock) lock_ids="$lock_ids $id" ;;
      esac
    done
  done
  [ -n "$rollout_id" ] \
    || fm_native_session_refuse "the running codex session has no saved rollout yet (no completed turn), so it cannot be resumed" || return 1
  for id in $lock_ids; do
    [ "$id" = "$rollout_id" ] \
      || fm_native_session_refuse "codex's open thread lock ($id) and rollout ($rollout_id) disagree about the running session" || return 1
  done
  [ -f "$rollout" ] \
    || fm_native_session_refuse "codex rollout $rollout is open but no longer on disk" || return 1
  fm_native_session_codex_header_ok "$rollout" "$rollout_id" "$wt" || return 1
  FM_NATIVE_SESSION_ID=$rollout_id
  FM_NATIVE_SESSION_FILE=$rollout
}

# fm_native_session_pi_header_ok: the Pi session file's first line is its
# session header and names <id> with <worktree> as its cwd.
fm_native_session_pi_header_ok() {  # <file> <id> <worktree>
  local file=$1 id=$2 wt=$3 header_id header_cwd
  header_id=$(head -n 1 "$file" 2>/dev/null | jq -r 'select(.type == "session") | .id // empty' 2>/dev/null)
  [ "$header_id" = "$id" ] \
    || fm_native_session_refuse "pi session file $file has a header naming '${header_id:-no session}', not $id" || return 1
  header_cwd=$(head -n 1 "$file" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null)
  fm_native_session_same_dir "$header_cwd" "$wt" \
    || fm_native_session_refuse "pi session $id ran in '${header_cwd:-unknown}', not the task worktree $wt" || return 1
}

fm_native_session_capture_pi() {  # <worktree> <state> <id> <gen>
  local wt=$1 state=$2 id=$3 gen=$4 record rec_gen rec_id rec_file
  [ -n "$state" ] && [ -n "$id" ] && [ -n "$gen" ] \
    || fm_native_session_refuse "a pi capture needs the task's state directory, id, and busy generation to find its extension record" || return 1
  record="$state/$id.pi-session"
  [ -f "$record" ] \
    || fm_native_session_refuse "the pi worker's extension left no session record at $record (a worker launched before session recording existed cannot be parked)" || return 1
  rec_gen=$(jq -r '.gen // empty' "$record" 2>/dev/null)
  rec_id=$(jq -r '.id // empty' "$record" 2>/dev/null)
  rec_file=$(jq -r '.file // empty' "$record" 2>/dev/null)
  [ "$rec_gen" = "$gen" ] \
    || fm_native_session_refuse "the pi session record at $record belongs to an earlier incarnation (generation '${rec_gen:-none}', current '$gen')" || return 1
  fm_native_session_is_uuid "$rec_id" \
    || fm_native_session_refuse "the pi session record at $record names no valid session id" || return 1
  [ -n "$rec_file" ] && [ -f "$rec_file" ] \
    || fm_native_session_refuse "pi session $rec_id's file '${rec_file:-none}' is not on disk, so it cannot be resumed" || return 1
  fm_native_session_pi_header_ok "$rec_file" "$rec_id" "$wt" || return 1
  FM_NATIVE_SESSION_ID=$rec_id
  FM_NATIVE_SESSION_FILE=$rec_file
}

# fm_native_session_capture: prove the native session of the agent running as
# <pid>... (the endpoint's foreground processes) in <worktree>. <state>, <id>,
# and <gen> locate and authenticate an extension-written record for adapters
# whose proof comes from one; other adapters ignore them.
fm_native_session_capture() {  # <harness> <worktree> <state> <id> <gen> <pid>...
  local harness=$1 wt=$2 state=$3 id=$4 gen=$5
  shift 5
  fm_native_session_reset
  fm_native_session_supported "$harness" \
    || fm_native_session_refuse "harness '$harness' has no verified native session capture" || return 1
  [ -r "$FM_NATIVE_SESSION_PROC/self/stat" ] \
    || fm_native_session_refuse "this host has no /proc, so no running session can be proven" || return 1
  [ -n "$wt" ] && [ -d "$wt" ] \
    || fm_native_session_refuse "the task worktree '${wt:-none}' is missing" || return 1
  [ "$#" -gt 0 ] \
    || fm_native_session_refuse "no process was found in the endpoint to read a session from" || return 1
  case "$harness" in
    claude) fm_native_session_capture_claude "$wt" "$@" ;;
    codex) fm_native_session_capture_codex "$wt" "$@" ;;
    pi|pi-signed) fm_native_session_capture_pi "$wt" "$state" "$id" "$gen" ;;
  esac
}

# fm_native_session_locate: confirm a RECORDED session can still be resumed
# before anything changes for the resume. Its file must exist, lie where the
# resume will look for it, and still name the recorded session. A missing or
# disagreeing file refuses by name: a resume never falls back to a fresh
# session. <claude-config> is the Claude configuration the resume will launch
# against; a claude transcript outside it would be invisible to `--resume`.
fm_native_session_locate() {  # <harness> <session-id> <file> <worktree> [<claude-config>]
  local harness=$1 sid=$2 file=$3 wt=$4 cfg=${5:-} cfg_real file_dir
  fm_native_session_reset
  fm_native_session_supported "$harness" \
    || fm_native_session_refuse "harness '$harness' has no verified native session resume" || return 1
  fm_native_session_is_uuid "$sid" \
    || fm_native_session_refuse "the recorded session '$sid' is not a valid session id" || return 1
  [ -n "$file" ] && [ -f "$file" ] && [ -s "$file" ] \
    || fm_native_session_refuse "the recorded $harness session $sid's file '${file:-none}' is missing, so the session cannot be resumed" || return 1
  case "$harness" in
    claude)
      [ "${file##*/}" = "$sid.jsonl" ] \
        || fm_native_session_refuse "the recorded claude transcript $file does not name session $sid" || return 1
      if [ -n "$cfg" ]; then
        cfg_real=$(fm_native_session_realpath "$cfg/projects") || cfg_real=
        file_dir=$(fm_native_session_realpath "${file%/*}/..") || file_dir=
        [ -n "$cfg_real" ] && [ "$file_dir" = "$cfg_real" ] \
          || fm_native_session_refuse "the recorded claude transcript $file is not under $cfg/projects, the configuration the resume would launch with" || return 1
      fi
      ;;
    codex) fm_native_session_codex_header_ok "$file" "$sid" "$wt" || return 1 ;;
    pi|pi-signed) fm_native_session_pi_header_ok "$file" "$sid" "$wt" || return 1 ;;
  esac
  FM_NATIVE_SESSION_ID=$sid
  FM_NATIVE_SESSION_FILE=$file
}

fm_native_session_shell_quote() {  # <value>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# fm_native_session_resume_launch: turn a harness's verified fresh-launch
# TEMPLATE (bin/fm-spawn.sh's launch_template, before placeholder substitution)
# into the launch that reopens exactly <session-id>, keeping every fleet flag.
# Every verified template ends with the launch-brief argument; the resume
# replaces exactly that argument, and codex also gains its `resume` subcommand.
# A template of any other shape refuses rather than being guessed at.
fm_native_session_resume_launch() {  # <harness> <template> <session-id> <file>
  local harness=$1 launch=$2 sid=$3 file=$4 brief args
  # shellcheck disable=SC2016 # The launch-brief argument is literal template text.
  brief='"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  case "$launch" in
    *"$brief") launch=${launch%"$brief"} ;;
    *) echo "error: the $harness launch does not end with its launch-brief argument, so its resume form cannot be built" >&2; return 1 ;;
  esac
  case "$harness" in
    claude) args="--resume $(fm_native_session_shell_quote "$sid")" ;;
    codex)
      case "$launch" in
        'codex '*) launch="codex resume ${launch#codex }" ;;
        *) echo "error: the codex launch does not start with the codex command, so its resume form cannot be built" >&2; return 1 ;;
      esac
      args=$(fm_native_session_shell_quote "$sid")
      ;;
    pi|pi-signed) args="--session $(fm_native_session_shell_quote "$file")" ;;
    *) echo "error: harness '$harness' has no verified native session resume" >&2; return 1 ;;
  esac
  printf '%s%s' "$launch" "$args"
}
