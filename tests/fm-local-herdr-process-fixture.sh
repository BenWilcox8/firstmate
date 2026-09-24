#!/usr/bin/env bash
# Real idle shell for process evidence in deterministic Herdr fixtures.
# Source this file and call fm_local_test_shell_start <private-temp-dir>.
# The caller kills and waits for FM_LOCAL_TEST_SHELL_PID during cleanup.
fm_local_test_shell_start() {
  local monitor=0
  [[ $- != *m* ]] || monitor=1
  mkfifo "$1/shell-input"
  set -m
  bash --noprofile --norc -c 'exec 3<>"$1"; IFS= read -r <&3' _ "$1/shell-input" </dev/null >/dev/null 2>&1 &
  FM_LOCAL_TEST_SHELL_PID=$!
  export FM_LOCAL_TEST_SHELL_PID
  [ "$monitor" = 1 ] || set +m
  sleep 0.1
}

# When executed, emit the structural process-info response for the requested
# fake pane. The kernel process table remains real.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  pane=
  while [ "$#" -gt 0 ]; do
    case "$1" in --pane) pane=$2; shift 2 ;; *) shift ;; esac
  done
  jq -n --arg pane "$pane" --argjson pid "$FM_LOCAL_TEST_SHELL_PID" '
    {result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:$pid,
      foreground_process_group_id:$pid,
      foreground_processes:[{pid:$pid,name:"bash",argv:["bash"]}]}}}'
fi
