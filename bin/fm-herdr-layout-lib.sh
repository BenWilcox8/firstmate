#!/usr/bin/env bash
# Shared wiring for agent-axi's herdr workspace-layout verbs into firstmate's
# supervision loop (spec agent-axi/v1, phase 1).
#
# agent-axi owns the durable per-home slot ledger and every layout mutation
# (spec agent-axi/v1; data/agent-axi-research-f2/report.md). Firstmate no longer
# re-derives slot geometry in bash; it only ASKS agent-axi to keep the live herdr
# workspace converged and to report drift, at three moments:
#
#   - session start (bin/fm-bootstrap.sh): full `layout --repair` so a drifted
#     layout self-heals when a locked session opens.
#   - watcher heartbeat (bin/fm-watch.sh): `layout --repair --dry-run` so live
#     drift is SURFACED (never silently mutated on the watcher's cadence).
#   - session-start digest (bin/fm-session-start.sh): `snapshot` so the digest
#     opens already showing live slot occupancy and any husks.
#
# This library is the SINGLE OWNER of the applicability guard and the three
# invocations, so the three consumers stay thin and the guard is defined once.
# The whole slot model is herdr-only (spec "Out of Scope"), so every helper is a
# definitive no-op unless BOTH hold:
#   1. this home is EXPLICITLY configured for herdr (FM_BACKEND or config/backend,
#      never runtime auto-detection - see fm_herdr_layout_backend_is_herdr), and
#   2. the agent-axi executable is resolvable.
# The executable name/path comes from FM_BACKEND_HERDR_AXI_BIN (default
# `agent-axi`), the same knob bin/backends/herdr.sh's phase-0 shim uses - an
# empty value forces the native fallback everywhere, and tests pin a fake bin
# through it. jq is required to read the --json contract; its absence is treated
# as "not applicable" rather than an error, matching the rest of the herdr
# adapter.

# fm_herdr_layout_bin: the agent-axi executable to invoke, or empty when
# delegation is disabled (FM_BACKEND_HERDR_AXI_BIN explicitly empty).
fm_herdr_layout_bin() {
  printf '%s' "${FM_BACKEND_HERDR_AXI_BIN-agent-axi}"
}

# fm_herdr_layout_backend_is_herdr: 0 only when THIS HOME is EXPLICITLY configured
# for herdr - the FM_BACKEND env override or a `config/backend` file naming herdr.
# It deliberately does NOT consult runtime auto-detection (fm_backend_name's
# HERDR_ENV/process-ancestry fallback): the wiring drives agent-axi against the
# home's live herdr workspace, so it must fire only for a deliberately herdr-backed
# home, never merely because the current process happens to run inside an ambient
# herdr pane - which would leak the mutating repair into a non-herdr home's own
# session (and into every test that runs from within a herdr pane). Mirrors
# bin/fm-backend.sh's explicit-source precedence (env, then the config file's
# first non-blank line), minus the auto-detect tail.
fm_herdr_layout_backend_is_herdr() {
  if [ -n "${FM_BACKEND:-}" ]; then
    [ "$FM_BACKEND" = herdr ]
    return
  fi
  local cfg line v
  cfg="${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}/backend"
  [ -f "$cfg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    v=$(printf '%s' "$line" | tr -d '[:space:]')
    if [ -n "$v" ]; then
      [ "$v" = herdr ]
      return
    fi
  done < "$cfg"
  return 1
}

# fm_herdr_layout_applicable: 0 only when the agent-axi layout wiring should run
# for this home - an explicitly herdr-backed home with a resolvable agent-axi and
# jq. Any other backend, a disabled/absent executable, or missing jq is a clean 1
# (the caller stays silent).
fm_herdr_layout_applicable() {
  local bin
  bin=$(fm_herdr_layout_bin)
  [ -n "$bin" ] || return 1
  fm_herdr_layout_backend_is_herdr || return 1
  command -v "$bin" >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
}

# fm_herdr_layout_snapshot: echo agent-axi's token-lean live slot map for the
# session-start digest, or nothing when not applicable or the probe fails.
# Read-only.
fm_herdr_layout_snapshot() {
  local bin out
  fm_herdr_layout_applicable || return 1
  bin=$(fm_herdr_layout_bin)
  out=$("$bin" snapshot 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fm_herdr_layout_repair: run the full `layout --repair` (MUTATING) at a locked
# session boundary and echo a one-line human summary of what it healed, or
# nothing when the workspace was already converged / not applicable / the probe
# failed. Returns 0 when it emitted a summary, 1 otherwise, so a caller can
# choose to stay silent on a no-op.
fm_herdr_layout_repair() {
  local bin out converged summary
  fm_herdr_layout_applicable || return 1
  bin=$(fm_herdr_layout_bin)
  out=$("$bin" layout --repair --json 2>/dev/null) || return 1
  converged=$(printf '%s' "$out" | jq -r '.repair.converged // empty' 2>/dev/null)
  [ "$converged" = "true" ] && return 1
  summary=$(fm_herdr_layout_counts_summary "$out") || return 1
  [ -n "$summary" ] || return 1
  printf 'healed herdr layout drift: %s\n' "$summary"
}

# fm_herdr_layout_drift: run the read-only `layout --repair --dry-run` on the
# watcher's heartbeat cadence and echo a compact drift signature when the live
# workspace has DRIFTED from its plan, or nothing when converged / not
# applicable / the probe failed. The signature is stable for a given drift shape
# so the caller can dedupe re-surfacing (same drift is not re-woken every
# heartbeat). Never mutates.
fm_herdr_layout_drift() {
  local bin out converged summary
  fm_herdr_layout_applicable || return 1
  bin=$(fm_herdr_layout_bin)
  out=$("$bin" layout --repair --dry-run --json 2>/dev/null) || return 1
  converged=$(printf '%s' "$out" | jq -r '.repair.converged // empty' 2>/dev/null)
  [ "$converged" = "true" ] && return 1
  summary=$(fm_herdr_layout_counts_summary "$out") || return 1
  [ -n "$summary" ] || return 1
  printf '%s\n' "$summary"
}

# fm_herdr_layout_counts_summary: fold a `layout --repair[ --dry-run] --json`
# body into "N husk(s), N rebind, N freed, N adopted" (husk = closed husk panes
# plus orphan husk panes). Empty on a parse failure so callers fail closed to
# "no summary".
fm_herdr_layout_counts_summary() {  # <repair-json>
  printf '%s' "$1" | jq -r '
    (.repair.counts // {}) as $c
    | "\((($c.huskClosed // 0) + ($c.orphanHuskClosed // 0))) husk(s), "
      + "\(($c.rebound // 0)) rebind, "
      + "\(($c.freed // 0)) freed, "
      + "\(($c.adopted // 0)) adopted"
  ' 2>/dev/null
}
