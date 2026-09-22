#!/usr/bin/env bash
# Public captain-answer lookup across the live backlog and archive.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null || { echo 'skip: tasks-axi not found'; exit 0; }
case_home=$(fm_test_tmproot fm-captain-archive-bound)
mkdir -p "$case_home/data" "$case_home/state" "$case_home/config"
cp "$ROOT/.tasks.toml" "$case_home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$case_home/data/backlog.md"
case_bin=$(fm_fakebin "$case_home")
tasks_binary=$(command -v tasks-axi)
captain() {
  PATH="$case_bin:$PATH" REAL_TASKS_AXI="$tasks_binary" \
    FM_HOME="$case_home" FM_STATE_OVERRIDE="$case_home/state" \
    FM_DATA_OVERRIDE="$case_home/data" FM_CONFIG_OVERRIDE="$case_home/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

captain hold sample-choice --title 'Choose retention' --reason 'Retention requires a decision' --repo sample >/dev/null
printf 'Keep ten.\n' > "$case_home/answer.txt"
captain answer sample-choice --decision-file "$case_home/answer.txt" > "$case_home/answer.out" \
  || fail 'a live captain call could not accept its answer'
assert_grep 'answered: sample-choice' "$case_home/answer.out" 'the live answer was not confirmed'
pass 'the live backlog carries the captain answer'

(cd "$case_home" && tasks-axi prune --keep 0 >/dev/null)
assert_no_grep sample-choice "$case_home/data/backlog.md" 'the call remains in the live backlog'
captain answer sample-choice --decision-file "$case_home/answer.txt" > "$case_home/replay.out" \
  || fail 'the archived answer could not replay'
assert_grep 'answered: sample-choice' "$case_home/replay.out" 'the archived answer was not confirmed'
pass 'the archive carries an idempotent answer replay'

cat > "$case_bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then
  sleep 5
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$case_bin/tasks-axi"
read_status=0
FM_BACKLOG_ROW_TIMEOUT_SECS=1 captain answer sample-choice --decision-file "$case_home/answer.txt" \
  > "$case_home/timeout.out" 2> "$case_home/timeout.err" || read_status=$?
[ "$read_status" -eq 124 ] || fail 'a live read timeout did not stop archive fallback'
assert_grep 'read bound' "$case_home/timeout.err" 'the timeout did not name its read bound'
pass 'a live read timeout cannot accept a stale archive answer'
