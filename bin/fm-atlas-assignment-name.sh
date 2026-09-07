#!/usr/bin/env bash
# Apply one committed Atlas assignment title to its managed Pi session.
# Usage: fm-atlas-assignment-name.sh accept
#
# Dashboard owns post-commit event emission and durable retry.
# This receiver only accepts one delivered atlas.assignment.v1 JSON object from standard input.
# It neither queues nor emits assignment events and returns one firstmate.atlas-assignment.ack.v1 JSON object.
# Exit 0 is a terminal acknowledgment.
# Exit 75 requests a retry for a temporary condition.
# Exit 64 rejects a permanent input error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REQUEST_HOME=$FM_HOME
REQUEST_STATE=$STATE
REQUEST_CONFIG=$CONFIG

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

ack() {  # <assignment-id> <result> <exit-code>
  jq -cn --arg assignmentId "$1" --arg result "$2" \
    '{schema:"firstmate.atlas-assignment.ack.v1",$assignmentId,$result}'
  exit "$3"
}

reject() {  # <assignment-id> <message>
  printf 'assignment-name: %s\n' "$2" >&2
  ack "$1" rejected 64
}

retry() {  # <assignment-id> <message>
  printf 'assignment-name: %s\n' "$2" >&2
  ack "$1" retry 75
}

[ "${1:-}" = accept ] && [ "$#" -eq 1 ] || {
  echo "usage: fm-atlas-assignment-name.sh accept" >&2
  exit 64
}
command -v jq >/dev/null 2>&1 || {
  echo "assignment-name: jq is required" >&2
  exit 75
}

PAYLOAD=$(cat)
ASSIGNMENT_ID=$(printf '%s' "$PAYLOAD" | jq -r '.assignmentId // empty' 2>/dev/null || true)
PAYLOAD_BYTES=$(printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')
case "$PAYLOAD_BYTES" in ''|*[!0-9]*) PAYLOAD_BYTES=65537 ;; esac
[ "$PAYLOAD_BYTES" -le 65536 ] || reject "$ASSIGNMENT_ID" "event exceeds 65536 bytes"
if ! printf '%s' "$PAYLOAD" | jq -e '
  type == "object"
  and .schema == "atlas.assignment.v1"
  and ([.assignmentId, .assignmentOrder, .atlasIdentity, .targetAgent,
        .targetTask, .ticketId, .title] | all(type == "string"))
  and (.assignmentId | length > 0)
  and (.assignmentOrder | length <= 128 and test("^(0|[1-9][0-9]*)$"))
  and (.atlasIdentity | length > 0)
  and (.targetAgent | length > 0)
  and (.targetTask | test("^[A-Za-z0-9._-]+$"))
  and (.ticketId | length > 0)
  and (.title | length > 0)
  and ([.assignmentId, .atlasIdentity, .targetAgent, .targetTask, .ticketId, .title]
       | all((test("[\\r\\n]") | not) and (contains("\u0000") | not)))
' >/dev/null 2>&1; then
  reject "$ASSIGNMENT_ID" "invalid atlas.assignment.v1 event"
fi

ASSIGNMENT_ID=$(printf '%s' "$PAYLOAD" | jq -r '.assignmentId')
ASSIGNMENT_ORDER=$(printf '%s' "$PAYLOAD" | jq -r '.assignmentOrder')
ATLAS_IDENTITY=$(printf '%s' "$PAYLOAD" | jq -r '.atlasIdentity')
TARGET_AGENT=$(printf '%s' "$PAYLOAD" | jq -r '.targetAgent')
ID=$(printf '%s' "$PAYLOAD" | jq -r '.targetTask')
TITLE=$(printf '%s' "$PAYLOAD" | jq -r '.title')
EVENT=$(printf '%s' "$PAYLOAD" | jq -cS '{schema,assignmentId,assignmentOrder,atlasIdentity,targetAgent,targetTask,ticketId,title}')

case "$ID" in fm-*) EXPECTED_AGENT=$ID ;; *) EXPECTED_AGENT="fm-$ID" ;; esac
[ "$TARGET_AGENT" = "$EXPECTED_AGENT" ] \
  || reject "$ASSIGNMENT_ID" "targetAgent does not match targetTask"

CANDIDATE_HOMES=()
add_candidate_home() {  # <home>
  local home=$1 key existing
  [ -f "$home/state/$ID.meta" ] && [ ! -L "$home/state/$ID.meta" ] || return 0
  key=$(secondmate_registry_path_key "$home" 2>/dev/null) || return 0
  for existing in "${CANDIDATE_HOMES[@]+"${CANDIDATE_HOMES[@]}"}"; do
    [ "$existing" != "$key" ] || return 0
  done
  CANDIDATE_HOMES+=("$key")
}

add_candidate_home "$REQUEST_HOME"
REGISTRY="$REQUEST_HOME/data/secondmates.md"
if [ -e "$REGISTRY" ]; then
  if ! secondmate_registry_validate_bindings "$REGISTRY" secondmate_registry_path_key; then
    retry "$ASSIGNMENT_ID" "home $REQUEST_HOME has an unsafe secondmate registry: $SECONDMATE_REGISTRY_ERROR"
  fi
  while IFS= read -r REGISTRY_LINE || [ -n "$REGISTRY_LINE" ]; do
    case "$REGISTRY_LINE" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$REGISTRY_LINE" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
    add_candidate_home "$SECONDMATE_REGISTRY_HOME"
  done < "$REGISTRY"
fi
case "${#CANDIDATE_HOMES[@]}" in
  0) retry "$ASSIGNMENT_ID" "home $REQUEST_HOME has no owned task record for $ID" ;;
  1) TARGET_HOME=${CANDIDATE_HOMES[0]} ;;
  *) retry "$ASSIGNMENT_ID" "home $REQUEST_HOME resolves more than one owned task record for $ID" ;;
esac

if [ "$TARGET_HOME" = "$(secondmate_registry_path_key "$REQUEST_HOME" 2>/dev/null || printf '%s' "$REQUEST_HOME")" ]; then
  FM_HOME=$REQUEST_HOME
  STATE=$REQUEST_STATE
  CONFIG=$REQUEST_CONFIG
else
  FM_HOME=$TARGET_HOME
  STATE="$FM_HOME/state"
  CONFIG="$FM_HOME/config"
fi
META="$STATE/$ID.meta"

POINTER="$CONFIG/specs"
if [ ! -e "$POINTER" ]; then
  if [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
     && fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" \
     && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
     && [ -n "$FM_SECONDMATE_PARENT_HOME" ]; then
    POINTER="$FM_SECONDMATE_PARENT_HOME/config/specs"
  fi
fi
if [ ! -f "$POINTER" ] || [ -L "$POINTER" ]; then
  retry "$ASSIGNMENT_ID" "home $FM_HOME has no verifiable config/specs pointer or local parent binding"
fi
SPEC_REPO=$(head -n 1 "$POINTER" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//')
case "$SPEC_REPO" in /*) ;; *) retry "$ASSIGNMENT_ID" "home $FM_HOME has an invalid config/specs pointer" ;; esac
[ -d "$SPEC_REPO/atlas" ] \
  || retry "$ASSIGNMENT_ID" "home $FM_HOME points to an unavailable Atlas store"
SPEC_IDENTITY=$(cd "$SPEC_REPO" 2>/dev/null && pwd -P) \
  || retry "$ASSIGNMENT_ID" "home $FM_HOME Atlas store cannot be resolved"
[ "$ATLAS_IDENTITY" = "$SPEC_IDENTITY" ] \
  || reject "$ASSIGNMENT_ID" "event Atlas identity does not match home $FM_HOME"

fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null 2>&1 \
  || retry "$ASSIGNMENT_ID" "task $ID has no valid owned endpoint in home $FM_HOME"
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
TARGET=$FM_BACKEND_VALIDATED_TARGET
HARNESS=$(fm_meta_get "$META" harness)
case "$HARNESS" in
  pi|pi-signed) ;;
  *) ack "$ASSIGNMENT_ID" not-applicable 0 ;;
esac

LOCK=$(fm_meta_lock_path "$META") \
  || retry "$ASSIGNMENT_ID" "task $ID metadata lock cannot be resolved"
fm_lock_acquire_wait "$LOCK"
TMP=
# shellcheck disable=SC2329 # The trap invokes this function.
cleanup() {
  [ -z "${TMP:-}" ] || rm -f -- "$TMP"
  fm_lock_release "$LOCK" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null 2>&1 \
  || retry "$ASSIGNMENT_ID" "task $ID endpoint changed before assignment delivery"
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
TARGET=$FM_BACKEND_VALIDATED_TARGET
HARNESS=$(fm_meta_get "$META" harness)
case "$HARNESS" in
  pi|pi-signed) ;;
  *) ack "$ASSIGNMENT_ID" not-applicable 0 ;;
esac

RECORD="$STATE/$ID.atlas-assignment-name.json"
CONFIRMATION="$STATE/$ID.pi-name-confirmation"
SPAWN_GEN=$(fm_meta_get "$META" spawn_gen)
[ -n "$SPAWN_GEN" ] || retry "$ASSIGNMENT_ID" "task $ID has no current spawn generation"
if [ -e "$CONFIRMATION" ]; then
  [ -f "$CONFIRMATION" ] && [ ! -L "$CONFIRMATION" ] \
    || retry "$ASSIGNMENT_ID" "native name confirmation is not a regular file for task $ID"
  rm -f -- "$CONFIRMATION" \
    || retry "$ASSIGNMENT_ID" "stale native name confirmation cannot be cleared for task $ID"
fi
decimal_order_cmp() {  # <left> <right>
  local left=$1 right=$2 LC_ALL=C
  if [ "${#left}" -lt "${#right}" ]; then printf '%s' -1; return; fi
  if [ "${#left}" -gt "${#right}" ]; then printf '%s' 1; return; fi
  if [ "$left" = "$right" ]; then printf '%s' 0; return; fi
  if [[ "$left" < "$right" ]]; then
    printf '%s' -1
  else
    printf '%s' 1
  fi
}

publish_assignment_record() {  # <delivery> <prior-name>
  local delivery=$1 prior_name=$2
  TMP=$(mktemp "$STATE/.$ID.atlas-assignment-name.XXXXXX") || return 1
  if ! printf '%s' "$EVENT" | jq -cS --arg delivery "$delivery" --arg priorName "$prior_name" \
      '. + {$delivery,$priorName}' > "$TMP" \
     || ! chmod 0600 "$TMP" \
     || ! mv -f -- "$TMP" "$RECORD"; then
    rm -f -- "$TMP"
    TMP=
    return 1
  fi
  TMP=
}

native_name_confirmed() {
  local confirmation_gen confirmation_name
  [ -f "$CONFIRMATION" ] && [ ! -L "$CONFIRMATION" ] || return 1
  confirmation_gen=$(awk -F= '$1 == "spawn_gen" { print substr($0, 11); exit }' "$CONFIRMATION")
  confirmation_name=$(awk -F= '$1 == "name" { print substr($0, 6); exit }' "$CONFIRMATION")
  [ "$confirmation_gen" = "$SPAWN_GEN" ] && [ "$confirmation_name" = "$TITLE" ]
}

native_name_visible() {
  local terminal_title attempt=0
  local attempts=${FM_ASSIGNMENT_CONFIRM_RETRIES:-20}
  local sleep_secs=${FM_ASSIGNMENT_CONFIRM_SLEEP:-0.1}
  case "$attempts" in ''|*[!0-9]*|0) attempts=20 ;; esac
  while [ "$attempt" -lt "$attempts" ]; do
    native_name_confirmed && return 0
    terminal_title=$(fm_backend_terminal_title "$BACKEND" "$TARGET" 2>/dev/null || true)
    case "$terminal_title" in
      "π - $TITLE - "*) return 0 ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -ge "$attempts" ] || sleep "$sleep_secs"
  done
  return 1
}

CURRENT_NAME=$(fm_meta_get "$META" session_name)
if [ -e "$RECORD" ]; then
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] \
    || retry "$ASSIGNMENT_ID" "assignment record is not a regular file for task $ID"
  if ! OLD_EVENT=$(jq -cS '{schema,assignmentId,assignmentOrder,atlasIdentity,targetAgent,targetTask,ticketId,title}' "$RECORD" 2>/dev/null) \
     || ! OLD_ORDER=$(jq -r '.assignmentOrder | select(type == "string" and test("^(0|[1-9][0-9]*)$"))' "$RECORD" 2>/dev/null) \
     || ! OLD_ID=$(jq -r '.assignmentId | select(type == "string")' "$RECORD" 2>/dev/null) \
     || ! OLD_DELIVERY=$(jq -r '.delivery | select(. == "stored" or . == "pending" or . == "submitted" or . == "manual")' "$RECORD" 2>/dev/null) \
     || ! OLD_PRIOR_NAME=$(jq -r '.priorName | select(type == "string")' "$RECORD" 2>/dev/null) \
     || [ -z "$OLD_ORDER" ] || [ -z "$OLD_ID" ] || [ -z "$OLD_DELIVERY" ]; then
    retry "$ASSIGNMENT_ID" "assignment record is malformed for task $ID"
  fi
  ORDER_CMP=$(decimal_order_cmp "$ASSIGNMENT_ORDER" "$OLD_ORDER")
  case "$ORDER_CMP" in
    -1) ack "$ASSIGNMENT_ID" superseded 0 ;;
    0)
      [ "$ASSIGNMENT_ID" = "$OLD_ID" ] \
        || reject "$ASSIGNMENT_ID" "assignment order conflicts with an existing event"
      [ "$EVENT" = "$OLD_EVENT" ] \
        || reject "$ASSIGNMENT_ID" "assignment identity has conflicting fields"
      case "$OLD_DELIVERY" in
        submitted|manual) ack "$ASSIGNMENT_ID" duplicate 0 ;;
        stored)
          if [ "$CURRENT_NAME" != "$OLD_PRIOR_NAME" ] && [ "$CURRENT_NAME" != "$TITLE" ]; then
            publish_assignment_record manual "$OLD_PRIOR_NAME" \
              || retry "$ASSIGNMENT_ID" "manual-name result cannot be recorded for task $ID"
            ack "$ASSIGNMENT_ID" duplicate 0
          fi
          ;;
        pending)
          if [ "$CURRENT_NAME" != "$TITLE" ]; then
            publish_assignment_record manual "$OLD_PRIOR_NAME" \
              || retry "$ASSIGNMENT_ID" "manual-name result cannot be recorded for task $ID"
            ack "$ASSIGNMENT_ID" duplicate 0
          fi
          ;;
      esac
      ;;
    1)
      OLD_DELIVERY=
      OLD_PRIOR_NAME=$CURRENT_NAME
      publish_assignment_record stored "$OLD_PRIOR_NAME" \
        || retry "$ASSIGNMENT_ID" "assignment record cannot be published for task $ID"
      ;;
  esac
else
  OLD_DELIVERY=
  OLD_PRIOR_NAME=$CURRENT_NAME
  publish_assignment_record stored "$OLD_PRIOR_NAME" \
    || retry "$ASSIGNMENT_ID" "assignment record cannot be published for task $ID"
fi

TMP=$(mktemp "$STATE/.$ID.meta.assignment.XXXXXX") \
  || retry "$ASSIGNMENT_ID" "task record cannot be prepared for $ID"
if ! awk -F= '$1 != "session_name"' "$META" > "$TMP" \
   || ! printf 'session_name=%s\n' "$TITLE" >> "$TMP" \
   || ! mv -f -- "$TMP" "$META"; then
  retry "$ASSIGNMENT_ID" "assignment name cannot be published for task $ID"
fi
TMP=
publish_assignment_record pending "$OLD_PRIOR_NAME" \
  || retry "$ASSIGNMENT_ID" "pending assignment cannot be published for task $ID"

BUSY=$(fm_busy_classify "$BACKEND" "$TARGET" "$HARNESS" "$ID" "$STATE")
case "${BUSY%% *}" in
  idle) ;;
  busy) retry "$ASSIGNMENT_ID" "task $ID is busy; native rename is deferred" ;;
  *) retry "$ASSIGNMENT_ID" "task $ID idle state is not verified" ;;
esac

migrate_native_name_extension() {
  local extension tmp
  extension="$STATE/$ID.pi-ext.ts"
  [ -f "$extension" ] && [ ! -L "$extension" ] || return 1
  grep -F 'fm-set-assignment-name' "$extension" >/dev/null 2>&1 && return 2
  tmp=$(mktemp "$STATE/.$ID.pi-ext.migrate.XXXXXX") || return 1
  if ! {
    cat "$extension"
    cat <<EOF
pi.on("session_info_changed", (event: any) => {
  if (typeof event.name !== "string") return;
  execFile("$FM_ROOT/bin/fm-session-name-sync.sh", ["--event", "$STATE", "$ID", "$SPAWN_GEN", event.name]);
});
pi.registerCommand("fm-set-assignment-name", {
  handler: (args: string) => {
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(args)) return;
    const name = Buffer.from(args, "base64").toString("utf8");
    if (Buffer.from(name, "utf8").toString("base64") !== args) return;
    pi.setSessionName(name);
  },
});
EOF
  } > "$tmp" \
     || ! chmod 0600 "$tmp" \
     || ! mv -f -- "$tmp" "$extension"; then
    rm -f -- "$tmp"
    return 1
  fi
}

RETRIES=${FM_ASSIGNMENT_SUBMIT_RETRIES:-3}
SLEEP_SECS=${FM_ASSIGNMENT_SUBMIT_SLEEP:-0.5}
SETTLE_SECS=${FM_ASSIGNMENT_SUBMIT_SETTLE:-0.1}
case "$RETRIES" in ''|*[!0-9]*|0) RETRIES=3 ;; esac
MIGRATED=0
if migrate_native_name_extension; then
  MIGRATED=1
else
  case "$?" in 2) ;; *) retry "$ASSIGNMENT_ID" "native name extension cannot be migrated for task $ID" ;; esac
fi
TITLE_B64=$(printf '%s' "$TITLE" | base64 | tr -d '\n') \
  || retry "$ASSIGNMENT_ID" "native assignment name cannot be encoded for task $ID"
if [ "$MIGRATED" = 1 ]; then
  fm_backend_send_text_submit "$BACKEND" "$TARGET" "/reload" \
    "$RETRIES" "$SLEEP_SECS" "$SETTLE_SECS" "fm-$ID" >/dev/null 2>&1 \
    || retry "$ASSIGNMENT_ID" "native name extension reload failed for task $ID"
fi
VERDICT=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "/fm-set-assignment-name $TITLE_B64" \
  "$RETRIES" "$SLEEP_SECS" "$SETTLE_SECS" "fm-$ID" 2>/dev/null) \
  || retry "$ASSIGNMENT_ID" "native rename delivery failed for task $ID"
if ! native_name_visible; then
  retry "$ASSIGNMENT_ID" "native rename was not confirmed for task $ID (submit verdict: ${VERDICT:-unknown})"
fi

publish_assignment_record submitted "$OLD_PRIOR_NAME" \
  || retry "$ASSIGNMENT_ID" "assignment acknowledgment cannot be published for task $ID"
rm -f -- "$CONFIRMATION" \
  || retry "$ASSIGNMENT_ID" "native name confirmation cannot be cleared for task $ID"
ack "$ASSIGNMENT_ID" accepted 0
