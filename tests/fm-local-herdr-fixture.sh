#!/usr/bin/env bash
# Guard every Herdr call, including calls from Firstmate and agent-axi.
# Call fm_local_lab_start after sourcing tests/lib.sh. Call fm_local_lab_finish on EXIT.
fm_local_lab_start() {
  command -v herdr >/dev/null 2>&1 || return 77
  FM_LOCAL_LAB_REAL_PATH=$PATH
  FM_LOCAL_LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
  FM_LOCAL_LAB_SESSION=$("$FM_LOCAL_LAB_HELPER" name pane-cleanup-on-exit-p1) || return 1
  export FM_LOCAL_LAB_REAL_PATH FM_LOCAL_LAB_HELPER FM_LOCAL_LAB_SESSION
  trap fm_local_lab_finish EXIT
  "$FM_LOCAL_LAB_HELPER" provision "$FM_LOCAL_LAB_SESSION" || return 1
  FM_LOCAL_LAB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-local-pane.XXXXXX") || return 1
  mkdir -p "$FM_LOCAL_LAB_ROOT/tools" "$FM_LOCAL_LAB_ROOT/home/state" "$FM_LOCAL_LAB_ROOT/home/data" "$FM_LOCAL_LAB_ROOT/home/config"
  cat > "$FM_LOCAL_LAB_ROOT/tools/herdr" <<'WRAPPER'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "${2:-}" = "$FM_LOCAL_LAB_SESSION" ] || exit 90; shift 2 ;;
    --session=*) [ "${1#*=}" = "$FM_LOCAL_LAB_SESSION" ] || exit 90; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
PATH=$FM_LOCAL_LAB_REAL_PATH exec "$FM_LOCAL_LAB_HELPER" run "$FM_LOCAL_LAB_SESSION" "${args[@]}"
WRAPPER
  chmod +x "$FM_LOCAL_LAB_ROOT/tools/herdr"
  export PATH="$FM_LOCAL_LAB_ROOT/tools:$PATH"
  unset HERDR_PANE_ID HERDR_TERMINAL_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH HERDR_ENV
  export HERDR_SESSION=$FM_LOCAL_LAB_SESSION FM_HOME="$FM_LOCAL_LAB_ROOT/home"
  FM_BACKEND_HERDR_AXI_LAUNCH="$(command -v bash) --noprofile --norc -i"
  export FM_BACKEND_HERDR_AXI_LAUNCH
  export FM_GATE_REFUSE_BYPASS=1
  printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
}

fm_local_lab_finish() {
  local rc=$?
  trap - EXIT
  if ! PATH=$FM_LOCAL_LAB_REAL_PATH "$FM_LOCAL_LAB_HELPER" teardown "$FM_LOCAL_LAB_SESSION"; then
    echo 'not ok - guarded lab cleanup or default-session tripwire failed' >&2
    exit 1
  fi
  [ -z "${FM_LOCAL_LAB_TASK_TMP:-}" ] || rm -rf "$FM_LOCAL_LAB_TASK_TMP"
  [ -z "${FM_LOCAL_LAB_ROOT:-}" ] || rm -rf "$FM_LOCAL_LAB_ROOT"
  exit "$rc"
}
