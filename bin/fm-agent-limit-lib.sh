# shellcheck shell=bash
# bin/fm-agent-limit-lib.sh - the machine-wide agent count and the concurrent
# agent limit, read from the live Herdr server.
#
# Usage: . bin/fm-agent-limit-lib.sh   (after bin/fm-backend.sh and
# bin/fm-wake-lib.sh; bin/fm-agent-count.sh and bin/fm-spawn.sh both do this)
#
# The count answers one question: how many firstmate workers are really open
# right now? An agent is counted only when all of these are true:
#   - A pane exists in a running Herdr session.
#   - That pane's foreground process is a recognised agent harness. The
#     recognition is the herdr adapter's own process classifier
#     (fm_backend_herdr_recovery_process_snapshot), so there is one owner of
#     which process names are agents.
#   - A firstmate home records that exact session and pane as a ship or scout
#     task (state/<id>.meta with backend=herdr).
# A parked task, a ghost Atlas leg, a closed pane, or a pane whose agent has
# exited therefore never counts, because the count starts from Herdr's live
# panes and never from task records or tickets.
#
# Supervisors are listed but not counted. A supervisor pane is one that MAIN
# records as a kind=secondmate task, or an agent pane whose foreground working
# directory is a known firstmate home (MAIN itself has no task record). An
# agent pane that no home records is listed as unmanaged and is not counted:
# it is the captain's own session, not fleet work.
#
# Homes: the walk starts at the local root home (fm_firstmate_root_home) and
# follows each kind=secondmate record's home= to the secondmate homes, so every
# local home on the machine counts from any one of them. Remote secondmate
# records (remote_host=) name panes on another machine and are skipped.
#
# Sessions: every session a home's Herdr record names, and no other, so a
# test home in a lab session never reads the captain's live session. A session
# whose server is not running holds no agents. Any other Herdr error makes the
# whole count unreadable, and the caller decides.
#
# The limit: config/agent-limit holds one positive integer or the word `off`.
# An absent file means FM_AGENT_LIMIT_DEFAULT. The file is inherited by
# secondmate homes (bin/fm-config-inherit-lib.sh), so the whole fleet shares
# one limit. A malformed file is an error, never a silent default.
#
# The spawn gate (fm_agent_limit_gate) refuses a new agent when the count is
# already at or above the limit. Its overrides are `off` in config/agent-limit
# and fm-spawn's per-spawn --over-limit flag. A caller that brings a closed
# task back into a NEW pane (a resume) adds an agent and must pass through the
# gate; a relaunch into the task's own still-open pane replaces an agent and
# does not.

FM_AGENT_LIMIT_DEFAULT=30
FM_AGENT_LIMIT_CONFIG_NAME=agent-limit

# fm_agent_limit_source <config-dir>: print default when config/agent-limit
# is absent, else config.
fm_agent_limit_source() {
  if [ -e "$1/$FM_AGENT_LIMIT_CONFIG_NAME" ] || [ -L "$1/$FM_AGENT_LIMIT_CONFIG_NAME" ]; then
    printf "config\n"
  else
    printf "default\n"
  fi
}

# fm_agent_limit_read <config-dir>: print the effective limit, a positive
# integer or `off`. A malformed file prints an error on stderr and returns 1.
fm_agent_limit_read() {
  local file="$1/$FM_AGENT_LIMIT_CONFIG_NAME" value
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' "$FM_AGENT_LIMIT_DEFAULT"
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file must be a readable regular file" >&2
    return 1
  fi
  value=$(tr -d '[:space:]' < "$file")
  case "$value" in
    off) printf 'off\n' ;;
    ''|*[!0-9]*|0*)
      echo "error: $file must hold one positive whole number or the word off (got '$value')" >&2
      return 1
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# fm_agent_limit_homes <start-home>: print "<home-id>\t<path>" for the root
# home (id main) and every local secondmate home reachable from it.
fm_agent_limit_homes() {
  local root queue=() seen='|' home id child next metas
  root=$(fm_firstmate_root_home "$1") || return 1
  queue=("main"$'\t'"$root")
  while [ "${#queue[@]}" -gt 0 ]; do
    next=${queue[0]}
    queue=("${queue[@]:1}")
    id=${next%%$'\t'*}
    home=${next#*$'\t'}
    case "$seen" in *"|$home|"*) continue ;; esac
    seen="$seen$home|"
    printf '%s\t%s\n' "$id" "$home"
    metas=("$home"/state/*.meta)
    [ -f "${metas[0]}" ] || continue
    while IFS=$'\t' read -r id child; do
      [ -n "$child" ] || continue
      child=$(CDPATH='' cd -- "$child" 2>/dev/null && pwd -P) || continue
      queue+=("$id"$'\t'"$child")
    done <<EOF
$(awk '
      function flush(   task) {
        if (file == "" || v["kind"] != "secondmate" || v["remote_host"] != "" || v["home"] == "") return
        task = file; sub(/^.*\//, "", task); sub(/\.meta$/, "", task)
        printf "%s\t%s\n", task, v["home"]
      }
      FNR == 1 { flush(); file = FILENAME; delete v }
      { eq = index($0, "="); if (eq > 1) v[substr($0, 1, eq - 1)] = substr($0, eq + 1) }
      END { flush() }
    ' "${metas[@]}")
EOF
  done
}

# fm_agent_limit_records <homes-tsv>: print one TSV row per local Herdr task
# record: session, pane, home-id, task, kind, harness. One awk pass per home
# reads the same last-assignment-wins fields as fm_meta_get and splits
# window= on its first colon exactly as fm_backend_herdr_parse_target does.
fm_agent_limit_records() {
  local homes=$1 id home metas
  while IFS=$'\t' read -r id home; do
    [ -n "$home" ] || continue
    metas=("$home"/state/*.meta)
    [ -f "${metas[0]}" ] || continue
    awk -v home="$id" '
      function flush(   task, session, pane) {
        if (file == "" || v["backend"] != "herdr" || v["remote_host"] != "") return
        session = v["window"]; sub(/:.*/, "", session)
        pane = substr(v["window"], length(session) + 2)
        if (session == "" || pane == "" || index(v["window"], ":") == 0) return
        task = file; sub(/^.*\//, "", task); sub(/\.meta$/, "", task)
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", session, pane, home, task, v["kind"], v["harness"]
      }
      FNR == 1 { flush(); file = FILENAME; delete v }
      { eq = index($0, "="); if (eq > 1) v[substr($0, 1, eq - 1)] = substr($0, eq + 1) }
      END { flush() }
    ' "${metas[@]}"
  done <<EOF
$homes
EOF
}

# fm_agent_limit_session_panes <session>: print the session's pane list as
# JSON, print nothing when its server is not running, and return 1 with an
# error on stderr for any other failure.
fm_agent_limit_session_panes() {
  local session=$1 out code
  out=$(fm_backend_herdr_cli "$session" pane list 2>&1) || true
  code=$(printf '%s' "$out" | jq -r 'if type == "object" then (.error.code // empty) else empty end' 2>/dev/null) || code=unparseable
  case "$code" in
    server_not_running) return 0 ;;
    '') ;;
    *)
      echo "error: herdr pane list failed for session $session: ${out:0:200}" >&2
      return 1
      ;;
  esac
  printf '%s' "$out" | jq -ce '.result.panes | if type == "array" then . else error("no panes") end' 2>/dev/null || {
    echo "error: herdr pane list for session $session returned an unexpected shape: ${out:0:200}" >&2
    return 1
  }
}

# fm_agent_limit_count_json <start-home> [session...]: print the count document.
# With no sessions, the sessions are those the homes' records name.
# Returns 1 with an error on stderr when Herdr cannot be read.
fm_agent_limit_count_json() {
  local start=$1 homes records sessions session panes pane_rows pane ws cwd snapshot agent_name
  local out='' unreadable=''
  shift
  homes=$(fm_agent_limit_homes "$start") || {
    echo "error: could not resolve the firstmate root home from $start" >&2
    return 1
  }
  records=$(fm_agent_limit_records "$homes")
  if [ "$#" -gt 0 ]; then
    sessions=$(printf '%s\n' "$@")
  else
    sessions=$(printf '%s\n' "$records" | cut -f1 | awk 'NF && !seen[$0]++')
  fi
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    panes=$(fm_agent_limit_session_panes "$session") || return 1
    [ -n "$panes" ] || continue
    pane_rows=$(printf '%s' "$panes" | jq -r '.[] | [.pane_id, (.workspace_id // ""), (.foreground_cwd // .cwd // "")] | @tsv')
    while IFS=$'\t' read -r pane ws cwd; do
      [ -n "$pane" ] || continue
      if ! snapshot=$(fm_backend_herdr_recovery_process_snapshot "$session" "$pane"); then
        unreadable="$unreadable$session"$'\t'"$pane"$'\n'
        continue
      fi
      agent_name=$(printf '%s' "$snapshot" | jq -r '
        [.foreground_processes[] | select(.agent or .codex_mainthread)
          | if .codex_mainthread then "codex" else .name end] | first // empty')
      [ -n "$agent_name" ] || continue
      cwd=$(CDPATH='' cd -- "$cwd" 2>/dev/null && pwd -P) || true
      out="$out$session"$'\t'"$pane"$'\t'"$ws"$'\t'"$cwd"$'\t'"$agent_name"$'\n'
    done <<EOF
$pane_rows
EOF
  done <<EOF
$sessions
EOF
  jq -n \
    --arg panes "$out" --arg records "$records" --arg homes "$homes" \
    --arg unreadable "$unreadable" --arg sessions "$sessions" '
    def rows($s): $s | split("\n") | map(select(length > 0) | split("\t"));
    (rows($records) | map({key: (.[0] + "\t" + .[1]), value: {home: .[2], task: .[3], kind: .[4], harness: .[5]}}) | from_entries) as $rec
    | (rows($homes) | map({key: .[1], value: .[0]}) | from_entries) as $home_of
    | rows($panes) | map(
        {session: .[0], pane: .[1], workspace: .[2], cwd: .[3], process: .[4]} as $p
        | ($rec[$p.session + "\t" + $p.pane]) as $r
        | {session: $p.session, pane: $p.pane, workspace: $p.workspace,
           home: (if $r.kind == "secondmate" then $r.task else ($r.home // $home_of[$p.cwd] // null) end),
           task: ($r.task // null), kind: ($r.kind // null),
           harness: (if ($r.harness // "") != "" then $r.harness else $p.process end),
           role: (if $r == null then (if $home_of[$p.cwd] then "supervisor" else "unmanaged" end)
                  elif ($r.kind == "ship" or $r.kind == "scout") then "crewmate"
                  elif $r.kind == "secondmate" then "supervisor"
                  else "unmanaged" end)})
    | {count: (map(select(.role == "crewmate")) | length),
       sessions: rows($sessions) | map(.[0]),
       agents: map(select(.role == "crewmate") | del(.role)),
       supervisors: map(select(.role == "supervisor") | del(.role)),
       unmanaged: map(select(.role == "unmanaged") | del(.role)),
       unreadable: (rows($unreadable) | map({session: .[0], pane: .[1]}))}'
}

# fm_agent_limit_gate <start-home> <config-dir>: return 0 when one more agent
# may start, or print the refusal on stderr and return 1. A limit of off passes
# without reading Herdr. An unreadable limit file or Herdr count refuses rather
# than guessing. Two spawns that check at the same moment can both pass: the
# limit spreads work out and is not a reservation.
fm_agent_limit_gate() {
  local start=$1 config=$2 limit doc count
  local override="pass --over-limit to start this one anyway, or write a larger number or off to $config/$FM_AGENT_LIMIT_CONFIG_NAME"
  limit=$(fm_agent_limit_read "$config") || {
    echo "error: spawn refused: the agent limit could not be read; fix the file, or $override" >&2
    return 1
  }
  [ "$limit" != off ] || return 0
  doc=$(fm_agent_limit_count_json "$start") || {
    echo "error: spawn refused: the agent count could not be read from Herdr; $override" >&2
    return 1
  }
  count=$(printf '%s' "$doc" | jq -r '.count')
  [ "$count" -ge "$limit" ] || return 0
  echo "error: spawn refused: agent limit reached: $count agents are open in Herdr and the limit is $limit ($(fm_agent_limit_source "$config") value); $override. bin/fm-agent-count.sh lists them." >&2
  return 1
}
