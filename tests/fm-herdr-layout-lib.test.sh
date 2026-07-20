#!/usr/bin/env bash
# tests/fm-herdr-layout-lib.test.sh - unit tests for the shared agent-axi
# herdr-layout wiring (bin/fm-herdr-layout-lib.sh), spec agent-axi/v1 phase 1.
#
# The library is the single owner of the applicability guard and the three
# agent-axi invocations (repair at session start, drift preview on the watcher
# heartbeat, snapshot in the session-start digest). These tests drive it with a
# fake `agent-axi` on PATH and assert:
#   - the guard is a definitive no-op unless the home backend is herdr AND
#     agent-axi resolves (absent executable, non-herdr backend);
#   - repair/drift summarize a non-converged workspace and stay silent when
#     converged;
#   - snapshot passes the token-lean map through.
# Mirrors the fakebin/command-log convention of tests/fm-backend-herdr.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr-layout wiring)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-layout-lib-tests)

# make_agent_axi_layout_fakebin: an `agent-axi` stub covering the three verbs the
# library drives. `snapshot` prints a canned token-lean map. `layout --repair
# [--dry-run] --json` prints a repair envelope whose `.repair.converged` and
# `.repair.counts` are controlled by FAKE_AXI_CONVERGED (1 = converged/no-op,
# else a drifted workspace with 2 husks + 1 rebind). FAKE_AXI_FAIL=1 makes every
# call exit non-zero (an unreachable/failed probe). Every call is logged to
# $FM_AXI_LOG, unit-separated.
make_agent_axi_layout_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/axibin"
  mkdir -p "$fb"
  cat > "$fb/agent-axi" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_AXI_LOG:?}"
{
  printf 'args'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
[ "${FAKE_AXI_FAIL:-0}" = 1 ] && exit 1
verb=${1:-}
if [ "$verb" = snapshot ]; then
  cat <<'OUT'
bin: agent-axi
workspace: firstmate (w1)  layout: split  slots: 1/6 filled
slots[6]{n,task,state,pane}:
  1,fm-demoA,live,w1:p2
husks: 0
OUT
  exit 0
fi
if [ "$verb" = layout ]; then
  if [ "${FAKE_AXI_CONVERGED:-0}" = 1 ]; then
    printf '{"workspace":{"label":"firstmate","id":"w1"},"repair":{"action":"repair","converged":true,"counts":{"huskClosed":0,"orphanHuskClosed":0,"rebound":0,"freed":0,"adopted":0},"actions":[]}}\n'
  else
    printf '{"workspace":{"label":"firstmate","id":"w1"},"repair":{"action":"repair","converged":false,"counts":{"huskClosed":1,"orphanHuskClosed":1,"rebound":1,"freed":0,"adopted":0},"actions":[{"kind":"close-husk","taskId":"fm-x","tab":1,"slot":2,"paneId":"w1:p3"}]}}\n'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fb/agent-axi"
  printf '%s\n' "$fb"
}

# run_lib: source the library in a clean child with the fake on PATH, the given
# env, and invoke <fn>. Echoes the function's stdout; the caller checks $?.
run_lib() {  # <fb> <extra-env-assignments...> -- <fn> [args...]
  local fb=$1; shift
  local -a env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift
  # $0/$@ are the CHILD shell's positional params (ROOT, then fn + args); the
  # single quotes are deliberate so they expand there, not here.
  # shellcheck disable=SC2016
  PATH="$fb:$PATH" FM_HOME="$ROOT" env "${env[@]}" \
    bash -c '. "$0/bin/fm-herdr-layout-lib.sh"; "$@"' "$ROOT" "$@"
}

# --- applicability guard -----------------------------------------------------

test_applicable_true_for_herdr_home_with_agent_axi() {
  local dir fb log; dir="$TMP_ROOT/appl-ok"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN=agent-axi \
    -- fm_herdr_layout_applicable \
    || fail "fm_herdr_layout_applicable should be true for a herdr home with a resolvable agent-axi"
  pass "fm_herdr_layout_applicable: true when the backend is herdr and agent-axi resolves"
}

test_applicable_false_for_non_herdr_backend() {
  local dir fb log; dir="$TMP_ROOT/appl-tmux"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  if run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=tmux FM_BACKEND_HERDR_AXI_BIN=agent-axi \
    -- fm_herdr_layout_applicable; then
    fail "fm_herdr_layout_applicable must be false on a non-herdr backend even when agent-axi is on PATH"
  fi
  [ -s "$log" ] && fail "the guard must short-circuit BEFORE invoking agent-axi on a non-herdr backend"
  pass "fm_herdr_layout_applicable: false (and never calls agent-axi) when the backend is not herdr"
}

test_applicable_false_when_executable_absent() {
  local dir fb log; dir="$TMP_ROOT/appl-absent"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  # Point the bin at a name that does not exist on PATH: herdr home, but no tool.
  if run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN=agent-axi-nope \
    -- fm_herdr_layout_applicable; then
    fail "fm_herdr_layout_applicable must be false when the configured agent-axi executable is not resolvable"
  fi
  pass "fm_herdr_layout_applicable: false when the agent-axi executable is absent"
}

test_applicable_false_when_bin_disabled_empty() {
  local dir fb log; dir="$TMP_ROOT/appl-empty"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  if run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN= \
    -- fm_herdr_layout_applicable; then
    fail "an explicitly EMPTY FM_BACKEND_HERDR_AXI_BIN must disable the wiring (the rollback lever)"
  fi
  pass "fm_herdr_layout_applicable: false when FM_BACKEND_HERDR_AXI_BIN is explicitly empty"
}

# --- snapshot ----------------------------------------------------------------

test_snapshot_passes_through_when_applicable() {
  local dir fb log out; dir="$TMP_ROOT/snap-ok"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  out=$(run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN=agent-axi \
    -- fm_herdr_layout_snapshot) || fail "fm_herdr_layout_snapshot should succeed when applicable"
  assert_contains "$out" "workspace: firstmate (w1)" "snapshot did not pass agent-axi's map through"
  assert_contains "$(cat "$log")" $'\x1f''snapshot' "snapshot did not invoke 'agent-axi snapshot'"
  pass "fm_herdr_layout_snapshot: passes agent-axi's token-lean slot map through"
}

test_snapshot_silent_on_non_herdr_backend() {
  local dir fb log out; dir="$TMP_ROOT/snap-tmux"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  out=$(run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=tmux FM_BACKEND_HERDR_AXI_BIN=agent-axi \
    -- fm_herdr_layout_snapshot) && fail "fm_herdr_layout_snapshot must fail (silent) on a non-herdr backend"
  [ -z "$out" ] || fail "fm_herdr_layout_snapshot must print nothing on a non-herdr backend, got '$out'"
  [ -s "$log" ] && fail "fm_herdr_layout_snapshot must not call agent-axi on a non-herdr backend"
  pass "fm_herdr_layout_snapshot: silent no-op on a non-herdr backend"
}

# --- repair (full, mutating) -------------------------------------------------

test_repair_summarizes_a_drifted_workspace() {
  local dir fb log out; dir="$TMP_ROOT/repair-drift"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  out=$(run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN=agent-axi FAKE_AXI_CONVERGED=0 \
    -- fm_herdr_layout_repair) || fail "fm_herdr_layout_repair should report a summary for a drifted workspace"
  assert_contains "$out" "healed herdr layout drift" "repair did not report a heal summary"
  assert_contains "$out" "2 husk(s)" "repair summary should fold huskClosed+orphanHuskClosed into the husk count"
  assert_contains "$out" "1 rebind" "repair summary should report the rebind count"
  assert_contains "$(cat "$log")" $'\x1f''layout'$'\x1f''--repair'$'\x1f''--json' "repair must call the full (non-dry-run) layout --repair"
  assert_not_contains "$(cat "$log")" '--dry-run' "the full repair must NOT pass --dry-run"
  pass "fm_herdr_layout_repair: heals and summarizes a drifted workspace via the full layout --repair"
}

test_repair_silent_when_converged() {
  local dir fb log out; dir="$TMP_ROOT/repair-conv"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  out=$(run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN=agent-axi FAKE_AXI_CONVERGED=1 \
    -- fm_herdr_layout_repair) && fail "fm_herdr_layout_repair should return non-zero (silent) on a converged workspace"
  [ -z "$out" ] || fail "fm_herdr_layout_repair must print nothing when the workspace is already converged, got '$out'"
  pass "fm_herdr_layout_repair: silent no-op when the workspace already matches the plan"
}

# --- drift (dry-run, read-only) ----------------------------------------------

test_drift_reports_signature_via_dry_run() {
  local dir fb log out; dir="$TMP_ROOT/drift"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  out=$(run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN=agent-axi FAKE_AXI_CONVERGED=0 \
    -- fm_herdr_layout_drift) || fail "fm_herdr_layout_drift should report a signature for a drifted workspace"
  assert_contains "$out" "2 husk(s), 1 rebind, 0 freed, 0 adopted" "drift signature should fold the repair counts"
  assert_not_contains "$out" "healed" "drift is a preview, not a heal - it must not claim it healed anything"
  assert_contains "$(cat "$log")" $'\x1f''layout'$'\x1f''--repair'$'\x1f''--dry-run'$'\x1f''--json' "drift must use the READ-ONLY --dry-run repair"
  pass "fm_herdr_layout_drift: previews a drifted workspace via the read-only layout --repair --dry-run"
}

test_drift_silent_when_converged() {
  local dir fb log out; dir="$TMP_ROOT/drift-conv"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  out=$(run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN=agent-axi FAKE_AXI_CONVERGED=1 \
    -- fm_herdr_layout_drift) && fail "fm_herdr_layout_drift should be silent (non-zero) on a converged workspace"
  [ -z "$out" ] || fail "fm_herdr_layout_drift must print nothing when converged, got '$out'"
  pass "fm_herdr_layout_drift: silent no-op when the live workspace matches the plan"
}

test_drift_silent_on_probe_failure() {
  local dir fb log out; dir="$TMP_ROOT/drift-fail"; mkdir -p "$dir"; log="$dir/log"; : > "$log"
  fb=$(make_agent_axi_layout_fakebin "$dir")
  out=$(run_lib "$fb" FM_AXI_LOG="$log" FM_BACKEND=herdr FM_BACKEND_HERDR_AXI_BIN=agent-axi FAKE_AXI_FAIL=1 \
    -- fm_herdr_layout_drift) && fail "fm_herdr_layout_drift should be silent when the agent-axi probe fails"
  [ -z "$out" ] || fail "fm_herdr_layout_drift must print nothing when the probe fails (e.g. no herdr server), got '$out'"
  pass "fm_herdr_layout_drift: silent no-op when the agent-axi probe fails (fails safe to no drift)"
}

test_applicable_true_for_herdr_home_with_agent_axi
test_applicable_false_for_non_herdr_backend
test_applicable_false_when_executable_absent
test_applicable_false_when_bin_disabled_empty
test_snapshot_passes_through_when_applicable
test_snapshot_silent_on_non_herdr_backend
test_repair_summarizes_a_drifted_workspace
test_repair_silent_when_converged
test_drift_reports_signature_via_dry_run
test_drift_silent_when_converged
test_drift_silent_on_probe_failure
