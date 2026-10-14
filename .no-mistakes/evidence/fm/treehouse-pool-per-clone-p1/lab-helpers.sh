WT=/home/ben/.no-mistakes/worktrees/3665d600861c/01M4Y4530SSCD26PJE443PN4GB
EVID=/home/ben/.no-mistakes/evidence/01M4Y4530SSCD26PJE443PN4GB
SCRATCH=/tmp/fmthp.vNub
BASE=/tmp/fmthp.vNub/base
export HOME=/tmp/fmthp.vNub/u
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH TREEHOUSE_ROOT CMUX_WORKSPACE_ID CMUX_SURFACE_ID ZELLIJ ZELLIJ_SESSION_NAME 2>/dev/null
export FM_BACKEND_HERDR_AXI_BIN=
[ -f /tmp/fmthp.vNub/session ] && export HERDR_SESSION=$(cat /tmp/fmthp.vNub/session)
HOME_A=/tmp/fmthp.vNub/home-a
HOME_B=/tmp/fmthp.vNub/home-b
AGENT="/tmp/fmthp.vNub/cursor-agent /tmp/fmthp.vNub/agent-fixture.js 900"
brief() { # <home> <id>
  mkdir -p "$1/data/$2"
  printf '# Task\n## Captain%ss intent\nPer-home pool lab check.\n\n## Firstmate spec\nIdle.\n' "'" > "$1/data/$2/brief.md"
}
spawn() { # <code-root> <home> <id> <project>
  local root=$1 home=$2 id=$3 proj=$4; shift 4
  brief "$home" "$id"
  FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$root/bin/fm-spawn.sh" "$id" "$proj" "$AGENT" --mode no-mistakes --yolo off --backend herdr "$@"
}
teardown() { # <code-root> <home> <id>
  FM_HOME="$2" FM_ROOT_OVERRIDE="$1" FM_STATE_OVERRIDE="$2/state" FM_DATA_OVERRIDE="$2/data" \
    FM_CONFIG_OVERRIDE="$2/config" "$1/bin/fm-teardown.sh" "$3"
}
meta() { sed -n "s/^$3=//p" "$1/state/$2.meta"; }  # <home> <id> <key>
common() { (cd "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" && pwd -P); }
log() { printf '%s\n' "$*" | tee -a "$EVID/lab-transcript.txt"; }
export FM_GATE_REFUSE_BYPASS=1
ROOT_A=/tmp/fmthp.vNub/u/.treehouse/firstmate-homes/2e0b3c055d74
ROOT_B=/tmp/fmthp.vNub/u/.treehouse/firstmate-homes/00a4f8dfb507
