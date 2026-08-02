#!/usr/bin/env bash
# Behavior tests for multi-account Claude routing.
#
# Two surfaces are covered through their executable interfaces only:
#   1. bin/fm-claude-account.sh - config validation, headroom scoring, standing
#      ceilings, explicit override, and graceful degradation. Account quota comes
#      from a fake `quota-axi` on PATH that answers per CLAUDE_CONFIG_DIR, so no
#      test ever reads a real login, credential, or network.
#   2. bin/fm-spawn.sh - that the selected account reaches the claude launch
#      command and the task's durable record, that an absent config leaves the
#      pre-existing single-store launch byte-identical, and that malformed
#      config aborts the spawn before any endpoint or metadata exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACCOUNT="$ROOT/bin/fm-claude-account.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-account)

# --- fixtures ---------------------------------------------------------------

# A fake quota-axi that answers from a fixture directory keyed by the account's
# CLAUDE_CONFIG_DIR, which is exactly the seam the real tool honors. A directory
# with no fixture file exits non-zero, standing in for an unreadable account.
make_quota_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
fixture="${FM_TEST_QUOTA_FIXTURES:-}/$(basename "${CLAUDE_CONFIG_DIR:-none}").json"
[ -f "$fixture" ] || exit 1
cat "$fixture"
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# Write one account's quota fixture in the real schema shape: a claude provider
# whose session (five_hour) and weekly (seven_day) windows carry percentRemaining.
write_quota_fixture() {
  local fixtures=$1 account_dir=$2 session=$3 weekly=$4
  mkdir -p "$fixtures"
  cat > "$fixtures/$(basename "$account_dir").json" <<EOF
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "plan": "max",
      "windows": [
        { "id": "five_hour", "kind": "session", "percentUsed": $((100 - session)), "percentRemaining": $session },
        { "id": "seven_day", "kind": "weekly", "percentUsed": $((100 - weekly)), "percentRemaining": $weekly },
        { "id": "model:fable", "kind": "model", "percentUsed": 0, "percentRemaining": 100 }
      ]
    }
  ]
}
EOF
}

write_accounts_config() {
  local config_dir=$1
  shift
  local entries='' name dir pair
  mkdir -p "$config_dir"
  for pair in "$@"; do
    name=${pair%%=*}
    dir=${pair#*=}
    entries="${entries:+$entries,}"$'\n'"    { \"name\": \"$name\", \"configDir\": \"$dir\" }"
  done
  printf '{\n  "accounts": [%s\n  ]\n}\n' "$entries" > "$config_dir/claude-accounts.json"
}

# A case directory with two real account config dirs and a fake quota-axi.
# Echoes "case_dir|config_dir|fixtures|fakebin|dir_fresh|dir_spent".
make_account_case() {
  local name=$1 case_dir config_dir fixtures fakebin fresh spent
  case_dir="$TMP_ROOT/$name"
  config_dir="$case_dir/config"
  fixtures="$case_dir/quota"
  fresh="$case_dir/claude-fresh"
  spent="$case_dir/claude-spent"
  mkdir -p "$config_dir" "$fixtures" "$fresh" "$spent"
  fakebin=$(make_quota_fakebin "$case_dir/fake")
  printf '%s\n' "$case_dir|$config_dir|$fixtures|$fakebin|$fresh|$spent"
}

read_account_case() {
  IFS='|' read -r CASE_DIR CONFIG_DIR FIXTURES FAKEBIN DIR_FRESH DIR_SPENT <<EOF
$1
EOF
}

run_account() {
  local config_dir=$1 fixtures=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$config_dir/.." FM_CONFIG_OVERRIDE="$config_dir" \
    FM_TEST_QUOTA_FIXTURES="$fixtures" PATH="$fakebin:$PATH" \
    "$ACCOUNT" "$@"
}

# --- selector: inert without configuration ----------------------------------

test_absent_config_reports_feature_off() {
  local rec out status
  rec=$(make_account_case absent-config)
  read_account_case "$rec"

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>&1)
  status=$?
  expect_code 3 "$status" "an absent accounts config should report the feature off"
  [ -z "$out" ] || fail "an absent accounts config should print nothing, got: $out"
  pass "no accounts config selects nothing and reports the feature off"
}

test_explicit_account_without_config_fails_loudly() {
  local rec out status
  rec=$(make_account_case explicit-without-config)
  read_account_case "$rec"

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select --account whichever 2>&1)
  status=$?
  expect_code 1 "$status" "an explicit account with no config should fail"
  assert_contains "$out" "does not exist" "the refusal did not name the missing config"
  pass "an explicit account request with no config fails loudly instead of degrading"
}

# --- selector: scoring and ceilings -----------------------------------------

test_most_headroom_account_wins() {
  local rec out status
  rec=$(make_account_case most-headroom)
  read_account_case "$rec"
  write_accounts_config "$CONFIG_DIR" "spent=$DIR_SPENT" "fresh=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_SPENT" 60 40
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 95 90

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>/dev/null)
  status=$?
  expect_code 0 "$status" "scored selection should succeed"
  [ "$out" = "fresh	$DIR_FRESH" ] || fail "expected the fresher account, got: $out"
  pass "the account with the most headroom is selected"
}

test_score_uses_the_tighter_of_session_and_weekly() {
  local rec out status
  rec=$(make_account_case tighter-window)
  read_account_case "$rec"
  # 'spent' has a far better session window but a worse weekly one; the minimum
  # across both windows is the real headroom, so 'fresh' must still win.
  write_accounts_config "$CONFIG_DIR" "spent=$DIR_SPENT" "fresh=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_SPENT" 99 20
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 40 39

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>/dev/null)
  status=$?
  expect_code 0 "$status" "scored selection should succeed"
  [ "$out" = "fresh	$DIR_FRESH" ] || fail "expected the account with the better minimum window, got: $out"
  pass "scoring uses the minimum across the session and weekly windows"
}

test_ceiling_breaching_account_is_skipped() {
  local rec out status score
  rec=$(make_account_case ceiling-skipped)
  read_account_case "$rec"
  # 'spent' is at 95% weekly used (5 remaining) - the standing weekly ceiling -
  # even though its session window is wide open and outscores the alternative.
  write_accounts_config "$CONFIG_DIR" "spent=$DIR_SPENT" "fresh=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_SPENT" 99 5
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 30 30

  score=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" score 2>/dev/null)
  assert_contains "$score" "spent	$DIR_SPENT	99	5	ceiling" "the spent account was not reported at its ceiling"
  assert_contains "$score" "fresh	$DIR_FRESH	30	30	eligible" "the fresh account was not reported eligible"

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>/dev/null)
  status=$?
  expect_code 0 "$status" "scored selection should succeed with one eligible account"
  [ "$out" = "fresh	$DIR_FRESH" ] || fail "a ceiling-breaching account was selected: $out"
  pass "an account at a standing ceiling is skipped while an eligible one exists"
}

test_session_ceiling_is_enforced_independently() {
  local rec score
  rec=$(make_account_case session-ceiling)
  read_account_case "$rec"
  # Exactly 90% session used (10 remaining) is at the ceiling, not under it.
  write_accounts_config "$CONFIG_DIR" "spent=$DIR_SPENT" "fresh=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_SPENT" 10 100
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 11 100

  score=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" score 2>/dev/null)
  assert_contains "$score" "spent	$DIR_SPENT	10	100	ceiling" "90% session used was not treated as at the ceiling"
  assert_contains "$score" "fresh	$DIR_FRESH	11	100	eligible" "89% session used was not treated as eligible"
  pass "the session ceiling is enforced independently of the weekly one"
}

test_only_account_is_used_despite_its_ceiling() {
  local rec out status err
  rec=$(make_account_case only-account)
  read_account_case "$rec"
  write_accounts_config "$CONFIG_DIR" "solo=$DIR_SPENT"
  write_quota_fixture "$FIXTURES" "$DIR_SPENT" 2 2

  err="$CASE_DIR/stderr"
  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>"$err")
  status=$?
  expect_code 0 "$status" "the only configured account should still be selected"
  [ "$out" = "solo	$DIR_SPENT" ] || fail "the only configured account was not selected: $out"
  assert_grep "at or beyond a standing usage ceiling" "$err" "no warning was printed for a ceiling-only selection"
  pass "the only configured account is used despite its ceiling, with a warning"
}

# --- selector: explicit override --------------------------------------------

test_explicit_account_beats_scoring() {
  local rec out status
  rec=$(make_account_case explicit-override)
  read_account_case "$rec"
  write_accounts_config "$CONFIG_DIR" "spent=$DIR_SPENT" "fresh=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_SPENT" 1 1
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 100 100

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select --account spent 2>/dev/null)
  status=$?
  expect_code 0 "$status" "an explicit account should be selected"
  [ "$out" = "spent	$DIR_SPENT" ] || fail "the explicit account did not beat scoring: $out"
  pass "an explicit account beats headroom scoring"
}

test_unknown_explicit_account_fails_with_the_configured_names() {
  local rec out status
  rec=$(make_account_case unknown-explicit)
  read_account_case "$rec"
  write_accounts_config "$CONFIG_DIR" "spent=$DIR_SPENT" "fresh=$DIR_FRESH"

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select --account nope 2>&1)
  status=$?
  expect_code 1 "$status" "an unknown account should fail"
  assert_contains "$out" "unknown claude account 'nope'" "the refusal did not name the bad account"
  assert_contains "$out" "spent, fresh" "the refusal did not list the configured accounts"
  pass "an unknown explicit account fails loudly and lists the configured names"
}

# --- selector: degradation and validation -----------------------------------

test_unscorable_accounts_fall_back_to_the_first() {
  local rec out status err
  rec=$(make_account_case unscorable)
  read_account_case "$rec"
  # No fixtures written at all, so every account's quota read fails.
  write_accounts_config "$CONFIG_DIR" "primary=$DIR_SPENT" "other=$DIR_FRESH"

  err="$CASE_DIR/stderr"
  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>"$err")
  status=$?
  expect_code 0 "$status" "unreadable quota should degrade rather than fail"
  [ "$out" = "primary	$DIR_SPENT" ] || fail "unscorable accounts did not fall back to the first: $out"
  assert_grep "no Claude account usage could be read" "$err" "degradation printed no warning"
  pass "unscorable quota falls back to the first configured account with a warning"
}

test_partially_unscorable_still_selects_a_scored_account() {
  local rec out status score
  rec=$(make_account_case partial-unscorable)
  read_account_case "$rec"
  write_accounts_config "$CONFIG_DIR" "primary=$DIR_SPENT" "other=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 50 50

  score=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" score 2>/dev/null)
  assert_contains "$score" "primary	$DIR_SPENT	-	-	unscorable" "the unreadable account was not reported unscorable"

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>/dev/null)
  status=$?
  expect_code 0 "$status" "a partially scorable fleet should still select"
  [ "$out" = "other	$DIR_FRESH" ] || fail "an unscorable account was selected over a scored one: $out"
  pass "an unscorable account is never selected by score while a scored one exists"
}

test_malformed_config_fails_loudly() {
  local rec out status case_name
  for case_name in \
    'not-json:{ this is not json' \
    'no-accounts:{"harness":"claude"}' \
    'empty-accounts:{"accounts":[]}' \
    'missing-name:{"accounts":[{"configDir":"/tmp"}]}' \
    'duplicate-names:{"accounts":[{"name":"a","configDir":"/tmp"},{"name":"a","configDir":"/tmp"}]}' \
    'relative-dir:{"accounts":[{"name":"a","configDir":"relative/path"}]}' \
    'tsv-hostile-name:{"accounts":[{"name":"a b","configDir":"/tmp"}]}'
  do
    rec=$(make_account_case "malformed-${case_name%%:*}")
    read_account_case "$rec"
    printf '%s\n' "${case_name#*:}" > "$CONFIG_DIR/claude-accounts.json"

    out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>&1)
    status=$?
    expect_code 1 "$status" "malformed config (${case_name%%:*}) should fail loudly"
    assert_contains "$out" "error: " "malformed config (${case_name%%:*}) printed no error"
  done
  pass "every malformed accounts config fails loudly instead of degrading"
}

test_missing_config_directory_is_a_validation_error() {
  local rec out status
  rec=$(make_account_case missing-dir)
  read_account_case "$rec"
  write_accounts_config "$CONFIG_DIR" "gone=$CASE_DIR/not-created"

  out=$(run_account "$CONFIG_DIR" "$FIXTURES" "$FAKEBIN" select 2>&1)
  status=$?
  expect_code 1 "$status" "a configDir that is not a directory should fail"
  assert_contains "$out" "is not a directory" "the refusal did not name the missing directory"
  pass "a configured account directory that does not exist fails loudly"
}

# --- spawn integration ------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(make_quota_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Echoes "case_dir|home|proj|wt|fakebin|launchlog|fixtures|dir_fresh|dir_spent".
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin fixtures fresh spent
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fixtures="$case_dir/quota"
  fresh="$case_dir/claude-fresh"
  spent="$case_dir/claude-spent"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$fixtures" "$fresh" "$spent"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$fixtures|$fresh|$spent"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG FIXTURES DIR_FRESH DIR_SPENT <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 fixtures=$5
  shift 5
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is pinned empty so launch assertions never depend on the
  # invoking shell; a test opts into the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_TEST_QUOTA_FIXTURES="$fixtures" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_without_accounts_config_is_unchanged() {
  local rec id out status launch expected
  id=account-inert-a1
  rec=$(make_spawn_case spawn-inert "$id")
  read_spawn_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$FIXTURES" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a claude spawn with no accounts config should succeed"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no accounts config changed the launch command"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  grep -q '^account=' "$HOME_DIR/state/$id.meta" && fail "no accounts config still recorded an account"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "the spawn line gained an account with no config"
  pass "with no accounts config the claude launch, record, and report are unchanged"
}

test_spawn_selects_the_fresher_account() {
  local rec id out status launch
  id=account-scored-a2
  rec=$(make_spawn_case spawn-scored "$id")
  read_spawn_case "$rec"
  write_accounts_config "$HOME_DIR/config" "spent=$DIR_SPENT" "fresh=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_SPENT" 40 40
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 90 90

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$FIXTURES" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a claude spawn with accounts configured should succeed"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "CLAUDE_CONFIG_DIR='$DIR_FRESH' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude "*) ;;
    *) fail "the selected account did not reach the launch command: $launch" ;;
  esac
  assert_grep "account=fresh" "$HOME_DIR/state/$id.meta" "the selected account was not recorded"
  assert_contains "$out" "spawned $id harness=claude account=fresh kind=ship" "the spawn line did not report the account"
  pass "a claude spawn launches on the account with the most headroom and records it"
}

test_spawn_account_override_beats_scoring() {
  local rec id out status launch
  id=account-override-a3
  rec=$(make_spawn_case spawn-override "$id")
  read_spawn_case "$rec"
  write_accounts_config "$HOME_DIR/config" "spent=$DIR_SPENT" "fresh=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_SPENT" 20 20
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 100 100

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$FIXTURES" \
    "$id" "$PROJ_DIR" --account spent)
  status=$?
  expect_code 0 "$status" "an explicit account spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "CLAUDE_CONFIG_DIR='$DIR_SPENT' "*) ;;
    *) fail "the explicit account did not reach the launch command: $launch" ;;
  esac
  assert_grep "account=spent" "$HOME_DIR/state/$id.meta" "the explicit account was not recorded"
  pass "an explicit --account beats headroom scoring at spawn time"
}

test_spawn_account_beats_the_inherited_config_dir() {
  local rec id status launch
  id=account-precedence-a4
  rec=$(make_spawn_case spawn-precedence "$id")
  read_spawn_case "$rec"
  write_accounts_config "$HOME_DIR/config" "fresh=$DIR_FRESH"
  write_quota_fixture "$FIXTURES" "$DIR_FRESH" 80 80

  FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/firstmate-own-store" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$FIXTURES" "$id" "$PROJ_DIR" >/dev/null
  status=$?
  expect_code 0 "$status" "a spawn with both an account and an inherited store should succeed"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "CLAUDE_CONFIG_DIR='$DIR_FRESH' "*) ;;
    *) fail "the selected account did not beat firstmate's own store: $launch" ;;
  esac
  pass "a selected account beats firstmate's own inherited config dir"
}

test_spawn_aborts_on_malformed_accounts_config() {
  local rec id out status
  id=account-malformed-a5
  rec=$(make_spawn_case spawn-malformed "$id")
  read_spawn_case "$rec"
  printf '%s\n' '{"accounts":[{"name":"broken"}]}' > "$HOME_DIR/config/claude-accounts.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$FIXTURES" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a malformed accounts config should abort the spawn"
  assert_contains "$out" "non-empty configDir" "the abort did not name the configuration defect"
  assert_absent "$HOME_DIR/state/$id.meta" "a malformed accounts config still wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "a malformed accounts config still typed a launch command"
  pass "a malformed accounts config aborts the spawn before any endpoint or record exists"
}

test_spawn_rejects_account_flag_for_a_non_claude_harness() {
  local rec id out status
  id=account-wrong-harness-a6
  rec=$(make_spawn_case spawn-wrong-harness "$id")
  read_spawn_case "$rec"
  write_accounts_config "$HOME_DIR/config" "fresh=$DIR_FRESH"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$FIXTURES" \
    "$id" "$PROJ_DIR" --harness codex --account fresh)
  status=$?
  expect_code 1 "$status" "--account on a non-claude harness should be refused"
  assert_contains "$out" "applies only to claude-harness spawns" "the refusal did not explain the flag's scope"
  assert_absent "$HOME_DIR/state/$id.meta" "a rejected --account still wrote task metadata"
  pass "--account is refused for a non-claude harness instead of being ignored"
}

test_spawn_degrades_to_the_first_account_when_quota_is_unreadable() {
  local rec id out status launch
  id=account-degraded-a7
  rec=$(make_spawn_case spawn-degraded "$id")
  read_spawn_case "$rec"
  # No quota fixtures: every account reads as unscorable.
  write_accounts_config "$HOME_DIR/config" "primary=$DIR_SPENT" "other=$DIR_FRESH"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$FIXTURES" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "unreadable quota should still spawn"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "CLAUDE_CONFIG_DIR='$DIR_SPENT' "*) ;;
    *) fail "the spawn did not fall back to the first configured account: $launch" ;;
  esac
  assert_contains "$out" "no Claude account usage could be read" "the degraded spawn printed no warning"
  assert_grep "account=primary" "$HOME_DIR/state/$id.meta" "the fallback account was not recorded"
  pass "unreadable quota degrades to the first configured account and warns"
}

test_absent_config_reports_feature_off
test_explicit_account_without_config_fails_loudly
test_most_headroom_account_wins
test_score_uses_the_tighter_of_session_and_weekly
test_ceiling_breaching_account_is_skipped
test_session_ceiling_is_enforced_independently
test_only_account_is_used_despite_its_ceiling
test_explicit_account_beats_scoring
test_unknown_explicit_account_fails_with_the_configured_names
test_unscorable_accounts_fall_back_to_the_first
test_partially_unscorable_still_selects_a_scored_account
test_malformed_config_fails_loudly
test_missing_config_directory_is_a_validation_error
test_spawn_without_accounts_config_is_unchanged
test_spawn_selects_the_fresher_account
test_spawn_account_override_beats_scoring
test_spawn_account_beats_the_inherited_config_dir
test_spawn_aborts_on_malformed_accounts_config
test_spawn_rejects_account_flag_for_a_non_claude_harness
test_spawn_degrades_to_the_first_account_when_quota_is_unreadable

echo "# all fm-claude-account tests passed"
