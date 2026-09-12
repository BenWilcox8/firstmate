#!/usr/bin/env bash
# This live guard proves the public Codex exit path in an isolated Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CONTROL_HERDR_CODEX_LIVE_E2E herdr jq codex

LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || fail "the guarded Herdr lab helper is not executable"
SESSION=$("$LAB_HELPER" name codex-attribution-r1) \
  || fail "the guarded Herdr lab name could not be created"
TMP_ROOT=$(fm_test_tmproot fm-control-herdr-codex-live)
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
mkdir -p "$FAKEBIN"
TEARDOWN_PENDING=1

cleanup_all() { # <exit-status>
  local status=$1
  trap - EXIT INT TERM
  if [ "$TEARDOWN_PENDING" -eq 1 ]; then
    if ! "$LAB_HELPER" teardown "$SESSION"; then
      printf 'not ok - the lab teardown or default-session tripwire failed during cleanup\n' >&2
      status=1
    fi
  fi
  fm_test_cleanup
  exit "$status"
}

trap 'cleanup_all $?' EXIT
trap 'cleanup_all 130' INT
trap 'cleanup_all 143' TERM

"$LAB_HELPER" provision "$SESSION" \
  || fail "the isolated Herdr lab session could not be provisioned"

export LAB_HELPER SESSION ORIGINAL_PATH
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

CREATE=$("$LAB_HELPER" run "$SESSION" workspace create \
  --cwd "$ROOT" --label fm-codex-attribution --no-focus) \
  || fail "the isolated Codex workspace could not be created"
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "the isolated Codex pane ID could not be read"
TAB=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.tab_id') \
  || fail "the isolated Codex tab ID could not be read"
WORKSPACE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.workspace_id') \
  || fail "the isolated Codex workspace ID could not be read"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/codexproof"
printf '# Codex attribution live guard\n' > "$HOME_DIR/data/codexproof/brief.md"
{
  printf 'window=%s:%s\n' "$SESSION" "$PANE"
  printf 'endpoint_task_id=codexproof\n'
  printf 'worktree=%s\n' "$ROOT"
  printf 'project=firstmate\n'
  printf 'harness=codex\n'
  printf 'kind=ship\n'
  printf 'mode=no-mistakes\n'
  printf 'yolo=off\n'
  printf 'model=gpt-5.6-terra\n'
  printf 'effort=default\n'
  printf 'backend=herdr\n'
  printf 'herdr_session=%s\n' "$SESSION"
  printf 'herdr_workspace_id=%s\n' "$WORKSPACE"
  printf 'herdr_tab_id=%s\n' "$TAB"
  printf 'herdr_pane_id=%s\n' "$PANE"
} > "$HOME_DIR/state/codexproof.meta"

"$LAB_HELPER" run "$SESSION" agent start codex-proof \
  --kind codex --pane "$PANE" --timeout 120000 -- -m gpt-5.6-terra >/dev/null \
  || fail "the real Codex agent did not become ready"

PROCESS_INFO=$("$LAB_HELPER" run "$SESSION" pane process-info --pane "$PANE") \
  || fail "the real Codex process information could not be read"
printf '%s' "$PROCESS_INFO" | jq -e '
  .result.process_info.foreground_processes
  | any(.[];
      .name == "MainThread"
      and (.argv[0] | split("/")[-1]) == "node"
      and (.argv[1] | split("/")[-1]) == "codex")
' >/dev/null || fail "the real Codex process did not expose the MainThread Node wrapper"
pass "real Codex exposes the expected MainThread Node wrapper"

OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=15 \
  "$ROOT/bin/fm-control.sh" codexproof exit 2>&1) \
  || fail "the public guarded exit refused the real Codex endpoint: $OUT"
case "$OUT" in
  "stopped codexproof harness=codex backend=herdr"*) ;;
  *) fail "the public guarded exit returned an unexpected result: $OUT" ;;
esac
pass "the public guarded exit stops the attributed Codex agent"

AFTER=$("$LAB_HELPER" run "$SESSION" pane process-info --pane "$PANE") \
  || fail "the preserved pane process information could not be read"
printf '%s' "$AFTER" | jq -e '
  .result.process_info as $process
  | ($process.foreground_processes | length) == 1
    and $process.foreground_processes[0].pid == $process.shell_pid
    and $process.foreground_processes[0].name == "bash"
' >/dev/null || fail "the guarded exit did not preserve the agent-free shell pane"
"$LAB_HELPER" run "$SESSION" pane get "$PANE" >/dev/null \
  || fail "the guarded exit removed the task pane"
pass "the guarded exit preserves the pane and its local worktree"

"$LAB_HELPER" teardown "$SESSION" \
  || fail "the lab teardown or default-session tripwire failed"
TEARDOWN_PENDING=0
pass "the lab was removed and the default session stayed unchanged"
