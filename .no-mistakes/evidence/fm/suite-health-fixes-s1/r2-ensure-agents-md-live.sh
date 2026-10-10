#!/usr/bin/env bash
# Live drive of bin/fm-ensure-agents-md.sh (round 2, after the dangling-component
# fix) in throwaway project dirs on a host with no python3.
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-ensure-r2.XXXXXX)
echo "python3 on PATH: $(command -v python3 || echo none); node: $(node --version)"
show() { (cd "$1" && for f in $(ls -A | sort); do if [ -L "$f" ]; then echo "  $f -> $(readlink "$f") (symlink)"; elif [ -d "$f" ]; then echo "  $f/ (dir)"; else echo "  $f (file)"; fi; done); }
drive() {
  local name=$1; shift
  local d="$T/$name"
  printf '\n$ bin/fm-ensure-agents-md.sh <tmp>/%s\n' "$name"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$d" 2>&1 | sed "s|$T|<tmp>|g"
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
  echo "after:"; show "$d"
  if [ -f "$d/CLAUDE.md" ] && [ ! -L "$d/CLAUDE.md" ]; then echo "  CLAUDE.md content:"; sed 's/^/    /' "$d/CLAUDE.md"; fi
}
mk() { mkdir -p "$T/$1"; printf '# Project\n\nSome knowledge.\n' > "$T/$1/AGENTS.md"; }

echo; echo "== 1. the fixed case: CLAUDE.md -> missing/../AGENTS.md (middle component does not exist)"
mk p1; ln -s missing/../AGENTS.md "$T/p1/CLAUDE.md"; echo "before:"; show "$T/p1"; drive p1

echo; echo "== 2. same, AGENTS.md already has the maintenance section (plain replace line)"
mk p2; "$ROOT/bin/fm-ensure-agents-md.sh" "$T/p2" >/dev/null; rm "$T/p2/CLAUDE.md"; ln -s missing/../AGENTS.md "$T/p2/CLAUDE.md"; drive p2

echo; echo "== 3. absolute dangling form: CLAUDE.md -> <tmp>/p3/missing/../AGENTS.md"
mk p3; ln -s "$T/p3/missing/../AGENTS.md" "$T/p3/CLAUDE.md"; drive p3

echo; echo "== 4. regression: CLAUDE.md -> sub/../AGENTS.md through an existing dir"
mk p4; mkdir "$T/p4/sub"; ln -s sub/../AGENTS.md "$T/p4/CLAUDE.md"; drive p4

echo; echo "== 5. adversarial: CLAUDE.md -> missing/../OTHER.md, OTHER.md exists (wrong file)"
mk p5; printf 'other\n' > "$T/p5/OTHER.md"; ln -s missing/../OTHER.md "$T/p5/CLAUDE.md"; drive p5

echo; echo "== 6. adversarial: CLAUDE.md -> missing/../NOPE.md (dangling, no such file)"
mk p6; ln -s missing/../NOPE.md "$T/p6/CLAUDE.md"; drive p6

echo; echo "== 7. adversarial: CLAUDE.md -> missing/AGENTS.md (missing dir, no ..)"
mk p7; ln -s missing/AGENTS.md "$T/p7/CLAUDE.md"; drive p7

echo; echo "== 8. adversarial: CLAUDE.md -> ../elsewhere/AGENTS.md (an AGENTS.md of another dir)"
mk p8; mkdir -p "$T/elsewhere"; printf '# other\n' > "$T/elsewhere/AGENTS.md"; ln -s ../elsewhere/AGENTS.md "$T/p8/CLAUDE.md"; drive p8

echo; echo "== 9. parity probe: two-hop chain CLAUDE.md -> hop -> missing/../AGENTS.md"
echo "   (Python non-strict realpath follows hop, then resolves missing/.. lexically: dir/AGENTS.md)"
mk p9; ln -s missing/../AGENTS.md "$T/p9/hop"; ln -s hop "$T/p9/CLAUDE.md"; drive p9

echo; echo "== 10. parity probe: symlinked dir before .. : CLAUDE.md -> ln/missing/../../AGENTS.md, ln -> deep/x"
echo "   (Python resolves ln first: dir/deep/AGENTS.md, which differs from dir/AGENTS.md)"
mk p10; mkdir -p "$T/p10/deep/x"; ln -s deep/x "$T/p10/ln"; ln -s ln/missing/../../AGENTS.md "$T/p10/CLAUDE.md"; drive p10
rm -rf "$T"
