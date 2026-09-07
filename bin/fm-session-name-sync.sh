#!/usr/bin/env bash
# Synchronize a Pi worker's native session name into its current task record.
# Usage: fm-session-name-sync.sh <task-id> <name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --event ]; then
  [ "$#" -eq 5 ] || exit 2
  STATE=${2:-}
  ID=${3:-}
  SPAWN_GEN=${4:-}
  NAME=${5:-}
  EVENT=1
else
  [ "$#" -eq 2 ] || exit 2
  FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  ID=${1:-}
  NAME=${2:-}
  SPAWN_GEN=
  EVENT=0
fi

case "$ID" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$NAME" in
  ''|*$'\n'*|*$'\r'*) exit 0 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
CONFIRMATION="$STATE/$ID.pi-name-confirmation"

meta_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); exit }' "$1"
}

if [ "$EVENT" = 1 ]; then
  [ "$(meta_value "$META" spawn_gen)" = "$SPAWN_GEN" ] || exit 0
  case "$(meta_value "$META" harness)" in pi|pi-signed) ;; *) exit 0 ;; esac
  TMP=$(mktemp "$STATE/.$ID.pi-name-confirmation.XXXXXX") || exit 0
  if ! {
    printf 'spawn_gen=%s\n' "$SPAWN_GEN"
    printf 'name=%s\n' "$NAME"
  } > "$TMP" \
     || ! chmod 0600 "$TMP" \
     || ! mv -f -- "$TMP" "$CONFIRMATION"; then
    rm -f -- "$TMP"
    exit 0
  fi
  TMP=
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK=$(fm_meta_lock_path "$META") || exit 0
fm_lock_acquire_wait "$LOCK"
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ "$EVENT" != 1 ] || rm -f -- "$CONFIRMATION"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT

if [ "$EVENT" = 1 ]; then
  [ "$(meta_value "$META" spawn_gen)" = "$SPAWN_GEN" ] || exit 0
fi
case "$(meta_value "$META" harness)" in pi|pi-signed) ;; *) exit 0 ;; esac
TMP=$(mktemp "$STATE/.$ID.meta.name.XXXXXX")
awk -F= '$1 != "session_name"' "$META" > "$TMP"
printf 'session_name=%s\n' "$NAME" >> "$TMP"
mv -f -- "$TMP" "$META"
TMP=
