#!/usr/bin/env bash
# Behavior tests for disabled Rovo dispatch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

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
      substitution) command="\"\$(printf rovo)\" run --yolo" ;;
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
  for label in unquoted quoted absolute absolute-env repeated-env delimiter-assignment one-letter-assignment one-letter-delimiter invalid-assignment invalid-unset nice nohup timeout nice-custom nohup-custom timeout-custom env-s pipe and redirect expansion double-expansion backticks env-after-delimiter env-after-assignment; do
    case "$label" in
      unquoted) command='rovo run --yolo' ;;
      quoted) command="'rovo' run --yolo" ;;
      absolute) command='/opt/rovo run --yolo' ;;
      absolute-env) command='/usr/bin/env ROVODEV_CLI=1 rovo run --yolo' ;;
      repeated-env) command='env env rovo run --yolo' ;;
      delimiter-assignment) command='env -- ROVODEV_CLI=1 rovo run --yolo' ;;
      one-letter-assignment) command='env X=1 rovo run --yolo' ;;
      one-letter-delimiter) command='env -- X=1 rovo run --yolo' ;;
      invalid-assignment) command='env X.Y=1 rovo run --yolo' ;;
      invalid-unset) command='env -u BAD=1 custom-agent' ;;
      nice) command='nice rovo run --yolo' ;;
      nohup) command='nohup rovo run --yolo' ;;
      timeout) command='timeout 1 rovo run --yolo' ;;
      nice-custom) command='nice custom-agent --flag' ;;
      nohup-custom) command='nohup custom-agent --flag' ;;
      timeout-custom) command='timeout 1 custom-agent --flag' ;;
      env-s) command='env -S custom-agent' ;;
      pipe) command='custom-agent --flag | rovo run' ;;
      and) command='custom-agent --flag && rovo run' ;;
      redirect) command='custom-agent --flag > result' ;;
      expansion) command="custom-agent \$HOME" ;;
      double-expansion) command="custom-agent \"\$HOME\"" ;;
      backticks) command="custom-agent \`printf rovo\`" ;;
      env-after-delimiter) command='env -- -i custom-agent' ;;
      env-after-assignment) command='env VALUE=one -i custom-agent' ;;
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
  local id rec output status command probe probe_shell index=0
  probe_shell=$(command -v bash)
  for command_template in 'DIRECT' 'ENV_CLEAR' 'ENV_UNSET' 'SINGLE_BACKSLASH' 'SINGLE_DOLLAR' 'DOUBLE_BACKSLASH' 'TAB_ONLY' 'SPACE_TAB' 'DOUBLE_ORDINARY_BACKSLASH' 'ESCAPED_DOLLAR' 'UNQUOTED_ESCAPED_DOLLAR'; do
    index=$((index + 1))
    id="raw-argv-z6-$index"
    rec=$(make_spawn_case "raw-argv-$index" pi "$id")
    IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$rec
EOF
    mkdir -p "$FAKEBIN_DIR/probe dir"
    probe="$CASE_DIR/probe.log"
    cat > "$FAKEBIN_DIR/probe dir/custom agent" <<'SH'
#!SHELL_FILE
printf 'argv:' > 'PROBE_FILE'
printf ' <%s>' "$@" >> 'PROBE_FILE'
printf '\nVALUE=%s CLEAR=%s DROP=%s KEEP=%s X=%s\n' "${VALUE-}" "${CLEAR_SENTINEL-unset}" "${DROP_SENTINEL-unset}" "${KEEP_SENTINEL-unset}" "${X-unset}" >> 'PROBE_FILE'
SH
    sed -i -e "s|PROBE_FILE|$probe|g" -e "s|SHELL_FILE|$probe_shell|g" "$FAKEBIN_DIR/probe dir/custom agent"
    chmod +x "$FAKEBIN_DIR/probe dir/custom agent"
    cp "$FAKEBIN_DIR/probe dir/custom agent" "$FAKEBIN_DIR/custom-agent"
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
      ENV_CLEAR) command="env -i -u DROP_SENTINEL -- VALUE=one '$FAKEBIN_DIR/probe dir/custom agent' rovo ''" ;;
      ENV_UNSET) command="env -u DROP_SENTINEL -- VALUE=one X=one '$FAKEBIN_DIR/probe dir/custom agent' rovo ''" ;;
      SINGLE_BACKSLASH) command="'$FAKEBIN_DIR/probe dir/custom agent' 'a\\b'" ;;
      SINGLE_DOLLAR) command="'$FAKEBIN_DIR/probe dir/custom agent' '\$HOME'" ;;
      DOUBLE_BACKSLASH) command="'$FAKEBIN_DIR/probe dir/custom agent' \"a\\\\b\"" ;;
      DOUBLE_ORDINARY_BACKSLASH) command="'$FAKEBIN_DIR/probe dir/custom agent' \"a\\b\"" ;;
      ESCAPED_DOLLAR) command="'$FAKEBIN_DIR/probe dir/custom agent' \"\\\$HOME\"" ;;
      UNQUOTED_ESCAPED_DOLLAR) command="'$FAKEBIN_DIR/probe dir/custom agent' "; command+="\\\$HOME" ;;
      TAB_ONLY)
        command="$FAKEBIN_DIR/custom-agent"$'\t'"--flag"
        case "$command" in *' '*) fail "tab-only fixture contains a masking space" ;; esac
        ;;
      SPACE_TAB) command="$FAKEBIN_DIR/custom-agent "$'\t'"--flag "$'\t'"tail" ;;
    esac
    : > "$CASE_DIR/launch.log"
    output=$(X=outer CLEAR_SENTINEL=clear DROP_SENTINEL=drop KEEP_SENTINEL=keep run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch.log" \
      "$id" "$PROJECT_DIR" --harness "$command" --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -eq 0 ] || printf '%s\n' "$output" >&2
    expect_code 0 "$status" "literal raw argv spawn should succeed"
    probe_argv=$(head -n 1 "$probe")
    case "$command_template" in
      DIRECT) [ "$probe_argv" = 'argv: <rovo> <> <tail>' ] || fail "direct raw argv changed: $probe_argv" ;;
      ENV_CLEAR|ENV_UNSET) [ "$probe_argv" = 'argv: <rovo> <>' ] || fail "env raw argv changed: $probe_argv" ;;
      SINGLE_BACKSLASH|DOUBLE_BACKSLASH|DOUBLE_ORDINARY_BACKSLASH) [ "$probe_argv" = 'argv: <a\b>' ] || fail "quoted backslash changed: $probe_argv" ;;
      SINGLE_DOLLAR|ESCAPED_DOLLAR|UNQUOTED_ESCAPED_DOLLAR) [ "$probe_argv" = "argv: <\$HOME>" ] || fail "literal dollar changed: $probe_argv" ;;
      TAB_ONLY) [ "$probe_argv" = 'argv: <--flag>' ] || fail "tab-separated argv changed: $probe_argv" ;;
      SPACE_TAB) [ "$probe_argv" = 'argv: <--flag> <tail>' ] || fail "mixed-whitespace argv changed: $probe_argv" ;;
    esac
    case "$command_template" in
      ENV_CLEAR)
        assert_contains "$(cat "$probe")" 'VALUE=one CLEAR=unset DROP=unset KEEP=unset X=unset' \
          "env -i did not clear inherited sentinels"
        ;;
      ENV_UNSET)
        assert_contains "$(cat "$probe")" 'VALUE=one CLEAR=clear DROP=unset KEEP=keep X=one' \
          "env -u did not remove only its named sentinel"
        ;;
    esac
  done
  pass "fm-spawn: literal raw argv is executed"
}

test_direct_rovo_selection_refuses_before_launch
test_configured_rovo_selection_refuses_before_launch
test_raw_rovo_selection_with_extra_environment_refuses_before_launch
test_raw_shell_forms_refuse_before_launch
test_literal_raw_argv_is_delivered
test_raw_rovo_variants_refuse_before_launch
