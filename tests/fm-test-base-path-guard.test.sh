#!/usr/bin/env bash
# tests/fm-test-base-path-guard.test.sh - every FM_TEST_BASE_PATH default must
# stay NixOS-safe.
#
# Several suites build a restricted PATH for the script under test with a
# fallback shape like:
#   BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# On a host where /usr/bin and /bin are nearly empty (NixOS), that fallback
# alone cannot even resolve `bash`, so any subshell or `bash -c` invocation
# built from it fails with "No such file or directory" or "command not found"
# instead of exercising the behavior under test. tests/lib.sh's
# fm_test_core_path symlinks a curated set of standard tools (bash, sed, grep,
# jq, ...) into a private directory precisely so a restricted-PATH fallback can
# prepend it and stay portable. This is a structural guard, not a snapshot of
# today's file list: it scans every suite for the hazard shape directly, so a
# newly added fallback that omits fm_test_core_path fails here regardless of
# which file introduces it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_base_path_fallback_shape_is_portable() {
  local unsafe safe
  unsafe="$TMP_ROOT/unsafe.sh"
  safe="$TMP_ROOT/safe.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'BASE_PATH=${FM_TEST_BASE_PATH:-"$(fm_test_core_path):/usr/bin:/bin:/usr/sbin:/sbin"}' > "$safe"
  base_path_fallback_hazards "$unsafe" | grep -q . \
    || fail "structural guard missed an FM_TEST_BASE_PATH fallback with no fm_test_core_path"
  [ -z "$(base_path_fallback_hazards "$safe")" ] \
    || fail "structural guard flagged an FM_TEST_BASE_PATH fallback that already includes fm_test_core_path"
  pass "fm-test-base-path-guard: the structural check tells a hazardous fallback from a portable one"
}

test_every_suite_fallback_is_portable() {
  local file hazards all_hazards=""
  for file in "$ROOT"/tests/*.test.sh; do
    [ "$(basename "$file")" != "fm-test-base-path-guard.test.sh" ] || continue
    hazards=$(base_path_fallback_hazards "$file")
    [ -z "$hazards" ] || all_hazards="$all_hazards
$file:
$hazards"
  done
  [ -z "$all_hazards" ] \
    || fail "FM_TEST_BASE_PATH fallback(s) without fm_test_core_path (NixOS bash/sed/etc. would not resolve):$all_hazards"
  pass "fm-test-base-path-guard: every suite's FM_TEST_BASE_PATH fallback prepends fm_test_core_path"
}

# base_path_fallback_hazards <file>: prints one line per FM_TEST_BASE_PATH
# default-value expression in <file> that mentions /usr/bin (the restricted
# system tail) without also mentioning fm_test_core_path.
base_path_fallback_hazards() {
  perl -ne '
    print "$.: $_" if /FM_TEST_BASE_PATH:-/ && /\/usr\/bin/ && !/fm_test_core_path/;
  ' "$1"
}

TMP_ROOT=$(fm_test_tmproot fm-test-base-path-guard)

test_base_path_fallback_shape_is_portable
test_every_suite_fallback_is_portable

echo "ALL TESTS PASSED"
