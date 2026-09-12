#!/usr/bin/env bash
# Isolated regression for Codex-on-Herdr durable short-wake delivery.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=bin/fm-supervise-daemon.sh disable=SC1091
. "$ROOT/bin/fm-supervise-daemon.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-short-wake.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

note_body() {
  awk 'seen { print } /^--$/ { seen=1 }' "$1"
}

wake_payload_for_note() {  # <state> <note-id>
  awk -F '\t' -v key="inbox:$2" '$4 == key { payload=$5 } END { print payload }' \
    "$1/.wake-queue"
}

test_staged_digest_wake_does_not_recurse() {
  local staged_root="$TMP_ROOT/no-recursion/staged" staged_state="$TMP_ROOT/no-recursion/staged/state"
  local external_root="$TMP_ROOT/no-recursion/external" external_state="$TMP_ROOT/no-recursion/external/state"
  local fallback_root="$TMP_ROOT/no-recursion/fallback" fallback_state="$TMP_ROOT/no-recursion/fallback/state"
  local staged_id staged_reason external_id external_reason fallback_id fallback_reason fallback_note

  mkdir -p "$staged_state" "$external_state" "$fallback_state"
  : > "$staged_state/.afk"
  escalate_add "$staged_state" "one original staged event"
  inject_msg() { return 0; }
  FM_HOME="$staged_root" FM_SUPERVISOR_BACKEND=herdr \
    FM_DAEMON_PRIMARY_HARNESS=codex escalate_flush "$staged_state" busy-override \
    || fail "could not stage and deliver the original short reference"
  staged_id=$(find "$staged_state/inbox" -maxdepth 1 -name '*.note' -printf '%f\n')
  staged_id=${staged_id%.note}
  staged_reason=$(wake_payload_for_note "$staged_state" "$staged_id")
  [ -n "$staged_reason" ] || fail "staged transport record emitted no check wake fixture"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "$staged_reason" "$staged_state" \
    || fail "staged transport wake could not be classified"
  [ ! -s "$staged_state/.subsuper-escalations" ] \
    || fail "staged transport check recursively entered the escalation buffer"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "$staged_reason" "$staged_state" \
    || fail "replayed staged transport wake could not be classified"
  [ ! -s "$staged_state/.subsuper-escalations" ] \
    || fail "replayed staged transport check recursively entered the escalation buffer"

  FM_HOME="$external_root" FM_STATE_OVERRIDE="$external_state" \
    "$ROOT/bin/fm-inbox.sh" note "external captain note stays actionable" >/dev/null \
    || fail "could not queue the external inbox control"
  external_id=$(find "$external_state/inbox" -maxdepth 1 -name '*.note' -printf '%f\n')
  external_id=${external_id%.note}
  external_reason=$(wake_payload_for_note "$external_state" "$external_id")
  FM_ESCALATE_BATCH_SECS=999 handle_wake "$external_reason" "$external_state" \
    || fail "external inbox wake could not be classified"
  grep -F "$external_reason" "$external_state/.subsuper-escalations" >/dev/null \
    || fail "external inbox wake stopped being actionable"

  : > "$fallback_state/.afk"
  escalate_add "$fallback_state" "undeliverable fallback event"
  FM_HOME="$fallback_root" escalate_fallback_to_inbox "$fallback_state" \
    || fail "failure fallback was not stored durably"
  fallback_id=${INJECT_DURABLE_NOTE_ID:-}
  [ -n "$fallback_id" ] || fail "failure fallback returned no durable note ID"
  fallback_note="$fallback_state/inbox/$fallback_id.note"
  [ -s "$fallback_note" ] || fail "failure fallback note is not durable"
  case "$(note_body "$fallback_note")" in
    'Away-mode escalation could not be delivered to your session ('*) ;;
    *) fail "failure fallback lost its delivery context" ;;
  esac
  fallback_reason=$(wake_payload_for_note "$fallback_state" "$fallback_id")
  : > "$fallback_state/.subsuper-escalations"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "$fallback_reason" "$fallback_state" \
    || fail "failure fallback wake could not be classified"
  grep -F "$fallback_reason" "$fallback_state/.subsuper-escalations" >/dev/null \
    || fail "failure fallback wake stopped being actionable"
  pass "staged transport check is non-recursive while external and fallback notes remain actionable"
}

test_same_digest_fallback_keeps_its_actionable_wake() {
  local root="$TMP_ROOT/same-digest-fallback" state="$TMP_ROOT/same-digest-fallback/state"
  local fallback_id fallback_reason

  mkdir -p "$state"
  : > "$state/.afk"
  escalate_add "$state" "same digest first reached the failure fallback"
  FM_HOME="$root" escalate_fallback_to_inbox "$state" \
    || fail "same-digest failure fallback was not stored"
  fallback_id=${INJECT_DURABLE_NOTE_ID:-}
  fallback_reason=$(wake_payload_for_note "$state" "$fallback_id")

  inject_msg() { return 0; }
  FM_HOME="$root" FM_SUPERVISOR_BACKEND=herdr \
    FM_DAEMON_PRIMARY_HARNESS=codex escalate_flush "$state" busy-override \
    || fail "same-digest short reference did not report success"
  : > "$state/.subsuper-escalations"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "$fallback_reason" "$state" \
    || fail "same-digest failure fallback wake could not be classified"
  grep -F "$fallback_reason" "$state/.subsuper-escalations" >/dev/null \
    || fail "same-digest staging suppressed a prior failure-fallback wake"
  pass "same-digest staging does not reclassify a prior failure fallback"
}

test_failed_short_reference_keeps_its_actionable_wake() {
  local root="$TMP_ROOT/failed-reference-wake" state="$TMP_ROOT/failed-reference-wake/state"
  local staged_id staged_reason

  mkdir -p "$state"
  : > "$state/.afk"
  escalate_add "$state" "short reference transport will fail"
  inject_msg() { return 1; }
  if FM_HOME="$root" FM_SUPERVISOR_BACKEND=herdr \
    FM_DAEMON_PRIMARY_HARNESS=codex escalate_flush "$state" busy-override; then
    fail "failed short reference reported success while checking wake provenance"
  fi
  staged_id=${INJECT_DURABLE_NOTE_ID:-}
  staged_reason=$(wake_payload_for_note "$state" "$staged_id")
  : > "$state/.subsuper-escalations"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "$staged_reason" "$state" \
    || fail "failed short-reference wake could not be classified"
  grep -F "$staged_reason" "$state/.subsuper-escalations" >/dev/null \
    || fail "failed short reference suppressed its only durable wake"
  pass "failed short reference leaves its durable wake actionable"
}

test_staged_digest_watcher_cycle_does_not_echo() {
  local staged_root="$TMP_ROOT/watcher-cycle/staged" staged_state="$TMP_ROOT/watcher-cycle/staged/state"
  local external_root="$TMP_ROOT/watcher-cycle/external" external_state="$TMP_ROOT/watcher-cycle/external/state"
  local fallback_root="$TMP_ROOT/watcher-cycle/fallback" fallback_state="$TMP_ROOT/watcher-cycle/fallback/state"
  local staged_id staged_reason external_id external_reason fallback_id fallback_reason

  mkdir -p "$staged_state" "$external_state" "$fallback_state"
  : > "$staged_state/.afk"
  escalate_add "$staged_state" "one composed staged event"
  inject_msg() { return 0; }
  FM_HOME="$staged_root" FM_SUPERVISOR_BACKEND=herdr \
    FM_DAEMON_PRIMARY_HARNESS=codex escalate_flush "$staged_state" busy-override \
    || fail "composed path could not stage and deliver the short reference"
  staged_id=$(find "$staged_state/inbox" -maxdepth 1 -name '*.note' -printf '%f\n')
  staged_id=${staged_id%.note}
  staged_reason=$(wake_payload_for_note "$staged_state" "$staged_id")
  FM_HOME="$staged_root" FM_STATE_OVERRIDE="$staged_state" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes "$staged_reason" "$staged_state" >/dev/null 2>&1 \
    || fail "composed path could not drain and classify the staged wake"
  [ ! -s "$staged_state/.subsuper-escalations" ] \
    || fail "composed staging-to-classification path generated a new echo"

  FM_HOME="$external_root" FM_STATE_OVERRIDE="$external_state" \
    "$ROOT/bin/fm-inbox.sh" note "composed external captain note" >/dev/null \
    || fail "composed path could not queue the external inbox control"
  external_id=$(find "$external_state/inbox" -maxdepth 1 -name '*.note' -printf '%f\n')
  external_id=${external_id%.note}
  external_reason=$(wake_payload_for_note "$external_state" "$external_id")
  FM_HOME="$external_root" FM_STATE_OVERRIDE="$external_state" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes "$external_reason" "$external_state" >/dev/null 2>&1 \
    || fail "composed path could not drain the external inbox wake"
  grep -F "$external_reason" "$external_state/.subsuper-escalations" >/dev/null \
    || fail "composed path absorbed the external inbox wake"

  : > "$fallback_state/.afk"
  escalate_add "$fallback_state" "composed failure fallback event"
  FM_HOME="$fallback_root" escalate_fallback_to_inbox "$fallback_state" \
    || fail "composed path could not store the failure fallback"
  fallback_id=${INJECT_DURABLE_NOTE_ID:-}
  fallback_reason=$(wake_payload_for_note "$fallback_state" "$fallback_id")
  : > "$fallback_state/.subsuper-escalations"
  FM_HOME="$fallback_root" FM_STATE_OVERRIDE="$fallback_state" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes "$fallback_reason" "$fallback_state" >/dev/null 2>&1 \
    || fail "composed path could not drain the failure fallback wake"
  grep -F "$fallback_reason" "$fallback_state/.subsuper-escalations" >/dev/null \
    || fail "composed path absorbed the failure fallback wake"
  pass "composed staging-to-watcher classification has no echo and preserves actionable controls"
}

test_failed_short_submit_keeps_exact_durable_digest() {
  local state="$TMP_ROOT/failed/state" sent="$TMP_ROOT/failed/sent" digest sha
  local marker note_id note saved notes short unrelated
  mkdir -p "$state"
  : > "$state/.afk"
  : > "$sent"
  escalate_add "$state" "$(printf 'long-event-%04096d' 0)"
  digest=$(escalate_digest "$state") || fail "could not build the long digest"
  sha=$(_sha256_text "$digest")
  FM_HOME="$TMP_ROOT/failed" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-inbox.sh" note "unrelated durable note" >/dev/null \
    || fail "could not seed the unrelated durable note"
  unrelated=$(find "$state/inbox" -maxdepth 1 -name '*.note' -print)
  unrelated=${unrelated##*/}

  inject_msg() {
    printf '%s\n' "$1" >> "$sent"
    return 1
  }
  if FM_HOME="$TMP_ROOT/failed" FM_SUPERVISOR_BACKEND=herdr \
    FM_DAEMON_PRIMARY_HARNESS=codex escalate_flush "$state" busy-override; then
    fail "an unconfirmed short submit reported success"
  fi

  marker=$(cat "$state/.subsuper-inject-fallback" 2>/dev/null || true)
  [ "${marker%%$'\t'*}" = "sha256:$sha" ] || fail "durable marker did not bind the exact digest hash"
  note_id=${marker#*$'\t'}
  [ -n "$note_id" ] && [ "$note_id" != "$marker" ] || fail "durable marker did not name one note"
  [ "$note_id.note" != "$unrelated" ] || fail "short wake selected the unrelated note"
  note="$state/inbox/$note_id.note"
  [ -f "$note" ] || fail "the named durable note does not exist"
  saved=$(note_body "$note")
  [ "$saved" = "$digest" ] || fail "durable note bytes differ from the source digest"
  [ "$(_sha256_text "$saved")" = "$sha" ] || fail "durable note hash differs from the source digest"

  short="Durable captain inbox note $note_id is ready. Run bin/fm-wake-drain.sh first."
  [ "$(cat "$sent")" = "$short" ] || fail "pane transport was not the one record-specific short wake"
  case "$(cat "$sent")" in *long-event-*) fail "short wake leaked the long digest into the composer" ;; esac
  [ -s "$state/.subsuper-escalations" ] || fail "failed submit cleared the source buffer"
  notes=$(find "$state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" -eq 2 ] || fail "failed submit did not retain the unrelated and staged records"

  inject_msg() {
    printf '%s\n' "$1" >> "$sent"
    return 0
  }
  FM_HOME="$TMP_ROOT/failed" FM_SUPERVISOR_BACKEND=herdr \
    FM_DAEMON_PRIMARY_HARNESS=codex escalate_flush "$state" busy-override \
    || fail "retry of the same short wake did not succeed"
  notes=$(find "$state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" -eq 2 ] || fail "retry created a duplicate durable record"
  [ ! -s "$state/.subsuper-escalations" ] || fail "confirmed retry did not clear the source buffer"
  [ "$(wc -l < "$sent" | tr -d ' ')" -eq 2 ] || fail "retry did not type exactly one short reference"
  pass "failed Codex short submit retains exact sha256=$sha and retries the same note"
}

test_other_harness_keeps_direct_transport() {
  local state="$TMP_ROOT/direct/state" sent="$TMP_ROOT/direct/sent" digest
  mkdir -p "$state"
  : > "$state/.afk"
  : > "$sent"
  escalate_add "$state" "direct transport stays unchanged"
  digest=$(escalate_digest "$state") || fail "could not build the direct digest"
  inject_msg() {
    printf '%s\n' "$1" > "$sent"
    return 0
  }
  FM_HOME="$TMP_ROOT/direct" FM_SUPERVISOR_BACKEND=herdr \
    FM_DAEMON_PRIMARY_HARNESS=claude escalate_flush "$state" \
    || fail "non-Codex direct transport failed"
  [ "$(cat "$sent")" = "$digest" ] || fail "non-Codex transport was rewritten"
  [ ! -e "$state/inbox" ] || fail "non-Codex transport was staged unexpectedly"
  pass "non-Codex Herdr transport remains direct"
}

test_startup_diagnostic_names_resolved_harness() {
  local home="$TMP_ROOT/startup" fakebin="$TMP_ROOT/startup/fakebin"
  local pid attempt=0 output
  mkdir -p "$home/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  printf '%%isolated-startup\n'
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=%isolated-startup \
    FM_DAEMON_PRIMARY_HARNESS=codex FM_WEDGE_ALARM_EXEC=discard \
    bash "$ROOT/bin/fm-supervise-daemon.sh" > "$home/output" 2>&1 &
  pid=$!
  while [ "$attempt" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    grep -F 'daemon starting ' "$home/state/.supervise-daemon.log" >/dev/null 2>&1 && break
    sleep 0.05
    attempt=$((attempt + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  output=$(cat "$home/state/.supervise-daemon.log" 2>/dev/null || true)
  case "$output" in
    *'daemon starting '*'; harness=codex; '*) ;;
    *) fail "executed daemon startup did not report the resolved harness ($output)" ;;
  esac
  [ ! -e "$home/state/.supervise-daemon.pid" ] \
    || fail "isolated diagnostic daemon did not clean up its pid record"
  pass "executed daemon startup diagnostic names the resolved primary harness"
}

test_failed_short_submit_keeps_exact_durable_digest
test_other_harness_keeps_direct_transport
test_startup_diagnostic_names_resolved_harness
test_staged_digest_wake_does_not_recurse
test_same_digest_fallback_keeps_its_actionable_wake
test_failed_short_reference_keeps_its_actionable_wake
test_staged_digest_watcher_cycle_does_not_echo
