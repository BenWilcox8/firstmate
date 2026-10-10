#!/usr/bin/env bash
# Round 3 live parity probes for bin/fm-ensure-agents-md.sh at 6ad37c7.
# Oracle: GNU `realpath -m`, which resolves each component in order, follows
# each symlink, keeps a missing component as a plain name, and returns the loop
# path for a symlink loop - the same semantics as Python non-strict
# os.path.realpath, which the base script compared:
#   os.path.realpath("CLAUDE.md") == os.path.realpath("AGENTS.md")
# Expected exit: 0 (migrate to pointer) when the two resolve equal, else 1
# (conflict, nothing touched).
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-ensure-r3.XXXXXX)
echo "python3 on PATH: $(command -v python3 || echo none); node: $(node --version); $(realpath --version | head -1)"
mismatches=0
show() { (cd "$1" && for f in $(ls -A | sort); do if [ -L "$f" ]; then echo "    $f -> $(readlink "$f")"; elif [ -d "$f" ]; then echo "    $f/"; else echo "    $f"; fi; done); }
mk() { mkdir -p "$T/$1"; printf '# Project\n\nSome knowledge.\n' > "$T/$1/AGENTS.md"; }
probe() {
  local name=$1 title=$2 d="$T/$1" want got out before_link oracle_c oracle_a verdict state
  echo
  echo "== $name: $title"
  echo "  before:"; show "$d"
  oracle_c=$(cd "$d" && realpath -m CLAUDE.md); oracle_a=$(cd "$d" && realpath -m AGENTS.md)
  if [ "$oracle_c" = "$oracle_a" ]; then want=0; else want=1; fi
  echo "  oracle realpath -m CLAUDE.md = ${oracle_c#"$T"/}"
  echo "  oracle realpath -m AGENTS.md = ${oracle_a#"$T"/}"
  before_link=$(readlink "$d/CLAUDE.md")
  cp "$d/AGENTS.md" "$T/.agents-before"
  out=$(timeout 20 "$ROOT/bin/fm-ensure-agents-md.sh" "$d" 2>&1); got=$?
  echo "  \$ bin/fm-ensure-agents-md.sh <tmp>/$name"
  printf '%s\n' "$out" | sed "s|$T|<tmp>|g; s/^/    /"
  echo "  [exit $got, expected $want]"
  if [ "$got" = 0 ]; then
    if [ -f "$d/CLAUDE.md" ] && [ ! -L "$d/CLAUDE.md" ] && grep -qx '@AGENTS.md' "$d/CLAUDE.md"; then state="CLAUDE.md is now the @AGENTS.md pointer file"; else state="BAD: CLAUDE.md not migrated"; fi
  else
    if [ -L "$d/CLAUDE.md" ] && [ "$(readlink "$d/CLAUDE.md")" = "$before_link" ] && cmp -s "$T/.agents-before" "$d/AGENTS.md"; then state="CLAUDE.md symlink and AGENTS.md untouched"; else state="BAD: state changed on refusal"; fi
  fi
  echo "  after: $state"
  if [ "$got" = "$want" ] && [ "${state#BAD}" = "$state" ]; then verdict=MATCH; else verdict=MISMATCH; mismatches=$((mismatches + 1)); fi
  echo "  => $verdict"
}

mk one-hop; ln -s missing/../AGENTS.md "$T/one-hop/CLAUDE.md"
probe one-hop "CLAUDE.md -> missing/../AGENTS.md (missing middle component)"

mk two-hop; ln -s missing/../AGENTS.md "$T/two-hop/hop"; ln -s hop "$T/two-hop/CLAUDE.md"
probe two-hop "two-hop chain CLAUDE.md -> hop -> missing/../AGENTS.md (round-2 failure)"

mk three-hop; mkdir "$T/three-hop/sub"; ln -s ../h2 "$T/three-hop/sub/h1"; ln -s missing/../AGENTS.md "$T/three-hop/h2"; ln -s sub/h1 "$T/three-hop/CLAUDE.md"
probe three-hop "three-hop chain CLAUDE.md -> sub/h1 -> ../h2 -> missing/../AGENTS.md"

mk abs-two-hop; ln -s "$T/abs-two-hop/missing/../AGENTS.md" "$T/abs-two-hop/hop"; ln -s "$T/abs-two-hop/hop" "$T/abs-two-hop/CLAUDE.md"
probe abs-two-hop "absolute two-hop chain CLAUDE.md -> <abs>/hop -> <abs>/missing/../AGENTS.md"

mk two-hop-wrong; printf 'other\n' > "$T/two-hop-wrong/OTHER.md"; ln -s missing/../OTHER.md "$T/two-hop-wrong/hop"; ln -s hop "$T/two-hop-wrong/CLAUDE.md"
probe two-hop-wrong "adversarial: two-hop chain to an existing OTHER.md"

mk symdir-before-parent; mkdir -p "$T/symdir-before-parent/deep/x"; ln -s deep/x "$T/symdir-before-parent/ln"; ln -s ln/missing/../../AGENTS.md "$T/symdir-before-parent/CLAUDE.md"
probe symdir-before-parent "symlinked dir before ..: CLAUDE.md -> ln/missing/../../AGENTS.md, ln -> deep/x (round-2 failure)"

mk symdir-before-parent-ok; mkdir -p "$T/symdir-before-parent-ok/sub"; ln -s sub "$T/symdir-before-parent-ok/ln"; ln -s ln/missing/../../AGENTS.md "$T/symdir-before-parent-ok/CLAUDE.md"
probe symdir-before-parent-ok "symlinked dir before .. that lands on AGENTS.md: ln -> sub"

mk dangling-symdir; ln -s nowhere/deeper "$T/dangling-symdir/sub"; ln -s sub/../AGENTS.md "$T/dangling-symdir/CLAUDE.md"
probe dangling-symdir "adversarial: CLAUDE.md -> sub/../AGENTS.md, sub -> nowhere/deeper (dangling symlinked dir)"

mkdir -p "$T/elsewhere/x"; printf '# other\n' > "$T/elsewhere/AGENTS.md"
mk abs-symdir; ln -s "$T/elsewhere/x" "$T/abs-symdir/ln"; ln -s ln/../AGENTS.md "$T/abs-symdir/CLAUDE.md"
probe abs-symdir "adversarial: CLAUDE.md -> ln/../AGENTS.md, ln -> <abs>/elsewhere/x (another AGENTS.md)"

mk self-loop; ln -s loop "$T/self-loop/loop"; ln -s loop "$T/self-loop/CLAUDE.md"
probe self-loop "loop: CLAUDE.md -> loop, loop -> loop"

mk two-link-loop; ln -s b "$T/two-link-loop/a"; ln -s a "$T/two-link-loop/b"; ln -s a "$T/two-link-loop/CLAUDE.md"
probe two-link-loop "loop: CLAUDE.md -> a, a -> b, b -> a"

mk claude-self; ln -s CLAUDE.md "$T/claude-self/CLAUDE.md"
probe claude-self "loop: CLAUDE.md -> CLAUDE.md"

mk mid-loop; ln -s loop "$T/mid-loop/loop"; ln -s loop/../AGENTS.md "$T/mid-loop/CLAUDE.md"
probe mid-loop "loop before ..: CLAUDE.md -> loop/../AGENTS.md, loop -> loop"

mk trailing-slash; ln -s AGENTS.md/ "$T/trailing-slash/CLAUDE.md"
probe trailing-slash "edge: CLAUDE.md -> AGENTS.md/ (trailing slash)"

echo
echo "SUMMARY: $mismatches mismatch(es) against the realpath -m oracle"
rm -rf "$T"
[ "$mismatches" = 0 ]
