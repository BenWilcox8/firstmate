---
name: firstmate-orca
description: Agent-only reference for inspecting, supervising, or reconciling existing Orca-backed task records. New Orca task selection is unsupported.
user-invocable: false
metadata:
  internal: true
---

# firstmate-orca

Use this for existing Orca task records only.
New Orca selection and automatic relaunch are unsupported.
It does not replace `AGENTS.md`, `docs/orca-backend.md`, or `harness-adapters`.

Orca is a runtime backend, not an agent harness.
The runtime backend owns the task endpoint and, for Orca, the task worktree.
The harness is the agent process launched inside that endpoint, such as `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, or `kimi`.
Load `harness-adapters` for harness-specific launch, interrupt, resume, trust-dialog, and skill-invocation facts.

Implementation details, metadata fields, teardown guarantees, and limitations live in `docs/orca-backend.md`.
`docs/verification/runtime-backends.md` "Orca" owns the current verification boundary.
Prefer the `bin/fm-*` helpers over raw `orca` commands.
Use raw `orca` only when the helper surface cannot answer the inspection question, and keep the recorded firstmate metadata as the task identity.

## Existing records

Inspect the recorded home and task metadata before any operation.
Use the exact recorded backend, terminal, worktree id, and worktree path.
Do not select Orca for new work or bypass its spawn refusal.
Keep existing task records until their normal lifecycle and landing checks permit cleanup.

## Supervision

Use `bin/fm-peek.sh`, `bin/fm-send.sh`, `bin/fm-crew-state.sh`, and `bin/fm-teardown.sh` for routine operation.
For steer messages, use `bin/fm-send.sh <id> '...'`; the stable `fm-<id>` alias also works, and ordinary local text steers may contain newlines because they ride the durable inbox.
Keep initial scope in the task brief; a temporary file remains useful when the instruction includes supporting material the worker should inspect separately.

When supervising, treat `state/<id>.meta` as the routing record and Orca's own ids as backend implementation details.
The stable firstmate alias is `fm-<id>`.
The recorded `terminal=` and `orca_worktree_id=` fields are what backend helpers use under the hood.

If an ordinary steer fails to enqueue, or a typed-plane `fm-send` fails to submit, do not immediately repeat the instruction.
Read the reported failure and peek first, then decide whether the record exists or the target is busy, waiting on a prompt, stuck behind a popup, or genuinely wedged.
For harness-specific interrupts or exits, load `harness-adapters`.

## Recovery

For a messy Orca-backed task:

1. Read `state/<id>.meta` and the relevant status tail first.
2. Confirm the task is actually Orca-backed before using Orca-specific assumptions.
3. Use the recorded `terminal=`, `orca_worktree_id=`, and `worktree=` as the task identity.
4. Prefer firstmate helpers for peek, send, state, and teardown.
5. Avoid raw deletion of Orca worktrees or manual branch cleanup.
6. Stop and inspect if the recorded worktree path, Orca worktree id, or project checkout no longer matches expectations.

Teardown remains governed by the normal firstmate landing rules.
Scout work can be torn down after the report exists and the `captain-hold-lifecycle` completion gate passes.
Ship work can be torn down only after the work is landed by its project mode.

## Verification

Run `tests/fm-backend-orca.test.sh` for unsupported-selection and existing-record regression coverage.
Do not launch a new Orca task as a smoke test.
