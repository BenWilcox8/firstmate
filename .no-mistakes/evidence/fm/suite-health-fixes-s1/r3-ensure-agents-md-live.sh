#!/usr/bin/env bash
# Round 3 live drive of bin/fm-ensure-agents-md.sh at the target commit, in
# throwaway project dirs, on a host with no python3. Expected outcomes follow
# Python's non-strict os.path.realpath (the base behavior), worked by hand per case.
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-ensure-r3.XXXXXX)
echo "python3 on PATH: $(command -v python3 || echo none); node: $(node --version)"
show() { (cd "$1" && for f in $(ls -A | sort); do if [ -L "$f" ]; then echo "  $f -> $(readlink "$f") (symlink)"; elif [ -d "$f" ]; then echo "  $f/ (dir)"; else echo "  $f (file)"; fi; done); }
drive() {
  local name=$1 expect=$2
  local d="$T/$name"
  printf '\n$ bin/fm-ensure-agents-md.sh <tmp>/%s\n' "$name"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$d" 2>&1); rc=$?
  printf '%s\n' "$out" | sed "s|$T|<tmp>|g"
  printf '[exit %s] expected exit %s -> %s\n' "$rc" "$expect" "$([ "$rc" = "$expect" ] && echo MATCH || echo MISMATCH)"
  echo "after:"; show "$d"
  if [ -f "$d/CLAUDE.md" ] && [ ! -L "$d/CLAUDE.md" ]; then echo "  CLAUDE.md content:"; sed 's/^/    /' "$d/CLAUDE.md"; fi
}
mk() { mkdir -p "$T/$1"; printf '# Project\n\nSome knowledge.\n' > "$T/$1/AGENTS.md"; }

echo; echo "== 1. CLAUDE.md -> missing/../AGENTS.md (middle component missing). Python: dir/AGENTS.md -> migrate"
mk p1; ln -s missing/../AGENTS.md "$T/p1/CLAUDE.md"; drive p1 0

echo; echo "== 2. absolute dangling form CLAUDE.md -> <tmp>/p2/missing/../AGENTS.md. Python: migrate"
mk p2; ln -s "$T/p2/missing/../AGENTS.md" "$T/p2/CLAUDE.md"; drive p2 0

echo; echo "== 3. regression: CLAUDE.md -> sub/../AGENTS.md through an existing dir. Python: migrate"
mk p3; mkdir "$T/p3/sub"; ln -s sub/../AGENTS.md "$T/p3/CLAUDE.md"; drive p3 0

echo; echo "== 4. round-2 parity probe A: two-hop chain CLAUDE.md -> hop -> missing/../AGENTS.md. Python: follows hop -> dir/AGENTS.md -> migrate"
mk p4; ln -s missing/../AGENTS.md "$T/p4/hop"; ln -s hop "$T/p4/CLAUDE.md"; drive p4 0

echo; echo "== 5. round-2 parity probe B: CLAUDE.md -> ln/missing/../../AGENTS.md, ln -> deep/x. Python: ln resolves first -> dir/deep/AGENTS.md -> refuse"
mk p5; mkdir -p "$T/p5/deep/x"; ln -s deep/x "$T/p5/ln"; ln -s ln/missing/../../AGENTS.md "$T/p5/CLAUDE.md"; drive p5 1

echo; echo "== 6. three-hop chain with an absolute middle hop: CLAUDE.md -> h1 -> <tmp>/p6/h2 -> ./AGENTS.md. Python: migrate"
mk p6; ln -s ./AGENTS.md "$T/p6/h2"; ln -s "$T/p6/h2" "$T/p6/h1"; ln -s h1 "$T/p6/CLAUDE.md"; drive p6 0

echo; echo "== 7. symlinked project dir: real dir reached through an alias; CLAUDE.md -> ../alias7/AGENTS.md. Python: both resolve to real/AGENTS.md -> migrate"
mkdir -p "$T/real7"; printf '# Project\n' > "$T/real7/AGENTS.md"; ln -s real7 "$T/alias7"; ln -s ../alias7/AGENTS.md "$T/real7/CLAUDE.md"
printf '\n$ bin/fm-ensure-agents-md.sh <tmp>/alias7   (run through the alias)\n'
out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$T/alias7" 2>&1); rc=$?; printf '%s\n' "$out" | sed "s|$T|<tmp>|g"; printf '[exit %s] expected exit 0 -> %s\n' "$rc" "$([ "$rc" = 0 ] && echo MATCH || echo MISMATCH)"; show "$T/real7"

echo; echo "== 8. adversarial: symlink loop CLAUDE.md -> loopa -> loopb -> loopa. Python: loop kept as path -> refuse (no hang)"
mk p8; ln -s loopb "$T/p8/loopa"; ln -s loopa "$T/p8/loopb"; ln -s loopa "$T/p8/CLAUDE.md"; drive p8 1

echo; echo "== 9. adversarial: self loop CLAUDE.md -> CLAUDE.md. Python: refuse"
mk p9; ln -s CLAUDE.md "$T/p9/CLAUDE.md"; drive p9 1

echo; echo "== 10. adversarial: CLAUDE.md -> missing/../OTHER.md (wrong existing file). Python: refuse"
mk p10; printf 'other\n' > "$T/p10/OTHER.md"; ln -s missing/../OTHER.md "$T/p10/CLAUDE.md"; drive p10 1

echo; echo "== 11. adversarial: CLAUDE.md -> missing/AGENTS.md (missing dir, no ..). Python: dir/missing/AGENTS.md -> refuse"
mk p11; ln -s missing/AGENTS.md "$T/p11/CLAUDE.md"; drive p11 1

echo; echo "== 12. adversarial: CLAUDE.md -> ../elsewhere/AGENTS.md (another dir's AGENTS.md). Python: refuse"
mk p12; mkdir -p "$T/elsewhere"; printf '# other\n' > "$T/elsewhere/AGENTS.md"; ln -s ../elsewhere/AGENTS.md "$T/p12/CLAUDE.md"; drive p12 1

echo; echo "== 13. adversarial: a file used as a directory: CLAUDE.md -> AGENTS.md/../AGENTS.md. Python non-strict: lexical .. -> dir/AGENTS.md -> migrate"
mk p13; ln -s AGENTS.md/../AGENTS.md "$T/p13/CLAUDE.md"; drive p13 0

echo; echo "== 14. adversarial: hop chain ending at a loop before ..: CLAUDE.md -> la/../AGENTS.md, la -> la. Python 3.13: loop kept as dir/la, .. -> dir -> migrate"
mk p14; ln -s la "$T/p14/la"; ln -s la/../AGENTS.md "$T/p14/CLAUDE.md"; drive p14 0

echo; echo "== 15. AGENTS.md absent, CLAUDE.md -> AGENTS.md dangling (literal name: short-circuits before the realpath port; base 2812e3cb also creates AGENTS.md, exit 0)"
mkdir -p "$T/p15"; ln -s AGENTS.md "$T/p15/CLAUDE.md"; drive p15 0
rm -rf "$T"
