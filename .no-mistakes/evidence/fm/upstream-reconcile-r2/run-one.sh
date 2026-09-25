#!/usr/bin/env bash
# Run one test file with the NixOS host tools, capture its transcript.
cd /home/ben/.no-mistakes/worktrees/3665d600861c/01M3B2RWBFZDJ8A8R6D9BB124Q
E=/home/ben/.no-mistakes/evidence/01M3B2RWBFZDJ8A8R6D9BB124Q
export PATH="/nix/store/bkbh352n0nf0jfvp9nac5mb7n5qzfcws-lsof-4.99.7/bin:/nix/store/lql1xkaqmzn68zlhjymk9ni0826ggl24-ruby-3.4.9/bin:/nix/store/rgnappqqc5vbq60gza5fflyk84sylwl6-python3-3.14.6/bin:$PATH"
export FM_CHROME_BIN=/nix/store/5prcsr1v91xai06jmpxxh3wh4c79h0s6-chromium-150.0.7871.181/bin/chromium
unset AI_AGENT CLAUDECODE CLAUDE_EFFORT CLAUDE_PID FM_TASK_ID
t=$1; name=$(basename "$t" .test.sh)
start=$(date +%s)
nice -n 10 bash "$t" > "$E/$name.log" 2>&1; rc=$?
printf '%s rc=%s secs=%s\n' "$t" "$rc" "$(( $(date +%s) - start ))" | tee -a "$E/summary.txt"
exit $rc
