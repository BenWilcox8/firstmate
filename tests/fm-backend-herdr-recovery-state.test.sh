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
  treehouse-shell)
    printf '%s\n' \
      '1 0 1 S systemd /sbin/init' \
      '100 1 100 S bash /bin/bash' \
      '101 100 101 S bash /bin/bash -l' \
      '103 101 103 Sl treehouse treehouse get' \
      '104 103 104 S bash /bin/bash'
    ;;
  treehouse-other-args|treehouse-active)
    broker_stat=Sl
    [ "$FM_RECOVERY_CASE" != treehouse-active ] || broker_stat=Rl
    printf '%s\n' \
      '1 0 1 S systemd /sbin/init' \
      '100 1 100 S bash /bin/bash' \
      '101 100 101 S bash /bin/bash -l' \
      "103 101 103 $broker_stat treehouse treehouse status" \
      '104 103 104 S bash /bin/bash'
    ;;
  active-pi|absent-active-pi)
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash' '102 100 102 S pi'
    ;;
  interpreter-pi)
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash' '102 100 102 S node'
    ;;
  codex-aarch64|kimi-code|muse-bin|cursor-agent|cursor-mainthread)
    case "$FM_RECOVERY_CASE" in
      codex-aarch64) process=codex-aarch64-a ;;
      kimi-code) process=kimi-code ;;
      muse-bin) process=muse-bin-0.1.0 ;;
      cursor-agent) process=cursor-agent ;;
      cursor-mainthread) process=MainThread ;;
    esac
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash' "102 100 102 S $process"
    ;;
  interpreter-claude|interpreter-codex)
    interpreter=python3
    [ "$FM_RECOVERY_CASE" = interpreter-codex ] && interpreter=node
    printf '%s\n' '1 0 1 S systemd' '100 1 100 S bash' "102 100 102 S $interpreter"
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
              treehouse-shell|treehouse-other-args|treehouse-active)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":104,\"foreground_processes\":[{\"pid\":104,\"name\":\"bash\",\"argv\":[\"/bin/bash\"]}]}}}"
                ;;
              active-pi|absent-active-pi)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"pi\",\"argv\":[\"pi\"]}]}}}"
                ;;
              interpreter-pi)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"node\",\"argv\":[\"/usr/local/bin/node\",\"/opt/pi/bin/pi\"]}]}}}"
                ;;
              codex-aarch64)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"codex-aarch64-a\",\"argv\":[\"codex-aarch64-a\"]}]}}}"
                ;;
              kimi-code)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"kimi-code\",\"argv\":[\"kimi-code\"]}]}}}"
                ;;
              muse-bin)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"muse-bin-0.1.0\",\"argv\":[\"muse-bin-0.1.0\"]}]}}}"
                ;;
              cursor-agent)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"cursor-agent\",\"argv\":[\"cursor-agent\"]}]}}}"
                ;;
              cursor-mainthread)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"MainThread\",\"argv\":[\"/home/test/.local/share/cursor-agent/versions/v1/cursor-agent\"]}]}}}"
                ;;
              interpreter-claude)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"python3\",\"argv\":[\"/usr/bin/python3\",\"/opt/claude/run.py\"]}]}}}"
                ;;
              interpreter-codex)
                printf "%s\n" "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p2\",\"shell_pid\":100,\"foreground_process_group_id\":102,\"foreground_processes\":[{\"pid\":102,\"name\":\"node\",\"argv\":[\"/usr/bin/node\",\"/opt/codex/run.js\"]}]}}}"
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
assert_case treehouse-shell working dead
pass "stale lifecycle status cannot keep an exited agent alive, including through nested launch shells and the exact Treehouse shell broker"

assert_case active-pi working alive
assert_case absent-active-pi absent alive
assert_case interpreter-pi idle alive
assert_case codex-aarch64 idle alive
assert_case kimi-code idle alive
assert_case muse-bin idle alive
assert_case cursor-agent idle alive
assert_case cursor-mainthread idle alive
assert_case interpreter-claude idle alive
assert_case interpreter-codex idle alive
assert_case other-command idle unreadable
assert_case treehouse-other-args idle unreadable
assert_case treehouse-active idle unreadable
assert_case unreadable idle unreadable
pass "active supported harnesses remain live, while other commands, an inexact or active Treehouse process, and unreadable evidence remain ambiguous"

assert_case process-race idle unreadable
assert_case pane-race idle unreadable
pass "changed process ownership or pane identity refuses recovery"
