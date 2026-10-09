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
# Shared helper for the node assertions below: it reads the JSONL provenance shards.
cat > "$TMP_ROOT/provenance-lib.js" <<'JS'
const fs = require("fs");
const path = require("path");
exports.sha256 = (bytes) => require("crypto").createHash("sha256").update(bytes).digest("hex");
exports.shards = (dir) => {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((name) => name.endsWith(".jsonl")).sort().map((name) => path.join(dir, name));
};
exports.records = (dir) => {
  const rows = [];
  for (const file of exports.shards(dir)) {
    const lines = fs.readFileSync(file, "utf8").split("\n");
    if (lines[lines.length - 1] === "") lines.pop();
    for (const line of lines) rows.push(JSON.parse(line));
  }
  return rows;
};
JS
export PROVENANCE_LIB="$TMP_ROOT/provenance-lib.js"
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
  node - "$FM_HOME/state" "$TMP_ROOT/typed" "$1" "$2" "$3" "$FM_HOME" <<'JS'
const assert = require("assert");
const fs = require("fs");
const lib = require(process.env.PROVENANCE_LIB);
const [state, typed, kind, task, count, sender] = process.argv.slice(2);
const records = lib.records(`${state}/local-send-provenance`);
assert.strictEqual(records.length, Number(count), `${records.length} ${count}`);
const record = records[records.length - 1];
assert.strictEqual(record.version, 1);
assert.strictEqual(record.sha256, lib.sha256(fs.readFileSync(typed)), JSON.stringify(record));
assert.deepStrictEqual(record.endpoint, { backend: "tmux", target: "sess:win", pane_id: "%7", task_id: task || null }, JSON.stringify(record));
assert.strictEqual(record.sender_home, sender, JSON.stringify(record));
assert.strictEqual(record.delivery_kind, kind, JSON.stringify(record));
assert.ok(Math.abs(Date.now() - Date.parse(record.time)) < 60000, record.time);
assert.ok(!("text" in record), JSON.stringify(record));
JS
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
  node - "$TMP_ROOT/remote-args" "$@" <<'JS'
const assert = require("assert");
const fs = require("fs");
const argv = process.argv.slice(2);
const args = fs.readFileSync(argv[0], "utf8").split("\0").slice(0, -1);
assert.deepStrictEqual(args.slice(0, 3), ["fm-remote-secondmate-control.sh", "send", "remote"], JSON.stringify(args));
assert.ok(args[3].endsWith(argv[1]), JSON.stringify(args));
assert.deepStrictEqual(args.slice(4), argv.slice(2), JSON.stringify(args));
JS
}
remote_args /no-mistakes || fail 'remote send arguments changed'
node - "$remote_home" "$FM_HOME" "$TMP_ROOT" <<'JS'
const assert = require("assert");
const fs = require("fs");
const lib = require(process.env.PROVENANCE_LIB);
const [remote, sender, temp] = process.argv.slice(2);
const provenanceDirs = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
  const full = `${dir}/${entry.name}`;
  if (entry.name === "local-send-provenance") return [full];
  return entry.isDirectory() ? provenanceDirs(full) : [];
});
assert.deepStrictEqual(provenanceDirs(remote), [], "the destination home wrote provenance");
const records = lib.records(`${sender}/state/local-send-provenance`);
assert.strictEqual(records.length, 7, JSON.stringify(records));
const r = records[records.length - 1];
assert.strictEqual(r.sender_home, sender, JSON.stringify(r));
assert.deepStrictEqual(r.endpoint, { backend: "herdr", target: "fm-remote:p1", pane_id: "p1", task_id: "remote", remote_host: "fixture" }, JSON.stringify(r));
assert.strictEqual(r.delivery_kind, "doorbell", JSON.stringify(r));
const typed = fs.readFileSync(`${temp}/remote-typed`);
assert.strictEqual(r.sha256, lib.sha256(typed), JSON.stringify(r));
assert.ok(typed.toString("utf8").startsWith(": Firstmate instruction waiting:"));
assert.ok(!typed.toString("utf8").includes("/no-mistakes"));
assert.ok(fs.readFileSync(`${remote}/state/parent-route/remote.inbox/001.msg`, "utf8").includes("/no-mistakes"));
JS
pass 'send-provenance-context: a remote steer keeps its arguments and records the remote doorbell in the sending home'

rc=0
FM_ROOT_OVERRIDE="$ROOT" TEST_SSH_LOST=1 send remote --fire-and-forget 0123456789abcdef 'retry the remote transport' || rc=$?
expect_code 3 "$rc" 'lost remote transport keeps the unconfirmed exit contract'
remote_args 'retry the remote transport' fire-and-forget || fail 'fire-and-forget remote send arguments changed'
node - "$remote_home" "$FM_HOME" "$TMP_ROOT/remote-count" <<'JS'
const assert = require("assert");
const fs = require("fs");
const lib = require(process.env.PROVENANCE_LIB);
const [remote, sender, count] = process.argv.slice(2);
const records = lib.records(`${sender}/state/local-send-provenance`);
assert.strictEqual(records.length, 8, JSON.stringify(records));
const countLines = fs.readFileSync(count, "utf8").split("\n");
if (countLines[countLines.length - 1] === "") countLines.pop();
assert.strictEqual(countLines.length, 3);
const inbox = fs.readdirSync(`${remote}/state/parent-route/remote.inbox`).filter((name) => name.endsWith(".msg"));
assert.strictEqual(inbox.length, 2);
JS
pass 'an unconfirmed remote send records once and preserves inbox deduplication'

# Exercise each submit adapter with deterministic transport primitives.
# Seams: send-provenance-herdr, send-provenance-zellij,
# send-provenance-cmux, and send-provenance-orca.
# shellcheck disable=SC2329 # Invoked indirectly by the function under test.
for backend in herdr zellij cmux orca; do
  (
    export FM_HOME="$TMP_ROOT/adapter-$backend"
    mkdir -p "$FM_HOME/state"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_local_hook provenance-init
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
    node - "$FM_HOME" "$backend" <<'JS'
const assert = require("assert");
const fs = require("fs");
const lib = require(process.env.PROVENANCE_LIB);
const [root, backend] = process.argv.slice(2);
const records = lib.records(`${root}/state/local-send-provenance`);
assert.strictEqual(records.length, 1, JSON.stringify(records));
assert.strictEqual(records[0].endpoint.backend, backend);
assert.strictEqual(records[0].sha256, lib.sha256(fs.readFileSync(`${root}/typed`)));
JS
  )
done
pass 'every submit adapter records after literal typing even when submission fails'

# The shared fork dispatcher keeps the fm_local_hook name after provenance hooks run.
# This is the send-provenance-dispatch seam.
(
  export FM_HOME="$TMP_ROOT/dispatch"
  mkdir -p "$FM_HOME/state"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_local_hook provenance-init
  fm_local_hook provenance-typed orca terminal-1 'dispatch bytes'
  fm_local_hook provenance-prune "$FM_HOME/state"
  rc=0
  fm_local_hook no-such-hook 2> "$TMP_ROOT/dispatch.err" || rc=$?
  [ "$rc" = 1 ] || fail 'the shared dispatcher must refuse an unknown hook after provenance hooks run'
  grep -qx 'error: unknown local hook: no-such-hook' "$TMP_ROOT/dispatch.err" \
    || fail 'the shared dispatcher must name the unknown hook'
  node - "$FM_HOME" <<'JS'
const assert = require("assert");
const lib = require(process.env.PROVENANCE_LIB);
const root = process.argv[2];
const records = lib.records(`${root}/state/local-send-provenance`);
assert.strictEqual(records.length, 1, JSON.stringify(records));
assert.deepStrictEqual(records[0].endpoint, { backend: "orca", target: "terminal-1", pane_id: "terminal-1", task_id: null }, JSON.stringify(records));
assert.strictEqual(records[0].sha256, lib.sha256(Buffer.from("dispatch bytes")), JSON.stringify(records));
JS
)
pass 'send-provenance-dispatch: provenance hooks route through the one shared fork dispatcher'

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
  node - "$FM_HOME" "$TMP_ROOT/watch-typed" <<'JS'
const assert = require("assert");
const fs = require("fs");
const lib = require(process.env.PROVENANCE_LIB);
const [home, typedFile] = process.argv.slice(2);
const records = lib.records(`${home}/state/local-send-provenance`);
assert.ok(records.length > 0, "the re-ring wrote no record");
const typed = fs.readFileSync(typedFile);
assert.ok(typed.toString("utf8").startsWith(": Firstmate instruction waiting:"));
for (const r of records) {
  assert.deepStrictEqual(r.endpoint, { backend: "tmux", target: "sess:win", pane_id: "%3", task_id: "steered" }, JSON.stringify(r));
  assert.strictEqual(r.delivery_kind, "doorbell", JSON.stringify(r));
  assert.strictEqual(r.sender_home, fs.realpathSync(home), JSON.stringify(r));
  assert.strictEqual(r.sha256, lib.sha256(typed), JSON.stringify(r));
}
JS
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
node - "$TMP_ROOT/concurrent-state" <<'JS'
const assert = require("assert");
const lib = require(process.env.PROVENANCE_LIB);
const records = lib.records(`${process.argv[2]}/local-send-provenance`);
assert.strictEqual(records.length, 12, String(records.length));
JS
node - "$store" <<'JS'
const assert = require("assert");
const fs = require("fs");
const lib = require(process.env.PROVENANCE_LIB);
const store = process.argv[2];
assert.ok(!fs.existsSync(`${store}/2000-01-01.jsonl`));
const records = lib.records(store);
assert.strictEqual(records.length, 20, String(records.length));
assert.strictEqual(fs.statSync(store).mode & 0o777, 0o700);
assert.ok(lib.shards(store).every((file) => (fs.statSync(file).mode & 0o777) === 0o600));
JS
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
node - "$store" <<'JS'
const assert = require("assert");
const lib = require(process.env.PROVENANCE_LIB);
const records = lib.records(process.argv[2]);
assert.strictEqual(records.length, 20, String(records.length));
JS
pass 'teardown retains recent history and removes only expired provenance'
