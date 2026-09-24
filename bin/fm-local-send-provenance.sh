#!/usr/bin/env bash
# Typed-send attribution. bin/fm-local-hooks.sh routes the provenance-* hooks here.
# fm_local_provenance_init [mode] [state] enables recording for this process.
# The mode is send (fm-send), re-ring (the watcher), or the delivery kind of a
# caller that types one kind only: exit-command (fm-control) or
# supervision-digest (the away-mode daemon). The state overrides the home state.
# fm_local_provenance_launch <backend> <target> <task> <launch> <brief> records the
# launch prompt that fm-spawn typed, then records later typings as launch prompts.
# fm_local_provenance_typed <backend> <target> <text> observes successful literal typing.
# fm_local_provenance_remote_sent records a remote steer in the sending home.
# fm_local_provenance_prune <state> expires old shards during task teardown.
# The writer owns storage mechanics. docs/local/send-provenance.schema.json
# owns the record format and the dashboard reader contract.

fm_local_provenance_state() {
  printf '%s' "${FM_LOCAL_PROVENANCE_STATE:-${STATE:-$FM_HOME/state}}"
}

fm_local_provenance_record() {  # <text> <backend> <target> <pane> <task> <remote-host> <kind>
  printf '%s' "$1" | perl "$FM_BACKEND_LIB_DIR/fm-local-send-provenance.pl" record \
    "$(fm_local_provenance_state)" "$2" "$3" "$4" "$5" "$6" "$FM_LOCAL_PROVENANCE_SENDER" "$7" \
    || printf 'warning: typed-send provenance could not be recorded; do not resend the text\n' >&2
}

fm_local_provenance_endpoint() {  # <text> <backend> <target> <task> <kind>
  local pane=${3##*:}
  if [ "$2" = tmux ]; then
    pane=$(tmux display-message -p -t "$3" '#{pane_id}' 2>/dev/null) || pane=''
  fi
  fm_local_provenance_record "$1" "$2" "$3" "$pane" "$4" '' "$5"
}

fm_local_provenance_init() {  # [mode] [state]
  FM_LOCAL_PROVENANCE_ACTIVE=1
  FM_LOCAL_PROVENANCE_MODE=${1:-send}
  FM_LOCAL_PROVENANCE_STATE=${2:-}
  FM_LOCAL_PROVENANCE_SENDER=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || FM_LOCAL_PROVENANCE_SENDER=$FM_HOME
}

# A launch prompt rides the typed launch line as a command substitution. The
# record hashes the prompt that the agent receives, not the shell line. A launch
# without the brief (a pointer harness or a resume) records nothing here.
fm_local_provenance_launch() {  # <backend> <target> <task> <launch> <brief>
  local prompt
  fm_local_provenance_init launch-prompt
  FM_LOCAL_PROVENANCE_TASK=$3
  case "$4" in *'encode launch-brief <'*) ;; *) return 0 ;; esac
  prompt=$("${FM_ROOT:-$FM_BACKEND_LIB_DIR/..}/bin/fm-operational-input.sh" encode launch-brief < "$5") || {
    printf 'warning: typed-send provenance could not be recorded; do not resend the text\n' >&2
    return 0
  }
  fm_local_provenance_endpoint "$prompt" "$1" "$2" "$3" launch-prompt
}

fm_local_provenance_typed() {  # <backend> <target> <text>
  [ "${FM_LOCAL_PROVENANCE_ACTIVE:-0}" = 1 ] || return 0
  local backend=$1 target=$2 text=$3 meta='' task=${FM_LOCAL_PROVENANCE_TASK:-} kind
  case "$FM_LOCAL_PROVENANCE_MODE" in
    send)
      meta=${TARGET_META:-}
      if [ "${INBOX_PLANE:-0}" = 1 ]; then
        kind=doorbell
      elif [ -n "${TARGET_SELECTOR:-}" ]; then
        kind=native-skill
      else
        kind=explicit-endpoint
      fi
      ;;
    re-ring) kind=doorbell ;;
    *) kind=$FM_LOCAL_PROVENANCE_MODE ;;
  esac
  if [ -z "$task" ] && [ "$FM_LOCAL_PROVENANCE_MODE" != send ]; then
    meta=$(fm_backend_meta_for_window "$target" "$(fm_local_provenance_state)" 2>/dev/null) || meta=''
  fi
  if [ -n "$meta" ]; then
    task=${meta##*/}
    task=${task%.meta}
  fi
  fm_local_provenance_endpoint "$text" "$backend" "$target" "$task" "$kind"
}

fm_local_provenance_remote_sent() {
  [ "${FM_LOCAL_PROVENANCE_ACTIVE:-0}" = 1 ] || return 0
  [ "${remote_rc:-1}" -eq 0 ] || [ "${remote_completion_unknown:-0}" -eq 1 ] || return 0
  local home target line
  home=$(fm_meta_get "$TARGET_META" home)
  target=$(fm_meta_get "$TARGET_META" remote_target)
  line=$(fm_task_inbox_doorbell_line "$home/state/parent-route/$TARGET_REMOTE_ID.inbox/.msg") || {
    printf 'warning: typed-send provenance could not be recorded; do not resend the text\n' >&2
    return 0
  }
  fm_local_provenance_record "$line" "$(fm_meta_get "$TARGET_META" remote_backend)" "$target" \
    "${target##*:}" "$TARGET_REMOTE_ID" "$TARGET_REMOTE_HOST" doorbell
}

fm_local_provenance_prune() {  # <state>
  perl "$FM_BACKEND_LIB_DIR/fm-local-send-provenance.pl" prune "$1" \
    || printf 'warning: expired typed-send provenance could not be removed\n' >&2
  return 0
}
