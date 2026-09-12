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
  # shellcheck disable=SC2016 # Match literal source text, not an expansion here.
  case "$(declare -f fm_super_main)" in
    *'primary_harness=$(fm_daemon_primary_harness)'*'harness=$primary_harness'*)
      pass "daemon startup diagnostic names the resolved primary harness"
      ;;
    *)
      fail "daemon startup diagnostic does not expose the resolved primary harness"
      ;;
  esac
}

test_failed_short_submit_keeps_exact_durable_digest
test_other_harness_keeps_direct_transport
test_startup_diagnostic_names_resolved_harness
