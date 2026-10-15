#!/usr/bin/env bash
# Live driver for F1 (--no-live-owner retirement) and F3 (archived backlog row
# closes). It runs the real bin/ scripts of a given checkout against throwaway
# Firstmate homes under /tmp: real git repos and worktrees, a real tasks-axi
# markdown backlog with its done archive, and a real tmux server isolated in a
# private TMUX_TMPDIR. It never reads or writes the live fleet: FM_HOME is
# always a fixture home, TMUX is unset, and a guard `treehouse` on PATH logs
# and fails so no real pool can be touched.
# Usage: live-driver.sh <checkout-root> <transcript-file> [only-case...]
set -u
ROOT=$(cd "${1:?checkout root}" && pwd -P)
OUT=${2:?transcript file}
shift 2
ONLY=" $* "
L=$(mktemp -d /tmp/fm-live-f1f3.XXXXXX)
L=$(cd "$L" && pwd -P)
export LC_ALL=C
unset NO_MISTAKES_GATE TMUX ATLAS_REPO SPECS_REPO FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
export TMUX_TMPDIR=$L/tmux
export ATLAS_AXI_DASH=http://127.0.0.1:1
export GIT_AUTHOR_NAME=live GIT_AUTHOR_EMAIL=live@example.invalid
export GIT_COMMITTER_NAME=live GIT_COMMITTER_EMAIL=live@example.invalid
export HOME=$L/user-home
mkdir -p "$TMUX_TMPDIR" "$HOME"
: > "$OUT"
PASSES=0 FAILS=0
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$L"; }
trap cleanup EXIT

log() { printf '%s\n' "$*" >> "$OUT"; }
ok() { PASSES=$((PASSES + 1)); log "  CHECK ok: $*"; }
bad() { FAILS=$((FAILS + 1)); log "  CHECK FAILED: $*"; }
check() { local label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
want() { [ -n "${ONLY// /}" ] || return 0; case "$ONLY" in *" $1 "*) return 0 ;; esac; return 1; }
meta() { local f=$1; shift; : > "$f"; for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done; }

# Run one real command with the fixture environment and record a transcript.
run() {  # <label> <home> <command...>
  local label=$1 home=$2 rc=0
  shift 2
  log "\$ FM_HOME=${home#"$L"/} ${*#"$ROOT"/}"
  (cd "$L" && env FM_HOME="$home" FM_TEARDOWN_GUARD_DONE=1 PATH="$C/guardbin:$PATH" "$@") > "$C/run.out" 2>&1 || rc=$?
  sed "s#$L/##g; s#$ROOT/##g" "$C/run.out" | sed 's/^/  | /' >> "$OUT"
  log "  exit=$rc"
  RC=$rc
  RUN_OUT=$(cat "$C/run.out")
}

agent_state() {  # <session:window>
  (cd "$L" && bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "$1")
}

# One Treehouse-shaped pool slot named by an older landed local-only ship
# record and a newer finished scout record that has its own branch and an
# untracked scratch file checked out in the slot. No worker runs: the pool
# lease carries no owner, the old window is gone, and the newer window is an
# idle shell. The old task's backlog row is in flight.
make_slot_case() {  # <name> [newer-home]
  C=$L/$1
  SESSION=s-$1
  local newer_home=${2:-$C/home}
  mkdir -p "$C/home/state" "$C/home/data" "$C/home/config" "$C/guardbin" "$newer_home/state" "$newer_home/data"
  touch "$C/home/state/.last-watcher-beat"
  printf 'claude\n' > "$C/home/config/crew-harness"
  printf '#!/usr/bin/env bash\nprintf "treehouse %%s\\n" "$*" >> "%s/guard.log"\nexit 1\n' "$C" > "$C/guardbin/treehouse"
  chmod +x "$C/guardbin/treehouse"
  git init -q -b main "$C/project"
  git -C "$C/project" commit -qm baseline --allow-empty
  git -C "$C/project" checkout -qb fm/old
  printf 'feature\n' > "$C/project/feature.txt"
  git -C "$C/project" add feature.txt
  git -C "$C/project" commit -qm 'old ship: add feature'
  git -C "$C/project" checkout -q main
  git -C "$C/project" merge -q --no-ff fm/old -m 'land fm/old locally'
  POOLDIR=$C/treehouse/project-1a2b3c
  WT=$POOLDIR/16/project
  mkdir -p "$POOLDIR/16"
  git -C "$C/project" worktree add -q -b fm/newer "$WT" main
  printf 'scout scratch notes\n' > "$WT/scratch-notes.md"
  POOL=$POOLDIR/treehouse-state.json
  printf '{"worktrees":[{"name":"16","path":"%s","created_at":"2026-09-30T10:00:00-05:00"}]}\n' "$WT" > "$POOL"
  OLD_META=$C/home/state/old.meta
  meta "$OLD_META" "window=$SESSION:fm-old" "endpoint_task_id=old" "worktree=$WT" "project=$C/project" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" "spawn_gen=s1760000000.4101.1"
  printf 'done: shipped feature to local main\n' > "$C/home/state/old.status"
  NEWER_META=$newer_home/state/newer.meta
  meta "$NEWER_META" "window=$SESSION:fm-newer" "endpoint_task_id=newer" "worktree=$WT" "project=$C/project" \
    "harness=claude" "kind=scout" "yolo=off" "spawn_gen=s1760500000.5202.2"
  printf 'done: scouted\n' > "$newer_home/state/newer.status"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n' > "$C/home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$C/home/data/backlog.md"
  (cd "$C/home" && tasks-axi add old 'Ship the feature' --kind ship --file data/backlog.md >/dev/null \
    && tasks-axi start old --file data/backlog.md >/dev/null)
  tmux new-session -d -s "$SESSION" -n keep bash
  tmux new-window -d -t "$SESSION:" -n fm-newer bash
  sleep 0.3
}

register_mate() {  # <mate-home>
  printf -- '- research - research second mate (home: %s; scope: research; projects: project; added 2026-10-01)\n' "$1" \
    > "$C/home/data/secondmates.md"
  printf 'research\n' > "$1/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$C/home" > "$1/.fm-secondmate-parent"
}

snapshot() {  # <file>
  {
    printf 'newer.meta %s\n' "$(sha256sum < "$NEWER_META")"
    printf 'pool %s\n' "$(sha256sum < "$POOL")"
    printf 'fm/old %s\n' "$(git -C "$C/project" rev-parse fm/old 2>&1)"
    printf 'fm/newer %s\n' "$(git -C "$C/project" rev-parse fm/newer 2>&1)"
    printf 'slot-branch %s\n' "$(git -C "$WT" branch --show-current)"
    printf 'slot-status %s\n' "$(git -C "$WT" status --porcelain --untracked-files=all | tr '\n' ' ')"
    printf 'scratch %s\n' "$(cat "$WT/scratch-notes.md")"
    printf 'windows %s\n' "$(tmux list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' ')"
  } > "$1"
}

old_meta_snapshot() { sha256sum < "$OLD_META"; }

assert_retired() {
  check 'retire exited 0' [ "$RC" = 0 ]
  check 'old record no longer active' [ ! -e "$OLD_META" ]
  check 'old record archived under data/old/retired-reassigned' [ -f "$C/home/data/old/retired-reassigned/old.meta" ]
  check 'old status archived' [ -f "$C/home/data/old/retired-reassigned/old.status" ]
  snapshot "$C/after"
  if cmp -s "$C/before" "$C/after"; then ok 'slot, pool lease, branches, newer record, scratch file, and tmux windows unchanged'
  else bad "slot state changed: $(diff "$C/before" "$C/after" | tr '\n' ' ')"; fi
  check 'guard treehouse never invoked' [ ! -e "$C/guard.log" ]
  check 'no backlog-close marker left' [ ! -e "$C/home/state/old.backlog-close" ]
  log "  after: $(sed "s#$L/##g" "$C/after" | tr '\n' ';')"
}

assert_refused() {  # <expected message fragment>
  check 'command refused (nonzero exit)' [ "$RC" != 0 ]
  case "$RUN_OUT" in *"$1"*) ok "refusal names: $1" ;; *) bad "refusal does not name: $1" ;; esac
  check 'old record still active and unchanged' [ "$(old_meta_snapshot)" = "$OLD_BEFORE" ]
  check 'nothing archived' [ ! -e "$C/home/data/old/retired-reassigned/old.meta" ]
  snapshot "$C/after"
  if cmp -s "$C/before" "$C/after"; then ok 'slot, pool lease, branches, newer record, and tmux windows unchanged'
  else bad "slot state changed: $(diff "$C/before" "$C/after" | tr '\n' ' ')"; fi
  check 'guard treehouse never invoked' [ ! -e "$C/guard.log" ]
}

retire() { run "$1" "$C/home" "$ROOT/bin/fm-local-retire-reassigned.sh" old "${@:2}"; }
begin() { log ''; log "=== $1"; }
prepare() { snapshot "$C/before"; OLD_BEFORE=$(old_meta_snapshot); }

if want help; then
  C=$L/help; mkdir -p "$C/guardbin"
  begin 'help: the retire command documents --no-live-owner'
  run help "$L" "$ROOT/bin/fm-local-retire-reassigned.sh" --help
  case "$RUN_OUT" in *'--no-live-owner'*) ok 'help names --no-live-owner' ;; *) bad 'help lacks --no-live-owner' ;; esac
fi

if want same-home; then
  make_slot_case same-home
  begin 'F1 same-home: teardown refuses the shared slot and points at the retire tool'
  log "  endpoint states: old=$(agent_state "$SESSION:fm-old") newer=$(agent_state "$SESSION:fm-newer")"
  prepare
  run teardown "$C/home" "$ROOT/bin/fm-teardown.sh" old
  assert_refused "is also task newer's recorded worktree"
  case "$RUN_OUT" in *'fm-local-retire-reassigned.sh'*) ok 'teardown refusal hints at fm-local-retire-reassigned.sh' ;; *) bad 'teardown refusal has no retire hint' ;; esac
  run teardown-force "$C/home" "$ROOT/bin/fm-teardown.sh" old --force
  assert_refused 'not even with --force'
  begin 'F1 same-home: --no-live-owner retires the older finished record and closes its row'
  retire retire --no-live-owner
  assert_retired
  case "$RUN_OUT" in *'retired old; slot '*' and its newer records unchanged'*) ok 'success line names the preserved slot' ;; *) bad 'unexpected success line' ;; esac
  state=$(cd "$C/home" && tasks-axi show old --file data/backlog.md 2>/dev/null | sed -n 's/^  state: *//p' | head -1)
  check "backlog row closed (state=$state)" [ "$state" = done ]
  check 'newer record still active' [ -f "$NEWER_META" ]
  begin 'F1 same-home: the newer record still refuses retirement (it is now the newest claimant)'
  OLD_META=$NEWER_META
  run retire-newer "$C/home" "$ROOT/bin/fm-local-retire-reassigned.sh" newer --no-live-owner
  check 'newer retire refused' [ "$RC" != 0 ]
  case "$RUN_OUT" in *'newest claimant'*|*'scout'*|*'report'*) ok "newer refused: $(printf '%s' "$RUN_OUT" | tail -1)" ;; *) bad 'newer refused for unexpected reason' ;; esac
fi

if want secondmate-home; then
  make_slot_case secondmate-home "$L/secondmate-home/mate"
  register_mate "$L/secondmate-home/mate"
  begin 'F1 cross-home: the newer claimant lives in a registered local secondmate home'
  log "  endpoint states: old=$(agent_state "$SESSION:fm-old") newer=$(agent_state "$SESSION:fm-newer")"
  prepare
  run teardown "$C/home" "$ROOT/bin/fm-teardown.sh" old
  assert_refused "is also task newer's recorded worktree"
  retire retire --no-live-owner
  assert_retired
fi

if want archived-row; then
  make_slot_case archived-row
  (cd "$C/home" && tasks-axi "done" old --keep 0 --file data/backlog.md >/dev/null)
  begin 'F1+F3: --no-live-owner retirement of a record whose row retention already archived'
  log "  archive before: $(grep -F -- '- [x] old -' "$C/home/data/done-archive.md")"
  log "  live backlog show: $(cd "$C/home" && tasks-axi show old --file data/backlog.md 2>&1 | head -2 | tr '\n' ' ')"
  prepare
  retire retire --no-live-owner
  assert_retired
  check 'archived entry still present' grep -qF -- '- [x] old -' "$C/home/data/done-archive.md"
  check 'row not restored into the live backlog' bash -c '! grep -qF -- "- [x] old -" "$1"' _ "$C/home/data/backlog.md"
fi

if want legacy-claimant; then
  make_slot_case legacy-claimant
  meta "$C/home/state/legacy.meta" "window=$SESSION:fm-legacy" "endpoint_task_id=legacy" "worktree=$WT" \
    "project=$C/project" "harness=claude" "kind=ship" "spawn_gen="
  printf 'done: legacy\n' > "$C/home/state/legacy.status"
  begin 'F1: a dead legacy claimant with an empty spawn_gen is skipped for ordering'
  prepare
  retire retire --no-live-owner
  assert_retired
fi

if want exited-owner; then
  make_slot_case exited-owner
  pid=$(bash -c 'printf "%s\n" "$$"')
  jq --argjson pid "$pid" '.worktrees[0] += {owner_pid: $pid, owner_started_at: 1760000000000}' "$POOL" > "$POOL.new" && mv "$POOL.new" "$POOL"
  begin "F1: a recorded pool owner pid $pid that /proc shows exited does not block retirement"
  prepare
  retire retire --no-live-owner
  assert_retired
fi

# Adversarial refusals: each must refuse and change nothing.
refusal_case() {  # <name> <description> <expected> <setup-function>
  if want "$1"; then
    make_slot_case "$1"
    "$4"
    begin "F1 guard: $2"
    log "  endpoint states: old=$(agent_state "$SESSION:fm-old") newer=$(agent_state "$SESSION:fm-newer")"
    prepare
    retire retire --no-live-owner ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    assert_refused "$3"
    EXTRA_ARGS=()
  fi
}
EXTRA_ARGS=()
# A stand-in agent: a script whose process name is `claude`, as the harness
# process appears to the tmux backend's foreground-process classifier.
fake_agent() {  # <window>
  mkdir -p "$L/agentbin"
  printf '#!%s\nwhile :; do sleep 1000; done\n' "$(command -v bash)" > "$L/agentbin/claude"
  chmod +x "$L/agentbin/claude"
  tmux new-window -d -t "$SESSION:" -n "$1" "$L/agentbin/claude"
  sleep 0.5
}
setup_live_newer() { tmux kill-window -t "$SESSION:fm-newer"; fake_agent fm-newer; }
setup_live_old() { fake_agent fm-old; }
setup_newest() { perl -pi -e 's/^spawn_gen=.*/spawn_gen=s1760900000.4101.1/' "$OLD_META"; }
setup_same_epoch() { perl -pi -e 's/^spawn_gen=.*/spawn_gen=s1760500000.9.9/' "$OLD_META"; }
setup_sole() { rm "$NEWER_META" "$C/home/state/newer.status"; NEWER_META=$C/home/state/.none; : > "$NEWER_META"; }
setup_running_owner() {
  sleep 100000 &
  OWNER_SLEEP=$!
  sleep 0.2
  local ticks btime hz started
  ticks=$(awk '{sub(/.*\) /, ""); print $20}' "/proc/$OWNER_SLEEP/stat")
  btime=$(awk '$1 == "btime" {print $2}' /proc/stat)
  hz=$(getconf CLK_TCK)
  started=$((btime * 1000 + ticks * 1000 / hz))
  jq --argjson pid "$OWNER_SLEEP" --argjson s "$started" '.worktrees[0] += {owner_pid: $pid, owner_started_at: $s}' "$POOL" > "$POOL.new" && mv "$POOL.new" "$POOL"
}
setup_unlanded() {
  git -C "$C/project" checkout -q fm/old
  printf 'more\n' >> "$C/project/feature.txt"
  git -C "$C/project" commit -qam 'old ship: unlanded follow-up'
  git -C "$C/project" checkout -q main
}
setup_claim_mine() { printf 'task=old\nhome=%s\n' "$C/home" > "$POOLDIR/16/.fm-slot-owner"; }
setup_with_live_task() { EXTRA_ARGS=(--live-task newer); }
setup_live_mate() {
  local mate=$L/live-mate/mate
  mkdir -p "$mate/state" "$mate/data"
  mv "$NEWER_META" "$mate/state/newer.meta"; mv "$C/home/state/newer.status" "$mate/state/newer.status"
  NEWER_META=$mate/state/newer.meta
  register_mate "$mate"
  setup_live_newer
}

refusal_case live-newer 'the newer claimant endpoint is a live agent' 'slot record newer does not have a confidently dead or missing endpoint' setup_live_newer
refusal_case live-old 'the old record endpoint is still a live agent' 'slot record old does not have a confidently dead or missing endpoint' setup_live_old
refusal_case live-mate 'the newer claimant in a registered secondmate home is a live agent' 'slot record newer does not have a confidently dead or missing endpoint' setup_live_mate
refusal_case newest 'the old record is the newest claimant by spawn_gen' 'newest claimant' setup_newest
refusal_case same-epoch 'the old and newer records share a spawn_gen epoch' 'newest claimant' setup_same_epoch
refusal_case sole 'no other record names the slot' 'newest claimant' setup_sole
refusal_case running-owner 'the recorded Treehouse pool owner process is still running' 'pool slot owner process is still running' setup_running_owner
refusal_case unlanded 'the old ship branch has a commit that is not on local main' 'old task branch has unlanded work' setup_unlanded
refusal_case claim-mine 'the slot-owner claim still names the old task' 'claim still names this task' setup_claim_mine
refusal_case with-live-task '--no-live-owner combined with --live-task' 'takes no live task' setup_with_live_task
[ -z "${OWNER_SLEEP:-}" ] || kill "$OWNER_SLEEP" 2>/dev/null || true

# The shared local-home scan (moved into fm-secondmate-registry-lib.sh) must
# refuse a partial scan in both callers with the same message.
setup_malformed_registry() { printf -- '- broken entry without a home\n' > "$C/home/data/secondmates.md"; }
setup_missing_mate() { mkdir -p "$L/gone-mate/mate"; register_mate "$L/gone-mate/mate"; rm -rf "$L/gone-mate"; }
if want malformed-registry; then
  make_slot_case malformed-registry
  setup_malformed_registry
  begin 'shared scan: a malformed registry entry refuses teardown and --no-live-owner alike'
  prepare
  run teardown "$C/home" "$ROOT/bin/fm-teardown.sh" old
  assert_refused 'malformed local Firstmate registry entry'
  retire retire --no-live-owner
  assert_refused 'malformed local Firstmate registry entry'
fi
if want missing-mate; then
  make_slot_case missing-mate
  setup_missing_mate
  begin 'shared scan: an unavailable registered local home refuses teardown and --no-live-owner alike'
  prepare
  run teardown "$C/home" "$ROOT/bin/fm-teardown.sh" old
  assert_refused 'registered local Firstmate home is unavailable'
  retire retire --no-live-owner
  assert_refused 'registered local Firstmate home is unavailable'
fi

# F3 through normal teardown: a finished local-only ship whose backlog row
# retention already moved into data/done-archive.md.
make_teardown_case() {  # <name>
  C=$L/$1
  SESSION=s-$1
  mkdir -p "$C/home/state" "$C/home/data" "$C/home/config" "$C/guardbin"
  touch "$C/home/state/.last-watcher-beat"
  printf 'claude\n' > "$C/home/config/crew-harness"
  printf '#!/usr/bin/env bash\nprintf "treehouse %%s\\n" "$*" >> "%s/guard.log"\nexit 1\n' "$C" > "$C/guardbin/treehouse"
  chmod +x "$C/guardbin/treehouse"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$C/home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$C/home/data/backlog.md"
  meta "$C/home/state/$2.meta" "window=$SESSION:fm-$2" "endpoint_task_id=$2" "worktree=$C/absent-worktree" \
    "project=$C/absent-project" "harness=claude" "kind=ship" "mode=local-only" "yolo=off" "spawn_gen=s1760000000.1.1"
  printf 'done: shipped\n' > "$C/home/state/$2.status"
  tmux new-session -d -s "$SESSION" -n keep bash
}

if want teardown-archived; then
  make_teardown_case teardown-archived arch
  (cd "$C/home" && tasks-axi add arch 'Archived ship' --kind ship --file data/backlog.md >/dev/null \
    && tasks-axi start arch --file data/backlog.md >/dev/null \
    && tasks-axi "done" arch --keep 0 --file data/backlog.md >/dev/null)
  begin 'F3 teardown: a row already in the done archive counts as closed'
  log "  archive: $(grep -F -- '- [x] arch -' "$C/home/data/done-archive.md")"
  log "  tasks-axi show (live backlog): $(cd "$C/home" && tasks-axi show arch --file data/backlog.md 2>&1 | head -2 | tr '\n' ' ')"
  run teardown "$C/home" "$ROOT/bin/fm-teardown.sh" arch
  check 'teardown exited 0' [ "$RC" = 0 ]
  check 'task record removed' [ ! -e "$C/home/state/arch.meta" ]
  check 'no backlog-close marker owed' [ ! -e "$C/home/state/arch.backlog-close" ]
  check 'archived entry intact' grep -qF -- '- [x] arch -' "$C/home/data/done-archive.md"
  check 'row not restored into the live backlog' bash -c '! grep -qF -- "arch -" "$1"' _ "$C/home/data/backlog.md"
fi

if want teardown-open-archive; then
  make_teardown_case teardown-open-archive opn
  printf '\n## Archived 2026-10-14\n- [x] other-opn - unrelated (done 2026-10-14)\n- [ ] opn - never finished\n' > "$C/home/data/done-archive.md"
  begin 'F3 guard: a row absent from the backlog and not Done in the archive still fails loudly'
  run teardown "$C/home" "$ROOT/bin/fm-teardown.sh" opn
  check 'teardown refused (nonzero exit)' [ "$RC" != 0 ]
  case "$RUN_OUT" in *'not found'*|*'NOT_FOUND'*) ok 'error still names the missing row' ;; *) bad 'error hides the missing row' ;; esac
  check 'backlog-close marker retained for replay' [ -e "$C/home/state/opn.backlog-close" ]
fi

log ''
log "SUMMARY: $PASSES checks ok, $FAILS checks failed"
printf 'SUMMARY: %s checks ok, %s checks failed\n' "$PASSES" "$FAILS"
[ "$FAILS" = 0 ]
