#!/usr/bin/env bash
# Runs the four broader suites serially under nice -n 10 and records exit status.
set -u
E=/home/ben/.no-mistakes/evidence/01M39P2Q4RY2230DGVBRDQWTXV
W=/home/ben/.no-mistakes/worktrees/3665d600861c/01M39P2Q4RY2230DGVBRDQWTXV
export PATH=/nix/store/bkbh352n0nf0jfvp9nac5mb7n5qzfcws-lsof-4.99.7/bin:/nix/store/zm1bfv9agv7v007kn3cylf8hjd2wbkrb-python3-3.12.13/bin:$PATH
cd "$W"
HEAD=$(git rev-parse HEAD)
: > "$E/broad-suites-status.txt"
echo "head=$HEAD" >> "$E/broad-suites-status.txt"
for s in fm-inactive-reconcile fm-teardown-endpoint-safety fm-backend-orca fm-teardown; do
  start=$(date +%s)
  { echo "== suite=$s head=$HEAD start=$(date -Is)"; } > "$E/$s.log"
  nice -n 10 bash "tests/$s.test.sh" >> "$E/$s.log" 2>&1
  rc=$?
  end=$(date +%s)
  echo "== exit=$rc elapsed=$((end-start))s end=$(date -Is)" >> "$E/$s.log"
  echo "$s exit=$rc elapsed=$((end-start))s" >> "$E/broad-suites-status.txt"
done
echo "done" >> "$E/broad-suites-status.txt"
