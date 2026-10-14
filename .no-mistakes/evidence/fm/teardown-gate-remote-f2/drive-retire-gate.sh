#!/usr/bin/env bash
# Drive the real bin/fm-local-retire-reassigned.sh CLI through the colocated
# fixture builders in tests/fm-local-cleanup-slot.test.sh (slot owner process,
# live task holding the slot, old finished ship record), with the script under
# test taken from <root-under-test>.
# Usage: drive-retire-gate.sh <helpers-root> <root-under-test> <label>
set -eu
HELPERS_ROOT=$1
UNDER_TEST=$2
LABEL=$3
WORK=$(mktemp -d /tmp/fm-f2-retire.XXXXXX)
# Load the suite's fixture functions without its bottom-of-file invocation list.
sed -e '/^test_[a-z_]*$/d' \
    -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$HELPERS_ROOT/tests/lib.sh#" \
    "$HELPERS_ROOT/tests/fm-local-cleanup-slot.test.sh" > "$WORK/suite-functions.sh"
# shellcheck disable=SC1091
. "$WORK/suite-functions.sh"
trap 'stop_fixture_processes; rm -rf "$WORK"' EXIT
ROOT=$UNDER_TEST

report() { # scenario rc
  echo "  \$ fm-local-retire-reassigned.sh old --live-task live   -> exit $2"
  sed 's#^#    stderr| #' "$CASE/err" | head -3
  if git -C "$CASE/project" show-ref --verify --quiet refs/heads/fm/old; then
    echo "  after: fm/old branch KEPT"
  else
    echo "  after: fm/old branch GONE"
  fi
  [ -e "$CASE/home/state/old.meta" ] && echo "  after: old record still ACTIVE" || echo "  after: old record RETIRED (archived)"
  echo "  RESULT: $([ "$2" = 0 ] && echo RETIRED || echo REFUSED)"
}

old_ship_commit_on() { # remotes...
  perl -pi -e 's/kind=scout/kind=ship/; s/mode=local-only/mode=no-mistakes/' "$CASE/home/state/old.meta"
  rm "$WT/sentinel"
  git -C "$WT" checkout -q fm/old
  git -C "$WT" commit -qm "old ship work" --allow-empty
  local r
  for r in "$@"; do
    git init -q --bare "$CASE/$r.git"
    git -C "$CASE/project" remote add "$r" "$CASE/$r.git"
    git -C "$WT" push -q "$r" fm/old
    git -C "$CASE/project" fetch -q "$r"
  done
  git -C "$WT" checkout -q fm/live
}

printf '\n=== [%s] R1 retire a finished no-mistakes ship whose fm/old reached only the no-mistakes gate\n' "$LABEL"
make_collision r1-gate-only
old_ship_commit_on no-mistakes
git -C "$CASE/project" for-each-ref --contains fm/old --format='  ref holding fm/old: %(refname)' refs/remotes
rc=0; run_retire > "$CASE/out" 2> "$CASE/err" || rc=$?
report r1 "$rc"

printf '\n=== [%s] R2 retire a finished no-mistakes ship whose fm/old is on the gate and on origin\n' "$LABEL"
make_collision r2-gate-and-origin
old_ship_commit_on no-mistakes origin
git -C "$CASE/project" for-each-ref --contains fm/old --format='  ref holding fm/old: %(refname)' refs/remotes
rc=0; run_retire > "$CASE/out" 2> "$CASE/err" || rc=$?
report r2 "$rc"

printf '\n=== [%s] R3 colocated refusal matrix test_retirement_refusals_preserve_records\n' "$LABEL"
test_retirement_refusals_preserve_records 2>&1
