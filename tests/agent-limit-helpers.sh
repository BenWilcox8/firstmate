#!/usr/bin/env bash
# tests/agent-limit-helpers.sh - a fake Herdr pane list shared by the agent
# count and agent limit suites. Source it after tests/lib.sh.

# make_fake_herdr <dir>: a herdr CLI over <dir>/herdr/<session>/panes.tsv.
# Each panes.tsv row is: pane-id, workspace-id, cwd, foreground name, argv...
# A session directory with a "down" file answers server_not_running, and one
# with a "broken" file answers an unexpected error. Every call is logged to
# <dir>/herdr/calls. status --json answers a running 0.8.2 server, pane get
# answers from the pane list, and agent get always answers agent_not_found.
# Every other endpoint call answers an unsupported error, so a spawn that gets past the limit stops at its first
# endpoint call and the log shows that it got there.
make_fake_herdr() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/herdr"
  : > "$dir/herdr/calls"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_HERDR_DIR
printf '%s\n' "$*" >> "$D/calls"
session=
pane=
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --session) session=${args[$((i + 1))]}; i=$((i + 2)); continue ;;
    --pane) pane=${args[$((i + 1))]}; i=$((i + 2)); continue ;;
  esac
  i=$((i + 1))
done
if [ "${1:-} ${2:-}" = "status --json" ]; then
  printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"version":"0.8.2","protocol":20}}\n'
  exit 0
fi
S="$D/$session"
if [ ! -d "$S" ] || [ -e "$S/down" ]; then
  printf '{"error":{"code":"server_not_running","message":"no herdr server"}}\n'
  exit 1
fi
if [ -e "$S/broken" ]; then
  printf '{"error":{"code":"internal","message":"boom"}}\n'
  exit 1
fi
rows() { [ -f "$S/panes.tsv" ] && cat "$S/panes.tsv"; }
case "${1:-} ${2:-}" in
  "pane get")
    row=$(rows | awk -F '\t' -v p="${3:-}" '$1 == p')
    [ -n "$row" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found"}}\n'; exit 1
    ;;
  "pane list")
    rows | jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t"))
      | {result: {panes: map({pane_id: .[0], workspace_id: .[1], cwd: .[2], foreground_cwd: .[2]})}}'
    ;;
  "pane process-info")
    row=$(rows | awk -F '\t' -v p="$pane" '$1 == p')
    [ -n "$row" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    printf '%s\n' "$row" | jq -R -c '
      split("\t") as $f
      | {result: {type: "pane_process_info", process_info: {
          pane_id: $f[0], shell_pid: 100, foreground_process_group_id: 200,
          foreground_processes: [{pid: 200, name: $f[3], argv: $f[4:]}]}}}'
    ;;
  *) printf '{"error":{"code":"unsupported"}}\n'; exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# add_pane <dir> <session> <pane> <workspace> <cwd> <name> <argv...>
add_pane() {
  local dir=$1 session=$2 pane=$3 ws=$4 cwd=$5 name=$6 line
  shift 6
  mkdir -p "$dir/herdr/$session"
  line="$pane"$'\t'"$ws"$'\t'"$cwd"$'\t'"$name"
  while [ $# -gt 0 ]; do
    line="$line"$'\t'"$1"
    shift
  done
  printf '%s\n' "$line" >> "$dir/herdr/$session/panes.tsv"
}

# agent_limit_task_meta <home> <id> <kind> <harness> <window>
agent_limit_task_meta() {
  fm_write_meta "$1/state/$2.meta" "window=$5" "kind=$3" "harness=$4" "backend=herdr" "worktree=$1/wt-$2"
}

# make_fake_ps <fakebin>: the process table behind every fake pane - shell pid
# 100 and one sleeping foreground process 200 - so a pane whose foreground is
# a plain shell reads as positively agent-free. Point FM_HERDR_PS_BIN at it.
make_fake_ps() {
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '1 0 1 S systemd /sbin/init' '100 1 100 S bash /bin/bash' '200 100 200 S bash /bin/bash'
SH
  chmod +x "$1/ps"
}
