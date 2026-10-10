#!/usr/bin/env bash
# Adversarial live drive: fm-inbox.sh machine-readable subcommands on a PATH with
# no node. Expect a clear error naming node, exit 1, and nothing written.
set -u
ROOT=$1
H=$(mktemp -d /tmp/fm-inbox-nonode.XXXXXX)
NB=$(mktemp -d /tmp/fm-inbox-nonode-bin.XXXXXX)
for d in /run/current-system/sw/bin /etc/profiles/per-user/$USER/bin; do
  for t in "$d"/*; do
    b=$(basename "$t"); [ "$b" = node ] && continue; [ -e "$NB/$b" ] || ln -s "$t" "$NB/$b"
  done
done
export FM_HOME=$H HOME=$H PATH=$NB
mkdir -p "$H/state" "$H/data"
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
echo "node on PATH: $(command -v node || echo none)"
run "$ROOT/bin/fm-inbox.sh" note --json -- "should not be saved"
run "$ROOT/bin/fm-inbox.sh" note --json --request-id r9 -- "should not be saved either"
run "$ROOT/bin/fm-inbox.sh" receipts
run "$ROOT/bin/fm-inbox.sh" ready
echo "== files under the home after the refused calls:"
find "$H" -mindepth 1 | sed "s|$H|<home>|" | sort
echo "== the human note path still works without node:"
run "$ROOT/bin/fm-inbox.sh" note -- "human note without node"
id=$(ls "$H/state/inbox" | grep '\.note$' | head -1); id=${id%.note}
run "$ROOT/bin/fm-inbox.sh" reply --json "$id" "json reply without node"
echo "== replies dir after refused reply --json:"
ls -A "$H/state/inbox/.replies" 2>&1 || true
rm -rf "$H" "$NB"
