#!/usr/bin/env bash
# Behavior tests for disabled Rovo dispatch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-rovo-harness)

make_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" rovo)
  fm_test_spawn_home "$home" "$harness"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$project" "$worktree" "rovo-$name"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

run_spawn() {
  local home=$1 worktree=$2 fakebin=$3 launch_log=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$worktree" "$fakebin" "$@" 2>&1
}

assert_rovo_refused_without_launch() {
  local output=$1 status=$2 home=$3 id=$4 launch_log=$5 route=$6
  expect_code 1 "$status" "$route Rovo dispatch must refuse"
  assert_contains "$output" "rovo dispatch is disabled" \
    "$route Rovo refusal did not explain that dispatch is disabled"
  assert_absent "$home/state/$id.meta" \
    "$route Rovo refusal created task metadata"
  [ ! -s "$launch_log" ] || fail "$route Rovo refusal launched a worker"
}

test_direct_rovo_selection_refuses_before_launch() {
  local id=rovo-direct-z1 rec output status
  rec=$(make_spawn_case direct pi "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  output=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch.log" \
    "$id" "$PROJECT_DIR" --harness rovo --mode no-mistakes --yolo off)
  status=$?
  assert_rovo_refused_without_launch "$output" "$status" "$HOME_DIR" "$id" \
    "$CASE_DIR/launch.log" "direct"
  pass "fm-spawn: direct Rovo selection refuses before launch"
}

test_configured_rovo_selection_refuses_before_launch() {
  local id=rovo-configured-z2 rec output status
  rec=$(make_spawn_case configured rovo "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  output=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch.log" \
    "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off)
  status=$?
  assert_rovo_refused_without_launch "$output" "$status" "$HOME_DIR" "$id" \
    "$CASE_DIR/launch.log" "configured"
  pass "fm-spawn: configured Rovo selection refuses before launch"
}

test_raw_rovo_selection_with_extra_environment_refuses_before_launch() {
  local id=rovo-raw-z3 rec output status
  rec=$(make_spawn_case raw pi "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  output=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch.log" \
    "$id" "$PROJECT_DIR" --harness 'env EXTRA=1 ROVODEV_CLI=1 rovo run --yolo' --mode no-mistakes --yolo off)
  status=$?
  assert_rovo_refused_without_launch "$output" "$status" "$HOME_DIR" "$id" \
    "$CASE_DIR/launch.log" "raw"
  pass "fm-spawn: raw Rovo selection refuses before launch"
}

test_raw_shell_forms_refuse_before_launch() {
  local id=rovo-raw-shell-z4 rec output status command label
  rec=$(make_spawn_case raw-shell pi "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  for label in nested-shell substitution separator; do
    case "$label" in
      nested-shell) command='env ROVODEV_CLI=1 /bin/sh -c "rovo run --yolo"' ;;
      substitution) command='"$(printf rovo)" run --yolo' ;;
      separator) command='pi --help; rovo run --yolo' ;;
    esac
    : > "$CASE_DIR/launch.log"
    output=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch.log" \
      "$id" "$PROJECT_DIR" --harness "$command" --mode no-mistakes --yolo off)
    status=$?
    expect_code 1 "$status" "$label raw shell form must refuse"
    assert_absent "$HOME_DIR/state/$id.meta" "$label raw shell form created task metadata"
    [ ! -s "$CASE_DIR/launch.log" ] || fail "$label raw shell form launched a worker"
  done
  pass "fm-spawn: raw shell forms refuse before launch"
}

test_raw_rovo_variants_refuse_before_launch() {
  local id=rovo-raw-variants-z5 rec output status command label
  rec=$(make_spawn_case raw-variants pi "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  for label in quoted absolute absolute-env repeated-env delimiter-assignment nice nohup timeout; do
    case "$label" in
      quoted) command="'rovo' run --yolo" ;;
      absolute) command='/opt/rovo run --yolo' ;;
      absolute-env) command='/usr/bin/env ROVODEV_CLI=1 rovo run --yolo' ;;
      repeated-env) command='env env rovo run --yolo' ;;
      delimiter-assignment) command='env -- ROVODEV_CLI=1 rovo run --yolo' ;;
      nice) command='nice rovo run --yolo' ;;
      nohup) command='nohup rovo run --yolo' ;;
      timeout) command='timeout 1 rovo run --yolo' ;;
    esac
    : > "$CASE_DIR/launch.log"
    output=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch.log" \
      "$id" "$PROJECT_DIR" --harness "$command" --mode no-mistakes --yolo off)
    status=$?
    expect_code 1 "$status" "$label raw Rovo form must refuse"
    assert_absent "$HOME_DIR/state/$id.meta" "$label raw Rovo form created task metadata"
    [ ! -s "$CASE_DIR/launch.log" ] || fail "$label raw Rovo form launched a worker"
  done
  pass "fm-spawn: raw Rovo variants refuse before launch"
}

test_literal_raw_argv_is_delivered() {
  local id rec output status command probe index=0
  for command_template in 'DIRECT' 'ENV'; do
    index=$((index + 1))
    id="raw-argv-z6-$index"
    rec=$(make_spawn_case "raw-argv-$index" pi "$id")
    IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$rec
EOF
    mkdir -p "$FAKEBIN_DIR/probe dir"
    probe="$CASE_DIR/probe.log"
    cat > "$FAKEBIN_DIR/probe dir/custom agent" <<'SH'
#!/usr/bin/env bash
printf 'argv:' > 'PROBE_FILE'
printf ' <%s>' "$@" >> 'PROBE_FILE'
printf '\nVALUE=%s PATH=%s\n' "${VALUE-}" "${PATH-unset}" >> 'PROBE_FILE'
SH
    sed -i "s|PROBE_FILE|$probe|g" "$FAKEBIN_DIR/probe dir/custom agent"
    chmod +x "$FAKEBIN_DIR/probe dir/custom agent"
    cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) ;;
  has-session|new-session|new-window|kill-window|set-window-option) ;;
  send-keys)
    payload=
    prev=
    for a in "$@"; do [ "$prev" != -l ] || payload=$a; prev=$a; done
    printf '%s\n' "$payload" >> "$FM_FAKE_LAUNCH_LOG"
    bash -c "$payload"
    ;;
esac
SH
    chmod +x "$FAKEBIN_DIR/tmux"
    case "$command_template" in
      DIRECT) command="'$FAKEBIN_DIR/probe dir/custom agent' rovo '' tail" ;;
      ENV) command="env -i -u PATH -- VALUE=one '$FAKEBIN_DIR/probe dir/custom agent' rovo ''" ;;
    esac
    : > "$CASE_DIR/launch.log"
    output=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch.log" \
      "$id" "$PROJECT_DIR" --harness "$command" --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -eq 0 ] || printf '%s\n' "$output" >&2
    expect_code 0 "$status" "literal raw argv spawn should succeed"
    assert_contains "$(cat "$probe")" 'argv: <rovo> <> <tail>' \
      "raw launch did not execute the expected argv"
    if [ "$command_template" = ENV ]; then
      assert_contains "$(cat "$probe")" 'VALUE=one PATH=unset' \
        "raw env launch did not apply assignment and unset environment"
    fi
  done
  pass "fm-spawn: literal raw argv is executed"
}

test_direct_rovo_selection_refuses_before_launch
test_configured_rovo_selection_refuses_before_launch
test_raw_rovo_selection_with_extra_environment_refuses_before_launch
test_raw_shell_forms_refuse_before_launch
test_literal_raw_argv_is_delivered
test_raw_rovo_variants_refuse_before_launch
