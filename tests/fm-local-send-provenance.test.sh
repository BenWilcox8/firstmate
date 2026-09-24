#!/usr/bin/env bash
# Behavior coverage for the send-provenance-* fork seams.
# Drive fm-send through a literal tmux transport and inspect its public JSONL.
# shellcheck disable=SC2016
# Each adapter deliberately uses its own FM_HOME in a subshell.
# shellcheck disable=SC2030,SC2031
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-send-provenance)
mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/home/state"
export PROVENANCE_TEST_ROOT="$TMP_ROOT"
cat > "$TMP_ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  send-keys)
    if [ "${4:-}" = -l ]; then
      [ "${TEST_TYPE_FAIL:-0}" = 0 ] || exit 1
      printf '%s' "$5" > "$PROVENANCE_TEST_ROOT/typed"
      printf '.\n' >> "$PROVENANCE_TEST_ROOT/type-count"
    elif [ "${TEST_ENTER_FAIL:-0}" = 1 ]; then
      exit 1
    fi ;;
  display-message)
    case "$*" in *cursor_y*) printf '1\n' ;; *) printf '%%7\n' ;; esac ;;
  capture-pane)
    if [ "${TEST_PENDING:-0}" = 1 ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi ;;
  list-windows) printf 'win\n' ;;
esac
SH
cat > "$TMP_ROOT/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/fakebin/"*
export PATH="$TMP_ROOT/fakebin:$PATH"
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT/home" FM_SEND_SETTLE=0
fm_write_meta "$FM_HOME/state/worker.meta" 'window=sess:win' 'kind=ship' 'harness=codex'

send() {
  "$ROOT/bin/fm-send.sh" "$@" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
}

assert_record() { # <kind> <task-id> <count>
  python3 - "$FM_HOME/state" "$TMP_ROOT/typed" "$1" "$2" "$3" "$FM_HOME" <<'PY'
import datetime, hashlib, json, pathlib, sys
state, typed, kind, task, count, sender = sys.argv[1:]
records = [json.loads(line) for file in sorted(pathlib.Path(state).glob('local-send-provenance/*.jsonl')) for line in file.read_text().splitlines()]
assert len(records) == int(count), (len(records), count)
record = records[-1]
assert record['version'] == 1
assert record['sha256'] == hashlib.sha256(pathlib.Path(typed).read_bytes()).hexdigest(), record
assert record['endpoint'] == {'backend': 'tmux', 'target': 'sess:win', 'pane_id': '%7', 'task_id': task or None}, record
assert record['sender_home'] == sender, record
assert record['delivery_kind'] == kind, record
now = datetime.datetime.now(datetime.timezone.utc)
assert abs((now - datetime.datetime.fromisoformat(record['time'])).total_seconds()) < 60
assert 'text' not in record, record
PY
}

send worker '$no-mistakes'
printf '%s' '$no-mistakes' > "$TMP_ROOT/expected"
cmp "$TMP_ROOT/expected" "$TMP_ROOT/typed" || fail 'native skill bytes changed'
assert_record native-skill worker 1
pass 'send-provenance-context and send-provenance-tmux: native skill keeps bytes and writes one record'

send worker '/no-mistakes'
assert_record native-skill worker 2
send sess:win $'literal "quotes" \\ $HOME ☃\n'
printf '%s' $'literal "quotes" \\ $HOME ☃\n' > "$TMP_ROOT/expected"
cmp "$TMP_ROOT/expected" "$TMP_ROOT/typed" || fail 'explicit text bytes changed'
assert_record explicit-endpoint worker 3
pass 'explicit endpoint preserves trailing newline and records its matching task'

send worker 'please continue'
assert_record doorbell worker 4
pass 'doorbell records the typed line instead of the inbox body'

TEST_PENDING=1 send worker 'defer until the composer clears'
assert_record doorbell worker 4
pass 'skipped doorbell writes no record'

rc=0
TEST_PENDING=1 TEST_ENTER_FAIL=1 send worker '/enter-fails' || rc=$?
[ "$rc" != 0 ] || fail 'Enter failure must keep the existing exit contract'
assert_record native-skill worker 5
[ "$(wc -l < "$TMP_ROOT/type-count" | tr -d ' ')" = 5 ] || fail 'Enter retry duplicated typing'
pass 'typed text has one record even if Enter fails'

rc=0
TEST_TYPE_FAIL=1 send worker '/type-fails' || rc=$?
[ "$rc" != 0 ] || fail 'literal failure must keep the existing exit contract'
assert_record native-skill worker 5
send worker --key Escape
assert_record native-skill worker 5
pass 'failed typing and key delivery write no records'

rm "$FM_HOME/state/worker.meta"
send sess:win 'outside the fleet'
assert_record explicit-endpoint '' 6
pass 'unregistered endpoint uses a null task id'

# The remote fixture executes fm-on and its host-local send command.
# The Herdr executable is a fixture. It refuses every lifecycle command.
cat > "$TMP_ROOT/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'status --json') printf '{"client":{"protocol":19},"server":{"running":true}}\n' ;;
  'pane send-text')
    printf '%s' "$4" > "$PROVENANCE_TEST_ROOT/remote-typed"
    printf '.\n' >> "$PROVENANCE_TEST_ROOT/remote-count" ;;
  'pane send-keys') : ;;
  'pane read') printf '╭────╮\n│    │\n╰────╯\n' ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"p1"}}}\n' ;;
  'agent get') printf '{"result":{"agent":{"agent":"claude","agent_status":"working"}}}\n' ;;
  *) exit 91 ;;
esac
SH
cat > "$TMP_ROOT/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
remote_home=$(perl -MMIME::Base64 -e 'print decode_base64($ARGV[0])' "$3")
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done \
  < <(perl -MMIME::Base64 -e 'print decode_base64($ARGV[0])' "$4")
printf '%s\0' "${args[@]}" > "$PROVENANCE_TEST_ROOT/remote-args"
env -u FM_STATE_OVERRIDE \
  FM_HOME="$remote_home" "$PROVENANCE_CODE_ROOT/bin/${args[0]}" "${args[@]:1}"
if [ "${TEST_SSH_LOST:-0}" = 1 ]; then exit 255; fi
SH
chmod +x "$TMP_ROOT/fakebin/herdr" "$TMP_ROOT/fakebin/ssh"
export PROVENANCE_CODE_ROOT="$ROOT" FM_SSH_BIN="$TMP_ROOT/fakebin/ssh"
remote_home="$TMP_ROOT/remote home"
mkdir -p "$remote_home/state/parent-route" "$remote_home/bin" "$FM_HOME/data"
printf 'remote\n' > "$remote_home/.fm-secondmate-home"
printf '# Fixture\n' > "$remote_home/AGENTS.md"
fm_write_meta "$remote_home/state/parent-route/remote.meta" \
  'window=fm-remote:p1' 'worktree=-' 'project=-' 'backend=herdr' \
  'endpoint_task_id=remote' 'harness=claude' 'herdr_session=fm-remote' \
  'herdr_workspace_id=w1' 'herdr_tab_id=t1' 'herdr_pane_id=p1'
fm_write_meta "$FM_HOME/state/remote.meta" \
  'window=fm-remote:p1' 'endpoint_task_id=remote' 'harness=claude' \
  'kind=secondmate' 'mode=secondmate' 'remote_host=fixture' "home=$remote_home" \
  'remote_root=/remote/root' 'remote_backend=herdr' \
  'remote_herdr_session=fm-remote' 'remote_target=fm-remote:p1'
printf '%s\n' "- remote - test (host: fixture; root: /remote/root; home: $remote_home; scope: test; projects: alpha; added 2026-09-24)" > "$FM_HOME/data/secondmates.md"
FM_ROOT_OVERRIDE="$ROOT" send remote '/no-mistakes'
remote_args() { # <text> [delivery-mode]
  python3 - "$TMP_ROOT/remote-args" "$@" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
assert args[:3] == [b"fm-remote-secondmate-control.sh", b"send", b"remote"], args
assert args[3].endswith(sys.argv[2].encode()), args
assert args[4:] == [m.encode() for m in sys.argv[3:]], args
PY
}
remote_args /no-mistakes || fail 'remote send arguments changed'
python3 - "$remote_home" "$FM_HOME" "$TMP_ROOT" <<'PY'
import hashlib, json, pathlib, sys
remote, sender, temp = map(pathlib.Path, sys.argv[1:])
assert not list(remote.glob('**/local-send-provenance')), 'the destination home wrote provenance'
records = [json.loads(line) for file in sorted((sender/'state/local-send-provenance').glob('*.jsonl')) for line in file.read_text().splitlines()]
assert len(records) == 7, records
r = records[-1]
assert r['sender_home'] == str(sender), r
assert r['endpoint'] == {'backend': 'herdr', 'target': 'fm-remote:p1', 'pane_id': 'p1', 'task_id': 'remote', 'remote_host': 'fixture'}, r
assert r['delivery_kind'] == 'doorbell', r
typed = (temp/'remote-typed').read_bytes()
assert r['sha256'] == hashlib.sha256(typed).hexdigest(), r
assert typed.startswith(b': Firstmate instruction waiting:')
assert b'/no-mistakes' not in typed
assert '/no-mistakes' in (remote/'state/parent-route/remote.inbox/001.msg').read_text()
PY
pass 'send-provenance-context: a remote steer keeps its arguments and records the remote doorbell in the sending home'

rc=0
FM_ROOT_OVERRIDE="$ROOT" TEST_SSH_LOST=1 send remote --fire-and-forget 0123456789abcdef 'retry the remote transport' || rc=$?
expect_code 3 "$rc" 'lost remote transport keeps the unconfirmed exit contract'
remote_args 'retry the remote transport' fire-and-forget || fail 'fire-and-forget remote send arguments changed'
python3 - "$remote_home" "$FM_HOME" "$TMP_ROOT/remote-count" <<'PY'
import json, pathlib, sys
remote, sender, count = map(pathlib.Path, sys.argv[1:])
records = [json.loads(line) for file in (sender/'state/local-send-provenance').glob('*.jsonl') for line in file.read_text().splitlines()]
assert len(records) == 8, records
assert len(count.read_text().splitlines()) == 3
assert len(list((remote/'state/parent-route/remote.inbox').glob('*.msg'))) == 2
PY
pass 'an unconfirmed remote send records once and preserves inbox deduplication'

# Exercise each submit adapter with deterministic transport primitives.
# Seams: send-provenance-herdr, send-provenance-zellij,
# send-provenance-cmux, and send-provenance-orca.
for backend in herdr zellij cmux orca; do
  (
    export FM_HOME="$TMP_ROOT/adapter-$backend"
    mkdir -p "$FM_HOME/state"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    # shellcheck source=bin/fm-local-send-provenance.sh
    . "$ROOT/bin/fm-local-send-provenance.sh"
    fm_local_hook init
    fm_backend_source "$backend"
    typed_mock() { printf '%s' "$2" > "$FM_HOME/typed"; }
    eval "fm_backend_${backend}_send_literal() { typed_mock \"\$@\"; }"
    eval "fm_backend_${backend}_send_key() { return 1; }"
    fm_backend_herdr_agent_status_raw() { printf working; }
    fm_backend_herdr_rendered_busy_state() { printf busy; }
    fm_backend_zellij_composer_content() { printf ''; }
    fm_backend_zellij_composer_observed_append() { return 1; }
    fm_backend_cmux_parse_target() { return 0; }
    fm_backend_cmux_composer_state() { printf send-failed; }
    fm_backend_orca_tool_check() { return 0; }
    fm_backend_orca_composer_state() { printf send-failed; }
    result=$(fm_backend_send_text_submit "$backend" 'session:p9' 'same bytes' 1 0 0)
    [ "$result" = send-failed ] || fail "$backend: expected failure after typing, got $result"
    python3 - "$FM_HOME" "$backend" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
records = [json.loads(line) for file in (root/'state/local-send-provenance').glob('*.jsonl') for line in file.read_text().splitlines()]
assert len(records) == 1, records
assert records[0]['endpoint']['backend'] == sys.argv[2]
assert records[0]['sha256'] == hashlib.sha256((root/'typed').read_bytes()).hexdigest()
PY
  )
done
pass 'every submit adapter records after literal typing even when submission fails'

# Run the real watcher against an aged unhandled steer on an idle pane.
# This is the send-provenance-re-ring seam.
(
  export FM_HOME="$TMP_ROOT/watch home"
  watchbin="$TMP_ROOT/watchbin"
  mkdir -p "$FM_HOME/state" "$watchbin"
  cat > "$watchbin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  send-keys) [ "${4:-}" != -l ] || printf '%s' "$5" > "$PROVENANCE_TEST_ROOT/watch-typed" ;;
  display-message)
    case "$*" in *cursor_y*) printf '1\n' ;; *pane_id*) printf '%%3\n' ;; *) printf 'fakepane\n' ;; esac ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'win\n' ;;
esac
SH
  printf '#!/usr/bin/env bash\nprintf "state: working · source: run-step · validating (running)\\n"\n' > "$watchbin/fm-crew-state.sh"
  chmod +x "$watchbin/"*
  fm_write_meta "$FM_HOME/state/steered.meta" 'window=sess:win' 'kind=ship' 'harness=grok'
  rec=$(bash -c '. "$1"; fm_task_inbox_write "$2" steered "please continue"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$FM_HOME/state")
  touch -t 202001010000 "$rec"
  PATH="$watchbin:${PATH#"$TMP_ROOT/fakebin:"}" FM_CREW_STATE_BIN="$watchbin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=99 \
    "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watch.out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ ! -s "$TMP_ROOT/watch-typed" ] || [ -z "$(find "$FM_HOME/state/local-send-provenance" -name '*.jsonl' 2>/dev/null)" ] || break
    kill -0 "$pid" 2>/dev/null || break
    perl -e 'select undef, undef, undef, 0.1'
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -s "$TMP_ROOT/watch-typed" ] || { cat "$TMP_ROOT/watch.out" >&2; fail 'the watcher did not re-ring the doorbell'; }
  python3 - "$FM_HOME" "$TMP_ROOT/watch-typed" <<'PY'
import hashlib, json, pathlib, sys
home, typed = map(pathlib.Path, sys.argv[1:])
records = [json.loads(line) for file in (home/'state/local-send-provenance').glob('*.jsonl') for line in file.read_text().splitlines()]
assert records, 'the re-ring wrote no record'
typed = typed.read_bytes()
assert typed.startswith(b': Firstmate instruction waiting:')
for r in records:
    assert r['endpoint'] == {'backend': 'tmux', 'target': 'sess:win', 'pane_id': '%3', 'task_id': 'steered'}, r
    assert r['delivery_kind'] == 'doorbell', r
    assert r['sender_home'] == str(home.resolve()), r
    assert r['sha256'] == hashlib.sha256(typed).hexdigest(), r
PY
)
pass 'send-provenance-re-ring: a watcher doorbell re-ring records the typed line for its task'

# Concurrent appenders retain complete records and expire only old shards.
writer="$ROOT/bin/fm-local-send-provenance.pl"
store="$FM_HOME/state/local-send-provenance"
printf '{"expired":true}\n' > "$store/2000-01-01.jsonl"
pids=()
for n in $(seq 1 12); do
  printf '%s' "$n" | perl "$writer" record "$FM_HOME/state" tmux sess:win %7 worker '' "$FM_HOME" native-skill &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
mkdir "$TMP_ROOT/concurrent-state"
pids=()
for n in $(seq 1 12); do
  printf '%s' "$n" | perl "$writer" record "$TMP_ROOT/concurrent-state" tmux sess:win %7 worker '' "$FM_HOME" native-skill &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
python3 - "$TMP_ROOT/concurrent-state" <<'PY'
import json, pathlib, sys
records = [json.loads(line) for file in pathlib.Path(sys.argv[1]).glob('local-send-provenance/*.jsonl') for line in file.read_text().splitlines()]
assert len(records) == 12, len(records)
PY
python3 - "$store" <<'PY'
import json, pathlib, sys
store = pathlib.Path(sys.argv[1])
assert not (store/'2000-01-01.jsonl').exists()
records = [json.loads(line) for file in store.glob('*.jsonl') for line in file.read_text().splitlines()]
assert len(records) == 20, len(records)
assert store.stat().st_mode & 0o777 == 0o700
assert all(f.stat().st_mode & 0o777 == 0o600 for f in store.glob('*.jsonl'))
PY
pass 'concurrent writers preserve complete private records and expire old shards'

# Drive real teardown on a landed local fixture, with external tools stubbed.
# This is the send-provenance-teardown seam.
fm_git_identity fmtest fmtest@example.invalid
mkdir -p "$TMP_ROOT/project" "$FM_HOME/config"
git -C "$TMP_ROOT/project" init -q -b main
git -C "$TMP_ROOT/project" commit -q --allow-empty -m baseline
git -C "$TMP_ROOT/project" worktree add -q -b fm/worker "$TMP_ROOT/worktree"
fm_write_meta "$FM_HOME/state/worker.meta" 'window=sess:fm-worker' 'backend=tmux' \
  'endpoint_task_id=worker' "worktree=$TMP_ROOT/worktree" "project=$TMP_ROOT/project" \
  'kind=ship' 'mode=local-only' 'spawn_gen=fixture'
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
for tool in treehouse no-mistakes gh-axi gh atlas-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/fakebin/$tool"
  chmod +x "$TMP_ROOT/fakebin/$tool"
done
printf '{"expired":true}\n' > "$store/2000-01-01.jsonl"
FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config" \
  FM_TEARDOWN_GUARD_DONE=1 "$ROOT/bin/fm-teardown.sh" worker > "$TMP_ROOT/teardown.out" 2> "$TMP_ROOT/teardown.err" \
  || { cat "$TMP_ROOT/teardown.err" >&2; fail 'fixture teardown failed'; }
[ ! -e "$FM_HOME/state/worker.meta" ] || fail 'fixture task did not retire'
[ ! -e "$store/2000-01-01.jsonl" ] || fail 'teardown did not prune expired provenance'
python3 - "$store" <<'PY'
import json, pathlib, sys
records = [json.loads(line) for file in pathlib.Path(sys.argv[1]).glob('*.jsonl') for line in file.read_text().splitlines()]
assert len(records) == 20, len(records)
PY
pass 'teardown retains recent history and removes only expired provenance'
