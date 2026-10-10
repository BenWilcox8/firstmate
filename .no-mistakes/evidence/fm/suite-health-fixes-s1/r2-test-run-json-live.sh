#!/usr/bin/env bash
# Live drive of the node JSON writers in bin/fm-test-run.sh (--json,
# --aggregate-json) and bin/fm-test-isolation-proof.sh (--json) on a host with
# no python3. Artifacts land in a throwaway dir; key layout is checked with jq.
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-json-r2.XXXXXX)
cd "$ROOT"
echo "python3 on PATH: $(command -v python3 || echo none)"
run() { printf '\n$ %s\n' "$*" | sed "s|$T|<tmp>|g"; "$@" 2>&1 | sed "s|$T|<tmp>|g"; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }
run bin/fm-test-run.sh --json "$T/lane-a.json" tests/fm-ensure-agents-md.test.sh
run bin/fm-test-run.sh --json "$T/lane-b.json" tests/fm-documentation-audiences.test.sh
echo; echo "--- lane-a.json (raw bytes: 2-space indent, sorted keys) ---"; cat "$T/lane-a.json"
echo "--- jq: keys sorted at every level? $(jq '[paths(objects) as $p | getpath($p) | keys_unsorted == (keys_unsorted|sort)] | all' "$T/lane-a.json")"
echo "--- trailing newline present: $(tail -c1 "$T/lane-a.json" | od -An -c | tr -d ' ')"
run bin/fm-test-run.sh --aggregate-json "$T/out/aggregate.json" "$T/./lane-a.json" "$T//lane-b.json"
echo "--- aggregate.json projection ---"
jq '{kind, summary, lanes: [.lanes[] | {path, selection, total: .summary.total}], slowest: [.slowest[] | {path, duration_ms, lane_selection}]}' "$T/out/aggregate.json" | sed "s|$T|<tmp>|g"
echo; echo "== adversarial: a lane that is a JSON array, not an object"
printf '[1,2]\n' > "$T/bad-array.json"
run bin/fm-test-run.sh --aggregate-json "$T/out/bad.json" "$T/lane-a.json" "$T/bad-array.json"
echo "bad.json written: $([ -e "$T/out/bad.json" ] && echo yes || echo no)"
echo; echo "== adversarial: a lane whose summary.total is not an integer"
jq '.summary.total = "seven"' "$T/lane-a.json" > "$T/bad-total.json"
run bin/fm-test-run.sh --aggregate-json "$T/out/bad2.json" "$T/bad-total.json"
echo; echo "== adversarial: no input lanes"
run bin/fm-test-run.sh --aggregate-json "$T/out/none.json"
echo; echo "== non-ASCII selection label is written as an ASCII \\u escape"
jq '.selection = "lane é ☕"' "$T/lane-b.json" > "$T/lane-u.json"
run bin/fm-test-run.sh --aggregate-json "$T/out/u.json" "$T/lane-u.json"
grep -m2 'lane_selection\|"selection"' "$T/out/u.json"
echo; echo "== fm-test-isolation-proof.sh --json (pool browser-reap, one worker)"
run bin/fm-test-isolation-proof.sh --pool browser-reap --jobs 1 --json "$T/proof.json"
cat "$T/proof.json"
rm -rf "$T"
