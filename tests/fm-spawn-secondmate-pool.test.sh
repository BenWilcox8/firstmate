#!/usr/bin/env bash
# Regression tests for which Treehouse pool a ship or scout spawn draws from.
#
# Treehouse names a pool from the repository basename and origin URL alone, so
# two homes that each hold a clone of one project would share one pool, and a
# slot of that pool could be a worktree of the other home's clone. A spawn that
# took one was refused at Claude trust registration as "not a worktree of
# project". The fork gives every home, the root home included, its own pool
# root (bin/fm-wake-lib.sh fm_treehouse_home_root), and the spawn runs
# `treehouse get` with TREEHOUSE_ROOT set to it. These tests drive the real
# spawn path with a fake terminal that answers the typed
# `TREEHOUSE_ROOT='<root>' treehouse get` the way Treehouse does: it grows a
# slot from the pane's clone under that root. Any other form of the command
# leaves the pane where it was, so the spawn stops.
# Every case keeps its pool base under its own case folder, never the real
# ~/.treehouse.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# A worker pane from bin/fm-spawn.sh inherits its home's TREEHOUSE_ROOT.
unset TREEHOUSE_ROOT

TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-pool)

make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -s "$FM_FAKE_PANE_FILE" ]; then
      cat "$FM_FAKE_PANE_FILE"
    else
      printf '%s\n' "$FM_FAKE_PANE_PATH"
    fi
    exit 0
    ;;
esac
window_file="$(dirname "$0")/.spawn-window"
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -s "$window_file" ] || cat "$window_file"
    exit 0
    ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0
    ;;
  kill-window)
    : > "$window_file"
    exit 0
    ;;
  send-keys)
    text=${4:-}
    case "$text" in
      "TREEHOUSE_ROOT='"*"' treehouse get")
        printf '%s\n' "$text" >> "$FM_FAKE_TREEHOUSE_LOG"
        root=${text#"TREEHOUSE_ROOT='"}
        root=${root%"' treehouse get"}
        pool="$root/.treehouse/project-pool"
        slot="$pool/1/project"
        mkdir -p "$pool"
        printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
        git -C "$FM_FAKE_PANE_PATH" worktree add --quiet --detach "$slot" >/dev/null 2>&1 || exit 1
        printf '%s\n' "$slot" > "$FM_FAKE_PANE_FILE"
        ;;
      'treehouse'*|*'treehouse get'*)
        printf 'unexpected: %s\n' "$text" >> "$FM_FAKE_TREEHOUSE_LOG"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

make_origin() {  # <case-dir>
  local origin="$1/origin-src"
  fm_git_init_commit "$origin"
  fm_git_add_origin "$origin" "$1/origin.git"
}

make_root_home() {  # <case-dir>
  local case_dir=$1 main="$1/main-home"
  fm_test_spawn_home "$main" claude
  git clone --quiet "file://$case_dir/origin.git" "$main/projects/project"
}

make_mate_home() {  # <case-dir> <route>
  local case_dir=$1 route=$2 mate
  mate="$case_dir/mate-home"
  fm_test_spawn_home "$mate" claude
  git clone --quiet "file://$case_dir/origin.git" "$mate/projects/project"
  if [ "$route" = local ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
      "$case_dir/main-home" > "$mate/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=parent-machine\n' \
      > "$mate/.fm-secondmate-parent"
  fi
}

# The pool base of a case: every home's pool root sits under it.
homes_base_of() {  # <case-dir>
  printf '%s\n' "$1/homes-base"
}

# The home's pool root as bin/fm-treehouse.sh prints it, with the case's base.
home_root_of() {  # <case-dir> <home>
  local case_dir=$1 home=$2
  FM_HOME="$home" HOME="$case_dir/user-home" FM_STATE_OVERRIDE="$home/state" \
    FM_TREEHOUSE_HOMES_BASE="$(homes_base_of "$case_dir")" \
    "$ROOT/bin/fm-treehouse.sh" --print-root
}

run_pool_spawn() {  # <case-dir> <home> <id> [homes-base]
  local case_dir=$1 home=$2 id=$3 base=${4:-}
  [ -n "$base" ] || base=$(homes_base_of "$case_dir")
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/treehouse.log"
  rm -f "$case_dir/pane"
  FM_FAKE_PANE_FILE="$case_dir/pane" \
    FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    FM_TREEHOUSE_HOMES_BASE="$base" \
    fm_test_run_spawn "$home" "$home/projects/project" "$case_dir/fake/fakebin" \
    "$id" "$home/projects/project" --scout
}

common_dir_of() {
  CDPATH='' cd -- "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" && pwd -P
}

meta_worktree() {  # <home> <id>
  sed -n 's/^worktree=//p' "$1/state/$2.meta"
}

# fail unless <path> and none of its ancestors is the home or under it.
assert_outside_home() {  # <home> <path> <label>
  local home_real=$1 path=$2 label=$3 dir
  home_real=$(CDPATH='' cd -- "$home_real" && pwd -P)
  case "$path" in
    "$home_real"|"$home_real"/*) fail "$label $path is inside the firstmate home $home_real" ;;
  esac
  dir=$path
  while [ -n "$dir" ] && [ "$dir" != / ]; do
    if [ -e "$dir/CLAUDE.md" ] || [ -L "$dir/CLAUDE.md" ] ||
      [ -e "$dir/AGENTS.md" ] || [ -L "$dir/AGENTS.md" ]; then
      case "$dir" in
        "$home_real"|"$home_real"/*) fail "ancestor $dir of $label $path holds the home's CLAUDE.md or AGENTS.md" ;;
      esac
    fi
    dir=$(dirname "$dir")
  done
}

test_local_secondmate_spawns_from_its_own_pool_outside_the_home() {
  local case_dir id out status wt mate root
  case_dir="$TMP_ROOT/local-mate"
  id='mate-pool-own-clone-s1'
  make_pool_fakebin "$case_dir/fake" >/dev/null
  make_origin "$case_dir"
  make_root_home "$case_dir"
  make_mate_home "$case_dir" local
  mate="$case_dir/mate-home"
  printf '%s\n' '@AGENTS.md' > "$mate/CLAUDE.md"
  printf '%s\n' '# secondmate supervisor contract' > "$mate/AGENTS.md"
  root=$(home_root_of "$case_dir" "$mate") || fail "could not resolve the secondmate home's pool root"
  [ -n "$root" ] || fail "a local secondmate pool root was empty"
  assert_outside_home "$mate" "$root" "pool root"

  out=$(run_pool_spawn "$case_dir" "$mate" "$id")
  status=$?
  expect_code 0 "$status" "a local secondmate spawn should launch from its own clone's pool"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the secondmate spawn did not report success"
  assert_not_contains "$out" "not a worktree of project" \
    "the secondmate spawn was handed another clone's slot"
  [ "$(cat "$case_dir/treehouse.log")" = "TREEHOUSE_ROOT='$root' treehouse get" ] \
    || fail "the secondmate spawn did not root its pool in the home's own root: $(cat "$case_dir/treehouse.log")"
  wt=$(meta_worktree "$mate" "$id")
  case "$wt" in
    "$root/"*) ;;
    *) fail "the secondmate spawn recorded a worktree outside its own pool: $wt" ;;
  esac
  assert_outside_home "$mate" "$wt" "slot"
  [ "$(common_dir_of "$wt")" = "$(common_dir_of "$mate/projects/project")" ] \
    || fail "the secondmate slot is not a worktree of the secondmate's own clone"
  [ -f "$(dirname "$wt")/.fm-slot-owner" ] \
    || fail "the secondmate spawn did not claim its own pool slot"
  pass "a local secondmate spawn takes its slot from its own clone's pool, outside the home"
}

test_root_home_spawns_from_its_own_pool() {
  local case_dir id out status main root wt
  case_dir="$TMP_ROOT/root-home"
  id='main-pool-own-s2'
  make_pool_fakebin "$case_dir/fake" >/dev/null
  make_origin "$case_dir"
  make_root_home "$case_dir"
  make_mate_home "$case_dir" local
  main="$case_dir/main-home"
  root=$(home_root_of "$case_dir" "$main") || fail "could not resolve the root home's pool root"
  [ "$root" != "$(home_root_of "$case_dir" "$case_dir/mate-home")" ] \
    || fail "the root home and a secondmate home resolved the same pool root $root"

  out=$(run_pool_spawn "$case_dir" "$main" "$id")
  status=$?
  expect_code 0 "$status" "a root-home spawn should launch from its own pool"$'\n'"$out"
  [ "$(cat "$case_dir/treehouse.log")" = "TREEHOUSE_ROOT='$root' treehouse get" ] \
    || fail "the root-home spawn did not use its own pool root: $(cat "$case_dir/treehouse.log")"
  wt=$(meta_worktree "$main" "$id")
  case "$wt" in
    "$root/"*) ;;
    *) fail "the root-home spawn recorded a worktree outside its own pool: $wt" ;;
  esac
  assert_outside_home "$main" "$wt" "slot"
  pass "a root-home spawn takes its slot from the root home's own pool, apart from a secondmate's"
}

test_remote_seeded_home_spawns_from_its_own_pool() {
  local case_dir id out status mate main root wt
  case_dir="$TMP_ROOT/remote-mate"
  id='remote-pool-own-s3'
  make_pool_fakebin "$case_dir/fake" >/dev/null
  make_origin "$case_dir"
  make_root_home "$case_dir"
  make_mate_home "$case_dir" remote
  mate="$case_dir/mate-home"
  main="$case_dir/main-home"
  root=$(home_root_of "$case_dir" "$mate") || fail "could not resolve the remote-seeded home's pool root"
  [ "$root" != "$(home_root_of "$case_dir" "$main")" ] \
    || fail "a remote-seeded home resolved the root home's pool root $root"

  out=$(run_pool_spawn "$case_dir" "$mate" "$id")
  status=$?
  expect_code 0 "$status" "a remote-seeded home's spawn should launch from its own pool"$'\n'"$out"
  assert_not_contains "$out" "not a worktree of project" \
    "the remote-seeded spawn was handed another clone's slot"
  [ "$(cat "$case_dir/treehouse.log")" = "TREEHOUSE_ROOT='$root' treehouse get" ] \
    || fail "a remote-seeded home did not use its own pool root: $(cat "$case_dir/treehouse.log")"
  wt=$(meta_worktree "$mate" "$id")
  case "$wt" in
    "$root/"*) ;;
    *) fail "the remote-seeded spawn recorded a worktree outside its own pool: $wt" ;;
  esac
  [ "$(common_dir_of "$wt")" = "$(common_dir_of "$mate/projects/project")" ] \
    || fail "the remote-seeded slot is not a worktree of the home's own clone"
  pass "a remote-seeded home spawns from its own pool, apart from the root home's"
}

test_pool_base_under_the_home_is_refused() {
  local case_dir id out status mate root
  case_dir="$TMP_ROOT/under-home-base"
  id='mate-pool-refused-s4'
  make_pool_fakebin "$case_dir/fake" >/dev/null
  make_origin "$case_dir"
  make_root_home "$case_dir"
  make_mate_home "$case_dir" local
  mate="$case_dir/mate-home"
  mkdir -p "$mate/inside"

  root=
  status=0
  root=$(FM_HOME="$mate" FM_TREEHOUSE_HOMES_BASE="$mate/inside" \
    bash -c '. "$1" && fm_treehouse_home_root "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$mate") || status=$?
  [ "$status" -ne 0 ] || fail "a pool base under the home was accepted: $root"
  [ -z "$root" ] || fail "a refused pool root still printed: $root"

  out=$(run_pool_spawn "$case_dir" "$mate" "$id" "$mate/inside")
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn with a pool base under the home went on"$'\n'"$out"
  assert_contains "$out" "could not resolve this home's own Treehouse root" \
    "the refused spawn did not name the unresolved pool root"
  [ ! -s "$case_dir/treehouse.log" ] || fail "a refused spawn still ran treehouse: $(cat "$case_dir/treehouse.log")"
  [ ! -e "$mate/state/$id.meta" ] || fail "a refused spawn published task metadata"
  pass "a pool base that resolves inside the home is refused and the spawn stops"
}

test_local_secondmate_spawns_from_its_own_pool_outside_the_home
test_root_home_spawns_from_its_own_pool
test_remote_seeded_home_spawns_from_its_own_pool
test_pool_base_under_the_home_is_refused

echo "# all fm-spawn-secondmate-pool tests passed"
