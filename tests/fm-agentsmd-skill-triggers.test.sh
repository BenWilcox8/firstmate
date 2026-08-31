#!/usr/bin/env bash
# AGENTS.md section 13 is the trigger registry for the agent-only reference
# skills. A trigger that names a skill this repo does not carry is dead weight:
# the session is told to load an owner that a bare install cannot resolve, and
# the contract it was supposed to own silently has no owner at all. This test
# pins that direction only - every registered trigger resolves to a readable
# repo skill - and deliberately not the reverse, because a deprecated redirect
# stub is allowed to exist with no trigger of its own.
#
# The registry is an owned text contract, not incidental source: section 13 is
# the declared list of load triggers every session reads, so this test parses it
# into a list of names and resolves each one, rather than asserting that any
# particular sentence appears anywhere. tests/fm-harness-adapter-references.test.sh
# validates the harness router's own reference artifact the same way.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"

# The registry is the bullet list of section 13, and each bullet opens with the
# skill's name in backticks before its trigger prose.
registry=$(awk '
  /^## 13\. Agent-only reference skills$/ { capture = 1; next }
  capture && /^## / { exit }
  capture && /^- `[^`]+` - / {
    line = $0
    sub(/^- `/, "", line)
    sub(/` - .*$/, "", line)
    print line
  }
' "$AGENTS")

[ -n "$registry" ] \
  || fail "AGENTS.md section 13 lists no skill triggers, so the registry could not be read"

count=0
while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  count=$((count + 1))
  [ -r "$ROOT/.agents/skills/$skill/SKILL.md" ] \
    || fail "AGENTS.md section 13 triggers \`$skill\`, but .agents/skills/$skill/SKILL.md is unreadable"
done <<EOF2
$registry
EOF2

[ "$count" -ge 10 ] \
  || fail "AGENTS.md section 13 parsed only $count skill triggers, so the registry parse is wrong"

pass "all $count AGENTS.md section 13 skill triggers resolve to a readable repo skill"
