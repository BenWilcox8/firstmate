#!/usr/bin/env bash
# Targeted tests for this change, one at a time under nice -n 10 (host memory care).
cd /home/ben/.no-mistakes/worktrees/3665d600861c/01M3ABN3VSHRMXK7ZJBA7TAA18
export PATH="/nix/store/bkbh352n0nf0jfvp9nac5mb7n5qzfcws-lsof-4.99.7/bin:/nix/store/lql1xkaqmzn68zlhjymk9ni0826ggl24-ruby-3.4.9/bin:/nix/store/rgnappqqc5vbq60gza5fflyk84sylwl6-python3-3.14.6/bin:$PATH"
export FM_HERDR_LAB_HELPER=/home/ben/firstmate/bin/fm-herdr-lab.sh
unset AI_AGENT CLAUDECODE CLAUDE_EFFORT CLAUDE_PID FM_TASK_ID
for t in fm-local-typing-provenance fm-local-send-provenance fm-local-codex-idle-frames fm-teardown fm-pr-merge fm-control-relaunch fm-lint; do
  s=$(date +%s); nice -n 10 bash tests/$t.test.sh > /home/ben/.no-mistakes/evidence/01M3ABN3VSHRMXK7ZJBA7TAA18/$t.log 2>&1; rc=$?
  echo "$t rc=$rc secs=$(( $(date +%s) - s ))" >> /home/ben/.no-mistakes/evidence/01M3ABN3VSHRMXK7ZJBA7TAA18/serial-summary.txt
done
echo DONE >> /home/ben/.no-mistakes/evidence/01M3ABN3VSHRMXK7ZJBA7TAA18/serial-summary.txt
