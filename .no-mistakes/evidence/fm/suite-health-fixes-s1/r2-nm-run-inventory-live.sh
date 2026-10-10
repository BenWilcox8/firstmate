#!/usr/bin/env bash
# Live drive: the kept python3 site in bin/fm-nm-run-lib.sh (sqlite run
# inventory) on a host with no python3. A truncated overview makes the library
# reach for the full inventory; the fallback line must name python3.
set -u
ROOT=$1
W=$(mktemp -d /tmp/fm-nm-inv.XXXXXX)
echo "python3 on PATH: $(command -v python3 || echo none)"
overview=$(printf 'count: 1 of 3 total\nruns[1]{id,branch,status,head,pr}:\n  01ABCDEF,fm/x,running,abcdef1234567,""\n')
echo "--- overview (truncated: 1 of 3 runs shown) ---"; printf '%s\n' "$overview"
echo; echo '$ fm_nm_select_run fm/x "$overview" <worktree>   (head commit)'
( . "$ROOT/bin/fm-nm-run-lib.sh"; fm_nm_select_run fm/x "$overview" "$W"; echo "[exit $?]" )
echo; echo '$ same call, base commit 2812e3cb library'
B=$(mktemp -d /tmp/fm-nm-base.XXXXXX); mkdir -p "$B/bin"
for f in $(git -C "$ROOT" ls-tree --name-only 2812e3cb bin/ | grep -E '\.sh$'); do git -C "$ROOT" show "2812e3cb:$f" > "$B/$f"; done
( . "$B/bin/fm-nm-run-lib.sh"; fm_nm_select_run fm/x "$overview" "$W"; echo "[exit $?]" )
echo; echo '$ complete overview (3 of 3) needs no python3 at all'
full=$(printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  01ABCDEF,fm/x,running,abcdef1234567,""\n')
( . "$ROOT/bin/fm-nm-run-lib.sh"; fm_nm_select_run fm/x "$full" "$W"; echo "[exit $?]" )
rm -rf "$W" "$B"
