#!/usr/bin/env bash
# fm-atlas-boundary-check.sh - keep Atlas text inside the optional Atlas module.
#
# Usage: bin/fm-atlas-boundary-check.sh [--root <repo>] [--list]
#
# The Atlas integration is an optional module, so that an upstream firstmate
# merge and an Atlas or dashboard update touch different files. This check is the
# single owner of the module's file set and of the hook-point registry below.
#
# Module files may mention the Atlas freely. A tracked path is a module file when
# it matches one of these patterns:
#   bin/fm-atlas-*.sh              module scripts
#   docs/atlas-module/*            the module map and the prompt fragments
#   .agents/skills/atlas-*/*       firstmate-side Atlas skills
#   tests/*                        tests, which may name what they exercise
#
# Every other tracked text file is core. A core file may mention the Atlas only
# on as many lines as its entry in the registry allows, and a core file with no
# entry may not mention it at all. A line mentions the Atlas when it contains
# "atlas" in any case; "Atlassian" (the Rovo vendor) does not count.
#
# The check passes and prints one `ok` line, or it prints one line on stderr for
# each core file over its allowance and exits 1. --root checks another
# repository (the default is the one holding this script). --list prints the
# module files and the registry with each file's current count, and checks
# nothing.
#
# To add a hook point to a core file, add or raise that file's entry below in the
# same change, so that every new Atlas line in a core file is a reviewed decision.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIST=0

# The hook-point registry: <core path> <most Atlas-mentioning lines allowed>,
# then an optional note on what those lines are.
hook_registry() {
  cat <<'EOF'
AGENTS.md 1 the config/specs layout line that points to the module map
bin/fm-session-start.sh 1 the call that prints the supervisor block
bin/fm-spawn.sh 12 --ticket, atlas_ticket=, and the module and hook calls
bin/fm-pr-merge.sh 7 the close-out call after a merge
bin/fm-merge-local.sh 8 the close-out call after a local landing
bin/fm-teardown.sh 26 the close-out calls at cleanup
bin/fm-test-run.sh 1 a timing hint for a module test
docs/configuration.md 5 the config/specs pointer section
docs/scripts.md 3 one index line for each module script
docs/documentation-audiences.json 4 one inventory entry for each module document
.agents/skills/firstmate-signalling/SKILL.md 1 names the dashboard signal command, atlas-axi
EOF
}

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "fm-atlas-boundary-check: --root needs a path" >&2; exit 2; }
      ROOT_DIR=$2
      shift 2
      ;;
    --list) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-atlas-boundary-check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

module_path() {  # <path>
  case "$1" in
    bin/fm-atlas-*.sh|docs/atlas-module/*|.agents/skills/atlas-*/*|tests/*) return 0 ;;
  esac
  return 1
}

allowance() {  # <path>
  hook_registry | awk -v p="$1" '$1 == p { print $2; found = 1 } END { if (!found) print 0 }'
}

atlas_lines() {  # <file>
  awk '{ l = tolower($0); gsub(/atlassian/, "", l); if (index(l, "atlas")) n++ } END { print n + 0 }' "$1"
}

git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "fm-atlas-boundary-check: $ROOT_DIR is not a git repository" >&2
  exit 2
}

if [ "$LIST" -eq 1 ]; then
  echo "module files:"
  git -C "$ROOT_DIR" ls-files | while IFS= read -r path; do
    case "$path" in tests/*) continue ;; esac
    module_path "$path" && printf '  %s\n' "$path"
  done
  echo "hook-point registry (path current/allowed):"
  hook_registry | while read -r path max note; do
    if [ -f "$ROOT_DIR/$path" ]; then
      printf '  %s %s/%s - %s\n' "$path" "$(atlas_lines "$ROOT_DIR/$path")" "$max" "$note"
    else
      printf '  %s absent/%s - %s\n' "$path" "$max" "$note"
    fi
  done
  exit 0
fi

violations=0
module_count=0
# Candidates are the tracked text files that contain the word at all; each is
# then counted exactly, so a file that only names Atlassian is never a finding.
while IFS= read -r -d '' path && IFS= read -r _count; do
  if module_path "$path"; then
    module_count=$((module_count + 1))
    continue
  fi
  [ -f "$ROOT_DIR/$path" ] && [ ! -L "$ROOT_DIR/$path" ] || continue
  lines=$(atlas_lines "$ROOT_DIR/$path")
  [ "$lines" -gt 0 ] || continue
  max=$(allowance "$path")
  if [ "$lines" -gt "$max" ]; then
    printf 'fm-atlas-boundary-check: %s has %s Atlas line(s) outside the module; its hook-point allowance is %s. Move the text into the module, or register the hook point in bin/fm-atlas-boundary-check.sh.\n' \
      "$path" "$lines" "$max" >&2
    violations=$((violations + 1))
  fi
done < <(git -C "$ROOT_DIR" grep -z -I -i -c -e atlas 2>/dev/null)

if [ "$violations" -gt 0 ]; then
  exit 1
fi
printf 'fm-atlas-boundary-check: ok module_files_mentioning=%s hook_files=%s\n' \
  "$module_count" "$(hook_registry | wc -l | tr -d ' ')"
