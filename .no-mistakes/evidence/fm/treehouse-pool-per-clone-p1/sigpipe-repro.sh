#!/usr/bin/env bash
# Usage: sigpipe-repro.sh <fm-root> <workers> <calls-per-worker>
# Runs the exact quota-choose command from tests/fm-quota-choose.test.sh
# ("unmapped omp prefix") with SIGPIPE ignored (as on GitHub runners), many
# workers at once to create load, and counts calls whose captured stderr is
# not exactly the expected single error line.
root=$1 workers=$2 calls=$3
expected='error: omp quota mapping covers only the openai-codex and claude-bridge prefixes: ollama/qwen3:8b'
out=$(mktemp -d)
trap '' PIPE
for w in $(seq 1 "$workers"); do
  (
    bad=0
    for _ in $(seq 1 "$calls"); do
      err=$("$root/bin/fm-quota-choose.sh" --snapshot /tmp/fmq-snap.json \
        --candidate omp:ollama/qwen3:8b --candidate claude:claude-3-5-sonnet 2>&1)
      if [ "$err" != "$expected" ]; then
        bad=$((bad + 1)); printf '%s\n---\n' "$err" >> "$out/bad.$w"
      fi
    done
    echo "$bad" > "$out/count.$w"
  ) &
done
wait
total=$(cat "$out"/count.* | paste -sd+ | bc)
echo "root=$root calls=$((workers * calls)) mismatched_stderr=$total"
if [ "$total" -gt 0 ]; then echo "distinct extra stderr lines (count line):"; cat "$out"/bad.* | grep -v -e "^---$" -e "^error: omp quota" | sort | uniq -c; fi
rm -rf "$out"
