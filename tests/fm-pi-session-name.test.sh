#!/usr/bin/env bash
# Behavior tests for native Pi session names in Firstmate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
SYNC="$ROOT/bin/fm-session-name-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-session-name)

make_fakebin() {
  local dir=$1 fakebin pi_bin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_FAKE_DIR:?}
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" -eq 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /quit) printf 'zsh' > "$D/command" ;;
        *codex*'encode launch-brief'*) printf 'codex' > "$D/command" ;;
        *'encode launch-brief'*) printf 'pi' > "$D/command" ;;
      esac
    fi
    exit 0
    ;;
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) cat "$D/cwd"; printf '\n' ;;
      *'#{pane_current_command}'*) cat "$D/command"; printf '\n' ;;
      *'#{cursor_y}'*) printf '1\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0
    ;;
  list-windows)
    cat "$D/windows" 2>/dev/null || true
    exit 0
    ;;
  has-session|new-session|new-window|kill-window)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  for pi_bin in pi pi-signed; do
    cat > "$fakebin/$pi_bin" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf 'Usage: pi [options]\n  --tui-mode <mode>\n' ;;
  --version) printf '0.85.1\n' ;;
esac
exit 0
SH
    chmod +x "$fakebin/$pi_bin"
  done
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 harness=$2 id=$3 dir home proj wt fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf 'instructions for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf '%s' "$harness" > "$dir/fake/command"
  : > "$dir/fake/windows"
  : > "$dir/fake/literal"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 fake=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_DIR="$fake" FM_FAKE_PANE_PATH="$wt" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.1 FM_CONTROL_LAUNCH_WAIT=0.1 \
    TMUX="fake,1,0" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_control() {
  local home=$1 fakebin=$2 fake=$3
  shift 3
  FM_HOME="$home" FM_SPAWN_NO_GUARD=1 FM_FAKE_DIR="$fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.1 FM_CONTROL_LAUNCH_WAIT=0.1 \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$CONTROL" "$@" 2>&1
}

make_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

test_pi_launch_names_are_native_and_exact() {
  local rec id out status=0 launch name
  id=pi-name-explicit-z1
  name="restore O'Brien, c574!"
  rec=$(make_case explicit pi "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/fake" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --session-name "$name") || status=$?
  expect_code 0 "$status" "Pi spawn with an explicit native name"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report Pi"
  launch=$(tail -1 "$CASE_DIR/fake/literal")
  assert_contains "$launch" "--name 'restore O'\\''Brien, c574!' -e " \
    "Pi did not receive the exact native name before its extension"
  assert_grep "session_name=$name" "$HOME_DIR/state/$id.meta" \
    "Pi metadata does not contain the exact applied name"
  pass "Pi gets an exact native name with spaces and punctuation"
}

test_pi_worker_default_is_the_task_id() {
  local rec id out status=0 launch
  id=pi-name-default-z2
  rec=$(make_case default pi "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/fake" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off) || status=$?
  expect_code 0 "$status" "Pi spawn with its default native name"
  launch=$(tail -1 "$CASE_DIR/fake/literal")
  assert_contains "$launch" "--name '$id' -e " "Pi did not use the task id as its default name"
  assert_grep "session_name=$id" "$HOME_DIR/state/$id.meta" \
    "Pi metadata does not contain the default task name"
  pass "a Pi worker uses its task id as the native default name"
}

test_pi_signed_secondmate_uses_the_conventional_name() {
  local rec id sm out status=0 launch
  id=atlas-core
  rec=$(make_case secondmate pi-signed "$id")
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/fake" \
    "$id" "$sm" --secondmate) || status=$?
  expect_code 0 "$status" "Pi-signed second mate spawn"
  launch=$(tail -1 "$CASE_DIR/fake/literal")
  assert_contains "$launch" "--name 'Secondmate, $id' -e " \
    "Pi-signed did not receive the conventional second mate name"
  assert_grep "session_name=Secondmate, $id" "$HOME_DIR/state/$id.meta" \
    "Pi-signed metadata does not contain the second mate name"
  pass "Pi-signed uses the 'Secondmate, <id>' native name"
}

test_pi_relaunch_keeps_the_recorded_name() {
  local rec id out status=0 launch name
  id=pi-name-relaunch-z3
  name="restore O'Brien, c574!"
  rec=$(make_case relaunch pi "$id")
  read_case "$rec"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$WT_DIR"
    printf 'project=%s\n' "$PROJ_DIR"
    printf 'harness=pi\nkind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'tasktmp=/tmp/fm-%s\nmodel=default\neffort=default\n' "$id"
    printf 'session_name=%s\n' "$name"
  } > "$HOME_DIR/state/$id.meta"
  printf '%s\n' "fm-$id" > "$CASE_DIR/fake/windows"

  out=$(run_control "$HOME_DIR" "$FAKEBIN_DIR" "$CASE_DIR/fake" \
    "$id" relaunch --note "continue the named Pi task") || status=$?
  expect_code 0 "$status" "Pi relaunch with a recorded native name"
  launch=$(tail -1 "$CASE_DIR/fake/literal")
  assert_contains "$launch" "--name 'restore O'\\''Brien, c574!'" \
    "the replacement did not receive the recorded native name"
  assert_grep "session_name=$name" "$HOME_DIR/state/$id.meta" \
    "the replacement metadata lost the native name"
  [ "$(grep -c '^session_name=' "$HOME_DIR/state/$id.meta")" -eq 1 ] \
    || fail "the replacement metadata contains duplicate native names"
  pass "a Pi replacement keeps one exact native name"
}

test_pi_native_name_update_survives_relaunch() {
  local rec id name out status=0 launch
  id=pi-name-update-z5
  name="renamed O'Brien, c574!"
  rec=$(make_case update pi "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/fake" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off) || status=$?
  expect_code 0 "$status" "Pi spawn before a native name update"
  out=$(EXT="$HOME_DIR/state/$id.pi-ext.ts" FM_HOME="$HOME_DIR" NAME="$name" NODE_NO_WARNINGS=1 \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); } };
const extension = await import(`${pathToFileURL(process.env.EXT).href}?update=${Date.now()}`);
extension.default(pi);
await handlers.get("session_info_changed")({ name: process.env.NAME });
JS
  ) || status=$?
  expect_code 0 "$status" "Pi native name metadata synchronization"
  [ -z "$out" ] || fail "Pi native name synchronization printed output: $out"
  assert_grep "session_name=$name" "$HOME_DIR/state/$id.meta" \
    "a native Pi name update did not update task metadata"
  printf '%s\n' "fm-$id" > "$CASE_DIR/fake/windows"

  out=$(run_control "$HOME_DIR" "$FAKEBIN_DIR" "$CASE_DIR/fake" \
    "$id" relaunch --note "continue after native name update") || status=$?
  expect_code 0 "$status" "Pi relaunch after a native name update"
  launch=$(tail -1 "$CASE_DIR/fake/literal")
  assert_contains "$launch" "--name 'renamed O'\\''Brien, c574!'" \
    "the replacement did not receive the updated native name"
  pass "a native Pi name update survives recovery"
}

test_existing_pi_worker_name_update_survives_relaunch() {
  local rec id name out status=0 launch
  id=pi-name-existing-z6
  name="existing O'Brien, c574!"
  rec=$(make_case existing pi "$id")
  read_case "$rec"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$WT_DIR"
    printf 'project=%s\n' "$PROJ_DIR"
    printf 'harness=pi\nkind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'tasktmp=/tmp/fm-%s\nmodel=default\neffort=default\nspawn_gen=old\n' "$id"
  } > "$HOME_DIR/state/$id.meta"
  printf '%s\n' "fm-$id" > "$CASE_DIR/fake/windows"

  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$SYNC" "$id" "$name" 2>&1) || status=$?
  expect_code 0 "$status" "existing Pi worker name metadata synchronization"
  [ -z "$out" ] || fail "existing Pi name synchronization printed output: $out"
  assert_grep "session_name=$name" "$HOME_DIR/state/$id.meta" \
    "the existing worker name was not recorded"
  [ ! -s "$CASE_DIR/fake/literal" ] || fail "name metadata synchronization disturbed the worker pane"

  out=$(run_control "$HOME_DIR" "$FAKEBIN_DIR" "$CASE_DIR/fake" \
    "$id" relaunch --note "continue after existing worker name update") || status=$?
  expect_code 0 "$status" "Pi relaunch after existing worker name update"
  launch=$(tail -1 "$CASE_DIR/fake/literal")
  assert_contains "$launch" "--name 'existing O'\\''Brien, c574!'" \
    "the existing worker replacement did not receive the updated native name"
  pass "an existing Pi worker name update survives recovery"
}

test_switch_to_an_unnamed_harness_drops_stale_metadata() {
  local rec id out status=0 launch
  id=pi-name-switch-z4
  rec=$(make_case switch pi "$id")
  read_case "$rec"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$WT_DIR"
    printf 'project=%s\n' "$PROJ_DIR"
    printf 'harness=pi\nkind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'tasktmp=/tmp/fm-%s\nmodel=default\neffort=default\n' "$id"
    printf 'session_name=native Pi task\n'
  } > "$HOME_DIR/state/$id.meta"
  printf '%s\n' "fm-$id" > "$CASE_DIR/fake/windows"

  out=$(run_control "$HOME_DIR" "$FAKEBIN_DIR" "$CASE_DIR/fake" \
    "$id" relaunch --harness codex --note "continue on Codex") || status=$?
  expect_code 0 "$status" "switch from Pi to an unnamed harness"
  launch=$(tail -1 "$CASE_DIR/fake/literal")
  assert_not_contains "$launch" "--name" "Codex received Pi's native name flag"
  assert_no_grep "session_name=" "$HOME_DIR/state/$id.meta" \
    "Codex metadata kept a native name that was not applied"
  pass "an unnamed replacement harness drops stale native-name metadata"
}

run_primary_name_case() {
  local fixture=$1
  mkdir -p "$fixture/.pi/extensions/lib" "$fixture/state" "$fixture/bin"
  printf '# Firstmate\n' > "$fixture/AGENTS.md"
  printf '{"type":"module"}\n' > "$fixture/package.json"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$fixture/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$fixture/.pi/extensions/lib/"
  git -C "$fixture" init -q
  git -C "$fixture" config user.email test@example.invalid
  git -C "$fixture" config user.name test
  git -C "$fixture" add .
  git -C "$fixture" commit -qm fixture

  EXT="$fixture/.pi/extensions/fm-primary-turnend-guard.ts" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
    node --input-type=module 2>&1 <<'JS'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let currentName = "";
const appliedNames = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  getSessionName() { return currentName || undefined; },
  setSessionName(name) {
    appliedNames.push(name);
    currentName = name;
  },
  sendMessage() {},
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?session-name=${Date.now()}`);
extension.default(pi);
const reload = () => handlers.get("session_start")({ reason: "reload" }, {});

reload();
reload();
if (currentName !== "Firstmate") {
  throw new Error(`primary default was ${JSON.stringify(currentName)}`);
}
if (appliedNames.join("|") !== "Firstmate") {
  throw new Error(`primary repeated application changed the name: ${JSON.stringify(appliedNames)}`);
}

currentName = "Captain's explicit, v2!";
reload();
if (currentName !== "Captain's explicit, v2!" || appliedNames.length !== 1) {
  throw new Error("reload replaced an explicit primary name");
}

writeFileSync(`${process.env.FM_HOME}/.fm-secondmate-home`, "atlas-core\n");
currentName = "";
reload();
reload();
if (currentName !== "Secondmate, atlas-core") {
  throw new Error(`second mate default was ${JSON.stringify(currentName)}`);
}
if (appliedNames.join("|") !== "Firstmate|Secondmate, atlas-core") {
  throw new Error(`second mate repeated application changed the name: ${JSON.stringify(appliedNames)}`);
}
JS
}

test_primary_and_secondmate_names_are_safe_on_reload() {
  local fixture out status=0
  command -v node >/dev/null 2>&1 || {
    echo "skip: node not found for the Pi session-name test"
    return 0
  }
  fixture="$TMP_ROOT/reload"
  out=$(run_primary_name_case "$fixture") || status=$?
  expect_code 0 "$status" "Pi primary and second mate session naming"
  [ -z "$out" ] || fail "Pi session naming printed output: $out"
  pass "Pi names an unnamed primary or second mate once and preserves explicit names on reload"
}

test_unmanaged_worktree_keeps_its_unnamed_session() {
  local fixture unrelated out status=0
  command -v node >/dev/null 2>&1 || return 0
  fixture="$TMP_ROOT/unmanaged"
  run_primary_name_case "$fixture" || fail "could not prepare the primary fixture"
  unrelated="$fixture/unrelated"
  git -C "$fixture" worktree add -q "$unrelated"
  mkdir -p "$unrelated/state"

  out=$(EXT="$fixture/.pi/extensions/fm-primary-turnend-guard.ts" \
    FM_HOME="$unrelated" FM_ROOT_OVERRIDE="$fixture" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const appliedNames = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  getSessionName() { return undefined; },
  setSessionName(name) { appliedNames.push(name); },
  sendMessage() {},
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?unmanaged=${Date.now()}`);
extension.default(pi);
handlers.get("session_start")({ reason: "startup" }, {});
if (appliedNames.length) throw new Error(`unmanaged worktree was renamed: ${appliedNames}`);
JS
  ) || status=$?
  expect_code 0 "$status" "unmanaged Pi worktree session naming"
  [ -z "$out" ] || fail "unmanaged Pi naming printed output: $out"
  pass "an unmanaged linked worktree keeps its unnamed Pi session"
}

test_pi_launch_names_are_native_and_exact
test_pi_worker_default_is_the_task_id
test_pi_signed_secondmate_uses_the_conventional_name
test_pi_relaunch_keeps_the_recorded_name
test_pi_native_name_update_survives_relaunch
test_existing_pi_worker_name_update_survives_relaunch
test_switch_to_an_unnamed_harness_drops_stale_metadata
test_primary_and_secondmate_names_are_safe_on_reload
test_unmanaged_worktree_keeps_its_unnamed_session

echo "# all Pi session-name tests passed"
