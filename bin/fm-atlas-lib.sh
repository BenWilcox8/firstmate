#!/usr/bin/env bash
# Shared rules for the optional Atlas module's scripts. Source it; it defines
# functions only and changes no state.
#
# This file is the single owner of two rules:
#   - the pointer rule: a home is wired to an Atlas when <config>/specs is a
#     regular file (not a symlink) whose first line is an absolute path to a
#     directory that holds atlas/ (docs/configuration.md "Atlas pointer");
#   - the holder rule: the Atlas crew name for a task is fm-<task-id>, or the task
#     id itself when it already starts with fm-. `ticket start --to` holds the
#     ticket under that name, and the worker's own writes carry the same name.

# fm_atlas_repo <config-dir>: print the wired Atlas repo, or return 1.
fm_atlas_repo() {
  local pointer="$1/specs" repo
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || return 1
  repo=$(head -n 1 "$pointer" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//') || return 1
  case "$repo" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -d "$repo/atlas" ] || return 1
  printf '%s\n' "$repo"
}

# fm_atlas_holder <task-id>: print the task's Atlas crew name.
fm_atlas_holder() {
  case "$1" in
    fm-*) printf '%s\n' "$1" ;;
    *) printf 'fm-%s\n' "$1" ;;
  esac
}
