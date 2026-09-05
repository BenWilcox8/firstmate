#!/usr/bin/env bash
# fm-action-pins-check.sh - repo invariant: every third-party GitHub Action
# reference in .github/workflows is pinned to a full commit SHA.
#
# A tag or branch ref (actions/checkout@v6, actions/checkout@main) is
# mutable: whoever controls that tag can repoint it to arbitrary code that
# then runs in CI with repo secrets. Pinning to the release's exact 40-hex
# commit SHA, with the human-readable version kept as a trailing comment,
# removes that trust dependency. This check is the "Repo invariants" job's
# enforcement of that; ci.yml's invariants job calls this script's default
# `check` verb so a newly introduced mutable tag fails CI, and a broken
# ci.yml itself cannot report its own breakage, so this must also run
# locally (bin/fm-lint.sh) rather than living only as an inline workflow
# step.
#
# A local composite action (uses: ./path or ../path) and a docker:// action
# are exempt: they are not fetched from a mutable remote tag.
#
# Usage:
#   fm-action-pins-check.sh [check]      check workflows under this repo
#   fm-action-pins-check.sh --root <dir> check workflows under <dir>
#   fm-action-pins-check.sh <path>...    check explicit workflow files
#   fm-action-pins-check.sh --help
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-action-pins-check.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

fm_action_pins_usage() {
  sed -n '2,22{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'fm-action-pins-check.sh: --root requires a directory.\n' >&2
        exit 2
      }
      EXPLICIT_ROOT=$2
      shift 2
      ;;
    --root=*)
      EXPLICIT_ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      fm_action_pins_usage
      exit 0
      ;;
    check)
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-action-pins-check.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
ARGS+=("$@")

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'fm-action-pins-check.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

collect_workflow_files() {
  local dir=$1
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f \
    | LC_ALL=C sort
}

FILES=()
if [ "${#ARGS[@]}" -gt 0 ]; then
  for path in "${ARGS[@]}"; do
    case "$path" in
      *.yml|*.yaml) ;;
      *)
        printf 'fm-action-pins-check.sh: not a workflow YAML file: %s\n' "$path" >&2
        exit 2
        ;;
    esac
    [ -f "$path" ] || {
      printf 'fm-action-pins-check.sh: workflow file not found: %s\n' "$path" >&2
      exit 2
    }
    FILES+=("$path")
  done
else
  workflow_dir="$ROOT/.github/workflows"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    FILES+=("$path")
  done < <(collect_workflow_files "$workflow_dir")
  if [ "${#FILES[@]}" -eq 0 ]; then
    printf 'fm-action-pins-check.sh: no GitHub workflow files found under %s\n' \
      "$workflow_dir" >&2
    exit 1
  fi
fi

SHA_RE='^[0-9a-fA-F]{40}$'
violations=0
checked=0

for file in "${FILES[@]}"; do
  while IFS=: read -r lineno line; do
    [ -n "$lineno" ] || continue
    # Only a real `uses:` mapping key, not incidental text inside a `run:`
    # block's shell.
    rest=${line#*uses:}
    [ "$rest" != "$line" ] || continue
    value=$(printf '%s' "$rest" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//')
    value=${value%\"}
    value=${value#\"}
    value=${value%\'}
    value=${value#\'}
    [ -n "$value" ] || continue

    case "$value" in
      ./*|../*|docker://*)
        continue
        ;;
    esac

    checked=$((checked + 1))
    ref=${value##*@}
    if [ "$ref" = "$value" ]; then
      printf '::error file=%s,line=%s::third-party action has no pinned ref: %s\n' \
        "$file" "$lineno" "$value" >&2
      violations=$((violations + 1))
      continue
    fi
    if ! printf '%s' "$ref" | grep -qE "$SHA_RE"; then
      printf '::error file=%s,line=%s::third-party action pinned to a mutable ref, not a commit SHA: %s\n' \
        "$file" "$lineno" "$value" >&2
      violations=$((violations + 1))
    fi
  done < <(grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]' "$file")
done

if [ "$violations" -gt 0 ]; then
  printf 'fm-action-pins-check.sh: %s third-party action reference(s) not pinned to a commit SHA\n' \
    "$violations" >&2
  exit 1
fi

printf 'fm-action-pins-check.sh: %s third-party action reference(s) pinned across %s workflow file(s)\n' \
  "$checked" "${#FILES[@]}"
exit 0
