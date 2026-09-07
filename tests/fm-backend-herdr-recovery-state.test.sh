#!/usr/bin/env bash
# Regression coverage for recovery-grade Herdr agent classification.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "${FM_RECOVERY_CASE:?}" in
  stale-shell|absent-shell|pane-race)
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash'
    ;;
  nested-shell)
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash' '101 100 101 S bash'
    ;;
  active-pi|absent-active-pi)
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash' '102 100 102 S pi'
    ;;
  other-command)
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash' '103 100 103 S sleep'
    ;;
  process-race)
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash' '200 1 200 S bash'
    ;;
  unreadable)
    exit 1
    ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/ps"

run_case() { # <case> <registry-status>
  FM_RECOVERY_CASE=$1 FM_REGISTRY_STATUS=$2 FM_RECOVERY_DIR="$TMP_ROOT" \
    FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" ROOT="$ROOT" bash -c '
      . "$ROOT/bin/backends/herdr.sh"
      fm_backend_herdr_cli() {
        case "$2 $3" in
          "pane get")
            count=$(cat "$FM_RECOVERY_DIR/pane-count-$FM_RECOVERY_CASE" 2>/dev/null || printf 0)
            count=$((count + 1))
            printf "%s" "$count" > "$FM_RECOVERY_DIR/pane-count-$FM_RECOVERY_CASE"
            if [ "$FM_RECOVERY_CASE" = pane-race ] && [ "$count" -gt 1 ]; then
              printf "%s\n" "{\"result\":{\"pane\":{\"pane_id\":\"w1:p9\"}}}"
            else
              printf "%s\n" "{\"result\":{\"pane\":{\"pane_id\":\"w1:p2\"}}}"
            fi
            ;;
          "agent get")
            if [ "$FM_REGISTRY_STATUS" = absent ]; then
              printf "%s\n" "{\"error\":{\"code\":\"agent_not_found\"}}"
            else
              printf "%s\n" "{\"result\":{\"agent\":{\"agent_status\":\"$FM_REGISTRY_STATUS\"}}}"
            fi
            ;;
          "pane process-info")
            count=$(cat "$FM_RECOVERY_DIR/process-count-$FM_RECOVERY_CASE" 2>/dev/null || printf 0)
            count=$((count + 1))
            printf "%s" "$count" > "$FM_RECOVERY_DIR/process-count-$FM_RECOVERY_CASE"
            case "$FM_RECOVERY_CASE" in
              stale-shell|absent-shell|pane-race)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":100,\"foreground_processes\":[{\"pid\":100,\"name\":\"bash\",\"argv\":[\"/bin/bash\"]}]}}}"
                ;;
              nested-shell)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":101,\"foreground_processes\":[{\"pid\":101,\"name\":\"bash\",\"argv\":[\"/bin/bash\"]}]}}}"
                ;;
              active-pi|absent-active-pi)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"pi\",\"argv\":[\"pi\"]}]}}}"
                ;;
              other-command)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":103,\"foreground_processes\":[{\"pid\":103,\"name\":\"sleep\",\"argv\":[\"sleep\",\"30\"]}]}}}"
                ;;
              process-race)
                if [ "$count" -eq 1 ]; then shell=100; else shell=200; fi
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":$shell,\"foreground_process_group_id\":$shell,\"foreground_processes\":[{\"pid\":$shell,\"name\":\"bash\",\"argv\":[\"/bin/bash\"]}]}}}"
                ;;
              unreadable)
                printf "%s\n" not-json
                ;;
            esac
            ;;
          *) return 1 ;;
        esac
      }
      fm_backend_herdr_agent_state test:w1:p2
    '
}

assert_case() { # <case> <registry-status> <expected>
  rm -f "$TMP_ROOT/pane-count-$1" "$TMP_ROOT/process-count-$1"
  out=$(run_case "$1" "$2") || fail "$1 could not be classified"
  [ "$out" = "$3" ] || fail "$1 with registry status $2 returned $out, expected $3"
}

assert_case stale-shell idle dead
assert_case absent-shell absent dead
assert_case nested-shell 'done' dead
pass "stale lifecycle status cannot keep an exited agent alive, including through nested launch shells"

assert_case active-pi working alive
assert_case absent-active-pi absent alive
assert_case other-command idle unreadable
assert_case unreadable idle unreadable
pass "active agents remain live, while other commands and unreadable process evidence remain ambiguous"

assert_case process-race idle unreadable
assert_case pane-race idle unreadable
pass "changed process ownership or pane identity refuses recovery"
