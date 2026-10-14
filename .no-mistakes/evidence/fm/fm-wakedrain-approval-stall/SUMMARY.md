# Live validation: Claude secondmate acknowledgement pre-approval

Target commit 2cf78a8 (fixed bin/fm-spawn.sh). Base commit 2812e3c (pre-fix bin/fm-spawn.sh). Claude Code 2.1.300. Herdr 0.8.2.
Driver: drive-ack-allow.sh. It ran in an isolated fm-lab-* Herdr session through bin/fm-herdr-lab.sh. Teardown passed and the default-session tripwire held.
Each launch ran in a real Herdr pane. A PATH claude wrapper recorded the exact argv that the pane shell delivered.
The wrapper then ran the real Claude Code with the same permission flag and --settings, in print mode, with a test prompt in place of the secondmate brief.
The home's fm-wake-drain.sh and fm-ping-ack.sh were stubs that print their arguments. The rules match command text and the home path, not script content.
Lab setup: the pane shell ran bash without rc files (FM_BACKEND_HERDR_AXI_LAUNCH seam). Without this, ~/.bashrc puts ~/.npm-global/bin/claude ahead of the wrapper.

## Launched settings and auto-mode permission decisions

### A. pre-fix spawn of secondmate sm-ack (seeded home), config/claude-permission-mode=auto
```
permission flag: --permission-mode auto
--settings: {"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}
permissionDecisionMs=1190  bin/fm-wake-drain.sh --ack-through 7 --recovery-generation g1.x
permissionDecisionMs=627  /tmp/fm-ackallow.GCO0Y6/sm-home/bin/fm-wake-drain.sh --ack-through 8
permissionDecisionMs=751  bin/fm-ping-ack.sh --origin script --wake heartbeat
```

### B. fixed-code relaunch of the EXISTING secondmate sm-ack
```
permission flag: --permission-mode auto
--settings: {"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},"permissions":{"allow":["Bash(bin/fm-wake-drain.sh)","Bash(bin/fm-wake-drain.sh *)","Bash(bin/fm-ping-ack.sh)","Bash(bin/fm-ping-ack.sh *)","Bash(/tmp/fm-ackallow.GCO0Y6/sm-home/bin/fm-wake-drain.sh)","Bash(/tmp/fm-ackallow.GCO0Y6/sm-home/bin/fm-wake-drain.sh *)","Bash(/tmp/fm-ackallow.GCO0Y6/sm-home/bin/fm-ping-ack.sh)","Bash(/tmp/fm-ackallow.GCO0Y6/sm-home/bin/fm-ping-ack.sh *)"]}}
debug: Adding 8 allow rule(s) to destination 'flagSettings'
permissionDecisionMs=488  cat bin/fm-wake-drain.sh bin/fm-ping-ack.sh; echo ---; cat bin/fm-wake-drain.sh.evil
permissionDecisionMs=3  bin/fm-wake-drain.sh --ack-through 7 --recovery-generation g1.x
permissionDecisionMs=3  /tmp/fm-ackallow.GCO0Y6/sm-home/bin/fm-wake-drain.sh --ack-through 8
permissionDecisionMs=2  bin/fm-ping-ack.sh --origin script --wake heartbeat
```

### C. fixed-code spawn of a NEW secondmate home sm-new
```
permission flag: --permission-mode auto
--settings: {"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},"permissions":{"allow":["Bash(bin/fm-wake-drain.sh)","Bash(bin/fm-wake-drain.sh *)","Bash(bin/fm-ping-ack.sh)","Bash(bin/fm-ping-ack.sh *)","Bash(/tmp/fm-ackallow.GCO0Y6/sm-new-home/bin/fm-wake-drain.sh)","Bash(/tmp/fm-ackallow.GCO0Y6/sm-new-home/bin/fm-wake-drain.sh *)","Bash(/tmp/fm-ackallow.GCO0Y6/sm-new-home/bin/fm-ping-ack.sh)","Bash(/tmp/fm-ackallow.GCO0Y6/sm-new-home/bin/fm-ping-ack.sh *)"]}}
debug: Adding 8 allow rule(s) to destination 'flagSettings'
permissionDecisionMs=6  bin/fm-wake-drain.sh --ack-through 7 --recovery-generation g1.x
permissionDecisionMs=3  /tmp/fm-ackallow.GCO0Y6/sm-new-home/bin/fm-wake-drain.sh --ack-through 8
permissionDecisionMs=2  bin/fm-ping-ack.sh --origin script --wake heartbeat
```

Pre-fix, every acknowledgement logged "Permission suggestions for Bash" (no rule matched) and waited for the auto-mode classifier (627-1190 ms).
Fixed, the 8 rules load into flagSettings, none is removed by auto mode, and each acknowledgement is decided in 2-6 ms without the classifier.
In launch B the model also ran 'cat ...' on its own. That command is not on the list, so it still went to the classifier (488 ms).

## dontAsk probes with the exact launched --settings (control = pre-fix settings, fixed = launch C settings)

### arm=control
```
 1.   bin/fm-wake-drain.sh --ack-through 7 --recovery-generation g1.x
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 2.   /tmp/fm-ackallow.GCO0Y6/sm-new-home/bin/fm-wake-drain.sh
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 3.   bin/fm-ping-ack.sh --origin script --wake w1 --note done
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 4.   bin/fm-wake-drain.sh --ack-through 9 && bin/fm-ping-ack.sh --origin script
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 5.   bin/fm-wake-drain.sh --ack-through 1; touch /tmp/fm-ackallow.GCO0Y6/marks/control/pwned-compound
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 6.   bin/fm-wake-drain.sh $(touch /tmp/fm-ackallow.GCO0Y6/marks/control/pwned-subst)
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 7.   bin/fm-wake-drain.sh.evil
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 8.   /tmp/fm-ackallow.GCO0Y6/evil-home/bin/fm-wake-drain.sh --ack-through 1
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 9.   touch /tmp/fm-ackallow.GCO0Y6/marks/control/pwned-plain
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
10.   bash bin/fm-wake-drain.sh --ack-through 1
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
```

### arm=fixed
```
 1.   bin/fm-wake-drain.sh --ack-through 7 --recovery-generation g1.x
      ->   err=false DRAIN_RAN[sm-new] --ack-through 7 --recovery-generation g1.x
 2.   /tmp/fm-ackallow.GCO0Y6/sm-new-home/bin/fm-wake-drain.sh
      ->   err=false DRAIN_RAN[sm-new]
 3.   bin/fm-ping-ack.sh --origin script --wake w1 --note done
      ->   err=false PING_RAN[sm-new] --origin script --wake w1 --note done
 4.   bin/fm-wake-drain.sh --ack-through 9 && bin/fm-ping-ack.sh --origin script
      ->   err=false DRAIN_RAN[sm-new] --ack-through 9 PING_RAN[sm-new] --origin script
 5.   bin/fm-wake-drain.sh --ack-through 1; touch /tmp/fm-ackallow.GCO0Y6/marks/fixed/pwned-compound
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 6.   bin/fm-wake-drain.sh $(touch /tmp/fm-ackallow.GCO0Y6/marks/fixed/pwned-subst)
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 7.   bin/fm-wake-drain.sh.evil
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 8.   /tmp/fm-ackallow.GCO0Y6/evil-home/bin/fm-wake-drain.sh --ack-through 1
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
 9.   touch /tmp/fm-ackallow.GCO0Y6/marks/fixed/pwned-plain
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
10.   bash bin/fm-wake-drain.sh --ack-through 1
      ->   err=true Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may*
```

Marker files created by any probe: none (see live/marks.txt). EVIL stub runs in live/ran.log: none.
