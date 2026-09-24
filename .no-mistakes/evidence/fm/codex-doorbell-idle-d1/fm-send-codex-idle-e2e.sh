#!/usr/bin/env bash
# Drive the REAL bin/fm-send.sh (steering-inbox data plane) at a Codex task on
# the Herdr backend, whose pane renders a captured idle Codex 0.155.1 composer
# frame: braille animation around the dim "Ask Codex to do anything"
# placeholder and a clipped "Context 6..." status row. Then run the watcher's
# re-ring (bin/fm-watch.sh calls fm_task_inbox_ring with the same arguments).
# A stub herdr serves the ANSI frame and logs every typed text and key.
# Usage: fm-send-codex-idle-e2e.sh <repo-root> <frame-index 0|1> [idle|typed]
set -u
ROOT=$1 IDX=$2 MODE=${3:-idle}
FRAMES=(
$'\033[0m\033[48;2;61;59;78m                         \033[0m\033[38;2;104;102;121m\033[48;2;61;59;78m⢀\033[0m\033[48;2;61;59;78m  \033[0m\033[38;2;109;107;127m\033[48;2;61;59;78m⠈\033[0m\033[48;2;61;59;78m               \033[0m\r\n\033[0m\033[1m\033[48;2;61;59;78m›\033[0m\033[48;2;61;59;78m \033[0m\033[2m\033[48;2;61;59;78mAsk Codex to do anything\033[0m\033[48;2;61;59;78m   \033[0m\033[38;2;107;105;125m\033[48;2;61;59;78m⠈\033[0m\033[48;2;61;59;78m            \033[0m\033[38;2;147;145;166m\033[48;2;61;59;78m⠁\033[0m\033[48;2;61;59;78m \033[0m\r\n\033[0m\033[48;2;61;59;78m                    \033[0m\033[38;2;115;113;133m\033[48;2;61;59;78m⠠\033[0m\033[48;2;61;59;78m               \033[0m\033[38;2;150;148;169m\033[48;2;61;59;78m⠠\033[0m\033[48;2;61;59;78m       \033[0m\r\n  \033[0m\033[2mgpt-6-astra xhigh · 178K used · Context 6…\033[0m'
$'\033[0m\033[48;2;61;59;78m    \033[0m\033[38;2;75;73;93m\033[48;2;61;59;78m⠈\033[0m\033[48;2;61;59;78m                           \033[0m\033[38;2;138;136;157m\033[48;2;61;59;78m⠁\033[0m\033[48;2;61;59;78m           \033[0m\r\n\033[0m\033[1m\033[48;2;61;59;78m›\033[0m\033[38;2;150;148;169m\033[48;2;61;59;78m⠁\033[0m\033[2m\033[48;2;61;59;78mAsk Codex to do anything\033[0m\033[48;2;61;59;78m         \033[0m\033[38;2;70;68;87m\033[48;2;61;59;78m⠈\033[0m\033[48;2;61;59;78m    \033[0m\033[38;2;134;132;152m\033[48;2;61;59;78m⠁\033[0m\033[48;2;61;59;78m   \033[0m\r\n\033[0m\033[48;2;61;59;78m        \033[0m\033[38;2;85;83;102m\033[48;2;61;59;78m⠐\033[0m\033[48;2;61;59;78m        \033[0m\033[38;2;73;71;90m\033[48;2;61;59;78m⠄\033[0m\033[48;2;61;59;78m                          \033[0m\r\n  \033[0m\033[2mgpt-6-astra xhigh · 178K used · Context 6…\033[0m'
)
frame=${FRAMES[$IDX]}
[ "$MODE" = typed ] && frame=${frame/'Ask Codex to do anything'/$'\033[22mplease also fix the tests'}
W=$(mktemp -d); mkdir -p "$W/home/state" "$W/fakebin"
printf '%s' "$frame" > "$W/frame.ansi"
cat > "$W/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
cmd=${1:-}; sub=${2:-}; pane=${3:-}
case "$cmd $sub" in
  "status --json") echo '{"client":{"version":"0.8.2","protocol":16},"server":{"running":true}}' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s","tab_id":"t1","workspace_id":"w1"}}}\n' "$pane" ;;
  "agent get") echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  "pane read") cat "$FM_FRAME" ;;
  "pane send-text") printf 'TYPED: %s\n' "${4:-}" >> "$FM_SEND_LOG" ;;
  "pane send-keys") printf 'KEY: %s\n' "${4:-}" >> "$FM_SEND_LOG" ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/sleep"; chmod +x "$W/fakebin/"*
printf '%s\n' window=default:w1:p2 backend=herdr herdr_session=default herdr_pane_id=w1:p2 \
  endpoint_task_id=t1 kind=ship harness=codex > "$W/home/state/t1.meta"
: > "$W/send.log"
# Sandboxed fake fleet (stub herdr, temp home): same bypass tests/lib.sh exports.
ENV=(FM_GATE_REFUSE_BYPASS=1 PATH="$W/fakebin:$PATH" FM_FRAME="$W/frame.ansi" FM_ROOT_OVERRIDE="$W/home"
  FM_HOME="$W/home" FM_SEND_LOG="$W/send.log" FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.01
  FM_BACKEND_HERDR_SUBMIT_POLLS=1 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0)
echo "--- Herdr pane (plain view of the styled capture) ---"
sed 's/\x1b\[[0-9;]*m//g' "$W/frame.ansi"; echo
echo "--- shared composer verdict: fm_backend_composer_state herdr ---"
env "${ENV[@]}" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state herdr default:w1:p2; echo' _ "$ROOT"
echo "--- \$ fm-send.sh t1 'rebase onto main and rerun tests' ---"
env "${ENV[@]}" "$ROOT/bin/fm-send.sh" t1 "rebase onto main and rerun tests" 2>&1 | grep -v '^●'
echo "exit=${PIPESTATUS[0]}"
echo "--- keystrokes fm-send delivered to the pane ---"
if [ -s "$W/send.log" ]; then sed "s|$W/||g" "$W/send.log"; else echo "(none - doorbell skipped)"; fi
: > "$W/send.log"
echo "--- watcher re-ring: fm_task_inbox_ring herdr default:w1:p2 <001.msg> ---"
env "${ENV[@]}" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_ring herdr default:w1:p2 "$2"; echo "ring_rc=$? (0 rang, 1 skipped: pending text)"' \
  _ "$ROOT" "$W/home/state/t1.inbox/001.msg"
if [ -s "$W/send.log" ]; then sed "s|$W/||g" "$W/send.log"; else echo "(none - doorbell skipped)"; fi
echo "--- durable inbox ---"; (cd "$W/home/state" && ls t1.inbox)
rm -rf "$W"
