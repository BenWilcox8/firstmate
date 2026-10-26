#!/usr/bin/env bash
# The agent-skill-trigger-index skill is the complete trigger registry for the
# agent-only reference skills, and AGENTS.md section 13 points at it. A trigger
# that names a skill this repo does not carry is dead weight: the session is
# told to load an owner that a bare install cannot resolve, and the contract it
# was supposed to own silently has no owner at all. This test pins that
# direction only - every registered trigger resolves to a readable repo skill -
# and deliberately not the reverse, because a deprecated redirect stub is
# allowed to exist with no trigger of its own.
#
# The registry is an owned text contract, not incidental source: the index is
# the declared list of load triggers, so this test parses it into a list of
# names and resolves each one, rather than asserting that any particular
# sentence appears anywhere. tests/fm-harness-adapter-references.test.sh
# validates the harness router's own reference artifact the same way.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
INDEX="$ROOT/.agents/skills/agent-skill-trigger-index/SKILL.md"

# AGENTS.md section 13 must still route a session to the complete index.
awk '
  /^## 13\. Agent-only reference skills$/ { capture = 1; next }
  capture && /^## / { exit }
  capture
' "$AGENTS" | grep -qF "\`agent-skill-trigger-index\`" \
  || fail "AGENTS.md section 13 does not name \`agent-skill-trigger-index\`, so the trigger registry has no route"

[ -r "$INDEX" ] \
  || fail ".agents/skills/agent-skill-trigger-index/SKILL.md is unreadable, so the registry could not be read"

# The registry is the bullet list of the index skill body, after its
# frontmatter, and each bullet opens with the skill's name in backticks before
# its trigger prose.
registry=$(awk '
  NR == 1 && /^---$/ { frontmatter = 1; next }
  frontmatter && /^---$/ { frontmatter = 0; next }
  frontmatter { next }
  /^- `[^`]+` - / {
    line = $0
    sub(/^- `/, "", line)
    sub(/` - .*$/, "", line)
    print line
  }
' "$INDEX")

[ -n "$registry" ] \
  || fail "the agent-skill-trigger-index lists no skill triggers, so the registry could not be read"

count=0
while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  count=$((count + 1))
  [ -r "$ROOT/.agents/skills/$skill/SKILL.md" ] \
    || fail "the agent-skill-trigger-index triggers \`$skill\`, but .agents/skills/$skill/SKILL.md is unreadable"
done <<EOF2
$registry
EOF2

[ "$count" -ge 10 ] \
  || fail "the agent-skill-trigger-index parsed only $count skill triggers, so the registry parse is wrong"

pass "all $count agent-skill-trigger-index skill triggers resolve to a readable repo skill"
