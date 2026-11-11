#!/usr/bin/env bash
# fm-treehouse.sh - run treehouse against this home's own worktree pool.
#
# Usage:
#   fm-treehouse.sh <project-dir> <treehouse-args...>
#   fm-treehouse.sh --print-root
#
# The first form runs `treehouse <treehouse-args...>` from <project-dir> with
# TREEHOUSE_ROOT set to this home's private root, so `status`, `prune`, and the
# other pool commands read the same pool bin/fm-spawn.sh takes slots from.
# The second form prints that root. FM_HOME selects the home (default: the
# code root). bin/fm-wake-lib.sh fm_treehouse_home_root owns the root and why
# each home keeps its own pool. A slot taken before per-home pools stays in the
# shared per-origin pool; plain `treehouse status` from the project reads it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-treehouse.sh <project-dir> <treehouse-args...> | --print-root" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
root=$(fm_treehouse_home_root "$FM_HOME") || {
  echo "error: could not resolve the Treehouse root for home $FM_HOME" >&2
  exit 1
}
if [ "$1" = --print-root ]; then
  [ "$#" -eq 1 ] || usage
  printf '%s\n' "$root"
  exit 0
fi
[ "$#" -ge 2 ] || usage
project=$1
shift
[ -d "$project" ] || {
  echo "error: project directory $project does not exist" >&2
  exit 1
}
cd -- "$project" || exit 1
TREEHOUSE_ROOT=$root exec treehouse "$@"
