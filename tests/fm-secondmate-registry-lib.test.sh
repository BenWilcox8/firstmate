#!/usr/bin/env bash
# tests/fm-secondmate-registry-lib.test.sh - data/secondmates.md field parsing.
#
# Regression coverage for a home-path resolution bug: an earlier per-caller
# parser anchored the home field to the FIRST "(" on the line, so a summary
# that itself contained parentheses (including one that happened to read
# "(home:") before the real structured suffix resolved to the wrong home, or
# to none at all. The shared parser now anchors to the suffix markers
# ("home:", "scope:", "projects:", "added ...)") instead, so it must find the
# LAST such suffix on the line regardless of what the free-text summary says.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-registry-lib)
REG="$TMP_ROOT/secondmates.md"

test_summary_with_parens_resolves_correct_home() {
  cat > "$REG" <<'EOF'
- osg - onestopgreek (consolidated 2026-08-26: former osg-redesign-q7 merged in) (home: /home/ben/.firstmate-secondmates/osg; scope: onestopgreek work; projects: onestopgreek; added 2026-08-26)
EOF
  local home
  home=$(secondmate_registry_field "$REG" osg home) \
    || fail "secondmate_registry_field refused a summary containing parentheses"
  [ "$home" = "/home/ben/.firstmate-secondmates/osg" ] \
    || fail "expected the real home path, got: $home"
  pass "registry parse: a summary with an unrelated parenthesized aside still resolves the real home"
}

test_summary_containing_home_colon_substring_resolves_correct_home() {
  # The summary text itself contains the literal substring "(home:" before the
  # real structured suffix - the exact shape that broke a first-"(" anchor.
  cat > "$REG" <<'EOF'
- osg2 - migrated (home: was misrouted here once, now fixed) (home: /home/ben/.firstmate-secondmates/osg2; scope: onestopgreek work; projects: onestopgreek; added 2026-08-27)
EOF
  local home
  home=$(secondmate_registry_field "$REG" osg2 home) \
    || fail "secondmate_registry_field refused a summary containing a literal '(home:' substring"
  [ "$home" = "/home/ben/.firstmate-secondmates/osg2" ] \
    || fail "expected the real home path (the LAST home: group), got: $home"
  pass "registry parse: a summary echoing '(home:' itself still resolves the trailing structured home"
}

test_scope_field_with_semicolons_and_parens() {
  cat > "$REG" <<'EOF'
- clash - clash reinforcement learning (many things; some (nested)) (home: /home/ben/.firstmate-secondmates/clash; scope: rl training (v2, batched); projects: clash-rl; added 2026-08-20)
EOF
  local scope
  scope=$(secondmate_registry_field "$REG" clash scope) \
    || fail "secondmate_registry_field refused a scope field containing parentheses"
  [ "$scope" = "rl training (v2, batched)" ] \
    || fail "expected the full scope text, got: $scope"
  pass "registry parse: scope free text with parentheses is preserved verbatim"
}

test_summary_with_parens_resolves_correct_home
test_summary_containing_home_colon_substring_resolves_correct_home
test_scope_field_with_semicolons_and_parens

echo "ALL TESTS PASSED"
