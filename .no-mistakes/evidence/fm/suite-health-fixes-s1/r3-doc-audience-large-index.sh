#!/usr/bin/env bash
# Live drive: bin/fm-doc-audience-check.sh against a copy of the repo whose git
# index holds 30000 extra tracked Markdown paths (git ls-files -z output well
# over Node's 1 MiB default spawnSync buffer). Expect the normal checker verdict
# (unclassified paths, exit 1), not "git ls-files failed: ... ENOBUFS".
set -u
ROOT=$1
F=$(mktemp -d /tmp/fm-doc-big.XXXXXX)
git -C "$ROOT" archive HEAD | tar -x -C "$F"
git -C "$F" init -q && git -C "$F" add -A >/dev/null
blob=$(git -C "$F" hash-object -w --stdin </dev/null)
pad=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for i in $(seq -w 1 30000); do printf '100644 %s\tdocs/bulk/%s-%s.md\n' "$blob" "$pad" "$i"; done | git -C "$F" update-index --add --index-info
echo "tracked entries: $(git -C "$F" ls-files | wc -l); ls-files -z output bytes matching the inventory patterns: $(git -C "$F" ls-files -z -- '*.md' '*.mdx' '*.rst' '*.txt' 'docs/examples/*' | wc -c)"
printf '\n$ bin/fm-doc-audience-check.sh --root <copy>\n'
out=$("$ROOT/bin/fm-doc-audience-check.sh" --root "$F" 2>&1); rc=$?
printf "%s\n" "$out" | cut -c1-260; echo "... (message is $(printf "%s" "$out" | wc -c) bytes; ENOBUFS mentioned: $(printf "%s" "$out" | grep -c ENOBUFS))"
echo "[exit $rc]"
rm -rf "$F"
