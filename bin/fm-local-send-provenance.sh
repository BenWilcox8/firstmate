#!/usr/bin/env bash
# Fork hooks for typed-send attribution. Source this file without arguments.
# fm_local_hook init [re-ring] enables recording in fm-send or the watcher.
# fm_local_hook typed <backend> <target> <text> observes successful literal typing.
# fm_local_hook remote-sent records a remote steer in the sending home.
# fm_local_hook prune <state> expires old shards during task teardown.
# The writer owns storage mechanics. docs/local/send-provenance.schema.json
# owns the record format and the dashboard reader contract.

FM_LOCAL_PROVENANCE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_local_provenance_record() {  # <text> <backend> <target> <pane> <task> <remote-host> <kind>
  printf '%s' "$1" | perl "$FM_LOCAL_PROVENANCE_BIN/fm-local-send-provenance.pl" record \
    "${STATE:-$FM_HOME/state}" "$2" "$3" "$4" "$5" "$6" "$FM_LOCAL_PROVENANCE_SENDER" "$7" \
    || printf 'warning: typed-send provenance could not be recorded; do not resend the text\n' >&2
}

fm_local_hook() {
  local action=$1
  shift
  case "$action" in
    init)
      FM_LOCAL_PROVENANCE_ACTIVE=1
      FM_LOCAL_PROVENANCE_MODE=${1:-send}
      FM_LOCAL_PROVENANCE_SENDER=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || FM_LOCAL_PROVENANCE_SENDER=$FM_HOME
      ;;
    typed)
      [ "${FM_LOCAL_PROVENANCE_ACTIVE:-0}" = 1 ] || return 0
      local backend=$1 target=$2 text=$3 meta task='' kind pane
      if [ "$FM_LOCAL_PROVENANCE_MODE" = re-ring ]; then
        meta=$(fm_backend_meta_for_window "$target" "$STATE" 2>/dev/null) || meta=''
        kind=doorbell
      else
        meta=${TARGET_META:-}
        if [ "${INBOX_PLANE:-0}" = 1 ]; then
          kind=doorbell
        elif [ -n "${TARGET_SELECTOR:-}" ]; then
          kind=native-skill
        else
          kind=explicit-endpoint
        fi
      fi
      if [ -n "$meta" ]; then
        task=${meta##*/}
        task=${task%.meta}
      fi
      pane=${target##*:}
      if [ "$backend" = tmux ]; then
        pane=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null) || pane=''
      fi
      fm_local_provenance_record "$text" "$backend" "$target" "$pane" "$task" '' "$kind"
      ;;
    remote-sent)
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
      ;;
    prune)
      perl "$FM_LOCAL_PROVENANCE_BIN/fm-local-send-provenance.pl" prune "$1" \
        || printf 'warning: expired typed-send provenance could not be removed\n' >&2
      ;;
  esac
  return 0
}
