#!/usr/bin/env bash
# Treehouse slot owner proof: the one owner of the owner-liveness and ancestry
# rules that bin/fm-local-retire-reassigned.sh and bin/fm-local-worker-restore.sh
# use. Treehouse records the slot owner as owner_pid and owner_started_at (epoch
# milliseconds). The proof reads /proc, so a host without it proves nothing.

fm_local_proc_field() {  # <pid> <index after the command name>
  local stat fields
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a fields <<< "${stat##*)}"
  [ -n "${fields[$2]:-}" ] || return 1
  printf '%s\n' "${fields[$2]}"
}

# The owner still runs with the start time Treehouse recorded, so a reused pid
# never reads as the owner.
fm_local_treehouse_owner_live() {  # <pid> <started-ms>
  local ticks btime hz
  ticks=$(fm_local_proc_field "$1" 19) || return 1
  btime=$(awk '$1 == "btime" {print $2}' /proc/stat 2>/dev/null) || return 1
  hz=$(getconf CLK_TCK 2>/dev/null) || return 1
  [ -n "$btime" ] && [ -n "$hz" ] || return 1
  [ "$((btime * 1000 + ticks * 1000 / hz))" = "$2" ]
}

fm_local_descends_from() {  # <pid> <ancestor>
  local pid=$1 depth
  for ((depth=0; depth<64; depth++)); do
    [ "$pid" != "$2" ] || return 0
    [ "$pid" -gt 1 ] 2>/dev/null || return 1
    pid=$(fm_local_proc_field "$pid" 1) || return 1
  done
  return 1
}
