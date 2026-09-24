#!/usr/bin/env bash
# Add ownership and real process evidence to legacy Herdr teardown fixtures.
# The original fixture still owns presence failures, close outcomes, and focus.
set -u
base=$1 meta=$2
shift 2
value() { sed -n "s/^$1=//p" "$meta" | head -1; }
pane=$(value herdr_pane_id)
workspace=$(value herdr_workspace_id)
tab=$(value herdr_tab_id)
task=$(value endpoint_task_id)
label=firstmate
if [ -f "${FM_HOME:-}/.fm-secondmate-home" ]; then
  label="2ndmate-$(cat "$FM_HOME/.fm-secondmate-home")"
fi
if [ "${1:-} ${2:-}" = 'pane process-info' ]; then
  exec "$FM_LOCAL_TEST_PROCESS_HELPER" "$@"
fi
rc=0
out=$("$base" "$@") || rc=$?
case "${1:-} ${2:-}" in
  'workspace list')
    if [ -z "$out" ] && [ "$rc" = 0 ]; then
      out=$(jq -n --arg ws "$workspace" '{result:{workspaces:[{workspace_id:$ws}]}}')
    fi
    printf '%s' "$out" | jq --arg ws "$workspace" --arg label "$label" \
      'if (.result.workspaces | type) == "array" then
         .result.workspaces |= map(if .workspace_id == $ws and .label == null then .label=$label else . end)
       else . end' || exit 1
    ;;
  'tab list')
    if [ -z "$out" ] && [ "$rc" = 0 ]; then
      out=$(jq -n --arg tab "$tab" '{result:{tabs:[{tab_id:$tab}]}}')
    fi
    printf '%s' "$out" | jq --arg tab "$tab" --arg task "fm-$task" \
      'if (.result.tabs | type) == "array" then
         .result.tabs |= map(if .tab_id == $tab and .label == null then .label=$task else . end)
       else . end' || exit 1
    ;;
  'pane list')
    presence=$("$base" pane get "$pane" 2>&1) || true
    if printf '%s' "$presence" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1; then
      out='{"result":{"panes":[]}}'
    elif [ -z "$out" ] && [ "$rc" = 0 ]; then
      out=$(printf '%s' "$presence" | jq '{result:{panes:[.result.pane]}}') || exit 1
    fi
    printf '%s' "$out" | jq --arg pane "$pane" --arg task "fm-$task" \
      'if (.result.panes | type) == "array" then
         .result.panes |= map(if .pane_id == $pane and .label == null then .label=$task else . end)
       else . end' || exit 1
    ;;
  'pane get')
    if [ -n "$out" ]; then
      printf '%s' "$out" | jq --arg pane "$pane" --arg task "fm-$task" \
        'if .result.pane.pane_id == $pane then .result.pane += {label:$task,terminal_id:("test-"+$pane)} else . end' || exit 1
    fi
    ;;
  *) printf '%s\n' "$out" ;;
esac
exit "$rc"
