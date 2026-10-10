#!/usr/bin/env bash
# Live drive: fm-remote-entrypoint.sh installed on a remote-style PATH as a
# two-hop symlink chain, on a PATH with no node, realpath or python3. The
# entrypoint must follow the chain to its real bin/ to load fm-remote-job-lib.sh.
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-entry.XXXXXX)
NB="$T/sysbin"; mkdir -p "$NB"
for d in /run/current-system/sw/bin /etc/profiles/per-user/$USER/bin; do
  for t in "$d"/*; do b=$(basename "$t"); case "$b" in node|realpath|python3|python) continue;; esac; [ -e "$NB/$b" ] || ln -s "$t" "$NB/$b"; done
done
mkdir -p "$T/home/bin" "$T/home/opt"
ln -s "$ROOT/bin/fm-remote-entrypoint.sh" "$T/home/opt/link-hop"
ln -s ../opt/link-hop "$T/home/bin/fm-remote-entrypoint.sh"
call() { (cd "$T/home" && env -i HOME="$T/home" PATH="$NB:$T/home/bin" bash -c 'fm-remote-entrypoint.sh "$@"' _ "$@" </dev/null); echo "[exit $?]"; }
echo "install: \$HOME/bin/fm-remote-entrypoint.sh -> ../opt/link-hop -> <repo>/bin/fm-remote-entrypoint.sh (absolute)"
echo "PATH holds node: $(PATH=$NB command -v node || echo no); realpath: $(PATH=$NB command -v realpath || echo no); python3: $(PATH=$NB command -v python3 || echo no)"
echo; echo '$ fm-remote-entrypoint.sh 999 x y z'; call 999 x y z
echo; echo '$ fm-remote-entrypoint.sh 1 "!!!" y z'; call 1 '!!!' y z
echo; echo '$ fm-remote-entrypoint.sh 1 <b64 /nonexistent> <b64 home> <b64 argv>'
call 1 "$(printf /nonexistent | base64)" "$(printf '%s' "$T/home" | base64)" "$(printf 'fm-x.sh\0' | base64 -w0)"
echo; echo "== control: a plain copy in \$HOME/bin (no link to follow) cannot find its library"
rm "$T/home/bin/fm-remote-entrypoint.sh"; cp "$ROOT/bin/fm-remote-entrypoint.sh" "$T/home/bin/"
echo '$ fm-remote-entrypoint.sh 999 x y z'; call 999 x y z
echo; echo "== base commit's entrypoint through the same symlink chain on the same PATH"
rm "$T/home/bin/fm-remote-entrypoint.sh"; git -C "$ROOT" show 2812e3cb:bin/fm-remote-entrypoint.sh > "$T/home/opt/base-entry.sh"; chmod +x "$T/home/opt/base-entry.sh"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$T/home/opt/" 2>/dev/null; rm -f "$T/home/opt/fm-remote-job-lib.sh"
mkdir -p "$T/basecheckout/bin"; cp "$T/home/opt/base-entry.sh" "$T/basecheckout/bin/fm-remote-entrypoint.sh"; git -C "$ROOT" show 2812e3cb:bin/fm-remote-job-lib.sh > "$T/basecheckout/bin/fm-remote-job-lib.sh"
rm "$T/home/opt/link-hop"; ln -s "$T/basecheckout/bin/fm-remote-entrypoint.sh" "$T/home/opt/link-hop"; ln -s ../opt/link-hop "$T/home/bin/fm-remote-entrypoint.sh"
echo '$ fm-remote-entrypoint.sh 999 x y z   (base)'; call 999 x y z
rm -rf "$T"
