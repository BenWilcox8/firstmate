# Atlas ticket

This task works Atlas ticket {TICKET}.
The Atlas is the captain's map of each project's nodes and tickets, shown on the dashboard.
Load the `atlas-working` skill and use it for the ticket's stages, checkpoints, review, and testing handover.
This section is firstmate's rule for workers, and it wins where `atlas-working` says something different.

Your shell already names this home's Atlas (`ATLAS_REPO`) and your author name (`ATLAS_AXI_BY={HOLDER}`).
Run `atlas-axi` without `--repo` or `--by`, so that the Atlas records you as the author of every change you make.

You can change the Atlas only in these ways, and only for ticket {TICKET} and its node:
- Move the node one stage at a time with `atlas-axi restage`: forward when a stage is done, or back when the work needs it.
- Record a checkpoint with `atlas-axi ticket record {TICKET} "<what you finished>"`.
- Hand the work over to the captain's testing with `atlas-axi ticket testing {TICKET} --link "<full URL>" --what "<what to do>"`.
- If the ticket changed what the node contains, refresh the node's content, description, or plate as `atlas-working` describes.

You never close a ticket and you never free its node.
Do not run `ticket complete`, `ticket abandon`, `ticket abort`, `land`, or `release`, and do not change another ticket or node.
Your part ends when your branch is committed and ready, whatever merge kind the ticket names.
If you are a scout, your part ends when your report is written.
You never merge, and you never fast-forward the default branch.
When `atlas-working` tells you to merge or to complete the ticket, report `done:` to firstmate instead.
Firstmate's guarded merge closes the ticket automatically after it lands your work, and your supervisor can also close it by hand.

At the review stage, use the project's committed `.claude/agents/adversarial-reviewer.md` if the project has that file.
If the project does not have it, do not create it.
Then the review of your delivery path stands in for it, and the ticket stays in the review stage until that review passes.
