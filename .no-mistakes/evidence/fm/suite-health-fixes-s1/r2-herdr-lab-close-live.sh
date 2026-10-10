#!/usr/bin/env bash
# Live drive in a throwaway Herdr lab session (bin/fm-herdr-lab.sh only): the
# focus-preserving pane close reaches the workspace.move capability check,
# which keeps python3 (herdr-workspace-move.py). With no python3 the warning
# must name python3, and the close must still succeed by the plain path.
set -u
ROOT=$1
LAB="$ROOT/bin/fm-herdr-lab.sh"
S=$("$LAB" name pyclose-r2) || exit 1
echo "Herdr $(herdr --version), lab session $S (throwaway, provisioned by bin/fm-herdr-lab.sh)"
echo "python3 on PATH: $(command -v python3 || echo none)"
cleanup() { echo; "$LAB" teardown "$S" >/dev/null 2>&1; echo "teardown of $S exit=$?"; herdr session list --json 2>/dev/null | jq -c --arg s "$S" '[.sessions[] | select(.name == $s)] | "lab sessions left with this name: \(length)"'; }
trap cleanup EXIT
"$LAB" provision "$S" >/dev/null || { echo "provision failed"; exit 1; }
mk() { "$LAB" run "$S" workspace create --label "$1" --no-focus | jq -r ".result.workspace.workspace_id"; }
ws() { "$LAB" run "$S" workspace list | jq -c '.result.workspaces[] | {workspace_id, label, focused, active_tab_id}'; }
# The lab starts empty: create doomed, then focused, then tail.
first=$(mk doomed)
w2=$(mk focused); w3=$(mk tail)
"$LAB" run "$S" workspace focus "$w2" >/dev/null
pane=$("$LAB" run "$S" pane list --workspace "$first" | jq -r '.result.panes[0].pane_id')
echo "--- layout before: '$first' doomed (one tab, one pane $pane) sits before the focused $w2, which is not last ---"
ws
echo
echo "\$ . bin/backends/herdr.sh; fm_backend_herdr_projection_close_pane_focus_preserving <lab> $pane"
( . "$ROOT/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving "$S" "$pane"; echo "[exit $?]" ) 2>&1
echo "--- layout after ---"
ws
echo
echo "=== base commit 2812e3cb bin/backends/herdr.sh, same lab, same shape ==="
B=$(mktemp -d /tmp/fm-herdr-base.XXXXXX); git -C "$ROOT" archive 2812e3cb bin | tar -x -C "$B"
d2=$(mk doomed2); "$LAB" run "$S" workspace focus "$w2" >/dev/null
# Put doomed2 before the focused workspace: it is created last, so use a fresh
# tail after it and move focus to the workspace in the middle.
w4=$(mk tail2); "$LAB" run "$S" workspace focus "$d2" >/dev/null; "$LAB" run "$S" workspace focus "$w4" >/dev/null
"$LAB" run "$S" workspace focus "$w2" >/dev/null
pane2=$("$LAB" run "$S" pane list --workspace "$w2" | jq -r '.result.panes[0].pane_id')
"$LAB" run "$S" workspace focus "$d2" >/dev/null
echo "--- layout before: $w2 (one pane $pane2) sits before the focused $d2, which is not last ---"
ws
echo "\$ . <base>/bin/backends/herdr.sh; fm_backend_herdr_projection_close_pane_focus_preserving <lab> $pane2"
( . "$B/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving "$S" "$pane2"; echo "[exit $?]" ) 2>&1
echo "--- layout after ---"
ws
rm -rf "$B"
