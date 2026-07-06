# Project skills: keeping project `AGENTS.md` context-cheap

## Why this exists

A project's `AGENTS.md` (with `CLAUDE.md` symlinked to it) is auto-loaded into the context window of every crewmate that works that project, on every spawn, whether or not that crewmate ever touches the area a given section describes.
Its token cost is therefore paid by every session, every time.
When `AGENTS.md` accumulates situation-specific detail - a full contract per subsystem, per script, or per screen - a crewmate fixing one area still carries all the others as dead weight.
Left unchecked this is a large, silent context tax: audited project `AGENTS.md` files reached 488-538 lines (~12k-20k tokens) almost entirely from inlined per-subsystem contracts.

Project skills fix this by moving the sometimes-relevant detail out of `AGENTS.md` and into on-demand skills, leaving `AGENTS.md` as always-needed operating facts plus a compact index of what skills exist and when to load them.
The situation-specific contract still exists and is still committed with the code; it just loads only in the sessions that actually need it.

## The layout

This mirrors firstmate's own `.agents/skills/` pattern, one level down in each project:

```
projects/<name>/            # the project repo
  AGENTS.md                 # always-needed operating facts + a `## Skills` index
  CLAUDE.md                 # symlink -> AGENTS.md (unchanged)
  .agents/skills/
    <subsystem-a>/SKILL.md   # situation-specific contract, user-invocable: false
    <subsystem-b>/SKILL.md
  .claude/skills            # symlink -> ../.agents/skills
```

`AGENTS.md` keeps: stack, build/test/release mechanics, cross-cutting conventions, sharp edges, and a `## Skills` index with one line per skill stating its load trigger, for example:

```markdown
## Skills (load before the matching work)
- `flow-sheet` - load before touching the flow-sheet document, columns, canvas, or round lifecycle.
- `block-file` - load before touching the block-file schema, section nodes, or argument queries.
- `editor` - load before changing the Tiptap/Yjs editor core, marks, or the outline seam.
```

Each `SKILL.md` carries frontmatter with `name`, a `description` whose text doubles as the load trigger, and `user-invocable: false` (these are agent-only references, not captain commands), then the full subsystem contract in its body.

## Precedent

`consider-it-done` already ships this exact structure: `projects/consider-it-done/.agents/skills/consider-it-done/SKILL.md` with `.claude/skills -> ../.agents/skills` and `user-invocable: false`.
firstmate's own repo uses the identical layout for its agent-only reference skills.
Project skills generalize that precedent to every project.

## The trigger (when to split instead of append)

The ship-brief project-memory contract (`bin/fm-brief.sh`, and section 11 of the root `AGENTS.md`) directs a crewmate to route durable project-intrinsic knowledge by size and specificity:

- **Record inline in `AGENTS.md`** when the knowledge is a general, always-needed operating fact AND `AGENTS.md` is still small (under the threshold below).
- **Split into a project skill** when the knowledge is a situation-specific subsystem/script/screen contract, OR `AGENTS.md` is already over the threshold.

Threshold (tunable): **`AGENTS.md` over ~300 lines or ~10k tokens (~40k bytes)**.
The line/token figures are a heuristic, not a hard gate; the underlying rule is the knowledge-placement decision tree in the `firstmate-coding-guidelines` skill - always-needed-every-session facts stay inline, nameable-situation facts move to a skill.

## How a crewmate does the split

1. Run `bin/fm-ensure-agents-md.sh . --skill <subsystem>` in the worktree.
   This ensures `AGENTS.md`/`CLAUDE.md` exist, creates `.agents/skills/` with the `.claude/skills -> ../.agents/skills` symlink if absent, and scaffolds `.agents/skills/<subsystem>/SKILL.md` as a stub (refusing to clobber an existing skill or a wrong symlink).
2. Write the situation-specific contract into that `SKILL.md` body and fill in its `description` load trigger.
3. Add or keep a one-line entry for it under the `## Skills` index in `AGENTS.md`.
4. Commit all of it through the project's normal delivery pipeline.

Firstmate never hand-writes project skills or project `AGENTS.md`, exactly as prime directive #1 requires; crewmates create and commit them inside their worktrees through the project's delivery mode.

## Payoff

Splitting a fat catalog-style `AGENTS.md` down to an operating core plus a skills index plausibly cuts the always-loaded cost from ~12k-20k tokens to ~4k-6k tokens per spawn for that project, with the moved detail one skill-load away in the sessions that need it.
