#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
gone=${FM_FAKE_HERDR_GONE_PANE:-}
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true}}\n' ;;
  "pane get")
    if [ -n "$gone" ] && [ "${3:-}" = "$gone" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3"; exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys"|"pane send-text")
    if [ -n "$gone" ] && [ "${3:-}" = "$gone" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3"; exit 1
    fi
    : ;;
  "agent get")
    if [ -n "$gone" ] && [ "${3:-}" = "$gone" ]; then
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$3"; exit 1
    fi
    # First read is the pre-Enter baseline (idle); every later read shows the
    # turn the Enter started, exactly like a real submit.
    n=$(cat "$FM_HERDR_LOG.agent-reads" 2>/dev/null || printf 0)
    n=$((n + 1)); printf '%s\n' "$n" > "$FM_HERDR_LOG.agent-reads"
    if [ "$n" -le 1 ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    fi ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

# herdr 0.8.2 prints pane ids bare, so an operator reading one out of
# `herdr agent list` has no session to prefix it with. An EXACT herdr_pane_id
# match in this home's own metadata is the evidence that resolves it to one
# recorded task; nothing is inferred from the id's shape, and a bare id still
# never falls through to a tmux window search.
test_bare_herdr_pane_id_resolves_through_recorded_meta() {
  local dir fb home err herdr_log tmux_log rc got
  dir="$TMP_ROOT/herdr-bare-id"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdrbare); err="$dir/send.err"
  herdr_log="$dir/herdr.log"; tmux_log="$dir/tmux.log"; : > "$herdr_log"; : > "$tmux_log"
  fm_write_meta "$home/state/bare-ok.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$herdr_log" FM_TMUX_LOG="$tmux_log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a bare herdr pane id recorded in this home should resolve"$'\n'"$(cat "$err")"
  got=$(cat "$herdr_log")
  assert_contains "$got" "pane send-text wB:p2 hello captain --session default" "the bare id did not steer its recorded pane in its recorded session"
  [ ! -s "$tmux_log" ] || fail "a bare herdr pane id fell through to tmux"$'\n'"$(cat "$tmux_log")"
  pass "fm-send strict: a bare herdr pane id resolves through its recorded task, never through a guessed session"
}

# The record is the only thing that resolves a bare id. With no recorded
# session there is nothing to steer against, so it must still refuse loudly.
test_bare_herdr_pane_id_without_a_recorded_session_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-bare-nosession"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdrbarenos); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/bare-nos.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a bare herdr pane id with no recorded session should fail"
  assert_contains "$(cat "$err")" "names no herdr session or endpoint" "the refusal did not say why the record could not resolve it"
  [ ! -s "$log" ] || fail "an unresolvable bare herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: a bare herdr pane id with no recorded session refuses instead of guessing one"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

# herdr 0.8.2 refuses a session-prefixed agent or pane target outright, so a
# steer to a task whose meta still records "window=default:<ws>:<pane>" must
# reach the CLI as the bare pane id. No meta is rewritten to make this work.
test_herdr_prefixed_meta_window_reaches_the_bare_pane() {
  local dir fb home err herdr_log rc got
  dir="$TMP_ROOT/herdr-prefixed-meta"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdrmeta); err="$dir/send.err"; herdr_log="$dir/herdr.log"
  : > "$herdr_log"
  fm_write_meta "$home/state/steer-ok.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" steer-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a steer to a herdr task with a session-prefixed meta window should land"$'\n'"$(cat "$err")"
  got=$(cat "$herdr_log")
  assert_contains "$got" "pane send-text wB:p2 hello captain --session default" "the steer did not type into the bare pane id"
  assert_contains "$got" "pane send-keys wB:p2 enter --session default" "the steer did not submit against the bare pane id"
  assert_no_grep 'default:wB:p2' "$herdr_log" "a session-prefixed target reached the herdr CLI, which 0.8.2 rejects"
  pass "fm-send strict: a session-prefixed herdr meta window steers the bare pane id 0.8.2 accepts"
}

# A gone endpoint and an unconfirmed submit used to read identically. They call
# for opposite responses - reconcile the task versus wait or retry - so the
# error must name which one happened.
test_herdr_gone_endpoint_is_named_not_reported_as_unconfirmed() {
  local dir fb home err herdr_log rc got
  dir="$TMP_ROOT/herdr-gone"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdrgone); err="$dir/send.err"; herdr_log="$dir/herdr.log"
  : > "$herdr_log"
  fm_write_meta "$home/state/steer-gone.meta" \
    "window=default:wB:p9" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p9" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    FM_FAKE_HERDR_GONE_PANE=wB:p9 \
    "$SEND" steer-gone "hello captain" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a steer to a gone herdr endpoint must fail"
  got=$(cat "$err")
  assert_contains "$got" "endpoint is gone" "the failure did not name the gone endpoint as the cause"
  assert_contains "$got" "no such pane" "the failure did not say what herdr reported"
  assert_not_contains "$got" "delivery unconfirmed" "a gone endpoint must not be reported as an unconfirmed delivery"
  pass "fm-send strict: a gone herdr endpoint is named as gone, never as an unconfirmed submit"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_bare_herdr_pane_id_resolves_through_recorded_meta
test_bare_herdr_pane_id_without_a_recorded_session_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_herdr_prefixed_meta_window_reaches_the_bare_pane
test_herdr_gone_endpoint_is_named_not_reported_as_unconfirmed
test_healthy_fm_id_send_still_works
