#!/usr/bin/env bash
# Drives fm-spawn.sh (from PRODUCT_ROOT) against real Herdr + real agent-axi in a
# named fm-lab-* session provisioned through the target worktree's lab helper.
# Usage: lab-scenarios.sh <product-root> <helper-root> <tag>
set -u
PRODUCT_ROOT=$1 HELPER_ROOT=$2 TAG=$3
HELPER="$HELPER_ROOT/bin/fm-herdr-lab.sh"
export FM_GATE_REFUSE_BYPASS=1  # same test-harness escape hatch tests/herdr-test-safety.sh exports
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION FM_HOME
REAL_AXI=$(command -v agent-axi)
T=$(mktemp -d "/tmp/fm-lab-scn-$TAG.XXXXXX")
SES=$("$HELPER" name "scn-$TAG") || { echo "cannot name lab"; exit 1; }
WTS=()
cleanup() {
  local wt
  for wt in ${WTS[@]+"${WTS[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  echo "--- teardown of $SES"; "$HELPER" teardown "$SES"; echo "teardown rc=$?"
  rm -rf "$T"
}
trap cleanup EXIT
"$HELPER" provision "$SES" || { echo "provision failed"; exit 1; }
echo "lab session: $SES   product root: $PRODUCT_ROOT"
lab() { "$HELPER" run "$SES" "$@"; }
SOCK=$(lab session list --json 2>/dev/null | jq -r --arg s "$SES" '.sessions[]|select(.name==$s)|.socket_path')

# agent fixture (same shape as the repo e2e)
cp "$(command -v node)" "$T/cursor-agent"
cat > "$T/agent.js" <<'JS'
setTimeout(() => process.exit(0), Number(process.argv[2]) * 1000)
require('readline').createInterface({ input: process.stdin }).on('line', (l) => { if (l.trim() === '/exit') process.exit(0) })
JS
AGENT="$T/cursor-agent $T/agent.js 300"

# argv-logging pass-through wrapper around the REAL agent-axi
ARGV_LOG="$T/axi-argv.log"; : > "$ARGV_LOG"
cat > "$T/axi-log" <<EOF
#!/usr/bin/env bash
{ printf 'FM_HOME=%s |' "\${FM_HOME:-}"; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
exec "$REAL_AXI" "\$@"
EOF
chmod +x "$T/axi-log"

# fault-injection wrapper: on spawn, move the home's label off the verified
# container onto a fresh workspace, then run the REAL agent-axi.
cat > "$T/axi-race" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = spawn ]; then
  label="2ndmate-\$(cat "\$FM_HOME/.fm-secondmate-home")"
  old=\$("$HELPER" run "$SES" workspace list | jq -r --arg l "\$label" '[.result.workspaces[]|select(.label==\$l)|.workspace_id][0]')
  "$HELPER" run "$SES" workspace rename "\$old" "\$label-moved" >/dev/null
  new=\$("$HELPER" run "$SES" workspace create --cwd /tmp --label "\$label" --no-focus | jq -r '.result.workspace.workspace_id')
  echo "RACE: moved label \$label from \$old to new workspace \$new" >> "$T/race.log"
fi
exec "$REAL_AXI" "\$@"
EOF
chmod +x "$T/axi-race"

proj="$T/proj"; mkdir -p "$proj"; git -C "$proj" init -q; echo x > "$proj/README.md"
git -C "$proj" add README.md; git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$proj" "$proj.origin.git"; git -C "$proj" remote add origin "file://$proj.origin.git"

brief() { mkdir -p "$(dirname "$1")"; printf '# Task\n## Captain'"'"'s intent\nlab %s\n\n## Firstmate spec\nnothing.\n' "$2" > "$1"; }
mk_primary() { mkdir -p "$1/state" "$1/config" "$1/data"; printf 'off\n' > "$1/config/herdr-presentation-spaces"; }
mk_sm() {  # <home> <id>
  mkdir -p "$1/state" "$1/config" "$1/projects" "$1/bin" "$1/data"
  printf 'off\n' > "$1/config/herdr-presentation-spaces"
  printf '# placeholder\n' > "$1/AGENTS.md"; printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf 'charter: nothing.\n' > "$1/data/charter.md"
}
P="$T/primary"; mk_primary "$P"
P2="$T/primary2"; mk_primary "$P2"
for s in smA smB smC; do mk_sm "$T/$s-home" "$s"; brief "$P/data/$s/brief.md" "$s"; done
brief "$T/smA-home/data/wA/brief.md" wA
for w in u1 u2; do brief "$P2/data/$w/brief.md" "$w"; done

# spawn <launcher-pane> <axi-bin> <home> <id> <project> [args...]
spawn() {
  local pane=$1 axi=$2 home=$3 id=$4 pr=$5; shift 5
  env HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_SESSION="$SES" HERDR_SOCKET_PATH="$SOCK" \
    FM_BACKEND_HERDR_AXI_BIN="$axi" FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$PRODUCT_ROOT" \
    "$PRODUCT_ROOT/bin/fm-spawn.sh" "$id" "$pr" "$AGENT" --backend herdr "$@" >"$T/$id.out" 2>"$T/$id.err"
  RC=$?
  echo "\$ fm-spawn.sh $id <project> <agent> --backend herdr $* (FM_HOME=$(basename "$home"), launcher pane $pane)  -> rc=$RC"
  grep -E '^(error|warning):' "$T/$id.err" | sed 's/^/    stderr: /'
}
ws_of_pane() { lab pane get "$1" 2>/dev/null | jq -r '.result.pane.workspace_id // empty'; }
ws_list() { lab workspace list | jq -c '[.result.workspaces[] | {id: .workspace_id, label}]'; }
meta() { grep "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }
ledger_ws() { jq -c '[paths(scalars) as $p | select(($p|last|tostring)|test("[Ww]orkspace")) | {($p|map(tostring)|join(".")): getpath($p)}] | add' "$1/state/.agent-axi-slots.json" 2>/dev/null || echo '(no ledger)'; }

out=$(lab workspace create --cwd "$T" --label firstmate --no-focus)
W_FM=$(echo "$out" | jq -r .result.workspace.workspace_id); L_FM=$(echo "$out" | jq -r .result.root_pane.pane_id)
echo "primary launcher workspace firstmate=$W_FM launcher pane=$L_FM"

echo; echo "=== S-A/S-B: --secondmate launch, workspace re-created, relaunch, then the second mate spawns its own worker"
spawn "$L_FM" "$T/axi-log" "$P" smA "$T/smA-home" --secondmate
SMA_WS1=$(meta "$P/state/smA.meta" herdr_workspace_id); SMA_PANE1=$(meta "$P/state/smA.meta" herdr_pane_id)
echo "  first launch: pane=$SMA_PANE1 workspace=$SMA_WS1; workspaces: $(ws_list)"
echo "  smA ledger workspace binding after first launch: $(ledger_ws "$T/smA-home")"
lab workspace close "$SMA_WS1" >/dev/null 2>&1; echo "  closed workspace $SMA_WS1 (simulated reboot); workspaces: $(ws_list)"
spawn "$L_FM" "$T/axi-log" "$P" smA "$T/smA-home" --secondmate
SMA_WS2=$(meta "$P/state/smA.meta" herdr_workspace_id); SMA_PANE2=$(meta "$P/state/smA.meta" herdr_pane_id)
echo "  relaunch record: pane=$SMA_PANE2 workspace=$SMA_WS2 (live pane workspace: $(ws_of_pane "$SMA_PANE2")); workspaces: $(ws_list)"
echo "  smA ledger workspace binding after relaunch: $(ledger_ws "$T/smA-home")"
if [ "$RC" = 0 ]; then
  spawn "$SMA_PANE2" "$T/axi-log" "$T/smA-home" wA "$proj" --mode no-mistakes --yolo off
  WTS+=("$(meta "$T/smA-home/state/wA.meta" worktree)")
  echo "  smA's worker wA lands in workspace $(ws_of_pane "$(meta "$T/smA-home/state/wA.meta" herdr_pane_id)") (expected $SMA_WS2)"
fi
echo "  agent-axi spawn argv as received (FM_HOME | argv):"
grep -F '| spawn' "$ARGV_LOG" | sed "s#$T#<lab>#g; s/^/    /"

echo; echo "=== S-C: real agent-axi refusal is surfaced (primary home re-created; launcher-home pins --workspace-id)"
spawn "$L_FM" "$REAL_AXI" "$P2" u1 "$proj" --mode no-mistakes --yolo off
WTS+=("$(meta "$P2/state/u1.meta" worktree)")
echo "  u1 in workspace $(ws_of_pane "$(meta "$P2/state/u1.meta" herdr_pane_id)"); primary2 ledger binding: $(ledger_ws "$P2")"
lab workspace close "$W_FM" >/dev/null 2>&1
out=$(lab workspace create --cwd "$T" --label firstmate --no-focus)
W_FM2=$(echo "$out" | jq -r .result.workspace.workspace_id); L_FM2=$(echo "$out" | jq -r .result.root_pane.pane_id)
echo "  closed $W_FM, re-created firstmate=$W_FM2 with launcher pane $L_FM2"
spawn "$L_FM2" "$REAL_AXI" "$P2" u2 "$proj" --mode no-mistakes --yolo off
WTS+=("$(grep -o '/[^ ]*treehouse[^ ]*' "$T/u2.err" | head -1)")
echo "  u2 meta published: $([ -e "$P2/state/u2.meta" ] && echo yes || echo no); fm-u2 panes in session: $(lab pane list 2>/dev/null | jq '[.result.panes[]? | select((.label // "") == "fm-u2")] | length')"

echo; echo "=== S-D (adversarial): two workspaces carry the second mate's label"
: > "$ARGV_LOG"
lab workspace create --cwd "$T" --label 2ndmate-smB --no-focus >/dev/null
lab workspace create --cwd "$T" --label 2ndmate-smB --no-focus >/dev/null
L_FM3=$(lab workspace create --cwd "$T" --label firstmate-launch3 --no-focus | jq -r .result.root_pane.pane_id)
spawn "$L_FM3" "$T/axi-log" "$P" smB "$T/smB-home" --secondmate
echo "  smB meta published: $([ -e "$P/state/smB.meta" ] && echo yes || echo no); agent-axi spawn calls: $(grep -cF '| spawn' "$ARGV_LOG")"
echo "  workspaces: $(ws_list)"

echo; echo "=== S-E (adversarial): agent-axi result lands outside the verified workspace (label moved mid-spawn)"
spawn "$L_FM3" "$T/axi-race" "$P" smC "$T/smC-home" --secondmate
cat "$T/race.log" 2>/dev/null | sed 's/^/  /'
echo "  smC meta published: $([ -e "$P/state/smC.meta" ] && echo yes || echo no)"
echo "  workspaces: $(ws_list)"
echo "  panes labeled fm-smC: $(lab pane list 2>/dev/null | jq -c '[.result.panes[]? | select((.label // "") == "fm-smC") | {pane_id, workspace_id}]')"
