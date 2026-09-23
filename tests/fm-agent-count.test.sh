#!/usr/bin/env bash
# tests/fm-agent-count.test.sh - bin/fm-agent-count.sh counts the agents that
# are really open in Herdr panes, from a fake Herdr pane list.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

COUNT="$ROOT/bin/fm-agent-count.sh"
TMP_ROOT=$(fm_test_tmproot fm-agent-count)

# shellcheck source=tests/agent-limit-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/agent-limit-helpers.sh"

make_home() {  # <home>
  mkdir -p "$1/state" "$1/data" "$1/config"
}

task_meta() {  # <home> <id> <kind> <harness> <window>
  agent_limit_task_meta "$@"
}

secondmate_meta() {  # <home> <id> <sm-home> <harness> <window>
  fm_write_meta "$1/state/$2.meta" "window=$5" "kind=secondmate" "harness=$4" "backend=herdr" "home=$3"
}

run_count() {  # <dir> <home> <fakebin> [args...]
  local dir=$1 home=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_FAKE_HERDR_DIR="$dir/herdr" \
    FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' PATH="$fakebin:$PATH" \
    "$COUNT" "$@"
}

# A fleet with every population the count must tell apart: a MAIN supervisor,
# a secondmate supervisor, crewmates in both homes, a parked task whose pane is
# closed, a task pane whose agent exited, and an unmanaged agent pane.
build_fleet() {  # <dir> -> sets HOME_MAIN HOME_SM FAKEBIN
  local dir=$1
  HOME_MAIN="$dir/main"
  HOME_SM="$dir/sm"
  make_home "$HOME_MAIN"
  make_home "$HOME_SM"
  printf '%s\n' sm1 > "$HOME_SM/.fm-secondmate-home"
  FAKEBIN=$(make_fake_herdr "$dir")
  add_pane "$dir" default w1:p1 w1 "$HOME_MAIN" claude claude --resume
  add_pane "$dir" default w1:p2 w1 "$dir/wt-a" claude claude --dangerously-skip-permissions
  add_pane "$dir" default w1:p3 w1 "$dir/wt-b" MainThread /usr/bin/node /opt/codex/bin/codex
  add_pane "$dir" default w1:p4 w1 "$dir/wt-c" bash /bin/bash
  add_pane "$dir" default w2:p1 w2 "$HOME_SM" pi pi
  add_pane "$dir" default w2:p2 w2 "$dir/wt-d" pi pi
  add_pane "$dir" default w9:p1 w9 "$dir" pi pi
  task_meta "$HOME_MAIN" task-a ship claude default:w1:p2
  task_meta "$HOME_MAIN" task-b scout codex default:w1:p3
  task_meta "$HOME_MAIN" task-c ship claude default:w1:p4
  task_meta "$HOME_MAIN" task-parked ship claude default:w1:p77
  secondmate_meta "$HOME_MAIN" sm1 "$HOME_SM" pi default:w2:p1
  task_meta "$HOME_SM" task-d ship pi default:w2:p2
}

test_counts_only_crewmate_agents_open_in_herdr() {
  local dir=$TMP_ROOT/fleet out
  mkdir -p "$dir"
  build_fleet "$dir"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json) || fail "fm-agent-count --json failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.count')" = 3 ] \
    || fail "expected 3 crewmate agents (task-a, task-b, task-d), got: $out"
  [ "$(printf '%s' "$out" | jq -r '[.agents[].task] | sort | join(",")')" = "task-a,task-b,task-d" ] \
    || fail "the counted agents are not the three live crewmates: $out"
  [ "$(printf '%s' "$out" | jq -r '.agents[] | select(.task == "task-d") | [.home, .harness, .pane, .session] | join(" ")')" = "sm1 pi w2:p2 default" ] \
    || fail "a secondmate's crewmate was not reported with its home, harness, pane, and session: $out"
  [ "$(printf '%s' "$out" | jq -r '.agents[] | select(.task == "task-b") | .harness')" = codex ] \
    || fail "the Codex crewmate was not reported with its harness: $out"
  [ "$(printf '%s' "$out" | jq -r '[.supervisors[] | .home] | sort | join(",")')" = "main,sm1" ] \
    || fail "the MAIN and secondmate supervisors were not listed separately: $out"
  [ "$(printf '%s' "$out" | jq -r '[.unmanaged[] | .pane] | join(",")')" = "w9:p1" ] \
    || fail "an agent pane that no firstmate home records was not listed as unmanaged: $out"
  assert_not_contains "$out" task-parked "a parked task with no open pane appeared in the count"
  assert_not_contains "$out" task-c "a task pane whose agent exited appeared in the count"
  pass "fm-agent-count: counts crewmate agents open in Herdr across homes, lists supervisors and unmanaged agents apart"
}

test_reports_limit_default_config_and_off() {
  local dir=$TMP_ROOT/limits out
  mkdir -p "$dir"
  build_fleet "$dir"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json) || fail "count failed: $out"
  [ "$(printf '%s' "$out" | jq -c '[.limit, .limit_source, .override, .at_limit]')" = '[30,"default","none",false]' ] \
    || fail "an absent config/agent-limit should report the default limit of 30: $out"

  printf '3\n' > "$HOME_MAIN/config/agent-limit"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json) || fail "count failed: $out"
  [ "$(printf '%s' "$out" | jq -c '[.count, .limit, .limit_source, .at_limit]')" = '[3,3,"config",true]' ] \
    || fail "a configured limit equal to the count should report at_limit: $out"

  printf 'off\n' > "$HOME_MAIN/config/agent-limit"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json) || fail "count failed: $out"
  [ "$(printf '%s' "$out" | jq -c '[.limit, .override, .at_limit]')" = '[null,"off",false]' ] \
    || fail "config off should report no limit and the off override: $out"

  printf 'lots\n' > "$HOME_MAIN/config/agent-limit"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json 2>&1) && fail "a malformed config/agent-limit was accepted: $out"
  assert_contains "$out" "positive whole number or the word off" "a malformed limit should say what the file must hold"

  printf '3\n' > "$HOME_MAIN/config/agent-limit"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN") || fail "plain count failed: $out"
  assert_contains "$out" "agents: 3 / 3" "the plain output should lead with the count and the limit"
  pass "fm-agent-count: reports the default, configured, and off limits, and refuses a malformed limit file"
}

test_session_states() {
  local dir=$TMP_ROOT/sessions out
  mkdir -p "$dir"
  build_fleet "$dir"
  touch "$dir/herdr/default/down"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json) || fail "a stopped Herdr session should count zero, not fail: $out"
  [ "$(printf '%s' "$out" | jq -r '.count')" = 0 ] || fail "a stopped session still counted agents: $out"

  rm -f "$dir/herdr/default/down"
  touch "$dir/herdr/default/broken"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json 2>&1) && fail "an unreadable Herdr session produced a count: $out"
  assert_contains "$out" "herdr pane list failed for session default" "the Herdr failure should be named"

  rm -f "$dir/herdr/default/broken"
  add_pane "$dir" fm-lab-other w1:p1 w1 "$dir/wt-a" claude claude
  : > "$dir/herdr/calls"
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json --session fm-lab-other) || fail "count failed: $out"
  [ "$(printf '%s' "$out" | jq -c '[.count, .sessions, (.unmanaged | length)]')" = '[0,["fm-lab-other"],1]' ] \
    || fail "--session should read only the named session: $out"
  assert_no_grep "--session default" "$dir/herdr/calls" "--session still read the default session"
  pass "fm-agent-count: a stopped session holds no agents, a Herdr error is reported, and --session narrows the read"
}

test_unreadable_pane_is_listed_not_counted() {
  local dir=$TMP_ROOT/unreadable out
  mkdir -p "$dir"
  build_fleet "$dir"
  add_pane "$dir" default w1:p5 w1 "$dir/wt-e" 'bad name!' claude
  task_meta "$HOME_MAIN" task-e ship claude default:w1:p5
  out=$(run_count "$dir" "$HOME_MAIN" "$FAKEBIN" --json) || fail "count failed: $out"
  [ "$(printf '%s' "$out" | jq -c '[.count, [.unreadable[].pane]]')" = '[3,["w1:p5"]]' ] \
    || fail "a pane whose process could not be read should be listed as unreadable and not counted: $out"
  pass "fm-agent-count: a pane whose process cannot be classified is listed, not counted"
}

test_counts_only_crewmate_agents_open_in_herdr
test_reports_limit_default_config_and_off
test_session_states
test_unreadable_pane_is_listed_not_counted
