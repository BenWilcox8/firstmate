#!/usr/bin/env bash
# Regression coverage for the Linux Codex Node wrapper in Herdr recovery attribution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "$(uname -s)" != Linux ]; then
  echo "skip: the MainThread Node wrapper is specific to Linux"
  exit 0
fi
for tool in cc setsid jq ps; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "$tool is required for the Linux Codex attribution regression"
done

TMP_ROOT=$(fm_test_tmproot fm-herdr-codex-attribution)
FIXTURE_ROOT=
FIXTURE_CHILD=

cleanup_fixture() {
  if [ -n "$FIXTURE_ROOT" ] && kill -0 "$FIXTURE_ROOT" 2>/dev/null; then
    kill -TERM -- "-$FIXTURE_ROOT" 2>/dev/null || true
    wait "$FIXTURE_ROOT" 2>/dev/null || true
  elif [ -n "$FIXTURE_CHILD" ] && kill -0 "$FIXTURE_CHILD" 2>/dev/null; then
    kill -TERM "$FIXTURE_CHILD" 2>/dev/null || true
    wait "$FIXTURE_CHILD" 2>/dev/null || true
  fi
  FIXTURE_ROOT=
  FIXTURE_CHILD=
}

cleanup_all() {
  cleanup_fixture
  fm_test_cleanup
}

trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

cat > "$TMP_ROOT/mainthread-node.c" <<'C'
#include <sys/prctl.h>
#include <unistd.h>

int main(void) {
  if (prctl(PR_SET_NAME, "MainThread", 0, 0, 0) != 0) return 1;
  for (;;) sleep(60);
}
C
cc -o "$TMP_ROOT/node" "$TMP_ROOT/mainthread-node.c" \
  || fail "the MainThread Node-wrapper fixture did not compile"
printf 'fixture\n' > "$TMP_ROOT/codex"
printf 'fixture\n' > "$TMP_ROOT/not-codex"
printf 'fixture\n' > "$TMP_ROOT/-codex"
ln -s "$TMP_ROOT/node" "$TMP_ROOT/-node"
cat > "$TMP_ROOT/process-info.jq" <<'JQ'
{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:$shell,foreground_process_group_id:$pgid,foreground_processes:[{pid:$child,name:"MainThread",argv:[$node,$entry]}]}}}
JQ

start_fixture() { # <node-wrapper> <entry-point>
  local node_binary=$1 entry_point=$2 child='' attempt=0
  local fixture_command="set -m; \"\$1\" \"\$2\"; echo fixture-ended"
  setsid bash --noprofile --norc -c "$fixture_command" \
    bash "$node_binary" "$entry_point" >/dev/null 2>&1 &
  FIXTURE_ROOT=$!
  while [ "$attempt" -lt 50 ]; do
    child=$(ps -o pid= --ppid "$FIXTURE_ROOT" 2>/dev/null | awk 'NF { print $1; exit }')
    [ -n "$child" ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -n "$child" ] || fail "the process fixture did not start its Node child"
  FIXTURE_CHILD=$child
  FIXTURE_PGID=$(ps -o pgid= -p "$child" 2>/dev/null | tr -d '[:space:]')
  FIXTURE_COMM=$(ps -o comm= -p "$child" 2>/dev/null | awk '{ sub(/^.*\//, ""); print }')
  FIXTURE_ARGS=$(ps -o args= -p "$child" 2>/dev/null)
  [ "$FIXTURE_COMM" = MainThread ] \
    || fail "the fixture did not expose the Linux MainThread command name"
}

classify_fixture() { # <kernel-entry-point> <herdr-entry-point> [node-wrapper]
  local kernel_entry=$1 herdr_entry=$2 node_binary=${3:-$TMP_ROOT/node} out
  cleanup_fixture
  start_fixture "$node_binary" "$kernel_entry"
  HERDR_NODE_BINARY=$node_binary HERDR_ENTRY_POINT=$herdr_entry \
    FIXTURE_ROOT=$FIXTURE_ROOT FIXTURE_CHILD=$FIXTURE_CHILD FIXTURE_PGID=$FIXTURE_PGID \
    FILTER=$TMP_ROOT/process-info.jq ROOT=$ROOT bash -c '
      . "$ROOT/bin/backends/herdr.sh"
      fm_backend_herdr_cli() {
        case "$2 $3" in
          "pane get")
            printf "%s\n" "{\"result\":{\"pane\":{\"pane_id\":\"w1:p2\"}}}"
            ;;
          "agent get")
            printf "%s\n" "{\"result\":{\"agent\":{\"agent_status\":\"idle\"}}}"
            ;;
          "pane process-info")
            jq -cn -f "$FILTER" \
              --arg pane "w1:p2" \
              --arg node "$HERDR_NODE_BINARY" \
              --arg entry "$HERDR_ENTRY_POINT" \
              --argjson shell "$FIXTURE_ROOT" \
              --argjson pgid "$FIXTURE_PGID" \
              --argjson child "$FIXTURE_CHILD"
            ;;
          *) return 1 ;;
        esac
      }
      fm_backend_herdr_agent_state test:w1:p2
    '
  out=$?
  cleanup_fixture
  return "$out"
}

out=$(classify_fixture "$TMP_ROOT/codex" "$TMP_ROOT/codex") \
  || fail "the matching Codex wrapper fixture could not be classified"
[ "$out" = alive ] \
  || fail "matching MainThread Node and Codex evidence returned $out, expected alive"
pass "matching Herdr and kernel evidence attributes the Codex Node wrapper"

out=$(classify_fixture "$TMP_ROOT/not-codex" "$TMP_ROOT/not-codex") \
  || fail "the unrelated MainThread fixture could not be classified"
[ "$out" = unreadable ] \
  || fail "an unrelated MainThread process returned $out, expected unreadable"
pass "an unrelated MainThread Node process remains unattributed"

out=$(classify_fixture "$TMP_ROOT/not-codex" "$TMP_ROOT/codex") \
  || fail "the kernel-conflict fixture could not be classified"
[ "$out" = unreadable ] \
  || fail "Herdr-only Codex evidence returned $out, expected unreadable"

out=$(classify_fixture "$TMP_ROOT/codex" "$TMP_ROOT/not-codex") \
  || fail "the Herdr-conflict fixture could not be classified"
[ "$out" = unreadable ] \
  || fail "kernel-only Codex evidence returned $out, expected unreadable"
pass "conflicting Herdr and kernel identities remain unattributed"

out=$(classify_fixture "$TMP_ROOT/-codex" "$TMP_ROOT/-codex" "$TMP_ROOT/-node") \
  || fail "the leading-hyphen fixture could not be classified"
[ "$out" = unreadable ] \
  || fail "a leading-hyphen Node and Codex wrapper returned $out, expected unreadable"
pass "leading-hyphen Node and Codex names remain unattributed"
