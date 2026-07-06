#!/usr/bin/env bash
# Behavior tests for bin/fm-ensure-agents-md.sh.
#
# Covers the unchanged AGENTS.md/CLAUDE.md reconciliation plus the --skill
# project-skills scaffolding: it creates .agents/skills/ with a
# .claude/skills -> ../.agents/skills symlink and a SKILL.md stub, is
# idempotent, and refuses to clobber an existing skill or a wrong symlink.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-ensure-agents-md.sh"
TMP_ROOT=$(fm_test_tmproot fm-ensure-agents-md)

# The script must always parse.
test_script_parses() {
  bash -n "$SCRIPT" 2>&1 || fail "bin/fm-ensure-agents-md.sh fails bash -n"
  pass "fm-ensure-agents-md.sh: bash -n succeeds"
}

# Default (no --skill) in an empty dir creates AGENTS.md + CLAUDE.md symlink,
# and must NOT create any skills scaffolding.
test_default_creates_agents_no_skills() {
  local d="$TMP_ROOT/default"
  mkdir -p "$d"
  "$SCRIPT" "$d" >/dev/null 2>&1 || fail "default run exited non-zero"
  assert_present "$d/AGENTS.md" "AGENTS.md not created"
  [ -L "$d/CLAUDE.md" ] || fail "CLAUDE.md not a symlink"
  assert_absent "$d/.agents/skills" "default run should not scaffold .agents/skills"
  assert_absent "$d/.claude/skills" "default run should not scaffold .claude/skills"
  pass "fm-ensure-agents-md.sh: default creates AGENTS.md, no skills layout"
}

# --skill scaffolds the full skills layout and a SKILL.md stub.
test_skill_scaffolds_layout() {
  local d="$TMP_ROOT/skill"
  mkdir -p "$d"
  local out
  out=$("$SCRIPT" --skill flow-sheet "$d" 2>&1) || fail "--skill run exited non-zero: $out"
  assert_present "$d/AGENTS.md" "AGENTS.md not created by --skill run"
  [ -d "$d/.agents/skills" ] || fail ".agents/skills dir not created"
  [ -L "$d/.claude/skills" ] || fail ".claude/skills symlink not created"
  [ "$(readlink "$d/.claude/skills")" = "../.agents/skills" ] || \
    fail ".claude/skills points at the wrong target"
  assert_present "$d/.agents/skills/flow-sheet/SKILL.md" "SKILL.md stub not created"
  assert_grep "name: flow-sheet" "$d/.agents/skills/flow-sheet/SKILL.md" \
    "SKILL.md missing name frontmatter"
  assert_grep "user-invocable: false" "$d/.agents/skills/flow-sheet/SKILL.md" \
    "SKILL.md missing user-invocable: false"
  pass "fm-ensure-agents-md.sh: --skill scaffolds layout + stub"
}

# --skill is idempotent and refuses to clobber an existing SKILL.md body.
test_skill_idempotent_no_clobber() {
  local d="$TMP_ROOT/idem"
  mkdir -p "$d"
  "$SCRIPT" --skill editor "$d" >/dev/null 2>&1 || fail "first --skill run failed"
  printf 'CUSTOM BODY\n' > "$d/.agents/skills/editor/SKILL.md"
  local out
  out=$("$SCRIPT" --skill editor "$d" 2>&1) || fail "second --skill run should succeed unchanged: $out"
  assert_contains "$out" "unchanged" "second run should report unchanged for existing SKILL.md"
  assert_grep "CUSTOM BODY" "$d/.agents/skills/editor/SKILL.md" \
    "existing SKILL.md was clobbered"
  pass "fm-ensure-agents-md.sh: --skill idempotent, never clobbers a real SKILL.md"
}

# A wrong .claude/skills symlink is a refusing conflict, not a silent overwrite.
test_wrong_claude_skills_symlink_refuses() {
  local d="$TMP_ROOT/wronglink"
  mkdir -p "$d/.claude" "$d/elsewhere"
  ln -s "../elsewhere" "$d/.claude/skills"
  local out rc
  out=$("$SCRIPT" --skill x "$d" 2>&1); rc=$?
  expect_code 1 "$rc" "wrong .claude/skills symlink should refuse"
  assert_contains "$out" "conflict" "refusal should explain the conflict"
  pass "fm-ensure-agents-md.sh: refuses a wrong .claude/skills symlink"
}

# An invalid skill slug is rejected up front.
test_invalid_slug_rejected() {
  local d="$TMP_ROOT/badslug"
  mkdir -p "$d"
  local rc
  "$SCRIPT" --skill "Bad Name" "$d" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "invalid skill slug should be rejected"
  pass "fm-ensure-agents-md.sh: rejects an invalid skill slug"
}

test_script_parses
test_default_creates_agents_no_skills
test_skill_scaffolds_layout
test_skill_idempotent_no_clobber
test_wrong_claude_skills_symlink_refuses
test_invalid_slug_rejected
