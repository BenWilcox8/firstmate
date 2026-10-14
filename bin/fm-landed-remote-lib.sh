# shellcheck shell=bash
# Shared "is this work on a real remote" ref set for landed-work decisions.
# Usage: . bin/fm-landed-remote-lib.sh
#        git log HEAD --not "${FM_LANDED_REMOTE_REFS[@]}" --
#
# `no-mistakes init` adds a local validation gate remote named `no-mistakes`.
# Its repository lives on this machine, so a commit that only reached it has not
# reached any forge and is not landed. A plain `--remotes` counts that gate as a
# remote, so a check built on it passes unlanded work and cleanup then deletes the
# branch. Every landed-work decision uses this ref set instead of a bare
# `--remotes`: all remote-tracking refs except the gate's.
#
# The exclusion makes such a check only stricter: a commit found only on the gate
# now counts as not on a remote, and the caller's other landed proofs (merged PR,
# content already in the default branch, local main for local-only) still apply.
# Checks that treat any remote ref as a reason to KEEP work, never to discard it,
# do not need this set.

# shellcheck disable=SC2034  # consumed by the sourcing scripts
FM_LANDED_REMOTE_REFS=(--exclude='no-mistakes/*' --remotes)
