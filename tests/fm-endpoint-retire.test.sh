#!/usr/bin/env bash
# Endpoint retirement: no replacement may leave the pane it stopped naming open.
#
# A task's durable record names exactly one endpoint. Three paths change that
# name - bin/fm-control.sh relaunch, the replacement spawn stuck recovery and
# secondmate liveness recovery drive through bin/fm-spawn.sh, and the secondmate
# liveness sweep in bin/fm-bootstrap.sh - and any of them that rewrites the name
# without closing the old endpoint leaves an unreferenced husk pane behind.
#
# These regressions pin the contract end to end, against fake backend adapters
# that record every close and open call in order:
#   1. fm_backend_endpoint_retire proves the close on both state-verified
#      backends, refuses to close a live agent's endpoint, treats an absent
#      endpoint as already retired, and never reports an unconfirmed close as
#      success - including on a backend with no recovery-grade classifier.
#   2. A replacement spawn closes the endpoint the record still names BEFORE the
#      new window value lands, reuses a target it resolved to the same endpoint
#      without closing anything, and names the leftover pane when the close
#      cannot be proven instead of succeeding silently.
#   3. A relaunch adopts its endpoint: no close, no open, same recorded window,
#      so the task still holds exactly one pane afterwards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-retire)
TASK_TMPS=()

retire_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap retire_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# --- fake backend adapters ---------------------------------------------------
#
# Both fakes append one line per call to <dir>/calls, so an assertion reads the
# close and open calls in the order the code actually made them. Neither fake
# encodes any expectation about how the production code is written: they model
# panes and windows, and answer the same probes the real CLIs answer.

# make_fake_herdr <dir>: a herdr CLI over <dir>/panes (structurally present pane
# ids) and <dir>/agents (pane ids with a registered agent). FM_FAKE_HERDR_STUCK
# names a pane whose close is accepted but never removes it - the unprovable
# close a retire must refuse to report as success.
make_fake_herdr() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/herdr"
  : > "$dir/herdr/calls"
  : > "$dir/herdr/panes"
  : > "$dir/herdr/agents"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_HERDR_DIR
printf '%s\n' "$*" >> "$D/calls"
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"protocol":14,"version":"test"},"server":{"running":true}}' ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/sock"}]}\n' "$D" ;;
  "pane get")
    if grep -qxF "${3:-}" "$D/panes"; then
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi ;;
  "agent get")
    if grep -qxF "${3:-}" "$D/agents"; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
      exit 1
    fi ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_STUCK:-}" != "${3:-}" ]; then
      grep -vxF "${3:-}" "$D/panes" > "$D/panes.next" || :
      mv "$D/panes.next" "$D/panes"
    fi ;;
  *) ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# make_fake_tmux <dir>: a tmux CLI over <dir>/tmux/windows.<session> (one window
# name per line) and <dir>/tmux/command.<session>:<window> (that window's
# foreground command, default zsh). FM_FAKE_TMUX_STUCK names a window whose
# kill-window is accepted but never removes it. FM_FAKE_TMUX_META, when set,
# makes every kill-window record the window value the task record holds AT THAT
# MOMENT, which is how the ordering assertion reads "closed before the new
# window was recorded" without touching the implementation's own bytes.
make_fake_tmux() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/tmux"
  : > "$dir/tmux/calls"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_TMUX_DIR
target=
prev=
for a in "$@"; do
  [ "$prev" = "-t" ] && target=$a
  prev=$a
done
target=${target#=}
target=${target/:=/:}
ses=${target%%:*}
win=${target#*:}
case "${1:-}" in
  display-message)
    printf '%s\n' "display-message $*" >> "$D/calls"
    for a in "$@"; do
      case "$a" in
        '#S') printf 'firstmate\n'; exit 0 ;;
        '#{pane_tty}') exit 0 ;;
        '#{cursor_y}') printf '1\n'; exit 0 ;;
        '#{pane_id}') printf 'fakepane\n'; exit 0 ;;
        '#{pane_current_path}') printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
        '#{pane_current_command}')
          if [ -f "$D/command.$ses:$win" ]; then cat "$D/command.$ses:$win"; else printf 'zsh\n'; fi
          exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  list-windows)
    printf '%s\n' "list-windows $ses" >> "$D/calls"
    if [ -f "$D/windows.$ses" ]; then cat "$D/windows.$ses"; exit 0; fi
    printf "can't find session: %s\n" "$ses" >&2
    exit 1 ;;
  new-window)
    for a in "$@"; do
      [ "$prev" = "-n" ] && win=$a
      prev=$a
    done
    printf '%s\n' "open firstmate:$win" >> "$D/calls"
    printf '%s\n' "$win" >> "$D/windows.firstmate"
    printf '@%s\n' "$RANDOM"
    exit 0 ;;
  kill-window)
    if [ -n "${FM_FAKE_TMUX_META:-}" ] && [ -f "$FM_FAKE_TMUX_META" ]; then
      printf '%s\n' "close $ses:$win record=$(grep '^window=' "$FM_FAKE_TMUX_META" | tail -1)" >> "$D/calls"
    else
      printf '%s\n' "close $ses:$win" >> "$D/calls"
    fi
    if [ "${FM_FAKE_TMUX_STUCK:-}" != "$win" ] && [ -f "$D/windows.$ses" ]; then
      grep -vxF "$win" "$D/windows.$ses" > "$D/windows.$ses.next" || :
      mv "$D/windows.$ses.next" "$D/windows.$ses"
    fi
    exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command.${FM_FAKE_TMUX_AGENT_WINDOW:-none}" ;;
        *'encode launch-brief'*) printf 'claude' > "$D/command.${FM_FAKE_TMUX_AGENT_WINDOW:-none}" ;;
      esac
    fi
    exit 0 ;;
  capture-pane) printf 'x\n'; exit 0 ;;
  has-session|new-session|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

calls_of() {  # <dir>/<kind>
  cat "$1/calls" 2>/dev/null
}

assert_call_order() {  # <calls-text> <first-pattern> <second-pattern> <msg>
  local text=$1 first=$2 second=$3 msg=$4 fi si
  fi=$(printf '%s\n' "$text" | grep -nF -- "$first" | head -1 | cut -d: -f1)
  si=$(printf '%s\n' "$text" | grep -nF -- "$second" | head -1 | cut -d: -f1)
  [ -n "$fi" ] || fail "$msg (never recorded: $first) - calls: $text"
  [ -n "$si" ] || fail "$msg (never recorded: $second) - calls: $text"
  [ "$fi" -lt "$si" ] || fail "$msg (order was $second then $first) - calls: $text"
}

# --- 1. the adapter contract -------------------------------------------------

# retire_in <fakebin> <env-assignments...>: run fm_backend_endpoint_retire with
# RETIRE_ARGS in a clean shell and echo the verdict.
retire_in() {  # <fakebin> [<env-assignment>...]
  local fakebin=$1
  shift
  env PATH="$fakebin:$PATH" "$@" bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    shift
    if fm_backend_endpoint_retire "$@"; then
      printf "retired\n"
    else
      printf "left-open: %s\n" "$FM_BACKEND_ENDPOINT_RETIRE_REASON"
    fi
  ' _ "$ROOT" "${RETIRE_ARGS[@]}"
}

test_herdr_husk_is_closed_and_proven_gone() {
  local dir=$TMP_ROOT/herdr-husk fakebin out
  mkdir -p "$dir"
  fakebin=$(make_fake_herdr "$dir")
  printf '%s\n' p-old > "$dir/herdr/panes"

  RETIRE_ARGS=(herdr default:p-old "" fm-t1)
  out=$(retire_in "$fakebin" FM_HOME="$dir" FM_FAKE_HERDR_DIR="$dir/herdr" \
    FM_BACKEND_HERDR_AXI_BIN=)
  [ "$out" = retired ] || fail "a confirmed Herdr husk should retire cleanly, got: $out"
  assert_contains "$(calls_of "$dir/herdr")" "pane close p-old" \
    "the retire never asked the backend to close the husk pane"
  pass "endpoint retire: a Herdr husk pane is closed and proven gone"
}

test_herdr_unprovable_close_is_reported() {
  local dir=$TMP_ROOT/herdr-stuck fakebin out
  mkdir -p "$dir"
  fakebin=$(make_fake_herdr "$dir")
  printf '%s\n' p-stuck > "$dir/herdr/panes"

  RETIRE_ARGS=(herdr default:p-stuck "" fm-t1)
  out=$(retire_in "$fakebin" FM_HOME="$dir" FM_FAKE_HERDR_DIR="$dir/herdr" \
    FM_FAKE_HERDR_STUCK=p-stuck FM_BACKEND_HERDR_AXI_BIN=)
  case "$out" in
    left-open:*) ;;
    *) fail "a close that left the pane behind was reported as retired: $out" ;;
  esac
  assert_contains "$out" "could not confirm the close" \
    "the refusal did not say the close was unconfirmed"
  pass "endpoint retire: an unconfirmed Herdr close is never reported as retired"
}

test_live_agent_endpoint_is_never_closed() {
  local dir=$TMP_ROOT/herdr-live fakebin out
  mkdir -p "$dir"
  fakebin=$(make_fake_herdr "$dir")
  printf '%s\n' p-live > "$dir/herdr/panes"
  printf '%s\n' p-live > "$dir/herdr/agents"

  RETIRE_ARGS=(herdr default:p-live "" fm-t1)
  out=$(retire_in "$fakebin" FM_HOME="$dir" FM_FAKE_HERDR_DIR="$dir/herdr" \
    FM_BACKEND_HERDR_AXI_BIN=)
  assert_contains "$out" "an agent is still running on it" \
    "retiring a live endpoint should report the running agent"
  assert_not_contains "$(calls_of "$dir/herdr")" "pane close" \
    "a live agent's pane was closed by the retire path"
  pass "endpoint retire: a live agent's endpoint is reported, never closed"
}

test_absent_endpoint_needs_no_close() {
  local dir=$TMP_ROOT/herdr-absent fakebin out
  mkdir -p "$dir"
  fakebin=$(make_fake_herdr "$dir")

  RETIRE_ARGS=(herdr default:p-gone "" fm-t1)
  out=$(retire_in "$fakebin" FM_HOME="$dir" FM_FAKE_HERDR_DIR="$dir/herdr" \
    FM_BACKEND_HERDR_AXI_BIN=)
  [ "$out" = retired ] || fail "an absent endpoint should already count as retired, got: $out"
  assert_not_contains "$(calls_of "$dir/herdr")" "pane close" \
    "an authoritatively absent pane should need no close call"
  pass "endpoint retire: an authoritatively absent endpoint is already retired"
}

test_tmux_window_is_closed_and_proven_gone() {
  local dir=$TMP_ROOT/tmux-husk fakebin out
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  printf '%s\n' fm-t1 > "$dir/tmux/windows.oldses"

  RETIRE_ARGS=(tmux oldses:fm-t1 "" fm-t1)
  out=$(retire_in "$fakebin" FM_HOME="$dir" FM_FAKE_TMUX_DIR="$dir/tmux")
  [ "$out" = retired ] || fail "an agent-free tmux window should retire cleanly, got: $out"
  assert_contains "$(calls_of "$dir/tmux")" "close oldses:fm-t1" \
    "the retire never asked tmux to close the window"
  pass "endpoint retire: an agent-free tmux window is closed and proven gone"
}

test_tmux_unreadable_inventory_is_never_reported_gone() {
  local dir=$TMP_ROOT/tmux-unreadable fakebin out
  mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  printf '%s\n' fm-t1 > "$dir/tmux/windows.oldses"

  RETIRE_ARGS=(tmux oldses:fm-t1 "" fm-t1)
  out=$(retire_in "$fakebin" FM_HOME="$dir" FM_FAKE_TMUX_DIR="$dir/tmux" \
    FM_FAKE_TMUX_STUCK=fm-t1)
  case "$out" in
    left-open:*) ;;
    *) fail "a tmux window that survived its close was reported as retired: $out" ;;
  esac
  pass "endpoint retire: a tmux window that survives its close is reported, not claimed gone"
}

test_backend_without_classifier_never_claims_a_retire() {
  local dir=$TMP_ROOT/zellij fakebin out
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" zellij

  RETIRE_ARGS=(zellij zses:ztab "" fm-t1)
  out=$(retire_in "$fakebin" FM_HOME="$dir")
  case "$out" in
    left-open:*) ;;
    *) fail "a backend with no recovery classifier must never claim a proven retire: $out" ;;
  esac
  pass "endpoint retire: a backend that cannot prove a close never reports one"
}

# --- 2. the replacement spawn ------------------------------------------------

# A replacement spawn world: a task record that already names an endpoint, a
# real isolated worktree, and the fake tmux above.
make_replacement_case() {  # <name> <recorded-window> -> case record
  local name=$1 window=$2 dir home proj wt fakebin id=rep-$1
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fakebin=$(make_fake_tmux "$dir")
  {
    printf 'window=%s\n' "$window"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$proj"
    printf 'harness=claude\n'
    printf 'kind=ship\n'
  } > "$home/state/$id.meta"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s|%s|%s|%s|%s|%s\n' "$dir" "$home" "$proj" "$wt" "$fakebin" "$id"
}

run_replacement_spawn() {  # <dir> <home> <proj> <wt> <fakebin> <id> [extra-env...]
  local dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TMUX_DIR="$dir/tmux" FM_FAKE_TMUX_META="$home/state/$id.meta" \
    GROK_HOME="$home/grok-home" "$@" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR TASK_ID <<EOF
$1
EOF
}

test_replacement_closes_the_old_endpoint_before_recording_the_new_one() {
  local rec out calls
  rec=$(make_replacement_case replace-closes oldses:fm-rep-replace-closes)
  read_case "$rec"
  printf '%s\n' fm-rep-replace-closes > "$CASE_DIR/tmux/windows.oldses"
  : > "$CASE_DIR/tmux/windows.firstmate"

  out=$(run_replacement_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$TASK_ID") \
    || fail "the replacement spawn failed: $out"
  calls=$(calls_of "$CASE_DIR/tmux")
  assert_contains "$calls" "close oldses:fm-$TASK_ID" \
    "the replacement never closed the endpoint its record still named"
  assert_contains "$calls" "record=window=oldses:fm-$TASK_ID" \
    "the old endpoint was closed only after the new window value had been recorded"
  assert_grep "window=firstmate:fm-$TASK_ID" "$HOME_DIR/state/$TASK_ID.meta" \
    "the replacement did not record its own endpoint"
  assert_call_order "$calls" "open firstmate:fm-$TASK_ID" "close oldses:fm-$TASK_ID" \
    "the replacement closed the previous endpoint before its own existed"
  pass "replacement spawn: the previous endpoint is closed before the new window is recorded"
}

test_replacement_reusing_the_same_endpoint_closes_nothing() {
  local rec out calls
  rec=$(make_replacement_case replace-reuses firstmate:fm-rep-replace-reuses)
  read_case "$rec"
  : > "$CASE_DIR/tmux/windows.firstmate"

  out=$(run_replacement_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$TASK_ID") \
    || fail "the replacement spawn failed: $out"
  calls=$(calls_of "$CASE_DIR/tmux")
  assert_not_contains "$calls" "close " \
    "a replacement that resolved the same endpoint should close nothing"
  assert_grep "window=firstmate:fm-$TASK_ID" "$HOME_DIR/state/$TASK_ID.meta" \
    "the replacement did not record its endpoint"
  pass "replacement spawn: an endpoint the replacement reuses is never closed"
}

test_replacement_names_a_leftover_it_could_not_close() {
  local rec out
  rec=$(make_replacement_case replace-leftover oldses:fm-rep-replace-leftover)
  read_case "$rec"
  printf '%s\n' fm-rep-replace-leftover > "$CASE_DIR/tmux/windows.oldses"
  : > "$CASE_DIR/tmux/windows.firstmate"

  out=$(run_replacement_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$TASK_ID" \
    FM_FAKE_TMUX_STUCK="fm-$TASK_ID") \
    || fail "a leftover endpoint must not fail the replacement: $out"
  assert_contains "$out" "oldses:fm-$TASK_ID" \
    "the leftover endpoint was not named in the replacement's report"
  assert_contains "$out" "was not retired" \
    "the replacement swallowed a close it could not prove"
  assert_grep "window=firstmate:fm-$TASK_ID" "$HOME_DIR/state/$TASK_ID.meta" \
    "the replacement did not land its own endpoint"
  pass "replacement spawn: a leftover pane is named by id instead of passing silently"
}

# --- 2b. the replacement spawn on Herdr --------------------------------------
#
# The production husk shape: the pane the record names sits in a tab the
# replacement's own label scan never looks at, so the backend's create path
# builds a fresh pane beside it and reaps nothing.

# make_spawn_herdr <dir>: a herdr CLI over the same call log, with one restored
# husk pane (p-old, in a tab labeled "restored") and a create path that always
# answers with a fresh tab and pane.
make_spawn_herdr() {  # <dir> <label>
  local dir=$1 label=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/herdr"
  : > "$dir/herdr/calls"
  printf '%s\n' p-old > "$dir/herdr/panes"
  : > "$dir/herdr/agents"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
D=\$FM_FAKE_HERDR_DIR
printf '%s\n' "\$*" >> "\$D/calls"
case "\${1:-} \${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"protocol":14,"version":"test"},"server":{"running":true}}' ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/sock"}]}\n' "\$D" ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"ws1","label":"$label","focused":true,"active_tab_id":"t-restored"}]}}' ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"t-restored","workspace_id":"ws1","label":"restored","focused":true}]}}' ;;
  "tab create")
    printf '%s\n' p-new >> "\$D/panes"
    printf '%s\n' '{"result":{"tab":{"tab_id":"t-new"},"root_pane":{"pane_id":"p-new"}}}' ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"p-old","tab_id":"t-restored"},{"pane_id":"p-new","tab_id":"t-new"}]}}' ;;
  "pane get")
    if grep -qxF "\${3:-}" "\$D/panes"; then
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"t-new","workspace_id":"ws1"}}}\n' "\${3:-}"
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi ;;
  "agent get")
    if grep -qxF "\${3:-}" "\$D/agents"; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
      exit 1
    fi ;;
  "pane close")
    grep -vxF "\${3:-}" "\$D/panes" > "\$D/panes.next" || :
    mv "\$D/panes.next" "\$D/panes" ;;
  *) ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" pi node
  printf '%s\n' "$fakebin"
}

test_herdr_replacement_retires_the_pane_its_record_named() {
  local dir=$TMP_ROOT/herdr-replacement home mate fakebin id=sm-herdr out calls
  home="$dir/home"
  mate="$dir/mate"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$mate/bin" "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'Second mate charter.\n' > "$mate/data/charter.md"
  printf '%s\n' herdr > "$home/config/backend"
  printf '%s\n' pi > "$home/config/secondmate-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_spawn_herdr "$dir" "2ndmate-$id")
  {
    printf 'window=default:p-old\n'
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'harness=pi\n'
    printf 'home=%s\n' "$mate"
    printf 'backend=herdr\n'
    printf 'herdr_session=default\n'
    printf 'herdr_workspace_id=ws1\n'
    printf 'herdr_tab_id=t-restored\n'
    printf 'herdr_pane_id=p-old\n'
  } > "$home/state/$id.meta"

  out=$(env PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN= FM_FAKE_HERDR_DIR="$dir/herdr" \
    HERDR_SESSION=default GROK_HOME="$home/grok-home" \
    "$SPAWN" "$id" --secondmate 2>&1) || fail "the Herdr replacement spawn failed: $out"

  calls=$(calls_of "$dir/herdr")
  assert_call_order "$calls" "tab create" "pane close p-old" \
    "the replacement closed the previous pane before its own existed"
  assert_grep "window=default:p-new" "$home/state/$id.meta" \
    "the replacement did not record its own Herdr pane"
  assert_no_grep p-old "$dir/herdr/panes" \
    "the pane the record stopped naming survived the replacement as a husk"
  pass "replacement spawn: a Herdr pane the create path never reaps is still retired"
}

# --- 3. relaunch adopts its endpoint ----------------------------------------

test_relaunch_keeps_exactly_one_endpoint() {
  local dir=$TMP_ROOT/relaunch home proj wt fakebin id=relaunch-r1 out calls before after
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'brief for %s\n\nDo the thing.\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-relaunch"
  fakebin=$(make_fake_tmux "$dir")
  printf '%s\n' "fm-$id" > "$dir/tmux/windows.fmses"
  printf 'claude' > "$dir/tmux/command.fmses:fm-$id"
  {
    printf 'window=fmses:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$proj"
    printf 'harness=claude\n'
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    printf 'tasktmp=/tmp/fm-%s\n' "$id"
    printf 'model=default\n'
    printf 'effort=default\n'
  } > "$home/state/$id.meta"
  TASK_TMPS+=("/tmp/fm-$id")
  before=$(grep '^window=' "$home/state/$id.meta")

  out=$(env PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_TMUX_DIR="$dir/tmux" FM_FAKE_TMUX_AGENT_WINDOW="fmses:fm-$id" \
    FM_FAKE_PANE_PATH="$wt" GROK_HOME="$home/grok-home" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$id" relaunch --note "picking up where the last worker stopped" 2>&1) \
    || fail "the relaunch failed: $out"

  after=$(grep '^window=' "$home/state/$id.meta")
  [ "$before" = "$after" ] || fail "the relaunch moved the task's endpoint: $before -> $after"
  calls=$(calls_of "$dir/tmux")
  assert_not_contains "$calls" "open " "a relaunch opened a second endpoint for the task"
  assert_not_contains "$calls" "close " "a relaunch closed the endpoint it is supposed to adopt"
  [ "$(wc -l < "$dir/tmux/windows.fmses")" -eq 1 ] \
    || fail "the task holds more than one window after a relaunch: $(cat "$dir/tmux/windows.fmses")"
  pass "relaunch: the endpoint is adopted, so the task still holds exactly one pane"
}

test_herdr_husk_is_closed_and_proven_gone
test_herdr_unprovable_close_is_reported
test_live_agent_endpoint_is_never_closed
test_absent_endpoint_needs_no_close
test_tmux_window_is_closed_and_proven_gone
test_tmux_unreadable_inventory_is_never_reported_gone
test_backend_without_classifier_never_claims_a_retire
test_replacement_closes_the_old_endpoint_before_recording_the_new_one
test_replacement_reusing_the_same_endpoint_closes_nothing
test_replacement_names_a_leftover_it_could_not_close
test_herdr_replacement_retires_the_pane_its_record_named
test_relaunch_keeps_exactly_one_endpoint
