#!/usr/bin/env bash
# Single owner of the scaffold blocks bin/fm-brief.sh renders into more than one
# brief kind: the worker status protocol (ship and scout rules 4-8, composed
# around the rule strings bin/fm-brief.sh passes in), the shared States line
# every kind carries, and the subagent model-tier block every kind carries.
# Before this owner existed the status protocol was written three times and the
# daemon rule twice, so one wording fix had to be applied in every copy or the
# scaffolds silently drifted apart.
#
# Ship and scout share one status contract. Their phase guidance differs.
#
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

# fm_brief_states_line <paused-verb> prints the one line naming the status states
# a worker may append. Every brief kind carries it verbatim.
fm_brief_states_line() {  # <paused-verb>
  local paused_verb=$1
  echo "States: working, needs-decision, blocked, $paused_verb, done, failed."
}

# fm_brief_worker_rules <ship|scout> <paused-verb> <status-append-command>
#   <ask-user-block> <pause-instructions> <shared-infra-rule> <shared-no-cd-rule>
# prints rules 4 through 8 of a crewmate brief on stdout with no trailing blank
# line. A secondmate charter has its own escalation contract and does not use it.
# bin/fm-brief.sh owns the status append command (the plain append plus the
# opt-in fleet ledger), the pause instructions, the shared infrastructure rule 7,
# and the leading-cd rule 8, and passes each in verbatim, so upstream wording
# changes to them land in bin/fm-brief.sh and need no fork copy here.
# The ask-user block is empty for a scout.
fm_brief_worker_rules() {  # <kind> <paused-verb> <status-append> <ask-user-block> <pause-instructions> <infra-rule> <no-cd-rule>
  local kind=$1 paused_verb=$2 status_append=$3 ask_user_block=${4:-}
  local pause_instructions=${5:-} infra_rule=${6:-} no_cd_rule=${7:-}
  case "$kind" in
    ship|scout) ;;
    *)
      echo "error: fm_brief_worker_rules: unknown brief kind '$kind'" >&2
      return 1 ;;
  esac
  if [ -z "$status_append" ] || [ -z "$pause_instructions" ] || [ -z "$infra_rule" ] || [ -z "$no_cd_rule" ]; then
    echo "error: fm_brief_worker_rules: the status append command, pause instructions, shared infrastructure rule, and leading-cd rule are required" >&2
    return 1
  fi
  pause_instructions=${pause_instructions%$'\n'}
  infra_rule=${infra_rule%$'\n'}
  no_cd_rule=${no_cd_rule%$'\n'}

  cat <<EOF
4. Report status by appending one line:
   \`$status_append\`
   $(fm_brief_states_line "$paused_verb")
   Replace \`<epoch>\` with the current Unix time in seconds from \`date +%s\`.
   A stamp that is not plain digits records no time.
EOF

  if [ "$kind" = ship ]; then
    cat <<EOF
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
EOF
  else
    cat <<EOF
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
EOF
  fi

  printf '%s\n' "$pause_instructions"
  cat <<EOF
   Whenever you mention a PR, write its full https:// URL exactly as the forge printed it.
   Use that URL, never a bare number such as "PR 108".
   Firstmate copies that URL rather than assembling one from a bare number.
5. If you hit the same obstacle twice, append \`blocked [at=<epoch>]: {why}\` and stop; firstmate will help.
EOF

  if [ "$kind" = ship ]; then
    cat <<'EOF'
6. If a decision belongs above the implementation worker (product choices, destructive actions),
EOF
  else
    cat <<'EOF'
6. If a decision belongs to a human (product choices, destructive actions),
EOF
  fi

  cat <<'EOF'
   append `needs-decision [at=<epoch>]: {summary of options}` and stop. Firstmate will reply with the decision.
EOF
  [ -z "$ask_user_block" ] || printf '%s\n' "$ask_user_block"
  cat <<'EOF'
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved [at=<epoch>]: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume.
EOF
  printf '%s\n%s\n' "$infra_rule" "$no_cd_rule"
}

# fm_brief_subagent_tier_block <fm-root> prints the "# Subagent model tier"
# section every scaffold kind carries on stdout with no trailing blank line.
# The token audit (data/token-audit-a1/report.md) found 96 percent of subagent
# spend ran off-tier because workflow agent() calls omitted a model and
# inherited the orchestrator's own session model. This block is the one place
# that states the rule, so no supervisor has to remember to paste it into a
# brief by hand; the fully authoritative tiers live outside this repo in the
# captain's private data/captain-shared.md, so this block states only the
# fixed default and the hard exclusion, then points at the tracked dispatch
# doc for everything else.
fm_brief_subagent_tier_block() {  # <fm-root>
  local fm_root=$1
  cat <<EOF
# Subagent model tier
Every subagent or workflow \`agent()\` call must pass an explicit model.
The default subagent tier is \`claude-sonnet-5\` unless this brief names another.
A Fable-class model or Haiku must never run as a subagent.
See \`$fm_root/docs/configuration.md\`, section "Crew dispatch profiles", for the full model-tier and dispatch-profile contract.
EOF
}
