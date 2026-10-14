#!/usr/bin/env bash
# Drive the real bin/fm-teardown.sh CLI against throwaway git fixtures that carry
# a real bare-repo remote named `no-mistakes` (the name `no-mistakes init` gives
# the local validation gate). Prints a transcript per scenario.
# Usage: drive-teardown-gate.sh <helpers-root> <root-under-test> <label>
#   helpers-root    firstmate checkout whose tests/lib.sh supplies fixture helpers
#   root-under-test firstmate tree whose bin/fm-teardown.sh is exercised
# Only tmux, treehouse, gh/gh-axi and the no-mistakes binary are stubbed, so no
# live session, slot, forge, or gate is touched. Git and the teardown script are real.
set -u
HELPERS_ROOT=$1
UNDER_TEST=$2
LABEL=$3
# shellcheck disable=SC1091
. "$HELPERS_ROOT/tests/lib.sh"
fm_git_identity drive drive@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-f2-drive)
TEARDOWN="$UNDER_TEST/bin/fm-teardown.sh"

make_fixture() {
  local name=$1 c fb
  c="$TMP_ROOT/$name"; fb="$c/fakebin"
  mkdir -p "$c/state" "$c/config" "$c/data" "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb"/*
  git init -q --bare "$c/origin.git"
  git -C "$c/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$c/origin.git" "$c/_seed" 2>/dev/null
  git -C "$c/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$c/_seed" push -q origin main
  rm -rf "$c/_seed"
  git clone -q "$c/origin.git" "$c/project"
  git -C "$c/project" remote set-head origin main 2>/dev/null || true
  git -C "$c/project" worktree add -q -b fm/task-x1 "$c/wt" main
  # The local validation gate: a bare repo on this machine, registered under the
  # remote name `no-mistakes`, exactly like a real `no-mistakes init` project.
  git init -q --bare "$c/gate.git"
  git -C "$c/project" remote add no-mistakes "$c/gate.git"
  touch "$c/state/.last-watcher-beat"
  fm_write_meta "$c/state/task-x1.meta" "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" "worktree=$c/wt" "project=$c/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=drive-task-x1"
  printf '%s\n' "$c"
}

commit_file() { # case file content msg
  printf '%s\n' "$3" > "$1/wt/$2"
  git -C "$1/wt" add -- "$2"
  git -C "$1/wt" commit -q -m "$4"
}

gh_merged_pr() { # case pr-head
  cat > "$1/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
esac
exit 0
SH
  cat > "$1/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED '$2' https://github.com/example/repo/pull/7 ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$2' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$1/fakebin/gh-axi" "$1/fakebin/gh"
}

show_refs() {
  local c=$1
  echo "  remote-tracking refs holding HEAD:"
  git -C "$c/wt" for-each-ref --contains HEAD --format='    %(refname)' refs/remotes | sed 's#^#  #' || true
  echo "  old check  (git log HEAD --not --remotes):                 $(git -C "$c/wt" log --oneline HEAD --not --remotes -- | wc -l) unlanded commit(s)"
  echo "  new check  (git log HEAD --not --exclude='no-mistakes/*' --remotes): $(git -C "$c/wt" log --oneline HEAD --not --exclude='no-mistakes/*' --remotes -- | wc -l) unlanded commit(s)"
}

run_and_report() {
  local c=$1 rc=0
  FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$UNDER_TEST" FM_STATE_OVERRIDE="$c/state" \
    FM_DATA_OVERRIDE="$c/data" FM_CONFIG_OVERRIDE="$c/config" FM_BACKEND_HERDR_AXI_BIN='' \
    PATH="$c/fakebin:$PATH" "$TEARDOWN" task-x1 > "$c/stdout" 2> "$c/stderr" || rc=$?
  echo "  \$ fm-teardown.sh task-x1   -> exit $rc"
  grep -E 'REFUSED|unpushed commits|^[0-9a-f]{7,} ' "$c/stderr" | sed 's#^#    stderr| #' || true
  [ "$rc" = 0 ] && grep -m2 -E 'Backlog:|torn down|Teardown' "$c/stdout" | sed 's#^#    stdout| #' || true
  if git -C "$c/project" show-ref --verify --quiet refs/heads/fm/task-x1; then
    echo "  after: task branch fm/task-x1 KEPT at $(git -C "$c/project" rev-parse --short refs/heads/fm/task-x1)"
  else
    echo "  after: task branch fm/task-x1 DELETED"
  fi
  [ -e "$c/state/task-x1.meta" ] && echo "  after: task record KEPT" || echo "  after: task record REMOVED"
  echo "  RESULT: $([ "$rc" = 0 ] && echo ALLOWED || echo REFUSED)"
}

banner() { printf '\n=== [%s] %s\n' "$LABEL" "$1"; }

# A: the reported bug - commits only on the local gate, nowhere on a forge.
banner "A gate-only: task commit pushed only to the no-mistakes gate"
c=$(make_fixture a-gate-only)
commit_file "$c" feature.txt hello "gate-only work"
git -C "$c/wt" push -q no-mistakes fm/task-x1
git -C "$c/project" fetch -q no-mistakes
show_refs "$c"; run_and_report "$c"

# A2: same, with a deeply nested gate branch name (glob must cross slashes).
banner "A2 gate-only on nested branch name fm/deep/nested/task-x1"
c=$(make_fixture a2-gate-nested)
commit_file "$c" feature.txt hello "gate-only nested"
git -C "$c/wt" push -q no-mistakes HEAD:refs/heads/fm/deep/nested/task-x1
git -C "$c/project" fetch -q no-mistakes
show_refs "$c"; run_and_report "$c"

# B: commit on both gate and origin - landed, must still be allowed.
banner "B gate + origin: same commit on the gate and on origin"
c=$(make_fixture b-gate-and-origin)
commit_file "$c" feature.txt hello "shipped work"
git -C "$c/wt" push -q no-mistakes fm/task-x1
git -C "$c/wt" push -q origin fm/task-x1
git -C "$c/project" fetch -q no-mistakes; git -C "$c/project" fetch -q origin
show_refs "$c"; run_and_report "$c"

# C1: the normal no-mistakes life cycle after a squash merge: the task branch sits
# on the gate, the PR merged, origin deleted its head branch. Merged PR head == HEAD.
banner "C1 normal flow: gate holds branch, PR merged (head == local HEAD), origin head branch deleted"
c=$(make_fixture c1-merged-pr)
commit_file "$c" feature.txt hello "add feature"
git -C "$c/wt" push -q no-mistakes fm/task-x1
git -C "$c/wt" push -q origin fm/task-x1
git -C "$c/project" fetch -q no-mistakes; git -C "$c/project" fetch -q origin
printf 'pr=https://github.com/example/repo/pull/7\n' >> "$c/state/task-x1.meta"
gh_merged_pr "$c" "$(git -C "$c/wt" rev-parse HEAD)"
git -C "$c/origin.git" branch -q -D fm/task-x1
git -C "$c/project" fetch -q --prune origin
show_refs "$c"; run_and_report "$c"

# C2: same flow, GitHub silent (no PR found), squash content already in origin/main.
banner "C2 normal flow: gate holds branch, no PR answer, squash content already in origin/main"
c=$(make_fixture c2-content-in-main)
commit_file "$c" feature.txt hello "add feature"
git -C "$c/wt" push -q no-mistakes fm/task-x1
git -C "$c/project" fetch -q no-mistakes
git clone -q "$c/origin.git" "$c/_land"
printf 'hello\n' > "$c/_land/feature.txt"; git -C "$c/_land" add feature.txt
git -C "$c/_land" commit -q -m "squash: add feature (#7)"; git -C "$c/_land" push -q origin HEAD:main
rm -rf "$c/_land"
show_refs "$c"; run_and_report "$c"

# D: merged PR covers the later commit, but the parent commit reached only the gate.
banner "D merged PR with a parent commit found only on the gate"
c=$(make_fixture d-gate-parent)
commit_file "$c" local-parent.txt parent "gate-only parent"
git -C "$c/wt" push -q no-mistakes "HEAD:refs/heads/fm/task-x1"
git -C "$c/project" fetch -q no-mistakes
commit_file "$c" feature.txt hello "add feature"
printf 'pr=https://github.com/example/repo/pull/7\n' >> "$c/state/task-x1.meta"
git clone -q "$c/origin.git" "$c/_eq"
printf 'hello\n' > "$c/_eq/feature.txt"; git -C "$c/_eq" add feature.txt
git -C "$c/_eq" commit -q -m "add feature"; git -C "$c/_eq" push -q origin HEAD:refs/heads/pr-head
rm -rf "$c/_eq"
git -C "$c/project" fetch -q origin pr-head
gh_merged_pr "$c" "$(git -C "$c/project" rev-parse refs/remotes/origin/pr-head)"
show_refs "$c"; run_and_report "$c"

# E1: a different remote whose name merely starts with no-mistakes is a real remote.
banner "E1 adversarial: commit only on a remote named no-mistakes-mirror (not the gate)"
c=$(make_fixture e1-lookalike-remote)
commit_file "$c" feature.txt hello "mirror work"
git init -q --bare "$c/mirror.git"
git -C "$c/project" remote add no-mistakes-mirror "$c/mirror.git"
git -C "$c/wt" push -q no-mistakes-mirror fm/task-x1
git -C "$c/project" fetch -q no-mistakes-mirror
show_refs "$c"; run_and_report "$c"

# E2: origin holds the commit under a branch named no-mistakes/... - still origin.
banner "E2 adversarial: origin holds the commit under branch name no-mistakes/fm/task-x1"
c=$(make_fixture e2-origin-branch-named-gate)
commit_file "$c" feature.txt hello "origin work"
git -C "$c/wt" push -q origin HEAD:refs/heads/no-mistakes/fm/task-x1
git -C "$c/project" fetch -q origin
show_refs "$c"; run_and_report "$c"
