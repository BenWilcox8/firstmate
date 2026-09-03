#!/usr/bin/env bash
# tests/fm-fleet-snapshot-home-summary-size.test.sh - large-backlog secondmate
# home summary regression.
#
# secondmate_home_summary_json() used to hand the whole backlog and task
# snapshot to jq via --argjson, which passes the value on the process argument
# list. A home with a large enough backlog (onestopgreek, 2026-09-02) blew past
# the OS argument-size limit and the summary failed outright with
# "Argument list too long" instead of the bounded structured summary this mode
# promises. The fix reads both documents from files via --slurpfile instead, so
# their size is bounded only by disk. This drives the real backlog parser past
# getconf ARG_MAX with a handful of oversized rows (cheap to parse, still large
# enough to overflow the argument list) rather than thousands of ordinary ones,
# to keep the regression fast.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-home-summary-size)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_oversized_backlog_still_summarizes() {
  local home pad out rc arg_max
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  arg_max=$(getconf ARG_MAX 2>/dev/null || printf '2097152\n')
  # A handful of oversized rows push the parsed backlog JSON well past
  # ARG_MAX without the per-line regex cost of thousands of ordinary ones.
  pad=$(printf 'x%.0s' $(seq 1 600000))
  {
    printf '## Done\n'
    local i
    for i in 1 2 3 4 5; do
      printf -- '- [x] done-task-%s - Done Task Number %s %s https://github.com/kunchenguid/firstmate/pull/%s (repo: alpha) (kind: ship) (merged 2026-07-06)\n' \
        "$i" "$i" "$pad" "$i"
    done
  } > "$home/data/backlog.md"
  [ "$(wc -c < "$home/data/backlog.md")" -gt "$arg_max" ] \
    || fail "fixture backlog must itself exceed ARG_MAX to exercise the argument-list hazard"

  out=$(FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary 2>"$TMP_ROOT/err"); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "secondmate-home-summary failed on an oversized backlog (rc=$rc): $(cat "$TMP_ROOT/err")"
  printf '%s' "$out" | jq -e '.schema == "fm-secondmate-home-summary.v1"' >/dev/null \
    || fail "secondmate-home-summary did not emit the expected schema: $out"
  pass "secondmate-home-summary handles a backlog larger than ARG_MAX without an argument-list failure"
}

test_oversized_backlog_still_summarizes

echo "ALL TESTS PASSED"
