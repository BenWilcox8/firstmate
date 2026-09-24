#!/usr/bin/env bash
# Ad hoc adversarial lab for worker restore (not committed). Run with ROOT=<worktree>.
set -euo pipefail
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/fm-local-herdr-fixture.sh"
trap 'printf "not ok - lab line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
fm_local_lab_start reboot-adv
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
export FM_BACKEND_HERDR_AXI_BIN=agent-axi
export CLAUDE_CONFIG_DIR="$FM_LOCAL_LAB_ROOT/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR"
L=$FM_LOCAL_LAB_ROOT
LAUNCHES="$L/launches"; : > "$LAUNCHES"
mkdir -p "$L/agent"; cp "$(command -v bash)" "$L/agent/claude"
cat > "$L/tools/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --help|--version) echo 'Claude lifecycle stand-in'; exit 0 ;; esac
printf '%s\n' "\$PWD" >> '$LAUNCHES'
exec '$L/agent/claude' -c 'while IFS= read -r line; do case "\$line" in /exit|/quit) exit 0;; esac; done'
SH
chmod +x "$L/tools/claude"
printf '#!%s\nexec env PATH=%s:"$PATH" %s --noprofile --norc -i\n' "$(command -v bash)" "$L/tools" "$(command -v bash)" > "$L/lab-shell"
chmod +x "$L/lab-shell"
export FM_BACKEND_HERDR_AXI_LAUNCH="$L/lab-shell"
project="$L/project"; mkdir -p "$project"; git -C "$project" init -q
printf 'base\n' > "$project/base.txt"; git -C "$project" add base.txt
git -C "$project" -c user.name=T -c user.email=t@e.invalid commit -qm base
container_raw=$(fm_backend_herdr_container_ensure "$project"); container=${container_raw%%$'\t'*}; workspace=${container#*:}
launches_in() { grep -cFx "$1" "$LAUNCHES" || true; }
wait_alive() { local d=$((SECONDS+120)) s=0; while [ "$SECONDS" -lt "$d" ]; do if [ "$(fm_backend_agent_state herdr "$1")" = alive ]; then s=$((s+1)); [ "$s" -lt 3 ] || return 0; else s=0; fi; sleep 0.2; done; echo "not ok - $1 never alive" >&2; return 1; }
worker() {
  local id=$1 wt=$2 ids tab pane
  [ -d "$wt" ] || git -C "$project" worktree add --quiet -b "fm/$id" "$wt"
  ids=$(fm_backend_herdr_create_task "$container" "fm-$id" "$wt" ''); read -r tab pane <<< "$ids"
  mkdir -p "$FM_HOME/data/$id"
  printf "# Task\n## Captain's intent\nKeep working.\n\n## Firstmate spec\nKeep working.\n" > "$FM_HOME/data/$id/brief.md"
  cat > "$FM_HOME/state/$id.meta" <<META
window=$HERDR_SESSION:$pane
endpoint_task_id=$id
worktree=$wt
project=$project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$L/tasktmp-$id
backend=herdr
spawn_gen=s$3.1.1
herdr_session=$HERDR_SESSION
herdr_workspace_id=$workspace
herdr_tab_id=$tab
herdr_pane_id=$pane
META
  sleep 1
  fm_backend_herdr_send_text_line "$HERDR_SESSION:$pane" claude
  wait_alive "$HERDR_SESSION:$pane"
  echo "worker $id pane=$pane"
}
worker w1 "$L/wt-w1" 1790000001
worker held "$L/wt-held" 1790000002
worker donelate "$L/wt-donelate" 1790000003
worker w2 "$L/wt-w2" 1790000004
worker parkres "$L/wt-parkres" 1790000005
printf 'working: building\n' > "$FM_HOME/state/w1.status"
printf 'working: step two\n' > "$FM_HOME/state/w2.status"
printf 'needs-decision [key=gate]: hold or ship?\ncaptain-held [key=gate]: captain says hold\n' > "$FM_HOME/state/held.status"
printf 'needs-decision [key=q]: A or B?\ndone: PR https://example.invalid/pull/9 green\n' > "$FM_HOME/state/donelate.status"
sid=0b5e4a1c-2d3f-4a5b-8c7d-9e0f1a2b3c4d
mkdir -p "$CLAUDE_CONFIG_DIR/projects/lab"
printf '{"sessionId":"%s"}\n' "$sid" > "$CLAUDE_CONFIG_DIR/projects/lab/$sid.jsonl"
printf 'parked=2026-09-24T01:00:00Z\nparked_reason=captain call\nnative_session=%s\nnative_session_harness=claude\nnative_session_file=%s\n' "$sid" "$CLAUDE_CONFIG_DIR/projects/lab/$sid.jsonl" >> "$FM_HOME/state/parkres.meta"
record() { printf '%s\n' "$1" > "$L/boot_id"; FM_RESTART_BOOT_ID_FILE="$L/boot_id" FM_RESTART_USER_MANAGER_ID=um-1 FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=120 "$ROOT/bin/fm-local-restart-recovery.sh" record; }
record boot-1 > "$L/r1.out"
echo "--- restart: stop and provision lab session"
PATH=$FM_LOCAL_LAB_REAL_PATH "$FM_LOCAL_LAB_HELPER" stop "$FM_LOCAL_LAB_SESSION" >/dev/null
PATH=$FM_LOCAL_LAB_REAL_PATH "$FM_LOCAL_LAB_HELPER" provision "$FM_LOCAL_LAB_SESSION" >/dev/null
container_raw=$(fm_backend_herdr_container_ensure "$project"); container=${container_raw%%$'\t'*}
# Filler panes: unrelated live agents in another dir, to take low pane ids that a stale worker record may still name.
mkdir -p "$L/other"
recorded=$(for id in w1 held donelate w2 parkres; do fm_meta_get "$FM_HOME/state/$id.meta" herdr_pane_id; done)
for n in 1 2 3 4 5 6; do
  ids=$(fm_backend_herdr_create_task "$container" "filler-$n" "$L/other" ''); read -r tab pane <<< "$ids"
  sleep 1; fm_backend_herdr_send_text_line "$HERDR_SESSION:$pane" claude; wait_alive "$HERDR_SESSION:$pane"
  echo "filler-$n pane=$pane (recorded worker ids: $(echo $recorded))"
done
# Another task takes the parked worker's worktree.
worker taker "$L/wt-parkres" 1790000900
echo "--- classify after restart (read-only)"
"$ROOT/bin/fm-local-worker-restore.sh" classify
echo "--- resume the parked worker whose worktree was taken"
before=$(launches_in "$L/wt-parkres")
if FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=30 "$ROOT/bin/fm-control.sh" parkres resume --over-limit > "$L/resume.out" 2>&1; then echo "not ok - resume into reused worktree succeeded"; cat "$L/resume.out"; exit 1; fi
cat "$L/resume.out"
grep -F worktree-lease "$L/resume.out" >/dev/null
[ "$(launches_in "$L/wt-parkres")" -eq "$before" ]
grep -q '^parked=' "$FM_HOME/state/parkres.meta"
echo "ok - resume into a reused worktree refused, no launch, still parked"
echo "--- record boot-2 (session start after restart)"
b1=$(launches_in "$L/wt-w1"); b2=$(launches_in "$L/wt-w2")
record boot-2 | tee "$L/r2.out"
d=$((SECONDS+300)); until grep -q 'check: worker restore' "$FM_HOME/state/.wake-queue" 2>/dev/null; do [ "$SECONDS" -lt "$d" ] || { echo 'not ok - no summary'; exit 1; }; sleep 1; done
echo "--- summary wake"
grep 'check: worker restore' "$FM_HOME/state/.wake-queue" | cut -f5-
for id in held donelate; do [ "$(launches_in "$L/wt-$id")" -eq 1 ] || { echo "not ok - $id relaunched"; exit 1; }; done
[ "$(launches_in "$L/wt-w1")" -eq $((b1+1)) ] && [ "$(launches_in "$L/wt-w2")" -eq $((b2+1)) ]
for id in w1 w2; do t=$(fm_meta_get "$FM_HOME/state/$id.meta" window); wait_alive "$t"; echo "$id now at $t cwd=$(fm_backend_current_path herdr "$t")"; [ "$(fm_backend_current_path herdr "$t")" = "$L/wt-$id" ]; done
echo "--- classify after restore"
"$ROOT/bin/fm-local-worker-restore.sh" classify
echo "--- ledger"; cat "$FM_HOME/state/.worker-restore.log"
echo "ok - both working workers restored in own worktrees; captain-held and done-after-decision stayed down"
