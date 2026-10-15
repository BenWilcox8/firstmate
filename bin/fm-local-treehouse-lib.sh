#!/usr/bin/env bash
# Treehouse slot owner proof: the one owner of the owner-liveness, ancestry, and
# slot-ordering rules that bin/fm-local-retire-reassigned.sh and
# bin/fm-local-worker-restore.sh use. Treehouse records the slot owner as
# owner_pid and owner_started_at (epoch milliseconds). The proof reads /proc, so
# a host without it proves nothing. Callers source bin/fm-backend.sh first.

# The spawn epoch from spawn_gen=s<epoch>.<pid>.<n>, which orders the records
# that name one slot. An empty or non-numeric epoch prints nothing and returns 1.
fm_local_spawn_epoch() {  # <meta>
  local gen
  gen=$(fm_meta_get "$1" spawn_gen)
  gen=${gen#s}
  gen=${gen%%.*}
  case "$gen" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$gen"
}

fm_local_proc_field() {  # <pid> <index after the command name>
  local stat fields
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a fields <<< "${stat##*)}"
  [ -n "${fields[$2]:-}" ] || return 1
  printf '%s\n' "${fields[$2]}"
}

# The owner still runs with the start time Treehouse recorded, so a reused pid
# never reads as the owner. Returns 0 when it runs, 1 when a readable /proc
# shows the pid absent or started at another time, and 2 when /proc cannot
# prove either.
fm_local_treehouse_owner_live() {  # <pid> <started-ms>
  local ticks btime hz
  case "$1" in ''|*[!0-9]*) return 2 ;; esac
  btime=$(awk '$1 == "btime" {print $2}' /proc/stat 2>/dev/null) || return 2
  hz=$(getconf CLK_TCK 2>/dev/null) || return 2
  [ -n "$btime" ] && [ -n "$hz" ] || return 2
  if ! ticks=$(fm_local_proc_field "$1" 19); then
    [ ! -e "/proc/$1" ] || return 2
    return 1
  fi
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
