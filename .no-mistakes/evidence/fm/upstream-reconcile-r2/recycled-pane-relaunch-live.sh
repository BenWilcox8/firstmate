#!/usr/bin/env bash
# Live drive: in an isolated Herdr lab session, a task whose home workspace
# ("firstmate") is absent records a pane id that now names other work (a
# bare shell labeled fm-other, then an unlabeled shell whose cwd is outside the
# worktree). `fm-spawn.sh <id> --relaunch` must refuse and must type nothing
# into that pane, leave it open, and leave the task record unchanged.
set -u
ROOT=${1:?repo root}
LAB="$ROOT/bin/fm-herdr-lab.sh"
TMP=$(mktemp -d /tmp/fm-recycled-live.XXXXXX)
SESSION=$("$LAB" name recycled) || exit 1
ORIG_PATH=$PATH
status=0
cleanup() { "$LAB" teardown "$SESSION" >/dev/null 2>&1 || echo "teardown failed"; rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/home/state" "$TMP/worktree" "$TMP/project"
cat > "$TMP/bin/herdr" <<SH
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = '$SESSION' ]; then
  unset "args[\$((n-1))]" "args[\$((n-2))]"
fi
set -- "\${args[@]}"
for a in "\$@"; do case "\$a" in --session|--session=*) echo "shim: foreign session flag" >&2; exit 9 ;; esac; done
exec env PATH='$ORIG_PATH' '$LAB' run '$SESSION' "\$@"
SH
cat > "$TMP/shell" <<SH
#!/usr/bin/env bash
cd /
exec bash --noprofile --norc -i
SH
chmod +x "$TMP/bin/herdr" "$TMP/shell"

env -u FM_HOME -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV \
  SHELL="$TMP/shell" "$LAB" provision "$SESSION" >/dev/null || { echo "provision failed"; exit 1; }
lab() { "$LAB" run "$SESSION" "$@"; }
echo "== lab session: $SESSION"
echo "== workspaces (no workspace carries the home label 'firstmate'):"
lab workspace list | jq -c '[.result.workspaces[] | {workspace_id,label}]'
read -r WS TAB PANE < <(lab workspace create --cwd / --label other-work --no-focus | jq -er ".result.root_pane | [.workspace_id, .tab_id, .pane_id] | @tsv")
echo "== foreign work: workspace $WS (label other-work), pane $PANE"
lab workspace list | jq -c "[.result.workspaces[] | {workspace_id,label}]"

write_meta() {
  cat > "$TMP/home/state/ended.meta" <<META
window=$SESSION:$PANE
endpoint_task_id=ended
kind=ship
worktree=$TMP/worktree
project=$TMP/project
backend=herdr
spawn_gen=old
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
META
  cp "$TMP/home/state/ended.meta" "$TMP/before.meta"
}

drive() { # <case-name>
  local name=$1 out rc
  write_meta
  lab pane send-text "$PANE" 'clear' >/dev/null; lab pane send-keys "$PANE" Enter >/dev/null; sleep 1
  local before_screen; before_screen=$(lab pane read "$PANE" --source visible --lines 20 --format text 2>/dev/null)
  echo "== case: $name"
  echo "-- recorded pane as Herdr reports it:"
  lab pane get "$PANE" | jq -c '.result.pane | {pane_id,workspace_id,tab_id,label,foreground_cwd}'
  out=$(env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV -u FM_TASK_ID \
    PATH="$TMP/bin:$ORIG_PATH" FM_HOME="$TMP/home" FM_BACKEND_HERDR_AXI_BIN='' FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-spawn.sh" ended --relaunch 2>&1); rc=$?
  echo "-- \$ fm-spawn.sh ended --relaunch  (exit $rc)"
  printf '%s\n' "$out" | sed 's/^/   /'
  sleep 2
  local after_screen; after_screen=$(lab pane read "$PANE" --source visible --lines 20 --format text 2>/dev/null)
  local verdict=pass
  [ "$rc" -ne 0 ] || verdict=fail
  printf '%s' "$out" | grep -Fq "ended has no home workspace and its recorded pane $SESSION:$PANE now belongs to other work; relaunch refused" || verdict=fail
  lab pane get "$PANE" >/dev/null 2>&1 || { echo "-- recorded pane was closed"; verdict=fail; }
  cmp -s "$TMP/before.meta" "$TMP/home/state/ended.meta" || { echo "-- task record changed"; verdict=fail; }
  [ "$before_screen" = "$after_screen" ] || { echo "-- foreign pane screen changed:"; printf '%s\n' "$after_screen" | tail -5; verdict=fail; }
  lab workspace list | jq -e '[.result.workspaces[] | select(.label == "firstmate")] | length == 0' >/dev/null \
    || { echo "-- a home workspace was created"; verdict=fail; }
  echo "-- result: $verdict (refused, pane still open, screen untouched, record unchanged, no workspace created)"
  [ "$verdict" = pass ] || status=1
}

lab pane rename "$PANE" fm-other >/dev/null
drive "recycled pane labeled fm-other (bare shell)"
lab pane rename "$PANE" "" >/dev/null 2>&1 || lab pane rename "$PANE" --clear >/dev/null 2>&1 || true
drive "recycled unlabeled pane with foreground cwd / (outside the worktree)"
exit $status
