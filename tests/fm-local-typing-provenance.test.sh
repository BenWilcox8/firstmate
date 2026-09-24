#!/usr/bin/env bash
# Behavior coverage for the typing-provenance-* fork seams.
# Drive fm-spawn, fm-control exit, and the away-mode daemon digest through a
# fake tmux pane and inspect the public provenance JSONL they leave behind.
# docs/local/send-provenance.schema.json owns the record format.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-typing-provenance)

# Fake tmux: every literal payload is appended to $FM_FAKE_DIR/literal as
# NUL-terminated bytes, and the last one is kept exactly in $FM_FAKE_DIR/typed.
# The pane is always an idle agent with an empty composer.
make_fakebin() {  # <dir> -> echoes fakebin
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "$*" in
  *"#{pane_current_path}"*) cat "$D/cwd"; printf '\n'; exit 0 ;;
  *"#{pane_current_command}"*) cat "$D/command"; printf '\n'; exit 0 ;;
  *"#{pane_id}"*) printf '%%9\n'; exit 0 ;;
  *cursor_y*) if [ -f "$D/cursor-y" ]; then cat "$D/cursor-y"; else printf '1\n'; fi; exit 0 ;;
esac
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
    if [ "$literal" = 1 ]; then
      printf '%s' "$1" > "$D/typed"
      printf '%s\0' "$1" >> "$D/literal"
      case "$1" in /exit) printf 'zsh' > "$D/command" ;; esac
    fi
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane)
    if [ -f "$D/pane" ]; then cat "$D/pane"; else printf '╭────╮\n│    │\n╰────╯\n'; fi; exit 0 ;;
  list-windows) [ ! -f "$D/windows" ] || cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/sleep"
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

records() {  # <state>
  cat "$1"/local-send-provenance/*.jsonl 2>/dev/null || true
}

record_count() {  # <state>
  records "$1" | grep -c . || true
}

# assert_record <state> <count> <kind> <task-or-empty> <sha256> <target> <pane>
assert_record() {
  local got
  got=$(record_count "$1")
  [ "$got" = "$2" ] || fail "expected $2 provenance records, found $got: $(records "$1")"
  records "$1" | tail -n 1 | jq -e \
    --arg kind "$3" --arg task "$4" --arg sha "$5" --arg target "$6" --arg pane "$7" --arg home "$FM_CASE_HOME" '
      .version == 1 and .delivery_kind == $kind and .sha256 == $sha
      and .endpoint == {backend: "tmux", target: $target, pane_id: $pane,
                        task_id: (if $task == "" then null else $task end)}
      and .sender_home == $home and (has("text") | not)
    ' >/dev/null || fail "unexpected provenance record for $3: $(records "$1" | tail -n 1)"
}

sha_of_file() { sha256sum "$1" | cut -d' ' -f1; }

# --- fm-spawn: the launch prompt --------------------------------------------

spawn_home() {  # <harness> -> sets SPAWN_DIR SPAWN_HOME SPAWN_PROJ SPAWN_WT SPAWN_FB SPAWN_ID
  local dir="$TMP_ROOT/spawn-$1" home proj wt fb id="$1-z1"
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$dir/fake" "$home/user-home"
  fb=$(make_fakebin "$dir/fake")
  printf "%s\n" "$1" > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$1"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf 'zsh' > "$dir/fake/command"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Launch with "quotes", a $HOME reference, and a snowman ☃.

## Firstmate spec
Record the launch prompt.
EOF
  SPAWN_DIR=$dir SPAWN_HOME=$home SPAWN_PROJ=$proj SPAWN_WT=$wt SPAWN_FB=$fb SPAWN_ID=$id
  FM_CASE_HOME=$(cd "$home" && pwd -P)
}

run_spawn() {
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$SPAWN_HOME" HOME="$SPAWN_HOME/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$SPAWN_HOME/state" FM_DATA_OVERRIDE="$SPAWN_HOME/data" \
    FM_PROJECTS_OVERRIDE="$SPAWN_HOME/projects" FM_CONFIG_OVERRIDE="$SPAWN_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_DIR="$SPAWN_DIR/fake" PATH="$SPAWN_FB:$PATH" \
    FM_KIMI_READY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    "$ROOT/bin/fm-spawn.sh" "$SPAWN_ID" "$SPAWN_PROJ" --mode no-mistakes --yolo off \
    > "$SPAWN_DIR/out" 2>&1 || fail "fm-spawn failed: $(cat "$SPAWN_DIR/out")"
}

spawn_case() {
  local dir home wt fb id
  spawn_home claude
  dir=$SPAWN_DIR home=$SPAWN_HOME wt=$SPAWN_WT fb=$SPAWN_FB id=$SPAWN_ID
  # The fake agent records the prompt argument it was launched with.
  cat > "$fb/claude" <<SH
#!/usr/bin/env bash
printf '%s' "\${@: -1}" > '$dir/fake/agent-prompt'
SH
  chmod +x "$fb/claude"
  run_spawn
  # Run the typed launch line the way the pane shell would, so the hash is
  # checked against the prompt the agent actually receives.
  (cd "$wt" && PATH="$fb:$PATH" bash -c "$(cat "$dir/fake/typed")") \
    || fail 'typed launch line did not run'
  [ -s "$dir/fake/agent-prompt" ] || fail 'fake agent received no launch prompt'
  grep -q 'snowman ☃' "$dir/fake/agent-prompt" || fail 'launch prompt does not carry the brief'
  assert_record "$home/state" 1 launch-prompt "$id" "$(sha_of_file "$dir/fake/agent-prompt")" "$(sed -n 's/^window=//p' "$home/state/$id.meta")" '%9'
  pass 'typing-provenance-launch: the launch prompt writes one record matching the prompt the agent receives'
}

kimi_case() {
  local dir home id
  if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    printf 'ok - SKIP typing-provenance-launch kimi pointer: python3 with tomllib is not installed\n'
    return 0
  fi
  spawn_home kimi
  dir=$SPAWN_DIR home=$SPAWN_HOME id=$SPAWN_ID
  fm_fake_exit0 "$SPAWN_FB" kimi
  mkdir -p "$home/user-home/.kimi-code"
  printf 'default_model = "test"\n' > "$home/user-home/.kimi-code/config.toml"
  # The pane echoes the submitted pointer, which is how fm-spawn confirms delivery.
  printf '✨ Read the brief at the launch brief\ncontext: 1%% (2k/256k)\n╭────────╮\n│ >      │\n╰────────╯\n' > "$dir/fake/pane"
  printf '3\n' > "$dir/fake/cursor-y"
  run_spawn
  case "$(cat "$dir/fake/typed")" in
    "Read the brief at "*) ;;
    *) fail "kimi typed '$(cat "$dir/fake/typed")' instead of the brief pointer" ;;
  esac
  assert_record "$home/state" 1 launch-prompt "$id" "$(sha_of_file "$dir/fake/typed")" "$(sed -n 's/^window=//p' "$home/state/$id.meta")" '%9'
  pass 'typing-provenance-launch: a brief pointer typed after launch writes one record and the bare launch line none'
}

# --- fm-control: the harness exit command -----------------------------------

control_case() {
  local dir="$TMP_ROOT/control" home fb wt id=t1 typed_count
  home="$dir/home"; wt="$dir/wt"
  mkdir -p "$home/state" "$home/data/$id" "$dir/fake"
  fb=$(make_fakebin "$dir/fake")
  fm_git_worktree "$dir/proj" "$wt" task-t1
  printf '# brief\n' > "$home/data/$id/brief.md"
  fm_write_meta "$home/state/$id.meta" "window=fmses:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$dir/proj" harness=claude kind=ship mode=no-mistakes yolo=off
  printf 'fm-%s\n' "$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf 'claude' > "$dir/fake/command"
  FM_CASE_HOME=$(cd "$home" && pwd -P)
  env PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.05 \
    "$ROOT/bin/fm-control.sh" "$id" exit > "$dir/out" 2>&1 \
    || fail "fm-control exit failed: $(cat "$dir/out")"
  [ "$(cat "$dir/fake/typed")" = /exit ] || fail "exit typed '$(cat "$dir/fake/typed")' instead of /exit"
  typed_count=$(tr -cd "\\0" < "$dir/fake/literal" | wc -c | tr -d " ")
  [ "$typed_count" = 1 ] || fail "exit typed $typed_count literals"
  assert_record "$home/state" 1 exit-command "$id" \
    "$(sha_of_file "$dir/fake/typed")" "fmses:fm-$id" '%9'
  pass 'typing-provenance-exit: the exit command keeps its bytes and writes one record'
}

# --- away-mode supervise daemon: the digest into the supervisor pane --------

daemon_case() {
  local dir="$TMP_ROOT/daemon" home fb
  home="$dir/home"
  mkdir -p "$home/state" "$dir/fake"
  fb=$(make_fakebin "$dir/fake")
  printf 'claude' > "$dir/fake/command"
  : > "$dir/fake/cwd"
  FM_CASE_HOME=$(cd "$home" && pwd -P)
  (
    export PATH="$fb:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_FAKE_DIR="$dir/fake" FM_SUPERVISOR_TARGET=sup:0 FM_SUPERVISOR_BACKEND=tmux \
      FM_INJECT_CONFIRM_SLEEP=0
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-supervise-daemon.sh"
    afk_enter "$home/state"
    inject_msg 'captain: the digest ☃' "$home/state"
  ) || fail 'daemon did not deliver the digest'
  grep -q 'the digest ☃' "$dir/fake/typed" || fail "daemon typed '$(cat "$dir/fake/typed")'"
  assert_record "$home/state" 1 supervision-digest '' "$(sha_of_file "$dir/fake/typed")" sup:0 '%9'
  pass 'typing-provenance-digest: the supervisor digest keeps its bytes and writes one record'
}

spawn_case
kimi_case
control_case
daemon_case
