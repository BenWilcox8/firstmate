#!/usr/bin/env bash
# Synchronize a Pi worker's native session name into its current task record.
# Usage: fm-session-name-sync.sh <state-dir> <task-id> <spawn-gen> <name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=$1
ID=$2
SPAWN_GEN=$3
NAME=$4

case "$ID" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$NAME" in
  ''|*$'\n'*|*$'\r'*) exit 0 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0

meta_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); exit }' "$1"
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK=$(fm_meta_lock_path "$META") || exit 0
fm_lock_acquire_wait "$LOCK"
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT

[ "$(meta_value "$META" spawn_gen)" = "$SPAWN_GEN" ] || exit 0
case "$(meta_value "$META" harness)" in pi|pi-signed) ;; *) exit 0 ;; esac
TMP=$(mktemp "$STATE/.$ID.meta.name.XXXXXX")
awk -F= '$1 != "session_name"' "$META" > "$TMP"
printf 'session_name=%s\n' "$NAME" >> "$TMP"
mv -f -- "$TMP" "$META"
TMP=
