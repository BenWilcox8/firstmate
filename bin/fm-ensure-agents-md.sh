#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md is a
# relative symlink to it for compatibility. Creates a minimal AGENTS.md skeleton
# when neither file exists, promotes a real CLAUDE.md file when it is the only
# file present, and refuses to clobber distinct real files or wrong symlinks.
#
# With --skill <name>, it also scaffolds the project skills layout, mirroring
# firstmate's own pattern: a `.agents/skills/` directory with a
# `.claude/skills -> ../.agents/skills` symlink, plus a
# `.agents/skills/<name>/SKILL.md` stub (user-invocable: false) when absent.
# This is how situation-specific subsystem contracts move out of a growing
# AGENTS.md and into on-demand skills (see docs/project-skills.md). It refuses
# to clobber an existing SKILL.md or a wrong .claude/skills symlink.
#
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [--skill <name>] [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [--skill <name>] [repo-or-worktree-dir]" >&2
}

SKILL_NAME=""
DIR="."
DIR_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --skill)
      shift
      [ "$#" -ge 1 ] || { echo "error: --skill requires a name" >&2; usage; exit 1; }
      SKILL_NAME=$1
      ;;
    --skill=*)
      SKILL_NAME=${1#--skill=}
      [ -n "$SKILL_NAME" ] || { echo "error: --skill requires a name" >&2; usage; exit 1; }
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage
      exit 1
      ;;
    *)
      [ "$DIR_SET" -eq 0 ] || { echo "error: unexpected argument: $1" >&2; usage; exit 1; }
      DIR=$1
      DIR_SET=1
      ;;
  esac
  shift
done

if [ -n "$SKILL_NAME" ]; then
  case "$SKILL_NAME" in
    *[!a-z0-9-]*|-*|*-)
      echo "error: --skill name must be a lowercase kebab slug (a-z, 0-9, dashes; no leading/trailing dash): $SKILL_NAME" >&2
      exit 1
      ;;
  esac
fi

[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
}

is_correct_claude_symlink() {
  [ -L "$CLAUDE" ] || return 1
  target=$(readlink "$CLAUDE")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

# Reconcile AGENTS.md / CLAUDE.md. Prints exactly one status line on success and
# returns 0; prints an error and exits non-zero on an unrecoverable conflict.
ensure_agents_claude() {
  if [ -L "$AGENTS" ]; then
    echo "conflict: AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file" >&2
    exit 1
  fi
  if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
    echo "conflict: AGENTS.md exists in $DIR but is not a regular file" >&2
    exit 1
  fi

  if [ -e "$AGENTS" ]; then
    if [ -L "$CLAUDE" ]; then
      if is_correct_claude_symlink; then
        echo "unchanged: AGENTS.md with CLAUDE.md -> AGENTS.md in $DIR"
        return 0
      fi
      echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
      exit 1
    fi
    if [ ! -e "$CLAUDE" ]; then
      ln -s "$AGENTS" "$CLAUDE"
      echo "symlinked: CLAUDE.md -> AGENTS.md in $DIR"
      return 0
    fi
    if [ -f "$CLAUDE" ]; then
      echo "conflict: both AGENTS.md and CLAUDE.md are real files in $DIR; reconcile them manually" >&2
      exit 1
    fi
    echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
    exit 1
  fi

  if [ -L "$CLAUDE" ]; then
    if is_correct_claude_symlink; then
      write_skeleton
      echo "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $DIR"
      return 0
    fi
    echo "conflict: CLAUDE.md is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
    exit 1
  fi

  if [ -e "$CLAUDE" ]; then
    if [ -f "$CLAUDE" ]; then
      mv "$CLAUDE" "$AGENTS"
      ln -s "$AGENTS" "$CLAUDE"
      echo "promoted: moved CLAUDE.md to AGENTS.md and symlinked CLAUDE.md -> AGENTS.md in $DIR"
      return 0
    fi
    echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
    exit 1
  fi

  write_skeleton
  ln -s "$AGENTS" "$CLAUDE"
  echo "created: AGENTS.md and CLAUDE.md -> AGENTS.md in $DIR"
}

# Scaffold the project skills layout and a SKILL.md stub for <name>. Mirrors
# firstmate's own `.agents/skills/` with `.claude/skills -> ../.agents/skills`.
ensure_skill() {
  skill_name=$1

  mkdir -p ".agents/skills"

  if [ -e ".claude" ] && [ ! -d ".claude" ] && [ ! -L ".claude" ]; then
    echo "conflict: .claude exists in $DIR but is not a directory" >&2
    exit 1
  fi
  if [ -L ".claude/skills" ]; then
    target=$(readlink ".claude/skills")
    case "$target" in
      "../.agents/skills") : ;;
      *)
        echo "conflict: .claude/skills is a symlink in $DIR but does not point to ../.agents/skills" >&2
        exit 1
        ;;
    esac
  elif [ -e ".claude/skills" ]; then
    echo "conflict: .claude/skills exists in $DIR but is not the expected symlink" >&2
    exit 1
  else
    mkdir -p ".claude"
    ln -s "../.agents/skills" ".claude/skills"
    echo "symlinked: .claude/skills -> ../.agents/skills in $DIR"
  fi

  skill_dir=".agents/skills/$skill_name"
  skill_file="$skill_dir/SKILL.md"
  if [ -L "$skill_dir" ] || { [ -e "$skill_dir" ] && [ ! -d "$skill_dir" ]; }; then
    echo "conflict: $skill_dir exists in $DIR but is not a directory" >&2
    exit 1
  fi
  if [ -e "$skill_file" ]; then
    echo "unchanged: $skill_file already exists in $DIR"
    return 0
  fi
  mkdir -p "$skill_dir"
  cat > "$skill_file" <<EOF
---
name: $skill_name
description: TODO one-line load trigger stating the subsystem this covers and when to load it, e.g. load before touching $skill_name.
user-invocable: false
---

# $skill_name

TODO: move the situation-specific contract for this subsystem out of AGENTS.md into this skill, and leave a one-line entry in the AGENTS.md skills index pointing here (see docs/project-skills.md).
EOF
  echo "scaffolded: $skill_file in $DIR"
}

ensure_agents_claude
if [ -n "$SKILL_NAME" ]; then
  ensure_skill "$SKILL_NAME"
fi
