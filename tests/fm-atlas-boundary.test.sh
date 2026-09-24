#!/usr/bin/env bash
# Behavior tests for bin/fm-atlas-boundary-check.sh, the guard that keeps Atlas
# text inside the optional Atlas module.
#
# The check passes on this repository, and it fails, naming the file, when Atlas
# text appears in a core file beyond that file's registered hook points. The
# fixture cases run the check against a throwaway git repository, so they pin
# the check's verdicts rather than any sentence in this repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-atlas-boundary-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-mapguard)

# A fixture repository with a clean core and a module that talks about the
# Atlas as much as it likes.
new_fixture() {  # <name> -> repo path
  local repo="$TMP_ROOT/$1"
  mkdir -p "$repo/bin" "$repo/docs/atlas-module" "$repo/.agents/skills/atlas-firstmate-bridge" \
    "$repo/.agents/skills/other" "$repo/tests"
  git -C "$repo" init -q
  printf '# Firstmate\n\nThe supervisor contract.\n' > "$repo/AGENTS.md"
  printf '#!/usr/bin/env bash\necho charter\n' > "$repo/bin/fm-brief.sh"
  printf '#!/usr/bin/env bash\n# Atlas hooks, Atlas tickets, Atlas nodes.\n' > "$repo/bin/fm-atlas-hook.sh"
  printf 'The Atlas is the map.\nAtlas rules live here.\n' > "$repo/docs/atlas-module/supervisor-block.md"
  printf 'Atlas bridge rules.\n' > "$repo/.agents/skills/atlas-firstmate-bridge/SKILL.md"
  printf 'An unrelated skill.\n' > "$repo/.agents/skills/other/SKILL.md"
  printf '#!/usr/bin/env bash\n# Tests may name the Atlas freely.\n' > "$repo/tests/fm-anything.test.sh"
  printf '#!/usr/bin/env bash\n# rovo is the agent CLI that Atlassian ships (ATLASSIAN_AGENT_TYPE).\n' > "$repo/bin/fm-harness.sh"
  git -C "$repo" add -A
  printf '%s\n' "$repo"
}

add_line() {  # <repo> <path> <line>
  printf '%s\n' "$3" >> "$1/$2"
  git -C "$1" add -A
}

test_passes_on_this_repository() {
  local out status
  out=$("$CHECK" 2>&1)
  status=$?
  expect_code 0 "$status" "the boundary check fails on this repository: $out"
  assert_contains "$out" "fm-atlas-boundary-check: ok" "the passing check did not say so"
  pass "the Atlas boundary check passes on this repository"
}

test_passes_on_a_clean_fixture() {
  local repo out status
  repo=$(new_fixture clean)
  out=$("$CHECK" --root "$repo" 2>&1)
  status=$?
  expect_code 0 "$status" "a clean fixture failed: $out"
  pass "module files, tests, and the word Atlassian never count against the boundary"
}

test_one_pointer_line_in_agents_md_is_allowed() {
  local repo out status
  repo=$(new_fixture pointer)
  add_line "$repo" AGENTS.md 'config/specs  optional Atlas module pointer; see docs/atlas-module/README.md'
  out=$("$CHECK" --root "$repo" 2>&1)
  status=$?
  expect_code 0 "$status" "one pointer line in AGENTS.md was refused: $out"
  pass "AGENTS.md may carry its one registered pointer line"
}

test_doctrine_in_agents_md_fails() {
  local repo out status
  repo=$(new_fixture agents)
  add_line "$repo" AGENTS.md 'config/specs  optional Atlas module pointer; see docs/atlas-module/README.md'
  add_line "$repo" AGENTS.md 'In an Atlas-wired home, run atlas-axi dispositions at every heartbeat.'
  out=$("$CHECK" --root "$repo" 2>&1)
  status=$?
  expect_code 1 "$status" "Atlas doctrine in AGENTS.md passed the boundary check"
  assert_contains "$out" "AGENTS.md" "the failure does not name AGENTS.md"
  pass "Atlas doctrine added to AGENTS.md fails the boundary check"
}

test_charter_template_mention_fails() {
  local repo out status
  repo=$(new_fixture charter)
  add_line "$repo" bin/fm-brief.sh '# Secondmates must keep the Atlas current.'
  out=$("$CHECK" --root "$repo" 2>&1)
  status=$?
  expect_code 1 "$status" "an Atlas mention in the charter template passed the boundary check"
  assert_contains "$out" "bin/fm-brief.sh" "the failure does not name the charter template"
  pass "an Atlas mention in the secondmate charter template fails the boundary check"
}

test_unregistered_core_file_fails() {
  local repo out status
  repo=$(new_fixture unregistered)
  printf '#!/usr/bin/env bash\n# Restage the Atlas ticket here.\n' > "$repo/bin/fm-new-thing.sh"
  printf 'Workers complete Atlas tickets.\n' > "$repo/.agents/skills/other/SKILL.md"
  git -C "$repo" add -A
  out=$("$CHECK" --root "$repo" 2>&1)
  status=$?
  expect_code 1 "$status" "Atlas text in unregistered core files passed the boundary check"
  assert_contains "$out" "bin/fm-new-thing.sh" "the failure does not name the unregistered script"
  assert_contains "$out" ".agents/skills/other/SKILL.md" "the failure does not name the non-module skill"
  pass "Atlas text in any unregistered core file fails, and every offending file is named"
}

test_passes_on_this_repository
test_passes_on_a_clean_fixture
test_one_pointer_line_in_agents_md_is_allowed
test_doctrine_in_agents_md_fails
test_charter_template_mention_fails
test_unregistered_core_file_fails
