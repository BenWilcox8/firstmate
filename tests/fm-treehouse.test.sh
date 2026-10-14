#!/usr/bin/env bash
# Behavior tests for fm-treehouse.sh and the per-home Treehouse root it shares
# with fm-spawn.sh: each home resolves its own stable root outside the home, the
# run form hands treehouse that root from the project directory, and with a real
# treehouse two homes' clones of one origin never share a pool while a slot from
# the old shared pool still returns by path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-treehouse.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse)
USER_HOME="$TMP_ROOT/user-home"
mkdir -p "$USER_HOME"

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

print_root() {  # <home>
  FM_HOME="$1" HOME="$USER_HOME" FM_STATE_OVERRIDE="$1/state" "$HELPER" --print-root
}

test_root_is_per_home_and_stable() {
  local a b a_again link a_link
  a=$(make_home home-a)
  b=$(make_home home-b)
  a_root=$(print_root "$a") || fail "--print-root failed for home A"
  b_root=$(print_root "$b") || fail "--print-root failed for home B"
  a_again=$(print_root "$a") || fail "--print-root failed again for home A"
  case "$a_root" in
    "$USER_HOME/.treehouse/firstmate-homes/"?*) ;;
    *) fail "home A root '$a_root' is not under the user-level treehouse store" ;;
  esac
  case "$a_root" in
    "$a"/*) fail "home A root '$a_root' must not sit inside the home" ;;
  esac
  [ "$a_root" = "$a_again" ] || fail "home A root is not stable: '$a_root' then '$a_again'"
  [ "$a_root" != "$b_root" ] || fail "two homes resolved the same Treehouse root '$a_root'"
  link="$TMP_ROOT/home-a-link"
  ln -s "$a" "$link"
  a_link=$(print_root "$link") || fail "--print-root failed through a symlinked home path"
  [ "$a_link" = "$a_root" ] || fail "a symlinked path to home A resolved '$a_link', not '$a_root'"
  pass "fm-treehouse: each home resolves its own stable root outside the home"
}

test_run_form_passes_root_and_project() {
  local home proj fakebin log root out
  home=$(make_home home-run)
  proj="$home/projects/alpha"
  mkdir -p "$proj"
  fakebin=$(fm_fakebin "$TMP_ROOT/run-fake")
  log="$TMP_ROOT/run.log"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "\$(pwd -P)"; printf 'root=%s\n' "\${TREEHOUSE_ROOT:-}"; printf 'args=%s\n' "\$*"; } > "$log"
SH
  chmod +x "$fakebin/treehouse"
  root=$(print_root "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" HOME="$USER_HOME" FM_STATE_OVERRIDE="$home/state" \
    "$HELPER" "$proj" status --json >/dev/null || fail "run form failed"
  grep -Fx "cwd=$(cd "$proj" && pwd -P)" "$log" >/dev/null || fail "treehouse did not run from the project: $(cat "$log")"
  grep -Fx "root=$root" "$log" >/dev/null || fail "treehouse did not receive this home's root: $(cat "$log")"
  grep -Fx "args=status --json" "$log" >/dev/null || fail "treehouse arguments were not passed through: $(cat "$log")"

  out=$(FM_HOME="$home" HOME="$USER_HOME" FM_STATE_OVERRIDE="$home/state" "$HELPER" 2>&1); status=$?
  expect_code 2 "$status" "no arguments must be a usage error"
  assert_contains "$out" "usage:" "no arguments must print usage"
  out=$(FM_HOME="$home" HOME="$USER_HOME" FM_STATE_OVERRIDE="$home/state" "$HELPER" "$proj" 2>&1); status=$?
  expect_code 2 "$status" "a project without treehouse arguments must be a usage error"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" HOME="$USER_HOME" FM_STATE_OVERRIDE="$home/state" \
    "$HELPER" "$home/projects/missing" status 2>&1); status=$?
  expect_code 1 "$status" "a missing project directory must refuse"
  assert_contains "$out" "does not exist" "a missing project directory must be named"
  pass "fm-treehouse: the run form gives treehouse this home's root from the project directory"
}

git_quiet() {
  GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1 git "$@" >/dev/null 2>&1
}

# Real treehouse: the guarantee comes from treehouse's own pool resolution, so
# only the installed tool can prove it. Last, because the gate exits on a skip.
test_real_treehouse_pools_per_home() {
  fm_live_gate default-on FM_LIVE_TREEHOUSE treehouse
  if ! treehouse get --help 2>&1 | grep -Fq TREEHOUSE_ROOT; then
    printf 'skip: live: installed treehouse %s does not read TREEHOUSE_ROOT\n' "$(treehouse --version 2>/dev/null)"
    return 0
  fi
  local origin seed a b root_a root_b old slot_a slot_b common
  export GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.email t@example.invalid
  git config --global user.name test
  git config --global init.defaultBranch main
  origin="$TMP_ROOT/origin.git"
  seed="$TMP_ROOT/seed"
  git_quiet init --bare "$origin" || fail "could not create the origin"
  git_quiet clone "$origin" "$seed" || fail "could not clone the seed"
  printf 'x\n' > "$seed/f"
  git_quiet -C "$seed" add f && git_quiet -C "$seed" commit -m init \
    && git_quiet -C "$seed" push origin main || fail "could not seed the origin"
  a=$(make_home live-a)
  b=$(make_home live-b)
  git_quiet clone "$origin" "$a/projects/proj" || fail "could not clone into home A"
  git_quiet clone "$origin" "$b/projects/proj" || fail "could not clone into home B"
  root_a=$(print_root "$a")
  root_b=$(print_root "$b")

  # A slot taken the old way, in the shared per-origin pool.
  old=$(cd "$a/projects/proj" && HOME="$USER_HOME" treehouse get --lease --no-fetch 2>/dev/null) \
    || fail "could not take a slot in the shared pool"
  slot_a=$(cd "$a/projects/proj" && HOME="$USER_HOME" TREEHOUSE_ROOT=$root_a treehouse get --lease --no-fetch 2>/dev/null) \
    || fail "home A could not take a slot from its own pool"
  slot_b=$(cd "$b/projects/proj" && HOME="$USER_HOME" TREEHOUSE_ROOT=$root_b treehouse get --lease --no-fetch 2>/dev/null) \
    || fail "home B could not take a slot from its own pool"
  case "$slot_a" in "$root_a"/*) ;; *) fail "home A slot '$slot_a' is outside its root '$root_a'" ;; esac
  case "$slot_b" in "$root_b"/*) ;; *) fail "home B slot '$slot_b' is outside its root '$root_b'" ;; esac
  common=$(git -C "$slot_b" rev-parse --path-format=absolute --git-common-dir)
  [ "$(cd "$common" && pwd -P)" = "$(cd "$b/projects/proj/.git" && pwd -P)" ] \
    || fail "home B's slot belongs to another clone: $common"

  # Cleanup returns by path with no TREEHOUSE_ROOT, as bin/fm-teardown.sh does.
  (cd "$a/projects/proj" && HOME="$USER_HOME" treehouse return --force "$slot_a" >/dev/null 2>&1) \
    || fail "a per-home slot did not return by path"
  (cd "$a/projects/proj" && HOME="$USER_HOME" treehouse return --force "$old" >/dev/null 2>&1) \
    || fail "a slot from the old shared pool did not return by path"

  # Home A's idle slot never reaches home B: B reuses only its own pool.
  (cd "$b/projects/proj" && HOME="$USER_HOME" treehouse return --force "$slot_b" >/dev/null 2>&1) \
    || fail "home B's slot did not return by path"
  slot_b=$(cd "$b/projects/proj" && HOME="$USER_HOME" TREEHOUSE_ROOT=$root_b treehouse get --lease --no-fetch 2>/dev/null) \
    || fail "home B could not take a slot again"
  common=$(git -C "$slot_b" rev-parse --path-format=absolute --git-common-dir)
  [ "$(cd "$common" && pwd -P)" = "$(cd "$b/projects/proj/.git" && pwd -P)" ] \
    || fail "home B was handed another clone's slot: $slot_b ($common)"
  pass "fm-treehouse: real treehouse keeps two homes' clones of one origin in separate pools"
}

test_root_is_per_home_and_stable
test_run_form_passes_root_and_project
test_real_treehouse_pools_per_home
