#!/usr/bin/env bash
# Run selected functions from tests/fm-teardown.test.sh, each in its own process,
# with bin/fm-teardown.sh taken from <root-under-test>.
# Usage: run-teardown-tests.sh <helpers-root> <root-under-test> <test-fn>...
set -u
HELPERS_ROOT=$1
UNDER_TEST=$2
shift 2
WORK=$(mktemp -d /tmp/fm-f2-tdtests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
sed -e '/^test_[a-z0-9_]*$/d' \
    -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$HELPERS_ROOT/tests/lib.sh#" \
    -e "s#^TEARDOWN=\"\$ROOT/bin/fm-teardown.sh\"#ROOT=$UNDER_TEST; TEARDOWN=\"\$ROOT/bin/fm-teardown.sh\"#" \
    "$HELPERS_ROOT/tests/fm-teardown.test.sh" > "$WORK/suite.sh"
grep -q "^ROOT=$UNDER_TEST; TEARDOWN=" "$WORK/suite.sh" || { echo "runner: could not pin ROOT" >&2; exit 2; }
for fn in "$@"; do
  { cat "$WORK/suite.sh"; printf '%s\n' "$fn"; } > "$WORK/one.sh"
  bash "$WORK/one.sh" 2>&1 | grep -E '^(ok|not ok) ' || echo "not ok - $fn produced no result line"
done
