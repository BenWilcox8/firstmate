#!/usr/bin/env bash
# Adversarial drive of the watcher-lock contention cases: start the FIRST
# contender (or the mutex contender) of each case 2.5 s late, the way a loaded
# host can schedule one late. The old fixed holds (sleep 1 / sleep 2) let that
# late contender find a dead-pid lock and reclaim it; the new hold waits until
# every contender has tried. Runs copies of tests/fm-watcher-lock.test.sh from
# the base and target trees, cut down to the three contention cases only.
set -u
ROOT=$1
S=$(mktemp -d /tmp/fm-r3-late.XXXXXX)
cat > "$S/bash_env" <<'SH'
# Delay only lock contenders: bash -c programs that call fm_lock_try_acquire on
# a case's .contend.lock. One per case (mkdir is the once-guard).
case "${BASH_EXECUTION_STRING:-}" in
  *fm_lock_try_acquire*)
    case "${2:-}" in
      */.contend.lock)
        case "${BASH_EXECUTION_STRING}" in *'.steal" || exit 7'*) ;; *)
          mkdir "$R3_LATE/$(basename "$(dirname "$(dirname "$2")")")" 2>/dev/null && sleep 2.5 ;;
        esac ;;
    esac ;;
esac
SH
cases='test_lock_single_winner_under_concurrency test_lock_stale_steal_single_winner_under_concurrency test_lock_live_steal_mutex_is_not_reclaimed'
for rev in 2812e3cb HEAD; do
  T=$(mktemp -d /tmp/fm-r3-late-tree.XXXXXX)
  git -C "$ROOT" archive "$rev" | tar -x -C "$T"
  f="$T/tests/fm-watcher-lock.test.sh"
  # Keep every definition; replace the call list at the end with the 3 cases.
  first=$(grep -n '^test_wait_deadline_reaps_a_stopped_child$' "$f" | tail -1 | cut -d: -f1)
  head -n $((first - 1)) "$f" > "$f.cut"; for c in $cases; do echo "$c" >> "$f.cut"; done; mv "$f.cut" "$f"
  mkdir -p "$S/late-$rev"
  echo "== $rev ($(git -C "$ROOT" rev-parse --short "$rev")): contention cases, first contender of each case 2.5 s late; load $(cut -d' ' -f1-3 /proc/loadavg)"
  (cd "$T" && BASH_ENV="$S/bash_env" R3_LATE="$S/late-$rev" timeout 300 bash tests/fm-watcher-lock.test.sh 2>&1 | grep -E '^(ok|not ok)|winner|wins' | head -8; echo "[suite exit ${PIPESTATUS[0]}]")
  echo "late contenders delayed: $(ls "$S/late-$rev" | wc -l) ($(ls "$S/late-$rev" | tr '\n' ' '))"
  echo
  rm -rf "$T"
done
rm -rf "$S"
