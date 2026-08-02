---
name: filesystem-map
description: >-
  The machine's authoritative map of where agent material lives and where a new file goes.
  Use before creating any skill, config, or agent-instruction file, and before moving, consolidating, or wiring up skills across the user level, firstmate, or a project.
  Covers the canonical layout of ~/AGENTS.md, ~/.agents/skills, the firstmate hub, and project-embedded skills, plus a where-does-it-go decision tree and the harness-agnosticism rule.
user-invocable: false
metadata:
  internal: true
---

# filesystem-map

Load this before creating or relocating any skill, config, or agent-instruction file anywhere on this machine.
It is the single owner of the layout contract; every other mention of it, including the pointer in `~/AGENTS.md`, is a one-line cross-reference back here, never a restatement.

## Canonical layout

Two canonical homes hold general agent material, both indexed from firstmate; a third pattern covers skills that ship as a project's deliverable.

```
~/AGENTS.md                        neutral global primary, read natively by every harness
~/.claude/CLAUDE.md                small @import of ~/AGENTS.md - the only Claude wiring; carries no content

~/.agents/skills/                  CANONICAL user-level general skills, harness-neutral
~/.claude/skills  ->  ~/.agents/skills     symlink, so Claude sees the identical set

<primary firstmate home>/          THE HUB (a shared template repo, git-tracked; location-independent via FM_HOME)
   AGENTS.md (real)  ;  CLAUDE.md -> AGENTS.md
   .agents/skills/   internal operating skills, canonical, metadata.internal=true
   .claude/skills  ->  ../.agents/skills
   .agents/skills/filesystem-map/  this skill
   skills/           public installer-facing skills (not loaded by firstmate); a published install contract - do not relocate

<project>/.agents/skills/<skill>/  skill-as-deliverable, in-project, CID-style wiring
   .claude/skills  ->  ../.agents/skills
```

The rule behind the split: firstmate is the hub and the index, but "within firstmate" means firstmate is the interface, not that every file physically lives in the shared template repo.
The user's harness-neutral general skills belong at `~/.agents/skills`, not committed inside firstmate.
Firstmate's own operating knowledge, and the machine map itself, live in the primary firstmate home's `.agents/skills` so they are git-tracked and reach every secondmate home through firstmate sync.

## Where does it go?

Given a new skill, config, or instruction file, place it at the first tier that fits.

1. A harness-neutral general skill usable by any agent (a dev workflow, a tool wrapper, a reusable technique)?
   `~/.agents/skills/<skill>/`.
   Claude reaches it automatically through the `~/.claude/skills` symlink; never author a second Claude-only copy.
2. Firstmate operating knowledge - something the fleet needs while running firstmate?
   The primary firstmate home's `.agents/skills/<skill>/` with `metadata.internal=true`, plus a one-line load trigger in `AGENTS.md` section 13.
3. A skill that is a specific project's deliverable (installed or gated per-home)?
   In that project at `.agents/skills/<skill>/` with the `.claude/skills -> ../.agents/skills` wiring, shipped through the project's own PR.
4. Per-harness-only content?
   Only when the skill explicitly declares itself harness-specific in its own frontmatter or body; absent that declaration, treat it as neutral and use tier 1.

Config that gates a skill for a home (for example a `config/<name>` activation file) lives under that home's `config/`, not beside the skill.

## Harness-agnosticism rule

`AGENTS.md` is the real file; `CLAUDE.md` is always a symlink to it.
Never create a content-bearing `CLAUDE.md` anywhere - the only legitimate real `CLAUDE.md` is `~/.claude/CLAUDE.md`, and it holds nothing but the `@import` of `~/AGENTS.md`.
A skill is Claude-only only if it says so explicitly; a skill whose content is neutral belongs on the neutral path even if it currently sits under a Claude-only directory.
Fixing such a skill is relocation and symlinking, not rewriting.
