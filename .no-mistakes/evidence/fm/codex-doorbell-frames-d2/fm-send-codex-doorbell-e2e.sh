#!/usr/bin/env bash
# E2E: drive the public bin/fm-send.sh steer path for a recorded Codex task on
# a stub Herdr CLI whose `pane read` returns a real idle Codex ANSI frame.
# Usage: fm-send-codex-doorbell-e2e.sh <tree> <frames-test-file>
set -u
TREE=$1 FRAMES=$2
. "$TREE/tests/lib.sh"
. "$TREE/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane; herdr_forget_inherited_home; unset HERDR_ENV HERDR_PANE_ID
eval "$(grep '^FRAME_' "$FRAMES")"
ESC=$(printf '\033')
TMP=$(mktemp -d)
make_stub() {
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
cmd=${1:-}; sub=${2:-}; pane=${3:-}
case "$cmd $sub" in
  "status --json") printf '{"client":{"version":"0.8.2","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s","tab_id":"t1","workspace_id":"w1"}}}\n' "$pane" ;;
  "agent get") printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  "pane read") cat "$FM_FAKE_SCREEN" ;;
  "pane send-text") printf 'send-text: %s\n' "${4:-}" >> "$FM_FAKE_TYPED" ;;
  "pane send-keys") printf 'send-keys: %s\n' "${4:-}" >> "$FM_FAKE_TYPED" ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/herdr"
}
run_case() {  # <label> <screen>
  local d="$TMP/$RANDOM$RANDOM" st=0
  mkdir -p "$d/home/state"; : > "$d/typed"; make_stub "$d"
  printf '%s' "$2" > "$d/screen"
  fm_write_meta "$d/home/state/t1.meta" "window=default:w1:p2" "backend=herdr" \
    "herdr_session=default" "herdr_pane_id=w1:p2" "endpoint_task_id=t1" "kind=ship" "harness=codex"
  env PATH="$d/fakebin:$PATH" FM_ROOT_OVERRIDE="$d/home" FM_HOME="$d/home" \
    FM_FAKE_SCREEN="$d/screen" FM_FAKE_TYPED="$d/typed" \
    FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.01 \
    FM_BACKEND_HERDR_SUBMIT_POLLS=1 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    "$TREE/bin/fm-send.sh" t1 "act on the queued instruction" >/dev/null 2>"$d/err" || st=$?
  echo "### $1"
  echo "fm-send exit: $st"
  echo "stderr:"; sed 's/^/  /' "$d/err"
  echo "keystrokes sent to the pane:"; if [ -s "$d/typed" ]; then sed 's/^/  /' "$d/typed"; else echo "  (none - doorbell skipped)"; fi
  echo
}
echo "== tree: $(git -C "$TREE" rev-parse --short HEAD)"
run_case "live idle Codex frame, no prompt-row animation cell" "$FRAME_NO_CELL_BELOW"
run_case "live idle Codex frame, cells above and below only" "$FRAME_NO_CELL_AROUND"
run_case "saved after-fix frame (295K used · Context 1…)" "$FRAME_SAVED_CONTEXT"
run_case "same live frame with a real typed draft" "${FRAME_NO_CELL_BELOW/'Ask Codex to do anything'/"${ESC}[22mtyped draft"}"
rm -rf "$TMP"
