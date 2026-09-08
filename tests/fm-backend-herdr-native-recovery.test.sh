#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

run_case() {
  local mode=$1 out status
  out=$(FM_NATIVE_RECOVERY_MODE="$mode" FM_NATIVE_RECOVERY_DIR="$TMP_ROOT/$mode" FM_BACKEND_HERDR_AXI_BIN=/no-agent-axi ROOT="$ROOT" bash -c '
    mkdir -p "$FM_NATIVE_RECOVERY_DIR"
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "tab list")
          printf "{\"result\":{\"tabs\":[{\"tab_id\":\"w1:t2\",\"label\":\"fm-task\"}]}}\n"
          ;;
        "pane list")
          count=$(cat "$FM_NATIVE_RECOVERY_DIR/panes" 2>/dev/null || printf 0)
          count=$((count + 1)); printf "%s" "$count" > "$FM_NATIVE_RECOVERY_DIR/panes"
          case "$FM_NATIVE_RECOVERY_MODE:$count" in
            multi:*) printf "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t2\"},{\"pane_id\":\"w1:p2\",\"tab_id\":\"w1:t2\"}]}}\n" ;;
            identity:3) printf "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p9\",\"tab_id\":\"w1:t3\"}]}}\n" ;;
            *)
              if [ "$count" -ge 3 ]; then pane=w1:p3; tab=w1:t3; else pane=w1:p1; tab=w1:t2; fi
              printf "{\"result\":{\"panes\":[{\"pane_id\":\"%s\",\"tab_id\":\"%s\"}]}}\n" "$pane" "$tab"
              ;;
          esac
          ;;
        "tab create") printf "{\"result\":{\"tab\":{\"tab_id\":\"w1:t3\"},\"root_pane\":{\"pane_id\":\"w1:p3\"}}}\n" ;;
        "tab close") printf "%s\n" "$4" >> "$FM_NATIVE_RECOVERY_DIR/closed" ;;
        *) return 1 ;;
      esac
    }
    fm_backend_herdr_recovery_pane_agent_state() {
      if [ "$2" = w1:p2 ]; then
        printf live
      elif [ "$2" = w1:p1 ]; then
        count=$(cat "$FM_NATIVE_RECOVERY_DIR/old-state" 2>/dev/null || printf 0)
        count=$((count + 1)); printf "%s" "$count" > "$FM_NATIVE_RECOVERY_DIR/old-state"
        [ "$count" -eq 1 ] && { printf no-agent; return; }
        printf live
      elif [ "$FM_NATIVE_RECOVERY_MODE" = state ]; then
        printf live
      else
        printf no-agent
      fi
    }
    fm_backend_herdr_create_task test:w1 fm-task /tmp
  ' 2>&1)
  status=$?
  printf '%s\n%s' "$status" "$out"
}

result=$(run_case multi)
[ "${result%%$'\n'*}" -ne 0 ] || fail "a multi-pane duplicate was replaced"
[ ! -e "$TMP_ROOT/multi/closed" ] || fail "a multi-pane duplicate was closed"
pass "shell-only first pane with a live sibling refuses tab replacement"

result=$(run_case rollback)
[ "${result%%$'\n'*}" -ne 0 ] || fail "a changed old pane was replaced"
[ "$(cat "$TMP_ROOT/rollback/closed" 2>/dev/null)" = w1:t3 ] || fail "safe exact replacement was not rolled back"
pass "post-create old-pane change rolls back the exact shell-only replacement"

result=$(run_case identity)
[ "${result%%$'\n'*}" -ne 0 ] || fail "an identity-changed old pane was replaced"
[ ! -e "$TMP_ROOT/identity/closed" ] || fail "identity-changed replacement was closed"

result=$(run_case state)
[ "${result%%$'\n'*}" -ne 0 ] || fail "a changed old pane was replaced"
[ ! -e "$TMP_ROOT/state/closed" ] || fail "state-changed replacement was closed"
pass "replacement rollback refuses changed identity or state"
