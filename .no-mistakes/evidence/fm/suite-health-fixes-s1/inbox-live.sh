#!/usr/bin/env bash
# Live drive of bin/fm-inbox.sh in a throwaway FM_HOME on a host with no python3.
set -u
ROOT=$1
H=$(mktemp -d /tmp/fm-inbox-live.XXXXXX)
export FM_HOME=$H
mkdir -p "$H/state" "$H/data"
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
echo "python3 on PATH: $(command -v python3 || echo none)"
echo "node: $(node --version)"
echo "== note --json with non-ASCII, DEL and a quote"
run "$ROOT/bin/fm-inbox.sh" note --json --request-id req-1 -- "café ☕ 𝄞 tab	\"q\" del"$'\x7f'
echo "== replay of the same request id"
run "$ROOT/bin/fm-inbox.sh" note --json --request-id req-1 -- "café ☕ 𝄞 tab	\"q\" del"$'\x7f'
echo "== second note, human output"
run "$ROOT/bin/fm-inbox.sh" note -- "plain second note"
id1=$(ls "$H/state/inbox" | grep '\.note$' | sort | head -1); id1=${id1%.note}
echo "== reply --json to $id1"
run "$ROOT/bin/fm-inbox.sh" reply --json "$id1" "answer with ünïcode"
echo "== second reply refused"
run "$ROOT/bin/fm-inbox.sh" reply --json "$id1" "again"
echo "== drain --ack"
run "$ROOT/bin/fm-inbox.sh" drain --ack "$id1"
echo "== hand-made note whose name is not valid UTF-8, next to ok.note"
printf 'id=bad\nat=2026-10-09T00:00:00Z\nsource=text\n--\nbody of bad\n' > "$H/state/inbox/bad"$'\xff'".note"
printf 'id=ok\nat=2026-10-09T00:00:01Z\nsource=text\n--\nbody of ok\n' > "$H/state/inbox/ok.note"
echo "== receipts"
run "$ROOT/bin/fm-inbox.sh" receipts
echo "== receipts piped to jq (valid JSON, pending ids)"
"$ROOT/bin/fm-inbox.sh" receipts | jq -c '{pending: [.pending[].id], handled: [.handled[] | {id, acknowledged, announced, reply: (.reply.body // null)}], reply_cursor, omitted}'
echo "== receipts --after a cursor"
cur=$("$ROOT/bin/fm-inbox.sh" receipts | jq -r .reply_cursor)
run "$ROOT/bin/fm-inbox.sh" receipts --after "$cur"
echo "== ready with no lock"
run "$ROOT/bin/fm-inbox.sh" ready
echo "== ready with a corrupt 25-digit pid in state/.lock"
printf '9999999999999999999999999\n' > "$H/state/.lock"
run "$ROOT/bin/fm-inbox.sh" ready
rm -f "$H/state/.lock"
echo "== status (human, unchanged)"
run "$ROOT/bin/fm-inbox.sh" status
rm -rf "$H"
