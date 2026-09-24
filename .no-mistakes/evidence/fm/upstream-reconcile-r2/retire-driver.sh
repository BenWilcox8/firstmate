#!/usr/bin/env bash
# Live driver: run bin/fm-local-retire-reassigned.sh against a fixture home built
# by the cleanup-slot test helpers, and show the operator-visible transcript.
. "$(dirname "$0")/retire-driver-lib.sh"
show() { echo "--- $1"; (cd "$CASE/home" && find state data -name "$2" 2>/dev/null | sort | while read -r f; do if [ -L "$f" ]; then echo "$f -> symlink"; else echo "$f: $(cat "$f" 2>/dev/null)"; fi; done); }

echo "=== Scenario A: landed ship retire archives merge-authority and progress"
make_collision landed-ship
perl -pi -e 's/kind=scout/kind=ship/' "$CASE/home/state/old.meta"
rm "$WT/sentinel"
printf 'old authority\n' > "$CASE/home/state/old.merge-authority"
printf 'old progress\n' > "$CASE/home/state/old.progress"
printf 'live authority\n' > "$CASE/home/state/live.merge-authority"
printf 'live progress\n' > "$CASE/home/state/live.progress"
show "before" '*.merge-authority'; show "before" '*.progress'
echo "\$ fm-local-retire-reassigned.sh old --live-task live"
rc=0; run_retire > "$CASE/out" 2> "$CASE/err" || rc=$?
echo "rc=$rc"; sed 's/^/stdout: /' "$CASE/out"; sed 's/^/stderr: /' "$CASE/err"
show "after" '*.merge-authority'; show "after" '*.progress'

echo
echo "=== Scenario B (adversarial): symlinked old.merge-authority must refuse and keep records"
make_collision symlink-authority
perl -pi -e 's/kind=scout/kind=ship/' "$CASE/home/state/old.meta"
rm "$WT/sentinel"
printf 'elsewhere\n' > "$CASE/outside-authority"
ln -s "$CASE/outside-authority" "$CASE/home/state/old.merge-authority"
printf 'old progress\n' > "$CASE/home/state/old.progress"
echo "\$ fm-local-retire-reassigned.sh old --live-task live"
rc=0; run_retire > "$CASE/out" 2> "$CASE/err" || rc=$?
echo "rc=$rc"; sed 's/^/stdout: /' "$CASE/out"; sed 's/^/stderr: /' "$CASE/err"
show "after" '*.merge-authority'; show "after" '*.progress'
[ -f "$CASE/home/state/old.meta" ] && echo "old.meta retained: yes" || echo "old.meta retained: NO"
echo "outside target content: $(cat "$CASE/outside-authority")"

echo
echo "=== Scenario C (adversarial): directory at old.progress must refuse"
make_collision dir-progress
perl -pi -e 's/kind=scout/kind=ship/' "$CASE/home/state/old.meta"
rm "$WT/sentinel"
mkdir "$CASE/home/state/old.progress"
rc=0; run_retire > "$CASE/out" 2> "$CASE/err" || rc=$?
echo "rc=$rc"; sed 's/^/stderr: /' "$CASE/err"
[ -f "$CASE/home/state/old.meta" ] && echo "old.meta retained: yes" || echo "old.meta retained: NO"
