#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans) and its fixture
# process registry (fm_test_track_pid / fm_test_reap_pids).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

# --- fixture process reaping ---------------------------------------------------
#
# A child suite starts stand-in processes the way real fixtures do - inside a
# command substitution, which loses any shell-array registration - and registers
# them with fm_test_track_pid. Once the child is gone, every registered process
# must be gone too, whichever way the child ended. The parent registers each
# reported PID in its own registry as well, so a regression here cannot leak the
# probes past this suite.

# Run a child suite that starts stand-ins and then ends through <ending>
# (exit, fail, or term). Prints the child's pid file directory.
run_reaping_child() {  # <ending>
  local ending=$1 harness pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-reap-harness)
  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
    out=$2
    plain() { sleep 300 >/dev/null 2>&1 & fm_test_track_pid "$!"; printf "%s\n" "$!"; }
    execed() { bash -c "exec sleep 300" >/dev/null 2>&1 & fm_test_track_pid "$!"; printf "%s\n" "$!"; }
    leader() {
      set -m
      bash -c "sleep 300 >/dev/null 2>&1 & printf \"%s\\n\" \"\$!\" > \"$1\"; wait" >/dev/null 2>&1 &
      set +m
      fm_test_track_pid "$!" group
      printf "%s\n" "$!"
    }
    p=$(plain); printf "%s\n" "$p" > "$out/plain"
    e=$(execed); printf "%s\n" "$e" > "$out/execed"
    l=$(leader "$out/member"); printf "%s\n" "$l" > "$out/leader"
    sleep 300 >/dev/null 2>&1 &
    printf "%s\n" "$!" > "$out/unregistered"
    tries=0
    while [ ! -s "$out/member" ] && [ "$tries" -lt 200 ]; do sleep 0.05; tries=$((tries + 1)); done
    : > "$out/ready"
    case "$3" in
      exit) exit 0 ;;
      fail) fail "deliberate failure after starting stand-ins" ;;
      term) while :; do sleep 0.1; done ;;
    esac
  ' _ "$LIB" "$harness" "$ending" 2>/dev/null &
  pid=$!
  tries=0
  while [ ! -e "$harness/ready" ] && [ "$tries" -lt 400 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -e "$harness/ready" ] || fail "the reaping child never started its stand-ins"
  for f in plain execed leader member unregistered; do
    fm_test_track_pid "$(cat "$harness/$f")"
  done
  [ "$ending" = term ] && kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  printf '%s\n' "$harness"
}

assert_reaped() {  # <pid> <message>
  local tries=0
  while fm_test_process_running "$1" && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  ! fm_test_process_running "$1" || fail "$2"
}

check_reaping_child() {  # <ending>
  local harness unregistered
  harness=$(run_reaping_child "$1")
  assert_reaped "$(cat "$harness/plain")" \
    "a stand-in registered from a command substitution survived its suite's $1"
  assert_reaped "$(cat "$harness/execed")" \
    "a registered stand-in that exec'd into another program survived its suite's $1"
  assert_reaped "$(cat "$harness/leader")" \
    "a registered process-group leader survived its suite's $1"
  assert_reaped "$(cat "$harness/member")" \
    "a member of a registered fixture process group survived its suite's $1"
  unregistered=$(cat "$harness/unregistered")
  fm_test_process_running "$unregistered" \
    || fail "teardown signaled a process the suite never registered"
  kill "$unregistered" 2>/dev/null
}

test_registered_fixture_processes_reaped_after_normal_exit() {
  check_reaping_child exit
  pass "registered fixture processes are reaped when their suite exits normally"
}

test_registered_fixture_processes_reaped_after_failure() {
  check_reaping_child fail
  pass "registered fixture processes are reaped when their suite fails"
}

test_registered_fixture_processes_reaped_after_sigterm() {
  check_reaping_child term
  pass "registered fixture processes are reaped when their suite is terminated"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_registered_fixture_processes_reaped_after_normal_exit
test_registered_fixture_processes_reaped_after_failure
test_registered_fixture_processes_reaped_after_sigterm
