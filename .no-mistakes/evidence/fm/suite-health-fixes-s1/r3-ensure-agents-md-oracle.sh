#!/usr/bin/env bash
# Independent cross-check of the expected classification: GNU realpath -m
# (resolve symlinks first, then .., missing parts allowed), the closest tool to
# Python non-strict os.path.realpath on this host, which has no python3.
set -u
T=$(mktemp -d /tmp/fm-oracle.XXXXXX); cd "$T"
o() { local n=$1; r1=$(cd $T/$n && realpath -m CLAUDE.md 2>&1); r2=$(cd $T/$n && realpath -m AGENTS.md); printf '%-4s CLAUDE.md -> %-28s realpath -m: %-20s same as AGENTS.md: %s\n' "$n" "$(readlink $T/$n/CLAUDE.md)" "${r1#$T/}" "$([ "$r1" = "$r2" ] && echo yes-migrate || echo no-refuse)"; }
mkp() { mkdir -p $T/$1; echo x > $T/$1/AGENTS.md; }
mkp p1; ln -s missing/../AGENTS.md p1/CLAUDE.md; o p1
mkp p4; ln -s missing/../AGENTS.md p4/hop; ln -s hop p4/CLAUDE.md; o p4
mkp p5; mkdir -p p5/deep/x; ln -s deep/x p5/ln; ln -s ln/missing/../../AGENTS.md p5/CLAUDE.md; o p5
mkp p6; ln -s ./AGENTS.md p6/h2; ln -s $T/p6/h2 p6/h1; ln -s h1 p6/CLAUDE.md; o p6
mkp p8; ln -s loopb p8/loopa; ln -s loopa p8/loopb; ln -s loopa p8/CLAUDE.md; o p8
mkp p11; ln -s missing/AGENTS.md p11/CLAUDE.md; o p11
mkp p13; ln -s AGENTS.md/../AGENTS.md p13/CLAUDE.md; o p13
mkp p14; ln -s la p14/la; ln -s la/../AGENTS.md p14/CLAUDE.md; o p14
cd /; rm -rf "$T"
