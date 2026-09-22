#!/usr/bin/env bash
# Recovery through the public backend interface with independent process views.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-merge-harnesses)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home"
cat > "$TMP_ROOT/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pane get') printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' ;;
  'agent get') printf '{"error":{"code":"agent_not_found"}}\n' ;;
  'pane process-info')
    jq -nc --arg name "$FM_TEST_PROCESS" --argjson argv "$FM_TEST_ARGV" \
      '{result:{type:"pane_process_info",process_info:{pane_id:"w1:p2",shell_pid:100,foreground_process_group_id:102,foreground_processes:[{pid:102,name:$name,argv:$argv}]}}}' ;;
  'status --json') printf '{"server":{"running":true}}\n' ;;
  *) exit 1 ;;
esac
SH
cat > "$TMP_ROOT/bin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '1 0 1 S systemd /sbin/init' '100 1 100 S bash /bin/bash'
printf '102 100 102 S %s %s\n' "$FM_TEST_PROCESS" "$FM_TEST_ARGS"
SH
chmod +x "$TMP_ROOT/bin/herdr" "$TMP_ROOT/bin/ps"
check_case() {
  local name=$1 argv=$2 args=$3 expected=$4 actual
  actual=$(PATH="$TMP_ROOT/bin:$PATH" FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_PROCESS="$name" FM_TEST_ARGV="$argv" FM_TEST_ARGS="$args" \
    FM_BACKEND_HERDR_BIN="$TMP_ROOT/bin/herdr" FM_HERDR_PS_BIN="$TMP_ROOT/bin/ps" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state herdr merge-test:w1:p2' _ "$ROOT")
  [ "$actual" = "$expected" ] || fail "$name recovery returned $actual, expected $expected"
}
check_case agy '["/opt/bin/agy"]' '/opt/bin/agy' alive
check_case omp '["/opt/bin/omp"]' '/opt/bin/omp' alive
check_case ompd '["/opt/bin/ompd"]' '/opt/bin/ompd' unreadable
check_case ragy '["/opt/bin/ragy"]' '/opt/bin/ragy' unreadable
check_case MainThread '["node","/opt/bin/codex"]' 'node /opt/bin/codex' alive
check_case MainThread '["node","/opt/bin/codex"]' 'node /opt/bin/unrelated' unreadable
pass 'AGY and omp remain alive without registry hooks; lookalikes and inconsistent Codex evidence refuse recovery'
