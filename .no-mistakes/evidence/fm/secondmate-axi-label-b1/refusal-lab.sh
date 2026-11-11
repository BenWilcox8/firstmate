#!/usr/bin/env bash
# Live check: a launcher-home worker spawn into a re-created "firstmate"
# workspace still pins --workspace-id, real agent-axi refuses on its stale
# ledger binding, and fm-spawn now prints agent-axi's own message.
set -u
ROOT=$1
H="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
T=$(mktemp -d /tmp/fm-refusal-lab.XXXXXX)
SES=$("$H" name fm-refusal) || exit 1
export HERDR_SESSION="$SES"
WTS=()
cleanup() { for w in ${WTS[@]+"${WTS[@]}"}; do treehouse return --force "$w" >/dev/null 2>&1; done; "$H" teardown "$SES"; echo "teardown exit=$?"; rm -rf "$T"; }
trap cleanup EXIT
"$H" provision "$SES" || exit 1
lab() { "$H" run "$SES" "$@"; }
SOCK=$(lab session list --json | jq -r --arg s "$SES" '.sessions[]|select(.name==$s)|.socket_path')
cp "$(command -v node)" "$T/cursor-agent"
echo 'setTimeout(()=>process.exit(0),300000)' > "$T/a.js"
HOME_P="$T/primary"; mkdir -p "$HOME_P/state" "$HOME_P/config"; echo off > "$HOME_P/config/herdr-presentation-spaces"
for id in wa wb; do mkdir -p "$HOME_P/data/$id"; printf '# Task\n## Captain'"'"'s intent\nx\n\n## Firstmate spec\ny\n' > "$HOME_P/data/$id/brief.md"; done
P="$T/proj"; mkdir -p "$P"; git -C "$P" init -q; echo x > "$P/R"; git -C "$P" add R; git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm i
git clone -q --bare "$P" "$P.git"; git -C "$P" remote add origin "file://$P.git"
mkws() { lab workspace create --cwd "$T" --label firstmate --no-focus | jq -r '[.result.workspace.workspace_id,.result.root_pane.pane_id]|@tsv'; }
spawn() { env HERDR_ENV=1 HERDR_PANE_ID="$1" HERDR_SESSION="$SES" HERDR_SOCKET_PATH="$SOCK" FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_P" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$2" "$P" "$T/cursor-agent $T/a.js" --backend herdr --mode no-mistakes --yolo off >"$T/$2.out" 2>"$T/$2.err"; echo $?; }
read -r W1 P1 < <(mkws); echo "workspace W1=$W1 launcher pane=$P1"
rc=$(spawn "$P1" wa); echo "== worker wa from W1: rc=$rc"; cat "$T/wa.err"
wt=$(grep '^worktree=' "$HOME_P/state/wa.meta" 2>/dev/null | cut -d= -f2-); [ -n "$wt" ] && WTS+=("$wt")
echo "wa recorded workspace: $(grep '^herdr_workspace_id=' "$HOME_P/state/wa.meta" | cut -d= -f2-)"
echo "== close W1 (simulated reboot of the home workspace)"; lab workspace close "$W1" >/dev/null
read -r W2 P2 < <(mkws); echo "re-created workspace W2=$W2 launcher pane=$P2"
rc=$(spawn "$P2" wb); echo "== worker wb from W2 (launcher-home, pins --workspace-id): rc=$rc"
echo "--- fm-spawn stderr ---"; cat "$T/wb.err"
wt=$(grep '^worktree=' "$HOME_P/state/wb.meta" 2>/dev/null | cut -d= -f2-); [ -n "$wt" ] && WTS+=("$wt")
