#!/usr/bin/env bash
# Path-level parity check: run the realpath function from the target
# bin/fm-ensure-agents-md.sh heredoc on each probe and compare its resolved
# CLAUDE.md path with GNU `realpath -m` and with the result of Python 3.13
# non-strict os.path.realpath, derived by hand from the CPython algorithm
# (this host has no python3).
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-parity-r4.XXXXXX); T=$(cd "$T" && pwd -P)
JS="$T/rp.js"
sed -n "/<<'JS'$/,/^JS$/p" "$ROOT/bin/fm-ensure-agents-md.sh" | sed '1d;$d' \
  | sed 's/^process\.exit(.*$/console.log(realpath(process.argv[2]));/' > "$JS"
mk() { mkdir -p "$T/$1"; echo x > "$T/$1/AGENTS.md"; }
probe() {
  local n=$1 py=$2 js gnu
  js=$(cd "$T/$n" && node "$JS" CLAUDE.md); gnu=$(cd "$T/$n" && realpath -m CLAUDE.md 2>&1)
  printf '%-4s %-30s node=%-18s gnu-m=%-18s python=%-18s node==python:%s\n' "$n" "$(readlink "$T/$n/CLAUDE.md" | sed "s|$T|<T>|")" \
    "${js#$T/}" "${gnu#$T/}" "$py" "$([ "${js#$T/}" = "$py" ] && echo yes || echo NO)"
}
mk p1; ln -s missing/../AGENTS.md p1/CLAUDE.md 2>/dev/null || (cd "$T" && ln -s missing/../AGENTS.md p1/CLAUDE.md); probe p1 p1/AGENTS.md
mk p4; (cd "$T" && ln -s missing/../AGENTS.md p4/hop && ln -s hop p4/CLAUDE.md); probe p4 p4/AGENTS.md
mk p5; (cd "$T" && mkdir -p p5/deep/x && ln -s deep/x p5/ln && ln -s ln/missing/../../AGENTS.md p5/CLAUDE.md); probe p5 p5/deep/AGENTS.md
mk p6; (cd "$T" && ln -s ./AGENTS.md p6/h2 && ln -s "$T/p6/h2" p6/h1 && ln -s h1 p6/CLAUDE.md); probe p6 p6/AGENTS.md
mk p8; (cd "$T" && ln -s loopb p8/loopa && ln -s loopa p8/loopb && ln -s loopa p8/CLAUDE.md); probe p8 p8/loopa
mk p9; (cd "$T" && ln -s CLAUDE.md p9/CLAUDE.md); probe p9 p9/CLAUDE.md
mk p11; (cd "$T" && ln -s missing/AGENTS.md p11/CLAUDE.md); probe p11 p11/missing/AGENTS.md
mk p13; (cd "$T" && ln -s AGENTS.md/../AGENTS.md p13/CLAUDE.md); probe p13 p13/AGENTS.md
mk p14; (cd "$T" && ln -s la p14/la && ln -s la/../AGENTS.md p14/CLAUDE.md); probe p14 p14/AGENTS.md
mk p16; (cd "$T" && ln -s / p16/root && ln -s "root$T/p16/missing/../AGENTS.md" p16/CLAUDE.md); probe p16 p16/AGENTS.md
mk p17; (cd "$T" && ln -s ../../../../../../../../../.. p17/up && ln -s "up$T/p17/AGENTS.md" p17/CLAUDE.md); probe p17 p17/AGENTS.md
rm -rf "$T"
