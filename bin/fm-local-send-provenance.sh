#!/usr/bin/env bash
# Fork hooks for typed-send attribution. Source this file without arguments.
# fm_local_hook init enables recording only in fm-send and its remote send leg.
# fm_local_hook remote-args adds sender context to the remote transport envelope.
# fm_local_hook typed <backend> <target> <text> observes successful literal typing.
# fm_local_hook prune <state> expires old shards during task teardown.
# The writer owns storage mechanics. docs/local/send-provenance.schema.json
# owns the record format and the dashboard reader contract.

FM_LOCAL_PROVENANCE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Remove the fork envelope before the upstream remote command parses its args.
# Sourcing without arguments makes this update the caller's positional args.
if [ "${0##*/}" = fm-remote-secondmate-control.sh ] && [ "${1:-}" = send ] && [ "$#" -eq 5 ]; then
  case "$5" in
    fm-provenance-v1:/*)
      FM_LOCAL_PROVENANCE_REMOTE_SENDER=${5#fm-provenance-v1:}
      set -- "$1" "$2" "$3" "$4"
      ;;
  esac
fi

fm_local_hook() {
  local action=$1
  shift
  case "$action" in
    init)
      FM_LOCAL_PROVENANCE_ACTIVE=1
      FM_LOCAL_PROVENANCE_SENDER=${FM_LOCAL_PROVENANCE_REMOTE_SENDER:-$(cd "$FM_HOME" && pwd -P)}
      ;;
    remote-args)
      REMOTE_SEND_ARGS=("$TARGET_REMOTE_ID" "$MESSAGE" "${FIRE_AND_FORGET_ID:+fire-and-forget}" "fm-provenance-v1:$FM_LOCAL_PROVENANCE_SENDER")
      ;;
    typed)
      [ "${FM_LOCAL_PROVENANCE_ACTIVE:-0}" = 1 ] || return 0
      local backend=$1 target=$2 text=$3 state task='' kind pane
      if [ "${0##*/}" = fm-remote-secondmate-control.sh ]; then
        state=$CONTROL_STATE
        task=${id:-}
        kind=doorbell
      else
        state=${STATE:-$FM_HOME/state}
        if [ -n "${TARGET_META:-}" ]; then
          task=${TARGET_META##*/}
          task=${task%.meta}
        fi
        if [ "${INBOX_PLANE:-0}" = 1 ]; then
          kind=doorbell
        elif [ -n "${TARGET_SELECTOR:-}" ]; then
          kind=native-skill
        else
          kind=explicit-endpoint
        fi
      fi
      pane=${target##*:}
      if [ "$backend" = tmux ]; then
        pane=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null) || pane=''
      fi
      printf '%s' "$text" | perl "$FM_LOCAL_PROVENANCE_BIN/fm-local-send-provenance.pl" record \
        "$state" "$backend" "$target" "$pane" "$task" "$FM_LOCAL_PROVENANCE_SENDER" "$kind" \
        || printf 'warning: typed-send provenance could not be recorded; do not resend the text\n' >&2
      ;;
    prune)
      perl "$FM_LOCAL_PROVENANCE_BIN/fm-local-send-provenance.pl" prune "$1" \
        || printf 'warning: expired typed-send provenance could not be removed\n' >&2
      ;;
  esac
  return 0
}
